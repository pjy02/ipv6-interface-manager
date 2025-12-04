#!/usr/bin/env bash

set -euo pipefail

# =============================
# IPv6 批量配置脚本（精简重写版）
# 功能保持不变：批量生成/应用 IPv6 地址、模板管理、配置导入导出、快照与日志
# =============================

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# 路径
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
CONFIG_DIR="$SCRIPT_DIR/configs"
TEMPLATE_DIR="$SCRIPT_DIR/templates"
BACKUP_DIR="$SCRIPT_DIR/backups"
CONFIG_FILE="$CONFIG_DIR/default.conf"
LOG_FILE="$LOG_DIR/ipv6_config_$(date +%Y%m%d).log"

mkdir -p "$LOG_DIR" "$CONFIG_DIR" "$TEMPLATE_DIR" "$BACKUP_DIR"

# ---------- 日志 ----------
log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] [$level] $msg" >>"$LOG_FILE"
    local color="$NC"
    case "$level" in
        INFO) color="$CYAN";;
        WARN) color="$YELLOW";;
        ERROR) color="$RED";;
        SUCCESS) color="$GREEN";;
    esac
    echo -e "${color}[$level]${NC} $msg"
}

# ---------- 配置 ----------
init_config() {
    [[ -f "$CONFIG_FILE" ]] && return
    cat >"$CONFIG_FILE" <<'CONF'
[general]
default_interface=
default_prefix=2012:f2c4:1:1f34
default_subnet_mask=64
default_start=1
default_end=10
require_confirmation=true

[backup]
retention=10
CONF
    log INFO "已创建默认配置文件 $CONFIG_FILE"
}

read_conf() {
    local key="$1" section="${2:-general}" default="${3:-}"
    [[ -f "$CONFIG_FILE" ]] || { echo "$default"; return; }
    awk -F'=' -v s="[$section]" -v k="$key" -v def="$default" '
        BEGIN { ins=0; found=0 }
        $0==s { ins=1; next }
        /^\[/ { ins=0 }
        ins && $1==k {
            gsub(/^[ \t]+|[ \t]+$/, "", $2)
            print $2
            found=1
            exit
        }
        END { if(!found) print def }
    ' "$CONFIG_FILE"
}

write_conf() {
    local key="$1" value="$2" section="${3:-general}"
    init_config
    python3 - "$CONFIG_FILE" "$section" "$key" "$value" <<'PYCFG'
import sys,configparser
cfg,section,key,value = sys.argv[1:]
parser=configparser.ConfigParser()
parser.read(cfg)
if section not in parser:
    parser[section] = {}
parser[section][key] = value
with open(cfg,'w') as f:
    parser.write(f)
PYCFG
    log INFO "配置已更新: [$section] $key=$value"
}

# ---------- 工具 ----------
ensure_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}需要 root 权限运行${NC}"; exit 1; fi
}

available_interfaces() {
    ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$'
}

