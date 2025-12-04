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
PERSIST_DIR="/etc/network/interfaces.d"

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

current_default_gateway() {
    local iface="$1"
    local route
    route=$(ip -6 route show default 2>/dev/null | grep " dev $iface" | head -n1 || true)
    [[ -z "$route" ]] && return 0
    echo "$route" | awk '{for(i=1;i<=NF;i++) if($i=="via") {print $(i+1); exit}}'
}

detect_ipv6_gateway() {
    local iface="$1"
    ip -6 neigh show dev "$iface" | awk '/router/ {print $1; exit}'
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

# ---------- 持久化 ----------
persist_addresses() {
    local iface="$1"; shift; local -n arr=$1
    local gateway="${2:-}"
    local file="/etc/network/interfaces"
    log INFO "持久化目标: $file (写入静态 IPv6 配置)"

    # 若未传入网关则尝试检测
    if [[ -z "$gateway" ]]; then
        gateway=$(detect_ipv6_gateway "$iface")
        [[ -n "$gateway" ]] && log INFO "已自动检测到网关 $gateway 用于持久化"
    fi

    local ts
    ts=$(date -Iseconds)

    python3 - "$file" "$iface" "$ts" "$gateway" "${arr[@]}" <<'PYMAIN'
import sys, pathlib

path_str, iface, ts, gateway, *addrs = sys.argv[1:]
path = pathlib.Path(path_str)

def split_addr(addr):
    if '/' not in addr:
        raise ValueError(f"地址缺少掩码: {addr}")
    ip, mask = addr.split('/', 1)
    return ip, mask

lines = []
if path.exists():
    try:
        lines = path.read_text().splitlines()
    except OSError:
        lines = []

begin = f"# BEGIN ipv6-batch-{iface}"
end = f"# END ipv6-batch-{iface}"

# 清理旧的标记块
cleaned = []
skip = False
for line in lines:
    if line.strip() == begin:
        skip = True
        continue
    if skip and line.strip() == end:
        skip = False
        continue
    if not skip:
        cleaned.append(line)

lines = cleaned

# 准备主地址与掩码
if not addrs:
    sys.exit("no addresses to persist")

primary_ip, primary_mask = split_addr(addrs[0])
secondary = addrs[1:]

block = [
    begin,
    f"# Generated by ipv6_batch_config.sh at {ts}",
    f"auto {iface}",
    f"iface {iface} inet6 static",
    f"    accept_ra 0",
    f"    address {primary_ip}",
    f"    netmask {primary_mask}",
]

for extra in secondary:
    block.append(f"    up /sbin/ip -6 addr add {extra} dev {iface}")
    block.append(f"    down /sbin/ip -6 addr del {extra} dev {iface} 2>/dev/null")

if gateway:
    block.append(f"    # persisted-gateway {gateway}")
    block.append(f"    gateway {gateway}")
else:
    block.append("    # persisted-gateway auto-detect")
    block.append(
        "    up /bin/sh -c 'gw=$(ip -6 neigh show dev \"" + iface + "\" | awk \"/router/ {print $1; exit}\"); "
        "[ -n \"$gw\" ] && /sbin/ip -6 route replace default via \"$gw\" dev \"" + iface + "\"'"
    )

block.append(end)

# 追加到文件末尾，确保结尾有空行
if lines and lines[-1].strip():
    lines.append('')

lines.extend(block)
lines.append('')

try:
    path.write_text('\n'.join(lines))
except OSError as exc:
    sys.exit(f"write failed: {exc}")
PYMAIN
    log SUCCESS "持久化配置已写入 $file"
}

ask_persist() {
    local iface="$1"; shift; local -n arr=$1
    local gw
    gw=$(current_default_gateway "$iface")
    read -rp "是否写入 /etc/network/interfaces 以便重启后生效? [y/N]: " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        persist_addresses "$iface" arr "$gw"
    else
        log INFO "已跳过持久化，当前地址仅对本次启动有效"
    fi
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
    ask_persist "$iface" addrs
}

# ---------- 诊断 ----------
collect_persistent_ipv6() {
    local iface="$1"
    python3 - "$iface" <<'PYCOL'
import sys, glob, re
iface=sys.argv[1]
files=['/etc/network/interfaces']+glob.glob('/etc/network/interfaces.d/*')
addrs=[]
for path in files:
    try:
        lines=open(path).read().splitlines()
    except OSError:
        continue
    current=None
    pending_addr=None
    pending_mask=None
    for raw in lines:
        line=raw.split('#',1)[0].strip()
        if not line:
            continue
        m=re.match(r'^iface\s+(\S+)\s+inet6\b', line)
        if m:
            current=m.group(1)
            pending_addr=None; pending_mask=None
            continue
        if current!=iface:
            continue
        m=re.search(r'ip\s+-6\s+addr\s+add\s+([0-9a-fA-F:]+/\d+)', line)
        if m:
            addrs.append(m.group(1)); continue
        m=re.match(r'address\s+([0-9a-fA-F:]+)', line)
        if m:
            pending_addr=m.group(1); continue
        m=re.match(r'netmask\s+(\d+)', line)
        if m and pending_addr:
            addrs.append(f"{pending_addr}/{m.group(1)}")
            pending_addr=None; pending_mask=None

print('\n'.join(dict.fromkeys(addrs)))
PYCOL
}

collect_persistent_gateway() {
    local iface="$1"
    python3 - "$iface" <<'PYGW'
import sys, glob, re
iface=sys.argv[1]
files=['/etc/network/interfaces']+glob.glob('/etc/network/interfaces.d/*')
last=None
for path in files:
    try:
        lines=open(path).read().splitlines()
    except OSError:
        continue
    current=None
    for raw in lines:
        line=raw.split('#',1)[0].strip()
        if not line:
            continue
        m=re.search(r'persisted-gateway\s+([0-9a-fA-F:]+)', raw)
        if m:
            last=m.group(1)
        m=re.search(r'persisted-gateway\s+([0-9a-fA-F:]+)', line)
        if m:
            last=m.group(1)
        m=re.match(r'^iface\s+(\S+)\s+inet6\b', line)
        if m:
            current=m.group(1)
            continue
        if current!=iface:
            continue
        m=re.search(r'route\s+(?:replace|add)\s+default\s+via\s+([0-9a-fA-F:]+)', line)
        if m:
            last=m.group(1)
        m=re.match(r'^gateway\s+([0-9a-fA-F:]+)', line)
        if m:
            last=m.group(1)

if last:
    print(last)
PYGW
}

diagnose_ipv6() {
    local iface
    iface=$(pick_interface)
    echo -e "${WHITE}--- IPv6 连通性诊断 ($iface) ---${NC}"

    echo "[1/5] 测试本地 IPv6 栈 (::1)"
    if ping -6 -c 2 ::1 >/dev/null 2>&1; then
        log SUCCESS "本地 IPv6 栈正常"
    else
        log ERROR "本地 IPv6 栈 ping 失败，检查内核/防火墙"
    fi

    echo "[2/5] 检查接口地址"
    local runtime_addrs
    runtime_addrs=($(ip -6 addr show dev "$iface" | awk '/inet6/{print $2}'))
    if [[ ${#runtime_addrs[@]} -eq 0 ]]; then
        log ERROR "$iface 未分配 IPv6 地址"
    else
        for a in "${runtime_addrs[@]}"; do log INFO "已配置: $a"; done
    fi

    echo "[3/5] 检查网关与路由"
    local default_route gw runtime_gw
    runtime_gw=$(current_default_gateway "$iface")
    default_route=$(ip -6 route show default 2>/dev/null | grep " dev $iface" || true)
    if [[ -z "$default_route" ]]; then
        log WARN "未找到默认 IPv6 路由，尝试自动检测网关..."
        gw=$(detect_ipv6_gateway "$iface")
        if [[ -n "$gw" ]]; then
            log INFO "检测到网关: $gw (link-local)"
            if ip -6 route replace default via "$gw" dev "$iface"; then
                runtime_gw="$gw"
                log SUCCESS "已成功添加默认路由"
            else
                log ERROR "自动添加默认路由失败"
            fi
        else
            log ERROR "未能自动检测到 IPv6 网关"
        fi
    else
        log SUCCESS "默认路由: $default_route"
        gw=$(echo "$default_route" | awk '{for(i=1;i<=NF;i++) if($i=="via") {print $(i+1); exit}}')
        runtime_gw="$gw"
    fi

    if [[ -n "$runtime_gw" ]]; then
        local target="$runtime_gw"
        [[ "$runtime_gw" == fe80::* ]] && target="$runtime_gw%$iface"
        if ping -6 -c 2 "$target" >/dev/null 2>&1; then
            log SUCCESS "网关可达 ($runtime_gw)"
        else
            log WARN "网关暂不可达: $runtime_gw"
        fi
    fi

    echo "[4/5] 外网连通性测试"
    local public_target="240c::6666"
    if ping -6 -c 3 "$public_target" >/dev/null 2>&1; then
        log SUCCESS "外网 IPv6 可用 ($public_target)"
    else
        log ERROR "外网 IPv6 不可达，可能是上游或路由问题"
    fi

    echo "[5/5] 路由表与邻居检查"
    ip -6 route show dev "$iface" | sed 's/^/    /'
    ip -6 neigh show dev "$iface" | sed 's/^/    /'

    echo "--- 持久化配置对比 ---"
    local persisted
    persisted=($(collect_persistent_ipv6 "$iface"))
    if [[ ${#persisted[@]} -eq 0 ]]; then
        log WARN "/etc/network/interfaces* 未找到 $iface 的 IPv6 配置"
    else
        for a in "${persisted[@]}"; do log INFO "配置文件: $a"; done
    fi

    if [[ ${#runtime_addrs[@]} -gt 0 ]]; then
        local mismatch=()
        for a in "${runtime_addrs[@]}"; do
            local base="${a%%/*}"
            local found=0
            for p in "${persisted[@]}"; do
                [[ "${p%%/*}" == "$base" ]] && { found=1; break; }
            done
            ((found==0)) && mismatch+=("$a")
        done
        if [[ ${#mismatch[@]} -gt 0 ]]; then
            log WARN "以下地址未写入 /etc/network/interfaces*，重启后会丢失:"
            for m in "${mismatch[@]}"; do echo "    $m"; done
            read -rp "是否将当前地址写入持久化配置并修复? [y/N]: " fix
            if [[ "$fix" =~ ^[Yy]$ ]]; then
                persist_addresses "$iface" runtime_addrs "$runtime_gw"
            else
                log INFO "已跳过修复"
            fi
        else
            log SUCCESS "持久化配置与当前地址一致"
        fi
    fi

    local persisted_gw
    persisted_gw=$(collect_persistent_gateway "$iface")
    if [[ -n "$runtime_gw" && -z "$persisted_gw" ]]; then
        log WARN "默认路由 ($runtime_gw) 未写入 /etc/network/interfaces*，重启后会丢失"
        read -rp "是否将当前默认路由写入持久化配置? [y/N]: " route_ans
        if [[ "$route_ans" =~ ^[Yy]$ ]]; then
            persist_addresses "$iface" runtime_addrs "$runtime_gw"
        else
            log INFO "已跳过路由持久化"
        fi
    elif [[ -n "$runtime_gw" && -n "$persisted_gw" && "$runtime_gw" != "$persisted_gw" ]]; then
        log WARN "持久化网关 ($persisted_gw) 与当前默认路由 ($runtime_gw) 不一致"
        read -rp "是否更新持久化网关为 $runtime_gw ? [y/N]: " update_route
        if [[ "$update_route" =~ ^[Yy]$ ]]; then
            persist_addresses "$iface" runtime_addrs "$runtime_gw"
        else
            log INFO "已保留原有持久化网关"
        fi
    elif [[ -z "$runtime_gw" && -n "$persisted_gw" ]]; then
        if [[ "$persisted_gw" != fe80::* ]]; then
            log WARN "配置文件包含默认路由 $persisted_gw (非 link-local)，优先尝试重新检测网关"
            gw=$(detect_ipv6_gateway "$iface")
            if [[ -n "$gw" ]]; then
                read -rp "是否改用检测到的网关 $gw 并写入持久化? [y/N]: " choose_gw
                if [[ "$choose_gw" =~ ^[Yy]$ ]]; then
                    runtime_gw="$gw"
                    ip -6 route replace default via "$gw" dev "$iface" && log SUCCESS "已切换默认路由" || log ERROR "切换默认路由失败"
                    persist_addresses "$iface" runtime_addrs "$gw"
                    return
                fi
            fi
        fi
        log WARN "配置文件包含默认路由 $persisted_gw，但当前系统未设置"
        read -rp "是否立即添加该默认路由? [y/N]: " apply_route
        if [[ "$apply_route" =~ ^[Yy]$ ]]; then
            if ip -6 route replace default via "$persisted_gw" dev "$iface"; then
                log SUCCESS "已按配置文件添加默认路由"
            else
                log ERROR "添加默认路由失败，请检查接口和网关"
            fi
        fi
    else
        log SUCCESS "默认路由与持久化配置一致"
    fi
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
    ask_persist "$iface" addrs
}

apply_template_flow() {
    local iface file
    iface=$(pick_interface)
    list_templates
    read -rp "输入模板文件名: " file
    file="$TEMPLATE_DIR/${file%.json}.json"
    apply_template "$file" "$iface"
    local addrs=()
    parse_template "$file" addrs
    [[ ${#addrs[@]} -gt 0 ]] && ask_persist "$iface" addrs
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
        echo "6) IPv6 诊断"
        echo "0) 退出"
        read -rp "选择操作: " opt
        case "$opt" in
            1) add_from_input;;
            2) apply_template_flow;;
            3) export_flow;;
            4) import_flow;;
            5) local iface; iface=$(pick_interface); write_conf default_interface "$iface"; log SUCCESS "默认接口已设为 $iface";;
            6) diagnose_ipv6;;
            0) exit 0;;
            *) echo "无效选择";;
        esac
    done
}

ensure_root
main_menu