pick_interface() {
    local current
    current=$(read_conf default_interface)
    if [[ -n "$current" ]]; then
        echo "$current"; return
    fi
    local list=( $(available_interfaces) )
    if [[ ${#list[@]} -eq 1 ]]; then
        echo "${list[0]}"; return
    fi
    echo -e "${BLUE}请选择网络接口:${NC}"
    select iface in "${list[@]}"; do
        [[ -n "$iface" ]] && { echo "$iface"; return; }
    done
}

format_ipv6() { # prefix host mask -> addr
    local prefix="$1" host="$2" mask="$3"
    printf "%s::%x/%s" "$prefix" "$host" "$mask"
}

# ---------- 地址生成 ----------
generate_range() {
    local prefix="$1" mask="$2" start="$3" end="$4"; shift 4
    local -n out=$1
    out=()
    for ((i=start;i<=end;i++)); do
        out+=("$(format_ipv6 "$prefix" "$i" "$mask")")
    done
}

# ---------- 快照 ----------
create_snapshot() {
    local iface="$1" note="$2"
    local file="$BACKUP_DIR/snapshot_${iface}_$(date +%Y%m%d_%H%M%S).txt"
    ip -6 addr show dev "$iface" >"$file"
    log INFO "已创建快照: $file ($note)"
    prune_snapshots
}

prune_snapshots() {
    local keep
    keep=$(read_conf retention backup 10)
    ls -1t "$BACKUP_DIR"/snapshot_* 2>/dev/null | tail -n +$((keep+1)) | xargs -r rm -f
}

# ---------- 模板 ----------
default_templates() {
    [[ -n $(find "$TEMPLATE_DIR" -maxdepth 1 -name '*.json' -print -quit) ]] && return
    cat >"$TEMPLATE_DIR/web_server.json" <<'TPL'
{"name":"Web服务器","prefix":"2012:f2c4:1:1f34","subnet_mask":64,"addresses":[{"type":"single","value":80},{"type":"single","value":443},{"type":"range","start":3000,"end":3003}]}
TPL
    log INFO "已写入内置模板"
}

list_templates() {
    default_templates
    echo -e "${BLUE}可用模板:${NC}"
    local idx=1
    for f in "$TEMPLATE_DIR"/*.json; do
        local name
        name=$(python3 - <<'PYNAME' "$f"
import sys,json
p=json.load(open(sys.argv[1]));print(p.get('name','(未命名)'))
PYNAME
)
        echo "$idx) $(basename "$f") - $name"; idx=$((idx+1))
    done
}

parse_template() {
    local file="$1"; shift; local -n out=$1
    out=()
    local data
    data=$(python3 - "$file" <<'PYTEMP'
import sys,json
p=json.load(open(sys.argv[1]))
prefix=p.get('prefix'); mask=p.get('subnet_mask')
for item in p.get('addresses', []):
    t=item.get('type')
    if t=='single' and 'value' in item:
        print(prefix,mask,item['value'])
    elif t=='range' and all(k in item for k in ('start','end')):
        print(prefix,mask, str(item['start'])+':'+str(item['end']))
PYTEMP
)
    while read -r line; do
        [[ -z "$line" ]] && continue
        local prefix mask token
        prefix=$(echo "$line" | awk '{print $1}')
        mask=$(echo "$line" | awk '{print $2}')
        token=$(echo "$line" | awk '{print $3}')
        if [[ "$token" == *:* ]]; then
            local s=${token%:*}; local e=${token#*:}
            local tmp=()
            generate_range "$prefix" "$mask" "$s" "$e" tmp
            out+=("${tmp[@]}")
        else
            out+=("$(format_ipv6 "$prefix" "$token" "$mask")")
        fi
    done <<<"$data"
}

apply_template() {
    local file="$1" iface="$2"
    [[ -f "$file" ]] || { log ERROR "模板不存在 $file"; return 1; }
    local addrs=()
    parse_template "$file" addrs
    [[ ${#addrs[@]} -gt 0 ]] || { log WARN "模板中无地址"; return 1; }
    create_snapshot "$iface" "apply-template"
    batch_add "$iface" addrs
}

# ---------- 地址操作 ----------
batch_add() {
    local iface="$1"; shift; local -n arr=$1
    local ok=0 fail=0
    for addr in "${arr[@]}"; do
        if ip -6 addr add "$addr" dev "$iface" 2>/dev/null; then
            log SUCCESS "添加成功: $addr"
            ((ok++))
        else
            log ERROR "添加失败: $addr"
            ((fail++))
        fi
    done
    echo -e "${GREEN}成功${NC}: $ok, ${RED}失败${NC}: $fail"
}

# ---------- 导入导出 ----------
export_config() {
    local iface="$1" file="$2"
    ip -6 addr show dev "$iface" | awk '/inet6/{print $2}' | sed 's/^/    "/;s/$/",/' >"$file.tmp"
    cat >"$file" <<EOF
{
  "interface": "$iface",
  "timestamp": "$(date -Iseconds)",
  "addresses": [
$(sed '$s/,$//' "$file.tmp")
  ]
}
EOF
    rm -f "$file.tmp"
    log SUCCESS "已导出到 $file"
}

import_config() {
    local iface="$1" file="$2"
    [[ -f "$file" ]] || { log ERROR "文件不存在 $file"; return 1; }
    local addrs=($(python3 - "$file" <<'PYIMP'
import sys,json
for a in json.load(open(sys.argv[1])).get('addresses', []):
    print(a)
PYIMP
))
    [[ ${#addrs[@]} -gt 0 ]] || { log WARN "没有可导入的地址"; return 1; }
    create_snapshot "$iface" "import"
    batch_add "$iface" addrs
}

# ---------- 主流程 ----------
add_from_input() {
    local iface prefix mask start end
    iface=$(pick_interface)
    read -rp "前缀 (默认 $(read_conf default_prefix)): " prefix
    prefix=${prefix:-$(read_conf default_prefix)}
    read -rp "子网掩码 (默认 $(read_conf default_subnet_mask)): " mask
    mask=${mask:-$(read_conf default_subnet_mask)}
    read -rp "起始编号 (默认 $(read_conf default_start)): " start
    start=${start:-$(read_conf default_start)}
    read -rp "结束编号 (默认 $(read_conf default_end)): " end
    end=${end:-$(read_conf default_end)}
    local addrs=()
    generate_range "$prefix" "$mask" "$start" "$end" addrs
    create_snapshot "$iface" "manual-range"
    batch_add "$iface" addrs
}

apply_template_flow() {
    local iface file
    iface=$(pick_interface)
    list_templates
    read -rp "输入模板文件名: " file
    file="$TEMPLATE_DIR/${file%.json}.json"
    apply_template "$file" "$iface"
}

export_flow() {
    local iface file
    iface=$(pick_interface)
    read -rp "导出文件名 (默认 export.json): " file
    file=${file:-export.json}
    export_config "$iface" "$file"
}

import_flow() {
    local iface file
    iface=$(pick_interface)
    read -rp "导入文件路径: " file
    import_config "$iface" "$file"
}

main_menu() {
    init_config
    default_templates
    while true; do
        echo -e "${WHITE}=== IPv6 批量配置 ===${NC}"
        echo "1) 批量添加地址"
        echo "2) 应用模板"
        echo "3) 导出配置"
        echo "4) 导入配置"
        echo "5) 设置默认接口"
        echo "0) 退出"
        read -rp "选择操作: " opt
        case "$opt" in
            1) add_from_input;;
            2) apply_template_flow;;
            3) export_flow;;
            4) import_flow;;
            5) local iface; iface=$(pick_interface); write_conf default_interface "$iface"; log SUCCESS "默认接口已设为 $iface";;
            0) exit 0;;
            *) echo "无效选择";;
        esac
    done
}

ensure_root
main_menu

