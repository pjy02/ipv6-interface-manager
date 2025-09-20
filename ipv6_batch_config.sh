#!/bin/bash

# IPv6批量配置脚本
# 作者: CodeBuddy
# 版本: 1.0
# 描述: Ubuntu服务器IPv6地址批量配置工具，提供交互式界面

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# 全局变量
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
CONFIG_DIR="$SCRIPT_DIR/configs"
TEMPLATE_DIR="$SCRIPT_DIR/templates"
CONFIG_FILE="$CONFIG_DIR/default.conf"
LOG_FILE="$LOG_DIR/ipv6_config_$(date +%Y%m%d).log"
BACKUP_DIR="$SCRIPT_DIR/backups"
OPERATION_HISTORY="$BACKUP_DIR/operation_history.json"

# 创建必要的目录
mkdir -p "$LOG_DIR"
mkdir -p "$BACKUP_DIR"
mkdir -p "$CONFIG_DIR"
mkdir -p "$TEMPLATE_DIR"

# 日志函数
log_message() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    
    case $level in
        "INFO")
            echo -e "${GREEN}[INFO]${NC} $message"
            ;;
        "WARN")
            echo -e "${YELLOW}[WARN]${NC} $message"
            ;;
        "ERROR")
            echo -e "${RED}[ERROR]${NC} $message"
            ;;
        "SUCCESS")
            echo -e "${GREEN}[SUCCESS]${NC} $message"
            ;;
    esac
}

# 通用IPv6地址添加函数 - 提供详细的错误信息
add_ipv6_address_with_details() {
    local addr="$1"
    local interface="$2"
    local show_progress="${3:-true}"
    
    if [[ "$show_progress" == "true" ]]; then
        echo -n "添加 $addr ... "
    fi
    
    # 尝试添加IPv6地址并捕获错误信息
    local error_output
    error_output=$(ip -6 addr add "$addr" dev "$interface" 2>&1)
    local exit_code=$?
    
    if [[ $exit_code -eq 0 ]]; then
        if [[ "$show_progress" == "true" ]]; then
            echo -e "${GREEN}成功${NC}"
        fi
        log_message "SUCCESS" "成功添加IPv6地址: $addr 到接口 $interface"
        return 0
    else
        # 分析失败原因
        local failure_reason="未知错误"
        if [[ "$error_output" =~ "File exists" ]] || [[ "$error_output" =~ "RTNETLINK answers: File exists" ]]; then
            failure_reason="地址已存在"
        elif [[ "$error_output" =~ "No such device" ]] || [[ "$error_output" =~ "Cannot find device" ]]; then
            failure_reason="网络接口不存在"
        elif [[ "$error_output" =~ "Invalid argument" ]]; then
            failure_reason="无效的IPv6地址格式"
        elif [[ "$error_output" =~ "Permission denied" ]] || [[ "$error_output" =~ "Operation not permitted" ]]; then
            failure_reason="权限不足"
        elif [[ "$error_output" =~ "Network is unreachable" ]]; then
            failure_reason="网络不可达"
        elif [[ "$error_output" =~ "Cannot assign requested address" ]]; then
            failure_reason="无法分配请求的地址"
        fi
        
        if [[ "$show_progress" == "true" ]]; then
            echo -e "${RED}失败 (${failure_reason})${NC}"
        fi
        log_message "ERROR" "添加IPv6地址失败: $addr 到接口 $interface - 原因: $failure_reason"
        return 1
    fi
}

# 配置文件和模板系统

# 初始化默认配置文件
init_default_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_message "INFO" "创建默认配置文件: $CONFIG_FILE"
        
        cat > "$CONFIG_FILE" << 'EOF'
# IPv6批量配置工具 - 默认配置文件
# 配置文件版本: 1.0

[general]
# 默认网络接口 (留空为自动选择)
default_interface=

# 默认子网掩码长度
default_subnet_mask=64

# 操作确认模式 (true/false)
require_confirmation=true

# 自动创建快照 (true/false)
auto_snapshot=true

# 日志级别 (INFO/WARN/ERROR)
log_level=INFO

[ipv6]
# 默认IPv6前缀
default_prefix=2012:f2c4:1:1f34

# 默认地址范围起始
default_start=1

# 默认地址范围结束
default_end=10

[templates]
# 启用的模板目录
template_dir=templates

# 自动加载模板 (true/false)
auto_load_templates=true

[backup]
# 最大快照数量
max_snapshots=50

# 快照保留天数
snapshot_retention_days=30

# 自动清理旧快照 (true/false)
auto_cleanup=true
EOF
        
        echo -e "${GREEN}✓${NC} 默认配置文件已创建"
    fi
}

# 读取配置文件
read_config() {
    local key=$1
    local section=$2
    local default_value=$3
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "$default_value"
        return
    fi
    
    local value
    if [[ -n "$section" ]]; then
        # 读取指定section下的key
        value=$(awk -F'=' -v section="[$section]" -v key="$key" '
            $0 == section { in_section = 1; next }
            /^\[/ && in_section { in_section = 0 }
            in_section && $1 == key { gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit }
        ' "$CONFIG_FILE")
    else
        # 读取全局key
        value=$(awk -F'=' -v key="$key" '
            !/^#/ && !/^\[/ && $1 == key { gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit }
        ' "$CONFIG_FILE")
    fi
    
    echo "${value:-$default_value}"
}

# 写入配置文件
write_config() {
    local key=$1
    local value=$2
    local section=$3
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        init_default_config
    fi
    
    local temp_file=$(mktemp)
    
    if [[ -n "$section" ]]; then
        # 更新指定section下的key
        awk -F'=' -v section="[$section]" -v key="$key" -v value="$value" '
            BEGIN { updated = 0 }
            $0 == section { in_section = 1; print; next }
            /^\[/ && in_section && !updated { 
                print key "=" value
                updated = 1
                in_section = 0
                print
                next
            }
            /^\[/ && in_section { in_section = 0 }
            in_section && $1 == key { 
                print key "=" value
                updated = 1
                next
            }
            { print }
            END { 
                if (!updated && in_section) {
                    print key "=" value
                }
            }
        ' "$CONFIG_FILE" > "$temp_file"
    else
        # 更新全局key
        awk -F'=' -v key="$key" -v value="$value" '
            BEGIN { updated = 0 }
            !/^#/ && !/^\[/ && $1 == key { 
                print key "=" value
                updated = 1
                next
            }
            { print }
            END { 
                if (!updated) {
                    print key "=" value
                }
            }
        ' "$CONFIG_FILE" > "$temp_file"
    fi
    
    mv "$temp_file" "$CONFIG_FILE"
    log_message "INFO" "配置已更新: $key=$value"
}

# 创建内置模板
create_builtin_templates() {
    # 家庭服务器模板
    cat > "$TEMPLATE_DIR/home_server.json" << 'EOF'
{
    "name": "家庭服务器",
    "description": "适用于家庭服务器的IPv6配置，包含常用服务端口",
    "version": "1.0",
    "author": "CodeBuddy",
    "config": {
        "prefix": "2012:f2c4:1:1f34",
        "subnet_mask": 64,
        "addresses": [
            {"type": "range", "start": 1, "end": 5},
            {"type": "single", "value": 80},
            {"type": "single", "value": 443},
            {"type": "single", "value": 22}
        ]
    },
    "tags": ["home", "server", "basic"]
}
EOF

    # Web服务器模板
    cat > "$TEMPLATE_DIR/web_server.json" << 'EOF'
{
    "name": "Web服务器",
    "description": "Web服务器常用端口配置",
    "version": "1.0",
    "author": "CodeBuddy",
    "config": {
        "prefix": "2012:f2c4:1:1f34",
        "subnet_mask": 64,
        "addresses": [
            {"type": "single", "value": 80, "description": "HTTP"},
            {"type": "single", "value": 443, "description": "HTTPS"},
            {"type": "single", "value": 8080, "description": "HTTP备用"},
            {"type": "single", "value": 8443, "description": "HTTPS备用"},
            {"type": "range", "start": 3000, "end": 3010, "description": "开发端口"}
        ]
    },
    "tags": ["web", "server", "http", "https"]
}
EOF

    # 邮件服务器模板
    cat > "$TEMPLATE_DIR/mail_server.json" << 'EOF'
{
    "name": "邮件服务器",
    "description": "邮件服务器端口配置",
    "version": "1.0",
    "author": "CodeBuddy",
    "config": {
        "prefix": "2012:f2c4:1:1f34",
        "subnet_mask": 64,
        "addresses": [
            {"type": "single", "value": 25, "description": "SMTP"},
            {"type": "single", "value": 110, "description": "POP3"},
            {"type": "single", "value": 143, "description": "IMAP"},
            {"type": "single", "value": 465, "description": "SMTPS"},
            {"type": "single", "value": 587, "description": "SMTP提交"},
            {"type": "single", "value": 993, "description": "IMAPS"},
            {"type": "single", "value": 995, "description": "POP3S"}
        ]
    },
    "tags": ["mail", "server", "smtp", "imap", "pop3"]
}
EOF

    # 测试环境模板
    cat > "$TEMPLATE_DIR/test_environment.json" << 'EOF'
{
    "name": "测试环境",
    "description": "开发和测试环境的IPv6配置",
    "version": "1.0",
    "author": "CodeBuddy",
    "config": {
        "prefix": "2012:f2c4:1:1f34",
        "subnet_mask": 64,
        "addresses": [
            {"type": "range", "start": 100, "end": 110, "description": "测试地址池"},
            {"type": "range", "start": 200, "end": 205, "description": "开发环境"},
            {"type": "single", "value": 9000, "description": "监控端口"}
        ]
    },
    "tags": ["test", "development", "staging"]
}
EOF

    # 大型网络模板
    cat > "$TEMPLATE_DIR/enterprise.json" << 'EOF'
{
    "name": "企业网络",
    "description": "大型企业网络IPv6配置",
    "version": "1.0",
    "author": "CodeBuddy",
    "config": {
        "prefix": "2012:f2c4:1:1f34",
        "subnet_mask": 64,
        "addresses": [
            {"type": "range", "start": 1, "end": 100, "description": "服务器池"},
            {"type": "range", "start": 1000, "end": 1050, "description": "应用服务"},
            {"type": "range", "start": 2000, "end": 2020, "description": "数据库服务"}
        ]
    },
    "tags": ["enterprise", "large", "production"]
}
EOF

    log_message "INFO" "内置模板已创建"
}

# 列出可用模板
list_templates() {
    echo -e "${BLUE}=== 📋 可用配置模板 ===${NC}"
    echo
    
    local templates=($(find "$TEMPLATE_DIR" -name "*.json" -type f 2>/dev/null))
    
    if [[ ${#templates[@]} -eq 0 ]]; then
        echo -e "${YELLOW}没有找到配置模板${NC}"
        echo -e "${CYAN}正在创建内置模板...${NC}"
        create_builtin_templates
        templates=($(find "$TEMPLATE_DIR" -name "*.json" -type f 2>/dev/null))
    fi
    
    echo -e "${WHITE}模板列表:${NC}"
    echo
    
    for i in "${!templates[@]}"; do
        local template_file="${templates[$i]}"
        local template_name=$(basename "$template_file" .json)
        
        # 尝试读取模板信息
        local name=$(grep '"name":' "$template_file" 2>/dev/null | cut -d'"' -f4)
        local description=$(grep '"description":' "$template_file" 2>/dev/null | cut -d'"' -f4)
        local tags=$(grep '"tags":' "$template_file" 2>/dev/null | sed 's/.*"tags": \[\(.*\)\].*/\1/' | tr -d '"' | tr ',' ' ')
        
        name=${name:-$template_name}
        description=${description:-"无描述"}
        
        echo -e "${WHITE}$((i+1)).${NC} ${GREEN}$name${NC}"
        echo -e "    描述: ${CYAN}$description${NC}"
        if [[ -n "$tags" ]]; then
            echo -e "    标签: ${YELLOW}$tags${NC}"
        fi
        echo -e "    文件: ${template_name}.json"
        echo
    done
    
    return ${#templates[@]}
}

# 应用模板配置
apply_template() {
    local template_file=$1
    local interface=$2
    
    if [[ ! -f "$template_file" ]]; then
        log_message "ERROR" "模板文件不存在: $template_file"
        return 1
    fi
    
    log_message "INFO" "应用模板: $template_file"
    
    # 读取模板信息
    local template_name=$(grep '"name":' "$template_file" | cut -d'"' -f4)
    local prefix=$(grep '"prefix":' "$template_file" | cut -d'"' -f4)
    local subnet_mask=$(grep '"subnet_mask":' "$template_file" | grep -o '[0-9]*')
    
    echo -e "${BLUE}=== 📋 应用模板: ${GREEN}$template_name${NC} ===${NC}"
    echo -e "接口: ${GREEN}$interface${NC}"
    echo -e "前缀: ${GREEN}$prefix${NC}"
    echo -e "子网掩码: ${GREEN}/$subnet_mask${NC}"
    echo
    
    # 创建操作前快照
    local snapshot_file=$(create_snapshot "$interface" "template" "应用模板 $template_name 前的备份")
    echo -e "${GREEN}✓${NC} 快照已保存: $(basename "$snapshot_file")"
    echo
    
    # 解析地址配置
    local addresses=()
    parse_template_addresses "$template_file" addresses
    
    if [[ ${#addresses[@]} -eq 0 ]]; then
        log_message "ERROR" "模板中没有找到有效的地址配置"
        return 1
    fi
    
    echo -e "${CYAN}将要配置的地址:${NC}"
    for addr in "${addresses[@]}"; do
        echo -e "  ${WHITE}•${NC} $addr"
    done
    
    echo
    echo -e "总计: ${GREEN}${#addresses[@]}${NC} 个地址"
    
    # 确认应用
    local auto_confirm=$(read_config "require_confirmation" "general" "true")
    if [[ "$auto_confirm" == "false" ]]; then
        local confirm="y"
    else
        read -p "确认应用此模板? (y/N): " confirm
    fi
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}模板应用已取消${NC}"
        return 0
    fi
    
    # 开始应用模板
    echo
    echo -e "${BLUE}=== 🚀 开始应用模板 ===${NC}"
    
    local success_count=0
    local error_count=0
    
    for addr in "${addresses[@]}"; do
        echo -n "配置 $addr ... "
        
        if ip -6 addr add "$addr" dev "$interface" 2>/dev/null; then
            echo -e "${GREEN}成功${NC}"
            log_message "SUCCESS" "模板应用成功添加IPv6地址: $addr"
            ((success_count++))
        else
            echo -e "${RED}失败${NC}"
            log_message "ERROR" "模板应用添加IPv6地址失败: $addr"
            ((error_count++))
        fi
        
        sleep 0.1
    done
    
    echo
    echo -e "${BLUE}=== ✅ 模板应用完成 ===${NC}"
    echo -e "成功: ${GREEN}$success_count${NC} 个地址"
    echo -e "失败: ${RED}$error_count${NC} 个地址"
    
    log_message "SUCCESS" "模板 $template_name 应用完成: 成功 $success_count 个，失败 $error_count 个"
    
    return 0
}

# 解析模板地址配置
parse_template_addresses() {
    local template_file=$1
    local -n result_array=$2
    
    # 提取prefix和subnet_mask
    local prefix=$(grep '"prefix":' "$template_file" | cut -d'"' -f4)
    local subnet_mask=$(grep '"subnet_mask":' "$template_file" | grep -o '[0-9]*')
    
    # 提取addresses数组内容
    local in_addresses=false
    local current_address=""
    
    while IFS= read -r line; do
        # 检查是否进入addresses数组
        if [[ "$line" =~ \"addresses\".*\[ ]]; then
            in_addresses=true
            continue
        fi
        
        # 检查是否退出addresses数组
        if [[ "$in_addresses" == true && "$line" =~ ^\s*\] ]]; then
            break
        fi
        
        # 处理addresses数组中的内容
        if [[ "$in_addresses" == true ]]; then
            if [[ "$line" =~ \{.*\"type\".*\"range\" ]]; then
                # 范围类型
                local start=$(echo "$line" | grep -o '"start": [0-9]*' | grep -o '[0-9]*')
                local end=$(echo "$line" | grep -o '"end": [0-9]*' | grep -o '[0-9]*')
                
                if [[ -n "$start" && -n "$end" ]]; then
                    for ((i=start; i<=end; i++)); do
                        result_array+=("$prefix::$i/$subnet_mask")
                    done
                fi
                
            elif [[ "$line" =~ \{.*\"type\".*\"single\" ]]; then
                # 单个值类型
                local value=$(echo "$line" | grep -o '"value": [0-9]*' | grep -o '[0-9]*')
                
                if [[ -n "$value" ]]; then
                    result_array+=("$prefix::$value/$subnet_mask")
                fi
            fi
        fi
    done < "$template_file"
}

# 保存当前配置为模板
save_as_template() {
    local interface=$1
    
    echo -e "${BLUE}=== 💾 保存当前配置为模板 ===${NC}"
    echo
    
    # 获取当前IPv6配置
    local ipv6_addrs=($(ip -6 addr show "$interface" 2>/dev/null | grep "inet6" | grep -v "fe80" | awk '{print $2}'))
    
    if [[ ${#ipv6_addrs[@]} -eq 0 ]]; then
        echo -e "${YELLOW}接口 $interface 上没有配置的IPv6地址${NC}"
        return 0
    fi
    
    echo -e "${WHITE}当前配置的IPv6地址:${NC}"
    for addr in "${ipv6_addrs[@]}"; do
        echo -e "  ${GREEN}•${NC} $addr"
    done
    
    echo
    local template_name
    while true; do
        read -p "模板名称: " template_name
        if validate_template_name "$template_name"; then
            break
        fi
    done
    
    read -p "模板描述: " template_description
    read -p "标签 (用空格分隔): " template_tags
    
    # 生成模板文件名
    local template_filename=$(echo "$template_name" | tr ' ' '_' | tr '[:upper:]' '[:lower:]')
    local template_file="$TEMPLATE_DIR/${template_filename}.json"
    
    # 检查文件是否存在
    if [[ -f "$template_file" ]]; then
        read -p "模板文件已存在，是否覆盖? (y/N): " overwrite
        if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}保存已取消${NC}"
            return 0
        fi
    fi
    
    # 分析地址模式
    local prefix=""
    local subnet_mask=""
    local addresses_json=""
    
    # 提取公共前缀和子网掩码
    if [[ ${#ipv6_addrs[@]} -gt 0 ]]; then
        local first_addr="${ipv6_addrs[0]}"
        subnet_mask=$(echo "$first_addr" | cut -d'/' -f2)
        
        # 简单的前缀提取（假设所有地址有相同前缀）
        prefix=$(echo "$first_addr" | cut -d'/' -f1 | sed 's/::[0-9]*$//')
    fi
    
    # 生成地址配置JSON
    addresses_json="["
    for i in "${!ipv6_addrs[@]}"; do
        local addr="${ipv6_addrs[$i]}"
        local addr_part=$(echo "$addr" | cut -d'/' -f1 | sed "s/^$prefix:://")
        
        if [[ $i -gt 0 ]]; then
            addresses_json="$addresses_json,"
        fi
        
        addresses_json="$addresses_json
            {\"type\": \"single\", \"value\": $addr_part}"
    done
    addresses_json="$addresses_json
        ]"
    
    # 处理标签
    local tags_json="["
    if [[ -n "$template_tags" ]]; then
        local tag_array=($template_tags)
        for i in "${!tag_array[@]}"; do
            if [[ $i -gt 0 ]]; then
                tags_json="$tags_json,"
            fi
            tags_json="$tags_json\"${tag_array[$i]}\""
        done
    fi
    tags_json="$tags_json]"
    
    # 创建模板文件
    cat > "$template_file" << EOF
{
    "name": "$template_name",
    "description": "$template_description",
    "version": "1.0",
    "author": "User",
    "created": "$(date '+%Y-%m-%d %H:%M:%S')",
    "config": {
        "prefix": "$prefix",
        "subnet_mask": $subnet_mask,
        "addresses": $addresses_json
    },
    "tags": $tags_json
}
EOF
    
    echo
    echo -e "${GREEN}✓${NC} 模板已保存: ${GREEN}$template_file${NC}"
    log_message "SUCCESS" "用户模板已保存: $template_name"
    
    return 0
}

# 导出配置
export_config() {
    local interface=$1
    local export_file=$2
    
    echo -e "${BLUE}=== 📤 导出配置 ===${NC}"
    echo
    
    if [[ -z "$export_file" ]]; then
        local timestamp=$(date '+%Y%m%d_%H%M%S')
        export_file="$CONFIG_DIR/export_${interface}_${timestamp}.json"
    fi
    
    # 获取当前配置
    local ipv6_addrs=($(ip -6 addr show "$interface" 2>/dev/null | grep "inet6" | grep -v "fe80" | awk '{print $2}'))
    
    # 创建导出文件
    cat > "$export_file" << EOF
{
    "export_info": {
        "timestamp": "$(date '+%Y-%m-%d %H:%M:%S')",
        "interface": "$interface",
        "hostname": "$(hostname)",
        "script_version": "1.0"
    },
    "ipv6_configuration": {
        "interface": "$interface",
        "addresses": [
EOF
    
    # 添加地址列表
    for i in "${!ipv6_addrs[@]}"; do
        local addr="${ipv6_addrs[$i]}"
        if [[ $i -eq $((${#ipv6_addrs[@]} - 1)) ]]; then
            echo "            \"$addr\"" >> "$export_file"
        else
            echo "            \"$addr\"," >> "$export_file"
        fi
    done
    
    cat >> "$export_file" << EOF
        ]
    },
    "system_info": {
        "os": "$(lsb_release -d 2>/dev/null | cut -f2 || echo "Unknown")",
        "kernel": "$(uname -r)",
        "ipv6_enabled": $([ -f /proc/net/if_inet6 ] && echo "true" || echo "false")
    }
}
EOF
    
    echo -e "${GREEN}✓${NC} 配置已导出到: ${GREEN}$export_file${NC}"
    echo -e "地址数量: ${GREEN}${#ipv6_addrs[@]}${NC}"
    
    log_message "SUCCESS" "配置导出完成: $export_file"
    
    return 0
}

# 导入配置
import_config() {
    local import_file=$1
    local interface=$2
    
    echo -e "${BLUE}=== 📥 导入配置 ===${NC}"
    echo
    
    if [[ ! -f "$import_file" ]]; then
        echo -e "${RED}导入文件不存在: $import_file${NC}"
        return 1
    fi
    
    # 验证文件格式
    if ! grep -q '"ipv6_configuration"' "$import_file"; then
        echo -e "${RED}无效的配置文件格式${NC}"
        return 1
    fi
    
    # 读取配置信息
    local export_timestamp=$(grep '"timestamp":' "$import_file" | head -1 | cut -d'"' -f4)
    local export_interface=$(grep '"interface":' "$import_file" | head -1 | cut -d'"' -f4)
    local export_hostname=$(grep '"hostname":' "$import_file" | cut -d'"' -f4)
    
    echo -e "${WHITE}配置文件信息:${NC}"
    echo -e "  导出时间: ${CYAN}$export_timestamp${NC}"
    echo -e "  原始接口: ${GREEN}$export_interface${NC}"
    echo -e "  原始主机: ${YELLOW}$export_hostname${NC}"
    echo -e "  目标接口: ${GREEN}$interface${NC}"
    echo
    
    # 提取地址列表
    local addresses=($(grep -o '"[0-9a-fA-F:]*\/[0-9]*"' "$import_file" | tr -d '"'))
    
    if [[ ${#addresses[@]} -eq 0 ]]; then
        echo -e "${YELLOW}配置文件中没有找到IPv6地址${NC}"
        return 0
    fi
    
    echo -e "${CYAN}将要导入的地址:${NC}"
    for addr in "${addresses[@]}"; do
        echo -e "  ${WHITE}•${NC} $addr"
    done
    
    echo
    echo -e "总计: ${GREEN}${#addresses[@]}${NC} 个地址"
    
    # 确认导入
    read -p "确认导入这些配置? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}导入已取消${NC}"
        return 0
    fi
    
    # 创建导入前快照
    local snapshot_file=$(create_snapshot "$interface" "import" "导入配置前的备份")
    echo -e "${GREEN}✓${NC} 快照已保存: $(basename "$snapshot_file")"
    echo
    
    # 开始导入
    echo -e "${BLUE}=== 🚀 开始导入配置 ===${NC}"
    
    local success_count=0
    local error_count=0
    
    for addr in "${addresses[@]}"; do
        echo -n "导入 $addr ... "
        
        if ip -6 addr add "$addr" dev "$interface" 2>/dev/null; then
            echo -e "${GREEN}成功${NC}"
            log_message "SUCCESS" "配置导入成功添加IPv6地址: $addr"
            ((success_count++))
        else
            echo -e "${RED}失败${NC}"
            log_message "ERROR" "配置导入添加IPv6地址失败: $addr"
            ((error_count++))
        fi
        
        sleep 0.1
    done
    
    echo
    echo -e "${BLUE}=== ✅ 配置导入完成 ===${NC}"
    echo -e "成功: ${GREEN}$success_count${NC} 个地址"
    echo -e "失败: ${RED}$error_count${NC} 个地址"
    
    log_message "SUCCESS" "配置导入完成: 成功 $success_count 个，失败 $error_count 个"
    
    return 0
}

# 配置管理菜单
config_management() {
    while true; do
        echo -e "${BLUE}=== ⚙️  配置文件和模板管理 ===${NC}"
        echo
        echo -e "${GREEN}📋 模板管理${NC}"
        echo -e "${GREEN}1.${NC} 查看可用模板"
        echo -e "${GREEN}2.${NC} 应用配置模板"
        echo -e "${GREEN}3.${NC} 保存当前配置为模板"
        echo
        echo -e "${GREEN}📁 配置管理${NC}"
        echo -e "${GREEN}4.${NC} 导出当前配置"
        echo -e "${GREEN}5.${NC} 导入配置文件"
        echo -e "${GREEN}6.${NC} 查看配置文件"
        echo -e "${GREEN}7.${NC} 编辑配置文件"
        echo
        echo -e "${GREEN}🧹 维护操作${NC}"
        echo -e "${GREEN}8.${NC} 清理配置文件"
        echo -e "${GREEN}9.${NC} 重置为默认配置"
        echo -e "${GREEN}0.${NC} 返回主菜单"
        echo
        
        read -p "请选择操作 (0-9): " choice
        
        case $choice in
            0)
                return 1
                ;;
            1)
                echo
                list_templates
                echo
                read -p "按回车键继续..."
                ;;
            2)
                echo
                config_apply_template
                echo
                read -p "按回车键继续..."
                ;;
            3)
                echo
                config_save_template
                echo
                read -p "按回车键继续..."
                ;;
            4)
                echo
                config_export
                echo
                read -p "按回车键继续..."
                ;;
            5)
                echo
                config_import
                echo
                read -p "按回车键继续..."
                ;;
            6)
                echo
                config_view
                echo
                read -p "按回车键继续..."
                ;;
            7)
                echo
                config_edit
                echo
                read -p "按回车键继续..."
                ;;
            8)
                echo
                config_cleanup
                echo
                read -p "按回车键继续..."
                ;;
            9)
                echo
                config_reset
                echo
                read -p "按回车键继续..."
                ;;
            0)
                break
                ;;
            *)
                echo
                echo -e "${RED}无效选择，请输入 0-9 之间的数字${NC}"
                sleep 2
                ;;
        esac
    done
}

# 应用模板的交互界面
config_apply_template() {
    echo -e "${BLUE}=== 📋 应用配置模板 ===${NC}"
    echo
    
    # 选择接口
    select_interface
    if [[ $? -ne 0 ]]; then
        return 1
    fi
    
    echo
    
    # 列出模板并选择
    local template_count
    list_templates
    template_count=$?
    
    if [[ $template_count -eq 0 ]]; then
        return 0
    fi
    
    local templates=($(find "$TEMPLATE_DIR" -name "*.json" -type f 2>/dev/null))
    
    while true; do
        read -p "请选择要应用的模板编号 (1-$template_count, 0=取消): " choice
        
        if [[ "$choice" == "0" ]]; then
            echo -e "${YELLOW}操作已取消${NC}"
            return 0
        elif [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le $template_count ]]; then
            local selected_template="${templates[$((choice-1))]}"
            
            # 询问是否自定义前缀
            echo
            local current_prefix=$(grep '"prefix":' "$selected_template" | cut -d'"' -f4)
            echo -e "${WHITE}模板默认前缀: ${GREEN}$current_prefix${NC}"
            read -p "是否使用自定义前缀? (y/N): " custom_prefix
            
            if [[ "$custom_prefix" =~ ^[Yy]$ ]]; then
                read -p "请输入新的IPv6前缀: " new_prefix
                if [[ -n "$new_prefix" ]]; then
                    # 创建临时模板文件
                    local temp_template=$(mktemp)
                    sed "s|\"prefix\": \"$current_prefix\"|\"prefix\": \"$new_prefix\"|" "$selected_template" > "$temp_template"
                    apply_template "$temp_template" "$SELECTED_INTERFACE"
                    rm -f "$temp_template"
                else
                    apply_template "$selected_template" "$SELECTED_INTERFACE"
                fi
            else
                apply_template "$selected_template" "$SELECTED_INTERFACE"
            fi
            
            break
        else
            echo -e "${RED}无效选择，请输入 1-$template_count 或 0${NC}"
        fi
    done
}

# 保存模板的交互界面
config_save_template() {
    echo -e "${BLUE}=== 💾 保存配置为模板 ===${NC}"
    echo
    
    # 选择接口
    select_interface
    if [[ $? -ne 0 ]]; then
        return 1
    fi
    
    echo
    save_as_template "$SELECTED_INTERFACE"
}

# 导出配置的交互界面
config_export() {
    echo -e "${BLUE}=== 📤 导出配置 ===${NC}"
    echo
    
    # 选择接口
    select_interface
    if [[ $? -ne 0 ]]; then
        return 1
    fi
    
    echo
    local export_filename
    while true; do
        read -p "导出文件名 (留空使用默认名称): " export_filename
        if validate_filename "$export_filename" "导出文件名"; then
            break
        fi
    done
    
    if [[ -n "$export_filename" ]]; then
        # 确保文件扩展名
        if [[ ! "$export_filename" =~ \.json$ ]]; then
            export_filename="${export_filename}.json"
        fi
        export_filename="$CONFIG_DIR/$export_filename"
    fi
    
    export_config "$SELECTED_INTERFACE" "$export_filename"
}

# 导入配置的交互界面
config_import() {
    echo -e "${BLUE}=== 📥 导入配置 ===${NC}"
    echo
    
    # 列出可用的配置文件
    local config_files=($(find "$CONFIG_DIR" -name "*.json" -type f 2>/dev/null))
    
    if [[ ${#config_files[@]} -eq 0 ]]; then
        echo -e "${YELLOW}没有找到可导入的配置文件${NC}"
        echo
        local import_file
        while true; do
            read -p "请输入配置文件的完整路径: " import_file
            if validate_file_path "$import_file" "配置文件"; then
                break
            fi
        done
    else
        echo -e "${WHITE}可用的配置文件:${NC}"
        echo
        
        for i in "${!config_files[@]}"; do
            local config_file="${config_files[$i]}"
            local filename=$(basename "$config_file")
            local timestamp=$(grep '"timestamp":' "$config_file" 2>/dev/null | head -1 | cut -d'"' -f4)
            
            echo -e "${WHITE}$((i+1)).${NC} $filename"
            if [[ -n "$timestamp" ]]; then
                echo -e "    时间: ${CYAN}$timestamp${NC}"
            fi
            echo
        done
        
        while true; do
            read -p "请选择配置文件编号 (1-${#config_files[@]}, 0=手动输入路径): " choice
            
            if [[ "$choice" == "0" ]]; then
                while true; do
                    read -p "请输入配置文件的完整路径: " import_file
                    if validate_file_path "$import_file" "配置文件"; then
                        break
                    fi
                done
                break
            elif [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le ${#config_files[@]} ]]; then
                import_file="${config_files[$((choice-1))]}"
                break
            else
                echo -e "${RED}无效选择，请输入 1-${#config_files[@]} 或 0${NC}"
            fi
        done
    fi
    
    # 选择目标接口
    echo
    select_interface
    if [[ $? -ne 0 ]]; then
        return 1
    fi
    
    echo
    import_config "$import_file" "$SELECTED_INTERFACE"
}

# 查看配置文件
config_view() {
    echo -e "${BLUE}=== 📄 查看配置文件 ===${NC}"
    echo
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${YELLOW}配置文件不存在，正在创建默认配置...${NC}"
        init_default_config
    fi
    
    echo -e "${WHITE}配置文件: $CONFIG_FILE${NC}"
    echo
    echo -e "${CYAN}=== 配置内容 ===${NC}"
    cat "$CONFIG_FILE"
    echo
}

# 编辑配置文件
config_edit() {
    echo -e "${BLUE}=== ✏️  编辑配置文件 ===${NC}"
    echo
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${YELLOW}配置文件不存在，正在创建默认配置...${NC}"
        init_default_config
    fi
    
    echo -e "${WHITE}配置文件: $CONFIG_FILE${NC}"
    echo
    echo -e "${CYAN}提示: 将使用系统默认编辑器打开配置文件${NC}"
    echo -e "${YELLOW}请谨慎修改配置文件，错误的配置可能导致脚本异常${NC}"
    echo
    
    read -p "确认编辑配置文件? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        # 备份当前配置
        local backup_file="$CONFIG_FILE.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$CONFIG_FILE" "$backup_file"
        echo -e "${GREEN}✓${NC} 配置文件已备份到: $backup_file"
        
        # 使用默认编辑器打开
        ${EDITOR:-nano} "$CONFIG_FILE"
        
        echo
        echo -e "${GREEN}✓${NC} 配置文件编辑完成"
        log_message "INFO" "用户编辑了配置文件"
    else
        echo -e "${YELLOW}编辑已取消${NC}"
    fi
}

# 清理配置文件
config_cleanup() {
    echo -e "${BLUE}=== 🧹 清理配置文件 ===${NC}"
    echo
    
    # 统计文件信息
    local config_count=$(find "$CONFIG_DIR" -name "*.json" -type f 2>/dev/null | wc -l)
    local template_count=$(find "$TEMPLATE_DIR" -name "*.json" -type f 2>/dev/null | wc -l)
    local backup_count=$(find "$CONFIG_DIR" -name "*.backup.*" -type f 2>/dev/null | wc -l)
    
    echo -e "${WHITE}当前文件统计:${NC}"
    echo -e "  配置文件: ${GREEN}$config_count${NC} 个"
    echo -e "  模板文件: ${GREEN}$template_count${NC} 个"
    echo -e "  备份文件: ${GREEN}$backup_count${NC} 个"
    
    if [[ $config_count -eq 0 && $template_count -eq 0 && $backup_count -eq 0 ]]; then
        echo -e "${YELLOW}没有文件需要清理${NC}"
        return 0
    fi
    
    echo
    echo -e "${WHITE}清理选项:${NC}"
    echo -e "${GREEN}1.${NC} 清理备份文件"
    echo -e "${GREEN}2.${NC} 清理导出的配置文件"
    echo -e "${GREEN}3.${NC} 清理用户创建的模板"
    echo -e "${RED}4.${NC} 清理所有文件 (保留默认配置)"
    echo -e "${GREEN}5.${NC} 取消"
    echo -e "${YELLOW}0.${NC} 返回主菜单"
    echo
    
    while true; do
        read -p "请选择清理选项 (0-5): " choice
        
        case $choice in
            1)
                local backup_files=($(find "$CONFIG_DIR" -name "*.backup.*" -type f 2>/dev/null))
                if [[ ${#backup_files[@]} -gt 0 ]]; then
                    echo -e "${YELLOW}将删除 ${#backup_files[@]} 个备份文件${NC}"
                    read -p "确认删除? (y/N): " confirm
                    if [[ "$confirm" =~ ^[Yy]$ ]]; then
                        local deleted=0
                        for file in "${backup_files[@]}"; do
                            if rm -f "$file" 2>/dev/null; then
                                ((deleted++))
                            fi
                        done
                        echo -e "${GREEN}成功删除 $deleted 个备份文件${NC}"
                    fi
                else
                    echo -e "${YELLOW}没有备份文件需要清理${NC}"
                fi
                break
                ;;
            2)
                local export_files=($(find "$CONFIG_DIR" -name "export_*.json" -type f 2>/dev/null))
                if [[ ${#export_files[@]} -gt 0 ]]; then
                    echo -e "${YELLOW}将删除 ${#export_files[@]} 个导出文件${NC}"
                    read -p "确认删除? (y/N): " confirm
                    if [[ "$confirm" =~ ^[Yy]$ ]]; then
                        local deleted=0
                        for file in "${export_files[@]}"; do
                            if rm -f "$file" 2>/dev/null; then
                                ((deleted++))
                            fi
                        done
                        echo -e "${GREEN}成功删除 $deleted 个导出文件${NC}"
                    fi
                else
                    echo -e "${YELLOW}没有导出文件需要清理${NC}"
                fi
                break
                ;;
            3)
                # 清理用户模板（保留内置模板）
                local user_templates=($(find "$TEMPLATE_DIR" -name "*.json" -type f -exec grep -l '"author": "User"' {} \; 2>/dev/null))
                if [[ ${#user_templates[@]} -gt 0 ]]; then
                    echo -e "${YELLOW}将删除 ${#user_templates[@]} 个用户模板${NC}"
                    for template in "${user_templates[@]}"; do
                        local name=$(grep '"name":' "$template" | cut -d'"' -f4)
                        echo -e "  • $name"
                    done
                    read -p "确认删除? (y/N): " confirm
                    if [[ "$confirm" =~ ^[Yy]$ ]]; then
                        local deleted=0
                        for file in "${user_templates[@]}"; do
                            if rm -f "$file" 2>/dev/null; then
                                ((deleted++))
                            fi
                        done
                        echo -e "${GREEN}成功删除 $deleted 个用户模板${NC}"
                    fi
                else
                    echo -e "${YELLOW}没有用户模板需要清理${NC}"
                fi
                break
                ;;
            4)
                echo -e "${RED}⚠️  警告: 这将删除所有配置和模板文件！${NC}"
                echo -e "${YELLOW}默认配置文件将会保留并重置${NC}"
                read -p "确认清理所有文件? (输入 'CLEAN' 确认): " confirm
                if [[ "$confirm" == "CLEAN" ]]; then
                    # 删除所有文件
                    rm -f "$CONFIG_DIR"/*.json 2>/dev/null
                    rm -f "$CONFIG_DIR"/*.backup.* 2>/dev/null
                    rm -f "$TEMPLATE_DIR"/*.json 2>/dev/null
                    
                    # 重新创建默认配置和模板
                    init_default_config
                    create_builtin_templates
                    
                    echo -e "${GREEN}✓${NC} 所有文件已清理，默认配置已重置"
                    log_message "WARN" "用户清理了所有配置文件"
                else
                    echo -e "${YELLOW}清理已取消${NC}"
                fi
                break
                ;;
            5)
                echo -e "${YELLOW}清理已取消${NC}"
                break
                ;;
            *)
                echo -e "${RED}无效选择，请输入 0-5 之间的数字${NC}"
                ;;
        esac
    done
}

# 重置配置
config_reset() {
    echo -e "${BLUE}=== 🔄 重置配置 ===${NC}"
    echo
    
    echo -e "${YELLOW}⚠️  警告: 这将重置配置文件到默认状态${NC}"
    echo -e "${WHITE}当前配置文件将被备份${NC}"
    echo
    
    read -p "确认重置配置文件? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        # 备份当前配置
        if [[ -f "$CONFIG_FILE" ]]; then
            local backup_file="$CONFIG_FILE.reset_backup.$(date +%Y%m%d_%H%M%S)"
            cp "$CONFIG_FILE" "$backup_file"
            echo -e "${GREEN}✓${NC} 当前配置已备份到: $backup_file"
        fi
        
        # 重新创建默认配置
        rm -f "$CONFIG_FILE" 2>/dev/null
        init_default_config
        
        echo -e "${GREEN}✓${NC} 配置文件已重置为默认设置"
        log_message "INFO" "配置文件已重置为默认设置"
    else
        echo -e "${YELLOW}重置已取消${NC}"
    fi
}

# 列出可用模板
list_templates() {
    echo -e "${BLUE}=== 📋 可用配置模板 ===${NC}"
    echo
    
    local templates=($(find "$TEMPLATE_DIR" -name "*.json" -type f 2>/dev/null))
    
    if [[ ${#templates[@]} -eq 0 ]]; then
        echo -e "${YELLOW}没有找到配置模板${NC}"
        echo -e "${CYAN}正在创建内置模板...${NC}"
        create_builtin_templates
        templates=($(find "$TEMPLATE_DIR" -name "*.json" -type f 2>/dev/null))
    fi
    
    echo -e "${WHITE}模板列表:${NC}"
    echo
    
    for i in "${!templates[@]}"; do
        local template_file="${templates[$i]}"
        local template_name=$(basename "$template_file" .json)
        
        # 尝试读取模板信息
        local name=$(grep '"name":' "$template_file" 2>/dev/null | cut -d'"' -f4)
        local description=$(grep '"description":' "$template_file" 2>/dev/null | cut -d'"' -f4)
        local tags=$(grep '"tags":' "$template_file" 2>/dev/null | sed 's/.*"tags": \[\(.*\)\].*/\1/' | tr -d '"' | tr ',' ' ')
        
        name=${name:-$template_name}
        description=${description:-"无描述"}
        
        echo -e "${WHITE}$((i+1)).${NC} ${GREEN}$name${NC}"
        echo -e "    描述: ${CYAN}$description${NC}"
        if [[ -n "$tags" ]]; then
            echo -e "    标签: ${YELLOW}$tags${NC}"
        fi
        echo -e "    文件: ${template_name}.json"
        echo
    done
    
    return ${#templates[@]}
}

# 应用模板配置
apply_template() {
    local template_file=$1
    local interface=$2
    
    if [[ ! -f "$template_file" ]]; then
        log_message "ERROR" "模板文件不存在: $template_file"
        return 1
    fi
    
    log_message "INFO" "应用模板: $template_file"
    
    # 读取模板信息
    local template_name=$(grep '"name":' "$template_file" | cut -d'"' -f4)
    local prefix=$(grep '"prefix":' "$template_file" | cut -d'"' -f4)
    local subnet_mask=$(grep '"subnet_mask":' "$template_file" | grep -o '[0-9]*')
    
    echo -e "${BLUE}=== 📋 应用模板: ${GREEN}$template_name${NC} ===${NC}"
    echo -e "接口: ${GREEN}$interface${NC}"
    echo -e "前缀: ${GREEN}$prefix${NC}"
    echo -e "子网掩码: ${GREEN}/$subnet_mask${NC}"
    echo
    
    # 创建操作前快照
    local snapshot_file=$(create_snapshot "$interface" "template" "应用模板 $template_name 前的备份")
    echo -e "${GREEN}✓${NC} 快照已保存: $(basename "$snapshot_file")"
    echo
    
    # 解析地址配置
    local addresses=()
    parse_template_addresses "$template_file" addresses
    
    if [[ ${#addresses[@]} -eq 0 ]]; then
        log_message "ERROR" "模板中没有找到有效的地址配置"
        return 1
    fi
    
    echo -e "${CYAN}将要配置的地址:${NC}"
    for addr in "${addresses[@]}"; do
        echo -e "  ${WHITE}•${NC} $addr"
    done
    
    echo
    echo -e "总计: ${GREEN}${#addresses[@]}${NC} 个地址"
    
    # 确认应用
    local auto_confirm=$(read_config "require_confirmation" "general" "true")
    if [[ "$auto_confirm" == "false" ]]; then
        local confirm="y"
    else
        read -p "确认应用此模板? (y/N): " confirm
    fi
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}模板应用已取消${NC}"
        return 0
    fi
    
    # 开始应用模板
    echo
    echo -e "${BLUE}=== 🚀 开始应用模板 ===${NC}"
    
    local success_count=0
    local error_count=0
    
    for addr in "${addresses[@]}"; do
        echo -n "配置 $addr ... "
        
        if ip -6 addr add "$addr" dev "$interface" 2>/dev/null; then
            echo -e "${GREEN}成功${NC}"
            log_message "SUCCESS" "模板应用成功添加IPv6地址: $addr"
            ((success_count++))
        else
            echo -e "${RED}失败${NC}"
            log_message "ERROR" "模板应用添加IPv6地址失败: $addr"
            ((error_count++))
        fi
        
        sleep 0.1
    done
    
    echo
    echo -e "${BLUE}=== ✅ 模板应用完成 ===${NC}"
    echo -e "成功: ${GREEN}$success_count${NC} 个地址"
    echo -e "失败: ${RED}$error_count${NC} 个地址"
    
    log_message "SUCCESS" "模板 $template_name 应用完成: 成功 $success_count 个，失败 $error_count 个"
    
    return 0
}

# 解析模板地址配置
parse_template_addresses() {
    local template_file=$1
    local -n result_array=$2
    
    # 提取prefix和subnet_mask
    local prefix=$(grep '"prefix":' "$template_file" | cut -d'"' -f4)
    local subnet_mask=$(grep '"subnet_mask":' "$template_file" | grep -o '[0-9]*')
    
    # 提取addresses数组内容
    local in_addresses=false
    local current_address=""
    
    while IFS= read -r line; do
        # 检查是否进入addresses数组
        if [[ "$line" =~ \"addresses\".*\[ ]]; then
            in_addresses=true
            continue
        fi
        
        # 检查是否退出addresses数组
        if [[ "$in_addresses" == true && "$line" =~ ^\s*\] ]]; then
            break
        fi
        
        # 处理addresses数组中的内容
        if [[ "$in_addresses" == true ]]; then
            if [[ "$line" =~ \{.*\"type\".*\"range\" ]]; then
                # 范围类型
                local start=$(echo "$line" | grep -o '"start": [0-9]*' | grep -o '[0-9]*')
                local end=$(echo "$line" | grep -o '"end": [0-9]*' | grep -o '[0-9]*')
                
                if [[ -n "$start" && -n "$end" ]]; then
                    for ((i=start; i<=end; i++)); do
                        result_array+=("$prefix::$i/$subnet_mask")
                    done
                fi
                
            elif [[ "$line" =~ \{.*\"type\".*\"single\" ]]; then
                # 单个值类型
                local value=$(echo "$line" | grep -o '"value": [0-9]*' | grep -o '[0-9]*')
                
                if [[ -n "$value" ]]; then
                    result_array+=("$prefix::$value/$subnet_mask")
                fi
            fi
        fi
    done < "$template_file"
}

# 保存当前配置为模板
save_as_template() {
    local interface=$1
    
    echo -e "${BLUE}=== 💾 保存当前配置为模板 ===${NC}"
    echo
    
    # 获取当前IPv6配置
    local ipv6_addrs=($(ip -6 addr show "$interface" 2>/dev/null | grep "inet6" | grep -v "fe80" | awk '{print $2}'))
    
    if [[ ${#ipv6_addrs[@]} -eq 0 ]]; then
        echo -e "${YELLOW}接口 $interface 上没有配置的IPv6地址${NC}"
        return 0
    fi
    
    echo -e "${WHITE}当前配置的IPv6地址:${NC}"
    for addr in "${ipv6_addrs[@]}"; do
        echo -e "  ${GREEN}•${NC} $addr"
    done
    
    echo
    local template_name
    while true; do
        read -p "模板名称: " template_name
        if validate_template_name "$template_name"; then
            break
        fi
    done
    
    read -p "模板描述: " template_description
    read -p "标签 (用空格分隔): " template_tags
    
    # 生成模板文件名
    local template_filename=$(echo "$template_name" | tr ' ' '_' | tr '[:upper:]' '[:lower:]')
    local template_file="$TEMPLATE_DIR/${template_filename}.json"
    
    # 检查文件是否存在
    if [[ -f "$template_file" ]]; then
        read -p "模板文件已存在，是否覆盖? (y/N): " overwrite
        if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}保存已取消${NC}"
            return 0
        fi
    fi
    
    # 分析地址模式
    local prefix=""
    local subnet_mask=""
    local addresses_json=""
    
    # 提取公共前缀和子网掩码
    if [[ ${#ipv6_addrs[@]} -gt 0 ]]; then
        local first_addr="${ipv6_addrs[0]}"
        subnet_mask=$(echo "$first_addr" | cut -d'/' -f2)
        
        # 简单的前缀提取（假设所有地址有相同前缀）
        prefix=$(echo "$first_addr" | cut -d'/' -f1 | sed 's/::[0-9]*$//')
    fi
    
    # 生成地址配置JSON
    addresses_json="["
    for i in "${!ipv6_addrs[@]}"; do
        local addr="${ipv6_addrs[$i]}"
        local addr_part=$(echo "$addr" | cut -d'/' -f1 | sed "s/^$prefix:://")
        
        if [[ $i -gt 0 ]]; then
            addresses_json="$addresses_json,"
        fi
        
        addresses_json="$addresses_json
            {\"type\": \"single\", \"value\": $addr_part}"
    done
    addresses_json="$addresses_json
        ]"
    
    # 处理标签
    local tags_json="["
    if [[ -n "$template_tags" ]]; then
        local tag_array=($template_tags)
        for i in "${!tag_array[@]}"; do
            if [[ $i -gt 0 ]]; then
                tags_json="$tags_json,"
            fi
            tags_json="$tags_json\"${tag_array[$i]}\""
        done
    fi
    tags_json="$tags_json]"
    
    # 创建模板文件
    cat > "$template_file" << EOF
{
    "name": "$template_name",
    "description": "$template_description",
    "version": "1.0",
    "author": "User",
    "created": "$(date '+%Y-%m-%d %H:%M:%S')",
    "config": {
        "prefix": "$prefix",
        "subnet_mask": $subnet_mask,
        "addresses": $addresses_json
    },
    "tags": $tags_json
}
EOF
    
    echo
    echo -e "${GREEN}✓${NC} 模板已保存: ${GREEN}$template_file${NC}"
    log_message "SUCCESS" "用户模板已保存: $template_name"
    
    return 0
}

# 导出配置
export_config() {
    local interface=$1
    local export_file=$2
    
    echo -e "${BLUE}=== 📤 导出配置 ===${NC}"
    echo
    
    if [[ -z "$export_file" ]]; then
        local timestamp=$(date '+%Y%m%d_%H%M%S')
        export_file="$CONFIG_DIR/export_${interface}_${timestamp}.json"
    fi
    
    # 获取当前配置
    local ipv6_addrs=($(ip -6 addr show "$interface" 2>/dev/null | grep "inet6" | grep -v "fe80" | awk '{print $2}'))
    
    # 创建导出文件
    cat > "$export_file" << EOF
{
    "export_info": {
        "timestamp": "$(date '+%Y-%m-%d %H:%M:%S')",
        "interface": "$interface",
        "hostname": "$(hostname)",
        "script_version": "1.0"
    },
    "ipv6_configuration": {
        "interface": "$interface",
        "addresses": [
EOF
    
    # 添加地址列表
    for i in "${!ipv6_addrs[@]}"; do
        local addr="${ipv6_addrs[$i]}"
        if [[ $i -eq $((${#ipv6_addrs[@]} - 1)) ]]; then
            echo "            \"$addr\"" >> "$export_file"
        else
            echo "            \"$addr\"," >> "$export_file"
        fi
    done
    
    cat >> "$export_file" << EOF
        ]
    },
    "system_info": {
        "os": "$(lsb_release -d 2>/dev/null | cut -f2 || echo "Unknown")",
        "kernel": "$(uname -r)",
        "ipv6_enabled": $([ -f /proc/net/if_inet6 ] && echo "true" || echo "false")
    }
}
EOF
    
    echo -e "${GREEN}✓${NC} 配置已导出到: ${GREEN}$export_file${NC}"
    echo -e "地址数量: ${GREEN}${#ipv6_addrs[@]}${NC}"
    
    log_message "SUCCESS" "配置导出完成: $export_file"
    
    return 0
}

# 导入配置
import_config() {
    local import_file=$1
    local interface=$2
    
    echo -e "${BLUE}=== 📥 导入配置 ===${NC}"
    echo
    
    if [[ ! -f "$import_file" ]]; then
        echo -e "${RED}导入文件不存在: $import_file${NC}"
        return 1
    fi
    
    # 验证文件格式
    if ! grep -q '"ipv6_configuration"' "$import_file"; then
        echo -e "${RED}无效的配置文件格式${NC}"
        return 1
    fi
    
    # 读取配置信息
    local export_timestamp=$(grep '"timestamp":' "$import_file" | head -1 | cut -d'"' -f4)
    local export_interface=$(grep '"interface":' "$import_file" | head -1 | cut -d'"' -f4)
    local export_hostname=$(grep '"hostname":' "$import_file" | cut -d'"' -f4)
    
    echo -e "${WHITE}配置文件信息:${NC}"
    echo -e "  导出时间: ${CYAN}$export_timestamp${NC}"
    echo -e "  原始接口: ${GREEN}$export_interface${NC}"
    echo -e "  原始主机: ${YELLOW}$export_hostname${NC}"
    echo -e "  目标接口: ${GREEN}$interface${NC}"
    echo
    
    # 提取地址列表
    local addresses=($(grep -o '"[0-9a-fA-F:]*\/[0-9]*"' "$import_file" | tr -d '"'))
    
    if [[ ${#addresses[@]} -eq 0 ]]; then
        echo -e "${YELLOW}配置文件中没有找到IPv6地址${NC}"
        return 0
    fi
    
    echo -e "${CYAN}将要导入的地址:${NC}"
    for addr in "${addresses[@]}"; do
        echo -e "  ${WHITE}•${NC} $addr"
    done
    
    echo
    echo -e "总计: ${GREEN}${#addresses[@]}${NC} 个地址"
    
    # 确认导入
    read -p "确认导入这些配置? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}导入已取消${NC}"
        return 0
    fi
    
    # 创建导入前快照
    local snapshot_file=$(create_snapshot "$interface" "import" "导入配置前的备份")
    echo -e "${GREEN}✓${NC} 快照已保存: $(basename "$snapshot_file")"
    echo
    
    # 开始导入
    echo -e "${BLUE}=== 🚀 开始导入配置 ===${NC}"
    
    local success_count=0
    local error_count=0
    
    for addr in "${addresses[@]}"; do
        echo -n "导入 $addr ... "
        
        if ip -6 addr add "$addr" dev "$interface" 2>/dev/null; then
            echo -e "${GREEN}成功${NC}"
            log_message "SUCCESS" "配置导入成功添加IPv6地址: $addr"
            ((success_count++))
        else
            echo -e "${RED}失败${NC}"
            log_message "ERROR" "配置导入添加IPv6地址失败: $addr"
            ((error_count++))
        fi
        
        sleep 0.1
    done
    
    echo
    echo -e "${BLUE}=== ✅ 配置导入完成 ===${NC}"
    echo -e "成功: ${GREEN}$success_count${NC} 个地址"
    echo -e "失败: ${RED}$error_count${NC} 个地址"
    
    log_message "SUCCESS" "配置导入完成: 成功 $success_count 个，失败 $error_count 个"
    
    return 0
}

# 应用模板的交互界面
config_apply_template() {
    echo -e "${BLUE}=== 📋 应用配置模板 ===${NC}"
    echo
    
    # 选择接口
    select_interface
    if [[ $? -ne 0 ]]; then
        return 1
    fi
    
    echo
    
    # 列出模板并选择
    local template_count
    list_templates
    template_count=$?
    
    if [[ $template_count -eq 0 ]]; then
        return 0
    fi
    
    local templates=($(find "$TEMPLATE_DIR" -name "*.json" -type f 2>/dev/null))
    
    while true; do
        read -p "请选择要应用的模板编号 (1-$template_count, 0=取消): " choice
        
        if [[ "$choice" == "0" ]]; then
            echo -e "${YELLOW}操作已取消${NC}"
            return 0
        elif [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le $template_count ]]; then
            local selected_template="${templates[$((choice-1))]}"
            
            # 询问是否自定义前缀
            echo
            local current_prefix=$(grep '"prefix":' "$selected_template" | cut -d'"' -f4)
            echo -e "${WHITE}模板默认前缀: ${GREEN}$current_prefix${NC}"
            read -p "是否使用自定义前缀? (y/N): " custom_prefix
            
            if [[ "$custom_prefix" =~ ^[Yy]$ ]]; then
                read -p "请输入新的IPv6前缀: " new_prefix
                if [[ -n "$new_prefix" ]]; then
                    # 创建临时模板文件
                    local temp_template=$(mktemp)
                    sed "s|\"prefix\": \"$current_prefix\"|\"prefix\": \"$new_prefix\"|" "$selected_template" > "$temp_template"
                    apply_template "$temp_template" "$SELECTED_INTERFACE"
                    rm -f "$temp_template"
                else
                    apply_template "$selected_template" "$SELECTED_INTERFACE"
                fi
            else
                apply_template "$selected_template" "$SELECTED_INTERFACE"
            fi
            
            break
        else
            echo -e "${RED}无效选择，请输入 1-$template_count 或 0${NC}"
        fi
    done
}

# 保存模板的交互界面
config_save_template() {
    echo -e "${BLUE}=== 💾 保存配置为模板 ===${NC}"
    echo
    
    # 选择接口
    select_interface
    if [[ $? -ne 0 ]]; then
        return 1
    fi
    
    echo
    save_as_template "$SELECTED_INTERFACE"
}

# 导出配置的交互界面
config_export() {
    echo -e "${BLUE}=== 📤 导出配置 ===${NC}"
    echo
    
    # 选择接口
    select_interface
    if [[ $? -ne 0 ]]; then
        return 1
    fi
    
    echo
    read -p "导出文件名 (留空使用默认名称): " export_filename
    
    if [[ -n "$export_filename" ]]; then
        # 确保文件扩展名
        if [[ ! "$export_filename" =~ \.json$ ]]; then
            export_filename="${export_filename}.json"
        fi
        export_filename="$CONFIG_DIR/$export_filename"
    fi
    
    export_config "$SELECTED_INTERFACE" "$export_filename"
}

# 导入配置的交互界面
config_import() {
    echo -e "${BLUE}=== 📥 导入配置 ===${NC}"
    echo
    
    # 列出可用的配置文件
    local config_files=($(find "$CONFIG_DIR" -name "*.json" -type f 2>/dev/null))
    
    if [[ ${#config_files[@]} -eq 0 ]]; then
        echo -e "${YELLOW}没有找到可导入的配置文件${NC}"
        echo
        read -p "请输入配置文件的完整路径: " import_file
        
        if [[ ! -f "$import_file" ]]; then
            echo -e "${RED}文件不存在: $import_file${NC}"
            return 1
        fi
    else
        echo -e "${WHITE}可用的配置文件:${NC}"
        echo
        
        for i in "${!config_files[@]}"; do
            local config_file="${config_files[$i]}"
            local filename=$(basename "$config_file")
            local timestamp=$(grep '"timestamp":' "$config_file" 2>/dev/null | head -1 | cut -d'"' -f4)
            
            echo -e "${WHITE}$((i+1)).${NC} $filename"
            if [[ -n "$timestamp" ]]; then
                echo -e "    时间: ${CYAN}$timestamp${NC}"
            fi
            echo
        done
        
        while true; do
            read -p "请选择配置文件编号 (1-${#config_files[@]}, 0=手动输入路径): " choice
            
            if [[ "$choice" == "0" ]]; then
                read -p "请输入配置文件的完整路径: " import_file
                break
            elif [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le ${#config_files[@]} ]]; then
                import_file="${config_files[$((choice-1))]}"
                break
            else
                echo -e "${RED}无效选择，请输入 1-${#config_files[@]} 或 0${NC}"
            fi
        done
    fi
    
    # 选择目标接口
    echo
    select_interface
    if [[ $? -ne 0 ]]; then
        return 1
    fi
    
    echo
    import_config "$import_file" "$SELECTED_INTERFACE"
}

# 查看配置文件
config_view() {
    echo -e "${BLUE}=== 📄 查看配置文件 ===${NC}"
    echo
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${YELLOW}配置文件不存在，正在创建默认配置...${NC}"
        init_default_config
    fi
    
    echo -e "${WHITE}配置文件: $CONFIG_FILE${NC}"
    echo
    echo -e "${CYAN}=== 配置内容 ===${NC}"
    cat "$CONFIG_FILE"
    echo
}

# 编辑配置文件
config_edit() {
    echo -e "${BLUE}=== ✏️  编辑配置文件 ===${NC}"
    echo
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${YELLOW}配置文件不存在，正在创建默认配置...${NC}"
        init_default_config
    fi
    
    echo -e "${WHITE}配置文件: $CONFIG_FILE${NC}"
    echo
    echo -e "${CYAN}提示: 将使用系统默认编辑器打开配置文件${NC}"
    echo -e "${YELLOW}请谨慎修改配置文件，错误的配置可能导致脚本异常${NC}"
    echo
    
    read -p "确认编辑配置文件? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        # 备份当前配置
        local backup_file="$CONFIG_FILE.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$CONFIG_FILE" "$backup_file"
        echo -e "${GREEN}✓${NC} 配置文件已备份到: $backup_file"
        
        # 使用默认编辑器打开
        ${EDITOR:-nano} "$CONFIG_FILE"
        
        echo
        echo -e "${GREEN}✓${NC} 配置文件编辑完成"
        log_message "INFO" "用户编辑了配置文件"
    else
        echo -e "${YELLOW}编辑已取消${NC}"
    fi
}

# 清理配置文件
config_cleanup() {
    echo -e "${BLUE}=== 🧹 清理配置文件 ===${NC}"
    echo
    
    # 统计文件信息
    local config_count=$(find "$CONFIG_DIR" -name "*.json" -type f 2>/dev/null | wc -l)
    local template_count=$(find "$TEMPLATE_DIR" -name "*.json" -type f 2>/dev/null | wc -l)
    local backup_count=$(find "$CONFIG_DIR" -name "*.backup.*" -type f 2>/dev/null | wc -l)
    
    echo -e "${WHITE}当前文件统计:${NC}"
    echo -e "  配置文件: ${GREEN}$config_count${NC} 个"
    echo -e "  模板文件: ${GREEN}$template_count${NC} 个"
    echo -e "  备份文件: ${GREEN}$backup_count${NC} 个"
    
    if [[ $config_count -eq 0 && $template_count -eq 0 && $backup_count -eq 0 ]]; then
        echo -e "${YELLOW}没有文件需要清理${NC}"
        return 0
    fi
    
    echo
    echo -e "${WHITE}清理选项:${NC}"
    echo -e "${GREEN}1.${NC} 清理备份文件"
    echo -e "${GREEN}2.${NC} 清理导出的配置文件"
    echo -e "${GREEN}3.${NC} 清理用户创建的模板"
    echo -e "${RED}4.${NC} 清理所有文件 (保留默认配置)"
    echo -e "${GREEN}5.${NC} 取消"
    echo -e "${YELLOW}0.${NC} 返回主菜单"
    echo
    
    while true; do
        read -p "请选择清理选项 (0-5): " choice
        
        case $choice in
            0)
                return 1
                ;;
            1)
                local backup_files=($(find "$CONFIG_DIR" -name "*.backup.*" -type f 2>/dev/null))
                if [[ ${#backup_files[@]} -gt 0 ]]; then
                    echo -e "${YELLOW}将删除 ${#backup_files[@]} 个备份文件${NC}"
                    read -p "确认删除? (y/N): " confirm
                    if [[ "$confirm" =~ ^[Yy]$ ]]; then
                        local deleted=0
                        for file in "${backup_files[@]}"; do
                            if rm -f "$file" 2>/dev/null; then
                                ((deleted++))
                            fi
                        done
                        echo -e "${GREEN}成功删除 $deleted 个备份文件${NC}"
                    fi
                else
                    echo -e "${YELLOW}没有备份文件需要清理${NC}"
                fi
                break
                ;;
            2)
                local export_files=($(find "$CONFIG_DIR" -name "export_*.json" -type f 2>/dev/null))
                if [[ ${#export_files[@]} -gt 0 ]]; then
                    echo -e "${YELLOW}将删除 ${#export_files[@]} 个导出文件${NC}"
                    read -p "确认删除? (y/N): " confirm
                    if [[ "$confirm" =~ ^[Yy]$ ]]; then
                        local deleted=0
                        for file in "${export_files[@]}"; do
                            if rm -f "$file" 2>/dev/null; then
                                ((deleted++))
                            fi
                        done
                        echo -e "${GREEN}成功删除 $deleted 个导出文件${NC}"
                    fi
                else
                    echo -e "${YELLOW}没有导出文件需要清理${NC}"
                fi
                break
                ;;
            3)
                # 清理用户模板（保留内置模板）
                local user_templates=($(find "$TEMPLATE_DIR" -name "*.json" -type f -exec grep -l '"author": "User"' {} \; 2>/dev/null))
                if [[ ${#user_templates[@]} -gt 0 ]]; then
                    echo -e "${YELLOW}将删除 ${#user_templates[@]} 个用户模板${NC}"
                    for template in "${user_templates[@]}"; do
                        local name=$(grep '"name":' "$template" | cut -d'"' -f4)
                        echo -e "  • $name"
                    done
                    read -p "确认删除? (y/N): " confirm
                    if [[ "$confirm" =~ ^[Yy]$ ]]; then
                        local deleted=0
                        for file in "${user_templates[@]}"; do
                            if rm -f "$file" 2>/dev/null; then
                                ((deleted++))
                            fi
                        done
                        echo -e "${GREEN}成功删除 $deleted 个用户模板${NC}"
                    fi
                else
                    echo -e "${YELLOW}没有用户模板需要清理${NC}"
                fi
                break
                ;;
            4)
                echo -e "${RED}⚠️  警告: 这将删除所有配置和模板文件！${NC}"
                echo -e "${YELLOW}默认配置文件将会保留并重置${NC}"
                read -p "确认清理所有文件? (输入 'CLEAN' 确认): " confirm
                if [[ "$confirm" == "CLEAN" ]]; then
                    # 删除所有文件
                    rm -f "$CONFIG_DIR"/*.json 2>/dev/null
                    rm -f "$CONFIG_DIR"/*.backup.* 2>/dev/null
                    rm -f "$TEMPLATE_DIR"/*.json 2>/dev/null
                    
                    # 重新创建默认配置和模板
                    init_default_config
                    create_builtin_templates
                    
                    echo -e "${GREEN}✓${NC} 所有文件已清理，默认配置已重置"
                    log_message "WARN" "用户清理了所有配置文件"
                else
                    echo -e "${YELLOW}清理已取消${NC}"
                fi
                break
                ;;
            5)
                echo -e "${YELLOW}清理已取消${NC}"
                break
                ;;
            *)
                echo -e "${RED}无效选择，请输入 0-5 之间的数字${NC}"
                ;;
        esac
    done
}

# 重置配置
config_reset() {
    echo -e "${BLUE}=== 🔄 重置配置 ===${NC}"
    echo
    
    echo -e "${YELLOW}⚠️  警告: 这将重置配置文件到默认状态${NC}"
    echo -e "${WHITE}当前配置文件将被备份${NC}"
    echo
    
    read -p "确认重置配置文件? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        # 备份当前配置
        if [[ -f "$CONFIG_FILE" ]]; then
            local backup_file="$CONFIG_FILE.reset_backup.$(date +%Y%m%d_%H%M%S)"
            cp "$CONFIG_FILE" "$backup_file"
            echo -e "${GREEN}✓${NC} 当前配置已备份到: $backup_file"
        fi
        
        # 重新创建默认配置
        rm -f "$CONFIG_FILE" 2>/dev/null
        init_default_config
        
        echo -e "${GREEN}✓${NC} 配置文件已重置为默认设置"
        log_message "INFO" "配置文件已重置为默认设置"
    else
        echo -e "${YELLOW}重置已取消${NC}"
    fi
}

# 配置文件和模板系统
# 配置文件和模板系统
# 配置文件和模板系统
# 配置文件和模板系统

# 初始化默认配置文件
init_default_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_message "INFO" "创建默认配置文件: $CONFIG_FILE"
        
        cat > "$CONFIG_FILE" << 'EOF'
# IPv6批量配置工具 - 默认配置文件
# 配置文件版本: 1.0

[general]
# 默认网络接口 (留空为自动选择)
default_interface=

# 默认子网掩码长度
default_subnet_mask=64

# 操作确认模式 (true/false)
require_confirmation=true

# 自动创建快照 (true/false)
auto_snapshot=true

# 日志级别 (INFO/WARN/ERROR)
log_level=INFO

[ipv6]
# 默认IPv6前缀
default_prefix=2012:f2c4:1:1f34

# 默认地址范围起始
default_start=1

# 默认地址范围结束
default_end=10

[templates]
# 启用的模板目录
template_dir=templates

# 自动加载模板 (true/false)
auto_load_templates=true

[backup]
# 最大快照数量
max_snapshots=50

# 快照保留天数
snapshot_retention_days=30

# 自动清理旧快照 (true/false)
auto_cleanup=true
EOF
        
        echo -e "${GREEN}✓${NC} 默认配置文件已创建"
    fi
}

# 读取配置文件
read_config() {
    local key=$1
    local section=$2
    local default_value=$3
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "$default_value"
        return
    fi
    
    local value
    if [[ -n "$section" ]]; then
        # 读取指定section下的key
        value=$(awk -F'=' -v section="[$section]" -v key="$key" '
            $0 == section { in_section = 1; next }
            /^\[/ && in_section { in_section = 0 }
            in_section && $1 == key { gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit }
        ' "$CONFIG_FILE")
    else
        # 读取全局key
        value=$(awk -F'=' -v key="$key" '
            !/^#/ && !/^\[/ && $1 == key { gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit }
        ' "$CONFIG_FILE")
    fi
    
    echo "${value:-$default_value}"
}

# 写入配置文件
write_config() {
    local key=$1
    local value=$2
    local section=$3
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        init_default_config
    fi
    
    local temp_file=$(mktemp)
    
    if [[ -n "$section" ]]; then
        # 更新指定section下的key
        awk -F'=' -v section="[$section]" -v key="$key" -v value="$value" '
            BEGIN { updated = 0 }
            $0 == section { in_section = 1; print; next }
            /^\[/ && in_section && !updated { 
                print key "=" value
                updated = 1
                in_section = 0
                print
                next
            }
            /^\[/ && in_section { in_section = 0 }
            in_section && $1 == key { 
                print key "=" value
                updated = 1
                next
            }
            { print }
            END { 
                if (!updated && in_section) {
                    print key "=" value
                }
            }
        ' "$CONFIG_FILE" > "$temp_file"
    else
        # 更新全局key
        awk -F'=' -v key="$key" -v value="$value" '
            BEGIN { updated = 0 }
            !/^#/ && !/^\[/ && $1 == key { 
                print key "=" value
                updated = 1
                next
            }
            { print }
            END { 
                if (!updated) {
                    print key "=" value
                }
            }
        ' "$CONFIG_FILE" > "$temp_file"
    fi
    
    mv "$temp_file" "$CONFIG_FILE"
    log_message "INFO" "配置已更新: $key=$value"
}

# 创建内置模板
create_builtin_templates() {
    # 家庭服务器模板
    cat > "$TEMPLATE_DIR/home_server.json" << 'EOF'
{
    "name": "家庭服务器",
    "description": "适用于家庭服务器的IPv6配置，包含常用服务端口",
    "version": "1.0",
    "author": "CodeBuddy",
    "config": {
        "prefix": "2012:f2c4:1:1f34",
        "subnet_mask": 64,
        "addresses": [
            {"type": "range", "start": 1, "end": 5},
            {"type": "single", "value": 80},
            {"type": "single", "value": 443},
            {"type": "single", "value": 22}
        ]
    },
    "tags": ["home", "server", "basic"]
}
EOF

    # Web服务器模板
    cat > "$TEMPLATE_DIR/web_server.json" << 'EOF'
{
    "name": "Web服务器",
    "description": "Web服务器常用端口配置",
    "version": "1.0",
    "author": "CodeBuddy",
    "config": {
        "prefix": "2012:f2c4:1:1f34",
        "subnet_mask": 64,
        "addresses": [
            {"type": "single", "value": 80, "description": "HTTP"},
            {"type": "single", "value": 443, "description": "HTTPS"},
            {"type": "single", "value": 8080, "description": "HTTP备用"},
            {"type": "single", "value": 8443, "description": "HTTPS备用"},
            {"type": "range", "start": 3000, "end": 3010, "description": "开发端口"}
        ]
    },
    "tags": ["web", "server", "http", "https"]
}
EOF

    # 邮件服务器模板
    cat > "$TEMPLATE_DIR/mail_server.json" << 'EOF'
{
    "name": "邮件服务器",
    "description": "邮件服务器端口配置",
    "version": "1.0",
    "author": "CodeBuddy",
    "config": {
        "prefix": "2012:f2c4:1:1f34",
        "subnet_mask": 64,
        "addresses": [
            {"type": "single", "value": 25, "description": "SMTP"},
            {"type": "single", "value": 110, "description": "POP3"},
            {"type": "single", "value": 143, "description": "IMAP"},
            {"type": "single", "value": 465, "description": "SMTPS"},
            {"type": "single", "value": 587, "description": "SMTP提交"},
            {"type": "single", "value": 993, "description": "IMAPS"},
            {"type": "single", "value": 995, "description": "POP3S"}
        ]
    },
    "tags": ["mail", "server", "smtp", "imap", "pop3"]
}
EOF

    # 测试环境模板
    cat > "$TEMPLATE_DIR/test_environment.json" << 'EOF'
{
    "name": "测试环境",
    "description": "开发和测试环境的IPv6配置",
    "version": "1.0",
    "author": "CodeBuddy",
    "config": {
        "prefix": "2012:f2c4:1:1f34",
        "subnet_mask": 64,
        "addresses": [
            {"type": "range", "start": 100, "end": 110, "description": "测试地址池"},
            {"type": "range", "start": 200, "end": 205, "description": "开发环境"},
            {"type": "single", "value": 9000, "description": "监控端口"}
        ]
    },
    "tags": ["test", "development", "staging"]
}
EOF

    # 大型网络模板
    cat > "$TEMPLATE_DIR/enterprise.json" << 'EOF'
{
    "name": "企业网络",
    "description": "大型企业网络IPv6配置",
    "version": "1.0",
    "author": "CodeBuddy",
    "config": {
        "prefix": "2012:f2c4:1:1f34",
        "subnet_mask": 64,
        "addresses": [
            {"type": "range", "start": 1, "end": 100, "description": "服务器池"},
            {"type": "range", "start": 1000, "end": 1050, "description": "应用服务"},
            {"type": "range", "start": 2000, "end": 2020, "description": "数据库服务"}
        ]
    },
    "tags": ["enterprise", "large", "production"]
}
EOF

    log_message "INFO" "内置模板已创建"
}

# 配置管理菜单
config_management() {
    while true; do
        echo -e "${BLUE}=== ⚙️  配置文件和模板管理 ===${NC}"
        echo
        echo -e "${GREEN}📋 模板管理${NC}"
        echo -e "${GREEN}1.${NC} 查看可用模板"
        echo -e "${GREEN}2.${NC} 应用配置模板"
        echo -e "${GREEN}3.${NC} 保存当前配置为模板"
        echo
        echo -e "${GREEN}📁 配置管理${NC}"
        echo -e "${GREEN}4.${NC} 导出当前配置"
        echo -e "${GREEN}5.${NC} 导入配置文件"
        echo -e "${GREEN}6.${NC} 查看配置文件"
        echo -e "${GREEN}7.${NC} 编辑配置文件"
        echo
        echo -e "${GREEN}🧹 维护操作${NC}"
        echo -e "${GREEN}8.${NC} 清理配置文件"
        echo -e "${GREEN}9.${NC} 重置为默认配置"
        echo -e "${GREEN}0.${NC} 返回主菜单"
        echo
        
        read -p "请选择操作 (0-9): " choice
        
        case $choice in
            1)
                echo
                list_templates
                echo
                read -p "按回车键继续..."
                ;;
            2)
                echo
                config_apply_template
                echo
                read -p "按回车键继续..."
                ;;
            3)
                echo
                config_save_template
                echo
                read -p "按回车键继续..."
                ;;
            4)
                echo
                config_export
                echo
                read -p "按回车键继续..."
                ;;
            5)
                echo
                config_import
                echo
                read -p "按回车键继续..."
                ;;
            6)
                echo
                config_view
                echo
                read -p "按回车键继续..."
                ;;
            7)
                echo
                config_edit
                echo
                read -p "按回车键继续..."
                ;;
            8)
                echo
                config_cleanup
                echo
                read -p "按回车键继续..."
                ;;
            9)
                echo
                config_reset
                echo
                read -p "按回车键继续..."
                ;;
            0)
                break
                ;;
            *)
                echo
                echo -e "${RED}无效选择，请输入 0-9 之间的数字${NC}"
                sleep 2
                ;;
        esac
    done
}

# 备份和回滚系统

# 创建配置快照
create_snapshot() {
    local interface=$1
    local operation_type=$2
    local description=$3
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local snapshot_file="$BACKUP_DIR/snapshot_${interface}_${timestamp}.json"
    
    log_message "INFO" "创建配置快照: $snapshot_file"
    
    # 获取当前IPv6配置
    local ipv6_addrs=($(ip -6 addr show "$interface" 2>/dev/null | grep "inet6" | grep -v "fe80" | awk '{print $2}'))
    
    # 创建JSON格式的快照
    cat > "$snapshot_file" << EOF
{
    "timestamp": "$(date '+%Y-%m-%d %H:%M:%S')",
    "interface": "$interface",
    "operation_type": "$operation_type",
    "description": "$description",
    "ipv6_addresses": [
EOF
    
    # 添加IPv6地址到快照
    for i in "${!ipv6_addrs[@]}"; do
        local addr="${ipv6_addrs[$i]}"
        if [[ $i -eq $((${#ipv6_addrs[@]} - 1)) ]]; then
            echo "        \"$addr\"" >> "$snapshot_file"
        else
            echo "        \"$addr\"," >> "$snapshot_file"
        fi
    done
    
    cat >> "$snapshot_file" << EOF
    ]
}
EOF
    
    # 更新操作历史
    update_operation_history "$snapshot_file" "$operation_type" "$description"
    
    echo "$snapshot_file"
}

# 更新操作历史
update_operation_history() {
    local snapshot_file=$1
    local operation_type=$2
    local description=$3
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # 如果历史文件不存在，创建初始结构
    if [[ ! -f "$OPERATION_HISTORY" ]]; then
        echo '{"operations": []}' > "$OPERATION_HISTORY"
    fi
    
    # 创建临时文件来更新历史
    local temp_file=$(mktemp)
    
    # 使用简单的文本处理来更新JSON（避免依赖jq）
    local operation_entry="{
        \"timestamp\": \"$timestamp\",
        \"operation_type\": \"$operation_type\",
        \"description\": \"$description\",
        \"snapshot_file\": \"$snapshot_file\",
        \"interface\": \"$SELECTED_INTERFACE\"
    }"
    
    # 读取现有历史并添加新操作
    if [[ -s "$OPERATION_HISTORY" ]]; then
        # 移除最后的 ]} 并添加新操作
        head -n -1 "$OPERATION_HISTORY" > "$temp_file"
        
        # 检查是否需要添加逗号
        if grep -q '"operations": \[\]' "$temp_file"; then
            # 空数组，直接添加
            sed 's/"operations": \[\]/"operations": [/' "$temp_file" > "$OPERATION_HISTORY"
            echo "        $operation_entry" >> "$OPERATION_HISTORY"
        else
            # 非空数组，添加逗号
            cat "$temp_file" >> "$OPERATION_HISTORY"
            echo "        ," >> "$OPERATION_HISTORY"
            echo "        $operation_entry" >> "$OPERATION_HISTORY"
        fi
        
        echo "    ]" >> "$OPERATION_HISTORY"
        echo "}" >> "$OPERATION_HISTORY"
    else
        # 创建新的历史文件
        cat > "$OPERATION_HISTORY" << EOF
{
    "operations": [
        $operation_entry
    ]
}
EOF
    fi
    
    rm -f "$temp_file"
    
    # 限制历史记录数量（保留最近50个操作）
    limit_operation_history
}

# 限制操作历史数量
limit_operation_history() {
    local max_operations=50
    local temp_file=$(mktemp)
    
    # 计算当前操作数量
    local operation_count=$(grep -c '"timestamp":' "$OPERATION_HISTORY" 2>/dev/null || echo "0")
    
    if [[ $operation_count -gt $max_operations ]]; then
        log_message "INFO" "清理操作历史，保留最近 $max_operations 个操作"
        
        # 提取最近的操作（这里使用简单的方法）
        # 在实际应用中可能需要更复杂的JSON处理
        cp "$OPERATION_HISTORY" "$temp_file"
        
        # 删除旧的快照文件
        local old_snapshots=$(find "$BACKUP_DIR" -name "snapshot_*.json" -type f | head -n -$max_operations)
        for old_snapshot in $old_snapshots; do
            rm -f "$old_snapshot" 2>/dev/null
        done
    fi
    
    rm -f "$temp_file"
}

# 从快照恢复配置
restore_from_snapshot() {
    local snapshot_file=$1
    local interface=$2
    
    if [[ ! -f "$snapshot_file" ]]; then
        log_message "ERROR" "快照文件不存在: $snapshot_file"
        return 1
    fi
    
    log_message "INFO" "从快照恢复配置: $snapshot_file"
    
    # 创建当前状态的备份（用于回滚的回滚）
    local current_backup=$(create_snapshot "$interface" "pre_restore" "恢复前的自动备份")
    
    # 清除当前所有IPv6地址（除了链路本地地址）
    local current_addrs=($(ip -6 addr show "$interface" 2>/dev/null | grep "inet6" | grep -v "fe80" | awk '{print $2}'))
    
    echo -e "${BLUE}=== 清除当前IPv6配置 ===${NC}"
    local clear_success=0
    local clear_error=0
    
    for addr in "${current_addrs[@]}"; do
        echo -n "删除 $addr ... "
        if ip -6 addr del "$addr" dev "$interface" 2>/dev/null; then
            echo -e "${GREEN}成功${NC}"
            ((clear_success++))
        else
            echo -e "${RED}失败${NC}"
            ((clear_error++))
        fi
    done
    
    # 从快照文件读取要恢复的地址
    echo
    echo -e "${BLUE}=== 从快照恢复IPv6配置 ===${NC}"
    
    # 提取IPv6地址（简单的文本处理）
    local restore_addrs=($(grep -o '"[0-9a-fA-F:]*\/[0-9]*"' "$snapshot_file" | tr -d '"'))
    
    local restore_success=0
    local restore_error=0
    
    for addr in "${restore_addrs[@]}"; do
        echo -n "恢复 $addr ... "
        if ip -6 addr add "$addr" dev "$interface" 2>/dev/null; then
            echo -e "${GREEN}成功${NC}"
            log_message "SUCCESS" "恢复IPv6地址: $addr"
            ((restore_success++))
        else
            echo -e "${RED}失败${NC}"
            log_message "ERROR" "恢复IPv6地址失败: $addr"
            ((restore_error++))
        fi
        sleep 0.1
    done
    
    echo
    echo -e "${BLUE}=== 恢复操作完成 ===${NC}"
    echo -e "清除: 成功 ${GREEN}$clear_success${NC}, 失败 ${RED}$clear_error${NC}"
    echo -e "恢复: 成功 ${GREEN}$restore_success${NC}, 失败 ${RED}$restore_error${NC}"
    
    # 记录恢复操作
    log_message "SUCCESS" "配置恢复完成: 清除 $clear_success 个，恢复 $restore_success 个地址"
    
    return 0
}

# 显示操作历史
show_operation_history() {
    echo -e "${BLUE}=== 📚 操作历史 ===${NC}"
    echo
    
    if [[ ! -f "$OPERATION_HISTORY" ]]; then
        echo -e "${YELLOW}暂无操作历史${NC}"
        return 0
    fi
    
    # 提取操作历史（简单的文本处理）
    local operations=($(grep -n '"timestamp":' "$OPERATION_HISTORY" | head -20))
    
    if [[ ${#operations[@]} -eq 0 ]]; then
        echo -e "${YELLOW}暂无操作历史${NC}"
        return 0
    fi
    
    echo -e "${WHITE}最近的操作记录:${NC}"
    echo
    
    local count=1
    for operation_line in "${operations[@]}"; do
        local line_num=$(echo "$operation_line" | cut -d: -f1)
        
        # 提取操作信息
        local timestamp=$(sed -n "${line_num}p" "$OPERATION_HISTORY" | grep -o '"timestamp": "[^"]*"' | cut -d'"' -f4)
        local op_type=$(sed -n "$((line_num+1))p" "$OPERATION_HISTORY" | grep -o '"operation_type": "[^"]*"' | cut -d'"' -f4)
        local description=$(sed -n "$((line_num+2))p" "$OPERATION_HISTORY" | grep -o '"description": "[^"]*"' | cut -d'"' -f4)
        local interface=$(sed -n "$((line_num+4))p" "$OPERATION_HISTORY" | grep -o '"interface": "[^"]*"' | cut -d'"' -f4)
        
        # 显示操作信息
        local op_color="${GREEN}"
        case $op_type in
            "add") op_color="${GREEN}"; op_type="添加" ;;
            "delete") op_color="${RED}"; op_type="删除" ;;
            "pre_restore") op_color="${YELLOW}"; op_type="恢复前备份" ;;
            *) op_color="${CYAN}" ;;
        esac
        
        echo -e "${WHITE}$count.${NC} ${op_color}[$op_type]${NC} $description"
        echo -e "    时间: ${CYAN}$timestamp${NC}"
        echo -e "    接口: ${GREEN}$interface${NC}"
        echo
        
        ((count++))
        if [[ $count -gt 10 ]]; then
            break
        fi
    done
}

# 回滚管理菜单
rollback_management() {
    while true; do
        echo -e "${BLUE}=== 🔄 回滚管理 ===${NC}"
        echo
        echo -e "${GREEN}1.${NC} 查看操作历史"
        echo -e "${GREEN}2.${NC} 回滚到指定快照"
        echo -e "${GREEN}3.${NC} 查看快照详情"
        echo -e "${GREEN}4.${NC} 清理旧快照"
        echo -e "${GREEN}5.${NC} 返回主菜单"
        echo
        
        read -p "请选择操作 (1-5): " choice
        
        case $choice in
            1)
                echo
                show_operation_history
                echo
                read -p "按回车键继续..."
                ;;
            2)
                echo
                rollback_to_snapshot
                echo
                read -p "按回车键继续..."
                ;;
            3)
                echo
                show_snapshot_details
                echo
                read -p "按回车键继续..."
                ;;
            4)
                echo
                cleanup_old_snapshots
                echo
                read -p "按回车键继续..."
                ;;
            5)
                break
                ;;
            *)
                echo
                echo -e "${RED}无效选择，请输入 1-5 之间的数字${NC}"
                sleep 2
                ;;
        esac
    done
}

# 回滚到指定快照
rollback_to_snapshot() {
    echo -e "${BLUE}=== 🔄 回滚到快照 ===${NC}"
    echo
    
    # 列出可用的快照
    local snapshots=($(find "$BACKUP_DIR" -name "snapshot_*.json" -type f | sort -r | head -20))
    
    if [[ ${#snapshots[@]} -eq 0 ]]; then
        echo -e "${YELLOW}没有可用的快照文件${NC}"
        return 0
    fi
    
    echo -e "${WHITE}可用的快照:${NC}"
    echo
    
    for i in "${!snapshots[@]}"; do
        local snapshot="${snapshots[$i]}"
        local filename=$(basename "$snapshot")
        
        # 提取快照信息
        local timestamp=$(grep '"timestamp":' "$snapshot" | cut -d'"' -f4)
        local interface=$(grep '"interface":' "$snapshot" | cut -d'"' -f4)
        local description=$(grep '"description":' "$snapshot" | cut -d'"' -f4)
        local addr_count=$(grep -c '"[0-9a-fA-F:]*\/[0-9]*"' "$snapshot")
        
        echo -e "${WHITE}$((i+1)).${NC} $filename"
        echo -e "    时间: ${CYAN}$timestamp${NC}"
        echo -e "    接口: ${GREEN}$interface${NC}"
        echo -e "    描述: ${YELLOW}$description${NC}"
        echo -e "    地址数: ${GREEN}$addr_count${NC}"
        echo
    done
    
    while true; do
        read -p "请选择要回滚的快照编号 (1-${#snapshots[@]}, 0=取消): " choice
        
        if [[ "$choice" == "0" ]]; then
            echo -e "${YELLOW}回滚操作已取消${NC}"
            return 0
        elif [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le ${#snapshots[@]} ]]; then
            local selected_snapshot="${snapshots[$((choice-1))]}"
            local interface=$(grep '"interface":' "$selected_snapshot" | cut -d'"' -f4)
            
            echo
            echo -e "${YELLOW}⚠️  警告: 回滚操作将替换当前的IPv6配置${NC}"
            echo -e "${WHITE}目标快照: $(basename "$selected_snapshot")${NC}"
            echo -e "${WHITE}目标接口: ${GREEN}$interface${NC}"
            echo
            
            read -p "确认执行回滚操作? (y/N): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                restore_from_snapshot "$selected_snapshot" "$interface"
            else
                echo -e "${YELLOW}回滚操作已取消${NC}"
            fi
            break
        else
            echo -e "${RED}无效选择，请输入 1-${#snapshots[@]} 或 0${NC}"
        fi
    done
}

# 显示快照详情
show_snapshot_details() {
    echo -e "${BLUE}=== 📋 快照详情 ===${NC}"
    echo
    
    local snapshots=($(find "$BACKUP_DIR" -name "snapshot_*.json" -type f | sort -r | head -10))
    
    if [[ ${#snapshots[@]} -eq 0 ]]; then
        echo -e "${YELLOW}没有可用的快照文件${NC}"
        return 0
    fi
    
    echo -e "${WHITE}选择要查看的快照:${NC}"
    echo
    
    for i in "${!snapshots[@]}"; do
        local snapshot="${snapshots[$i]}"
        local filename=$(basename "$snapshot")
        local timestamp=$(grep '"timestamp":' "$snapshot" | cut -d'"' -f4)
        
        echo -e "${WHITE}$((i+1)).${NC} $filename (${CYAN}$timestamp${NC})"
    done
    
    echo
    while true; do
        read -p "请选择快照编号 (1-${#snapshots[@]}, 0=返回): " choice
        
        if [[ "$choice" == "0" ]]; then
            return 0
        elif [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le ${#snapshots[@]} ]]; then
            local selected_snapshot="${snapshots[$((choice-1))]}"
            
            echo
            echo -e "${BLUE}=== 快照详细信息 ===${NC}"
            echo
            
            # 显示快照内容
            local timestamp=$(grep '"timestamp":' "$selected_snapshot" | cut -d'"' -f4)
            local interface=$(grep '"interface":' "$selected_snapshot" | cut -d'"' -f4)
            local operation_type=$(grep '"operation_type":' "$selected_snapshot" | cut -d'"' -f4)
            local description=$(grep '"description":' "$selected_snapshot" | cut -d'"' -f4)
            
            echo -e "文件名: ${GREEN}$(basename "$selected_snapshot")${NC}"
            echo -e "时间: ${CYAN}$timestamp${NC}"
            echo -e "接口: ${GREEN}$interface${NC}"
            echo -e "操作类型: ${YELLOW}$operation_type${NC}"
            echo -e "描述: ${WHITE}$description${NC}"
            echo
            
            echo -e "${WHITE}IPv6地址列表:${NC}"
            local addrs=($(grep -o '"[0-9a-fA-F:]*\/[0-9]*"' "$selected_snapshot" | tr -d '"'))
            
            if [[ ${#addrs[@]} -eq 0 ]]; then
                echo -e "  ${YELLOW}无IPv6地址${NC}"
            else
                for addr in "${addrs[@]}"; do
                    echo -e "  ${GREEN}•${NC} $addr"
                done
            fi
            
            break
        else
            echo -e "${RED}无效选择，请输入 1-${#snapshots[@]} 或 0${NC}"
        fi
    done
}

# 清理旧快照
cleanup_old_snapshots() {
    echo -e "${BLUE}=== 🧹 清理旧快照 ===${NC}"
    echo
    
    local all_snapshots=($(find "$BACKUP_DIR" -name "snapshot_*.json" -type f))
    local snapshot_count=${#all_snapshots[@]}
    
    if [[ $snapshot_count -eq 0 ]]; then
        echo -e "${YELLOW}没有快照文件需要清理${NC}"
        return 0
    fi
    
    echo -e "${WHITE}当前快照统计:${NC}"
    echo -e "  总数: ${GREEN}$snapshot_count${NC} 个快照"
    
    # 计算快照占用空间
    local total_size=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
    echo -e "  占用空间: ${GREEN}$total_size${NC}"
    
    echo
    echo -e "${WHITE}清理选项:${NC}"
    echo -e "${GREEN}1.${NC} 保留最近10个快照"
    echo -e "${GREEN}2.${NC} 保留最近20个快照"
    echo -e "${GREEN}3.${NC} 保留最近50个快照"
    echo -e "${GREEN}4.${NC} 清理7天前的快照"
    echo -e "${GREEN}5.${NC} 清理30天前的快照"
    echo -e "${RED}6.${NC} 清理所有快照"
    echo -e "${GREEN}7.${NC} 取消"
    echo -e "${YELLOW}0.${NC} 返回上级菜单"
    echo
    
    while true; do
        read -p "请选择清理方式 (0-7): " choice
        
        case $choice in
            0)
                return 1
                ;;
            1|2|3)
                local keep_count
                case $choice in
                    1) keep_count=10 ;;
                    2) keep_count=20 ;;
                    3) keep_count=50 ;;
                esac
                
                if [[ $snapshot_count -le $keep_count ]]; then
                    echo -e "${YELLOW}当前快照数量不超过 $keep_count 个，无需清理${NC}"
                else
                    local to_delete=$((snapshot_count - keep_count))
                    echo -e "${YELLOW}将删除最旧的 $to_delete 个快照${NC}"
                    read -p "确认执行? (y/N): " confirm
                    
                    if [[ "$confirm" =~ ^[Yy]$ ]]; then
                        local old_snapshots=($(find "$BACKUP_DIR" -name "snapshot_*.json" -type f | sort | head -n $to_delete))
                        local deleted=0
                        
                        for snapshot in "${old_snapshots[@]}"; do
                            if rm -f "$snapshot" 2>/dev/null; then
                                ((deleted++))
                            fi
                        done
                        
                        echo -e "${GREEN}成功删除 $deleted 个旧快照${NC}"
                        log_message "INFO" "清理旧快照: 删除 $deleted 个文件"
                    fi
                fi
                break
                ;;
            4|5)
                local days
                case $choice in
                    4) days=7 ;;
                    5) days=30 ;;
                esac
                
                local old_snapshots=($(find "$BACKUP_DIR" -name "snapshot_*.json" -type f -mtime +$days))
                local old_count=${#old_snapshots[@]}
                
                if [[ $old_count -eq 0 ]]; then
                    echo -e "${YELLOW}没有 $days 天前的快照需要清理${NC}"
                else
                    echo -e "${YELLOW}找到 $old_count 个超过 $days 天的快照${NC}"
                    read -p "确认删除? (y/N): " confirm
                    
                    if [[ "$confirm" =~ ^[Yy]$ ]]; then
                        local deleted=0
                        for snapshot in "${old_snapshots[@]}"; do
                            if rm -f "$snapshot" 2>/dev/null; then
                                ((deleted++))
                            fi
                        done
                        
                        echo -e "${GREEN}成功删除 $deleted 个旧快照${NC}"
                        log_message "INFO" "清理 $days 天前的快照: 删除 $deleted 个文件"
                    fi
                fi
                break
                ;;
            6)
                echo -e "${RED}⚠️  警告: 这将删除所有快照文件！${NC}"
                echo -e "${YELLOW}删除后将无法回滚到之前的配置状态${NC}"
                read -p "确认删除所有快照? (输入 'DELETE' 确认): " confirm
                
                if [[ "$confirm" == "DELETE" ]]; then
                    local deleted=0
                    for snapshot in "${all_snapshots[@]}"; do
                        if rm -f "$snapshot" 2>/dev/null; then
                            ((deleted++))
                        fi
                    done
                    
                    # 清理操作历史
                    rm -f "$OPERATION_HISTORY" 2>/dev/null
                    
                    echo -e "${GREEN}成功删除所有 $deleted 个快照${NC}"
                    log_message "WARN" "清理所有快照: 删除 $deleted 个文件"
                else
                    echo -e "${YELLOW}清理操作已取消${NC}"
                fi
                break
                ;;
            7)
                echo -e "${YELLOW}清理操作已取消${NC}"
                break
                ;;
            *)
                echo -e "${RED}无效选择，请输入 0-7 之间的数字${NC}"
                ;;
        esac
    done
}

# 检查是否为root用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_message "ERROR" "此脚本需要root权限运行"
        echo -e "${RED}请使用 sudo 运行此脚本${NC}"
        exit 1
    fi
}

# 检查系统依赖
check_dependencies() {
    local deps=("ip" "grep" "awk" "sed")
    local missing_deps=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_message "ERROR" "缺少依赖: ${missing_deps[*]}"
        echo -e "${RED}请安装缺少的依赖包${NC}"
        exit 1
    fi
}

# 验证IPv6前缀格式
validate_ipv6_prefix() {
    local prefix=$1
    
    # 检查是否为空
    if [[ -z "$prefix" ]]; then
        echo -e "${RED}IPv6前缀不能为空${NC}"
        return 1
    fi
    
    # 移除可能的尾部冒号
    prefix=${prefix%:}
    
    # 检查IPv6前缀格式 (支持压缩格式)
    if [[ ! "$prefix" =~ ^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$ ]] && [[ ! "$prefix" =~ ^::([0-9a-fA-F]{0,4}:){0,6}[0-9a-fA-F]{0,4}$ ]] && [[ ! "$prefix" =~ ^([0-9a-fA-F]{0,4}:){1,6}:([0-9a-fA-F]{0,4}:){0,5}[0-9a-fA-F]{0,4}$ ]]; then
        echo -e "${RED}IPv6前缀格式不正确${NC}"
        echo -e "${YELLOW}正确格式示例: 2012:f2c4:1:1f34 或 2001:db8::1${NC}"
        return 1
    fi
    
    # 检查段数 (IPv6最多8段)
    local segment_count=$(echo "$prefix" | tr -cd ':' | wc -c)
    if [[ $segment_count -ge 8 ]]; then
        echo -e "${RED}IPv6前缀段数过多，请留出至少1段用于地址配置${NC}"
        return 1
    fi
    
    return 0
}

# 验证文件名
validate_filename() {
    local filename=$1
    local name=$2
    
    # 如果为空，返回成功（允许使用默认值）
    if [[ -z "$filename" ]]; then
        return 0
    fi
    
    # 检查文件名是否包含非法字符
    local invalid_chars='[/\\:*?"<>|]'
    if [[ "$filename" =~ $invalid_chars ]]; then
        echo -e "${RED}${name}不能包含以下字符: / \\ : * ? \" < > |${NC}"
        return 1
    fi
    
    # 检查文件名长度
    if [[ ${#filename} -gt 255 ]]; then
        echo -e "${RED}${name}长度不能超过255个字符${NC}"
        return 1
    fi
    
    return 0
}

# 验证文件路径
validate_file_path() {
    local file_path=$1
    local name=$2
    
    # 检查是否为空
    if [[ -z "$file_path" ]]; then
        echo -e "${RED}${name}不能为空${NC}"
        return 1
    fi
    
    # 检查文件是否存在
    if [[ ! -f "$file_path" ]]; then
        echo -e "${RED}文件不存在: $file_path${NC}"
        return 1
    fi
    
    # 检查文件是否可读
    if [[ ! -r "$file_path" ]]; then
        echo -e "${RED}文件不可读: $file_path${NC}"
        return 1
    fi
    
    # 检查文件扩展名（如果是JSON文件）
    if [[ "$name" =~ 配置文件 ]] && [[ ! "$file_path" =~ \.json$ ]]; then
        echo -e "${YELLOW}⚠️  警告: 文件不是JSON格式，可能无法正确解析${NC}"
        read -p "确认使用此文件? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            return 1
        fi
    fi
    
    return 0
}

# 验证模板名称
validate_template_name() {
    local name=$1
    
    # 检查是否为空
    if [[ -z "$name" ]]; then
        echo -e "${RED}模板名称不能为空${NC}"
        return 1
    fi
    
    # 检查名称是否包含非法字符
    # 检查模板名称是否包含非法字符
    case "$name" in
        */*|*\\*|*:*|*\**|*\?*|*\"*|*\<*|*\>*|*\|*)
            echo -e "${RED}模板名称不能包含以下字符: / \\ : * ? \" < > |${NC}"
            return 1
            ;;
    esac
    
    # 检查名称长度
    if [[ ${#name} -gt 100 ]]; then
        echo -e "${RED}模板名称长度不能超过100个字符${NC}"
        return 1
    fi
    
    return 0
}

# 验证段范围输入
validate_segment_range() {
    local range_input=$1
    
    # 检查是否为空
    if [[ -z "$range_input" ]]; then
        echo -e "${RED}输入不能为空${NC}"
        return 1
    fi
    
    # 检查单个数字格式
    if [[ "$range_input" =~ ^[0-9]+$ ]]; then
        local num=$range_input
        if [[ $num -lt 0 || $num -gt 65535 ]]; then
            echo -e "${RED}数字必须在0-65535之间${NC}"
            return 1
        fi
        return 0
    fi
    
    # 检查范围格式 (数字-数字)
    if [[ "$range_input" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        local start=${BASH_REMATCH[1]}
        local end=${BASH_REMATCH[2]}
        
        if [[ $start -lt 0 || $start -gt 65535 ]]; then
            echo -e "${RED}起始值必须在0-65535之间${NC}"
            return 1
        fi
        
        if [[ $end -lt 0 || $end -gt 65535 ]]; then
            echo -e "${RED}结束值必须在0-65535之间${NC}"
            return 1
        fi
        
        if [[ $end -lt $start ]]; then
            echo -e "${RED}结束值必须大于或等于起始值${NC}"
            return 1
        fi
        
        local range_size=$((end - start + 1))
        if [[ $range_size -gt 1000 ]]; then
            echo -e "${YELLOW}⚠️  警告: 范围包含${range_size}个值，可能会生成大量地址${NC}"
            read -p "确认使用此范围? (y/N): " confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                return 1
            fi
        fi
        
        return 0
    fi
    
    echo -e "${RED}格式错误，请输入数字或数字-数字格式 (例如: 5 或 1-20)${NC}"
    return 1
}

# 验证地址编号
validate_address_number() {
    local number=$1
    local name=$2
    
    # 检查是否为空
    if [[ -z "$number" ]]; then
        echo -e "${RED}${name}不能为空${NC}"
        return 1
    fi
    
    # 检查是否为数字
    if [[ ! "$number" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}${name}必须是数字${NC}"
        return 1
    fi
    
    # 检查范围 (IPv6地址编号通常在1-65535之间)
    if [[ $number -lt 1 || $number -gt 65535 ]]; then
        echo -e "${RED}${name}必须在1-65535之间${NC}"
        return 1
    fi
    
    return 0
}

# 验证子网掩码长度
validate_subnet_mask() {
    local mask=$1
    
    # 检查是否为空，使用默认值
    if [[ -z "$mask" ]]; then
        echo "64"
        return 0
    fi
    
    # 检查是否为数字
    if [[ ! "$mask" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}子网掩码长度必须是数字${NC}"
        return 1
    fi
    
    # 检查范围 (IPv6子网掩码长度通常在48-128之间)
    if [[ $mask -lt 1 || $mask -gt 128 ]]; then
        echo -e "${RED}子网掩码长度必须在1-128之间${NC}"
        echo -e "${YELLOW}常用值: 64 (推荐), 48, 56, 96, 128${NC}"
        return 1
    fi
    
    # 对于小于48的值给出警告
    if [[ $mask -lt 48 ]]; then
        echo -e "${YELLOW}⚠️  警告: 子网掩码长度小于48可能不适合IPv6网络${NC}"
        read -p "确认使用 /$mask ? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            return 1
        fi
    fi
    
    echo "$mask"
    return 0
}

# 检测网络配置系统类型
detect_network_system() {
    if command -v netplan &> /dev/null && [[ -d /etc/netplan ]]; then
        echo "netplan"
    elif [[ -f /etc/network/interfaces ]]; then
        echo "interfaces"
    elif command -v nmcli &> /dev/null; then
        echo "networkmanager"
    else
        echo "unknown"
    fi
}

# 获取netplan配置文件路径
get_netplan_config_file() {
    local config_files=($(find /etc/netplan -name "*.yaml" -o -name "*.yml" 2>/dev/null | head -1))
    if [[ ${#config_files[@]} -gt 0 ]]; then
        echo "${config_files[0]}"
    else
        echo "/etc/netplan/01-netcfg.yaml"
    fi
}

# 备份网络配置文件
backup_network_config() {
    local network_system=$(detect_network_system)
    local backup_file=""
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    
    case $network_system in
        "netplan")
            local netplan_file=$(get_netplan_config_file)
            if [[ -f "$netplan_file" ]]; then
                backup_file="${netplan_file}.backup.${timestamp}"
                cp "$netplan_file" "$backup_file" 2>/dev/null
                echo "$backup_file"
            fi
            ;;
        "interfaces")
            if [[ -f /etc/network/interfaces ]]; then
                backup_file="/etc/network/interfaces.backup.${timestamp}"
                cp /etc/network/interfaces "$backup_file" 2>/dev/null
                echo "$backup_file"
            fi
            ;;
    esac
}

# 检查netplan依赖
check_netplan_dependencies() {
    local missing_deps=()
    
    # 检查Python3
    if ! command -v python3 &> /dev/null; then
        missing_deps+=("python3")
    fi
    
    # 检查PyYAML
    if ! python3 -c "import yaml" 2>/dev/null; then
        missing_deps+=("python3-yaml")
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        echo -e "${YELLOW}⚠${NC} 缺少netplan配置依赖: ${missing_deps[*]}"
        echo -e "${CYAN}安装命令:${NC} ${WHITE}sudo apt update && sudo apt install ${missing_deps[*]}${NC}"
        return 1
    fi
    
    return 0
}

# 写入netplan配置
write_netplan_config() {
    local interface=$1
    shift
    local addresses=("$@")
    
    local netplan_file=$(get_netplan_config_file)
    local temp_file=$(mktemp)
    
    log_message "INFO" "写入netplan配置: $netplan_file"
    
    # 检查依赖
    if check_netplan_dependencies; then
        # 使用Python方法处理YAML
        if write_netplan_with_python "$interface" "$netplan_file" "$temp_file" "${addresses[@]}"; then
            mv "$temp_file" "$netplan_file"
            chmod 600 "$netplan_file"
            
            # 验证生成的配置
            if netplan generate 2>/dev/null; then
                echo -e "${GREEN}✓${NC} netplan配置写入并验证成功"
                return 0
            else
                echo -e "${YELLOW}⚠${NC} netplan配置写入成功但验证失败，使用简单模式重新生成"
                write_netplan_simple "$interface" "${addresses[@]}"
                return $?
            fi
        else
            echo -e "${YELLOW}⚠${NC} Python方法失败，使用简单文本处理"
            write_netplan_simple "$interface" "${addresses[@]}"
            return $?
        fi
    else
        echo -e "${YELLOW}⚠${NC} 缺少依赖，使用简单文本处理"
        write_netplan_simple "$interface" "${addresses[@]}"
        return $?
    fi
    
    rm -f "$temp_file" 2>/dev/null
}

# 使用Python处理netplan配置
write_netplan_with_python() {
    local interface=$1
    local netplan_file=$2
    local temp_file=$3
    shift 3
    local addresses=("$@")
    
    python3 -c "
import yaml
import sys
import os

config_file = '$netplan_file'
interface = '$interface'
addresses = [$(printf "'%s'," "${addresses[@]}" | sed 's/,$//'))]

try:
    # 读取现有配置
    if os.path.exists(config_file):
        with open(config_file, 'r') as f:
            config = yaml.safe_load(f) or {}
    else:
        config = {}
    
    # 确保基本结构存在
    if 'network' not in config:
        config['network'] = {}
    if 'version' not in config['network']:
        config['network']['version'] = 2
    if 'ethernets' not in config['network']:
        config['network']['ethernets'] = {}
    if interface not in config['network']['ethernets']:
        config['network']['ethernets'][interface] = {}
    
    # 保留现有的重要配置
    interface_config = config['network']['ethernets'][interface]
    
    # 保留DHCP配置
    dhcp4_enabled = interface_config.get('dhcp4', False)
    dhcp6_enabled = interface_config.get('dhcp6', False)
    
    # 保留网关配置
    gateway4 = interface_config.get('gateway4')
    gateway6 = interface_config.get('gateway6')
    
    # 保留DNS配置
    nameservers = interface_config.get('nameservers')
    
    # 保留路由配置
    routes = interface_config.get('routes')
    
    # 获取现有地址
    existing_addresses = interface_config.get('addresses', [])
    
    # 分离IPv4和IPv6地址
    ipv4_addresses = [addr for addr in existing_addresses if ':' not in addr]
    ipv6_addresses = [addr for addr in existing_addresses if ':' in addr]
    
    # 添加新的IPv6地址（避免重复）
    for addr in addresses:
        if addr not in ipv6_addresses:
            ipv6_addresses.append(addr)
    
    # 合并所有地址
    all_addresses = ipv4_addresses + ipv6_addresses
    
    # 重新构建接口配置
    new_interface_config = {}
    
    # 保留DHCP配置（重要！）
    if dhcp4_enabled:
        new_interface_config['dhcp4'] = True
    if dhcp6_enabled:
        new_interface_config['dhcp6'] = True
    
    # 添加地址配置
    if all_addresses:
        new_interface_config['addresses'] = all_addresses
    
    # 保留其他重要配置
    if gateway4:
        new_interface_config['gateway4'] = gateway4
    if gateway6:
        new_interface_config['gateway6'] = gateway6
    if nameservers:
        new_interface_config['nameservers'] = nameservers
    if routes:
        new_interface_config['routes'] = routes
    
    # 更新配置
    config['network']['ethernets'][interface] = new_interface_config
    
    # 写入配置
    with open('$temp_file', 'w') as f:
        yaml.dump(config, f, default_flow_style=False, sort_keys=False, indent=2)
    
    print('SUCCESS')
    
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null
    
    return $?
}

# 简单的netplan配置写入
write_netplan_simple() {
    local interface=$1
    shift
    local addresses=("$@")
    
    local netplan_file=$(get_netplan_config_file)
    
    cat > "$netplan_file" << EOF
network:
  version: 2
  ethernets:
    $interface:
      addresses:
EOF
    
    for addr in "${addresses[@]}"; do
        echo "        - $addr" >> "$netplan_file"
    done
    
    chmod 600 "$netplan_file"
}

# 写入interfaces配置
write_interfaces_config() {
    local interface=$1
    shift
    local addresses=("$@")
    
    local interfaces_file="/etc/network/interfaces"
    local temp_file=$(mktemp)
    
    log_message "INFO" "写入interfaces配置: $interfaces_file"
    
    # 复制现有配置
    if [[ -f "$interfaces_file" ]]; then
        cp "$interfaces_file" "$temp_file"
    fi
    
    # 添加IPv6配置注释
    echo "" >> "$temp_file"
    echo "# IPv6 addresses added by ipv6_batch_config.sh - $(date)" >> "$temp_file"
    
    # 添加第一个地址作为主地址
    if [[ ${#addresses[@]} -gt 0 ]]; then
        local first_addr="${addresses[0]}"
        local ipv6_addr=$(echo "$first_addr" | cut -d'/' -f1)
        local prefix_len=$(echo "$first_addr" | cut -d'/' -f2)
        
        echo "iface $interface inet6 static" >> "$temp_file"
        echo "    address $ipv6_addr" >> "$temp_file"
        echo "    netmask $prefix_len" >> "$temp_file"
    fi
    
    # 添加其他地址作为up命令
    for ((i=1; i<${#addresses[@]}; i++)); do
        local addr="${addresses[$i]}"
        echo "    up ip -6 addr add $addr dev $interface" >> "$temp_file"
        echo "    down ip -6 addr del $addr dev $interface" >> "$temp_file"
    done
    
    mv "$temp_file" "$interfaces_file"
}

# 写入NetworkManager配置
write_networkmanager_config() {
    local interface=$1
    shift
    local addresses=("$@")
    
    log_message "INFO" "使用NetworkManager配置IPv6地址"
    
    # 获取连接名称
    local connection_name=$(nmcli -t -f NAME,DEVICE connection show --active | grep "$interface" | cut -d: -f1)
    
    if [[ -z "$connection_name" ]]; then
        log_message "ERROR" "未找到接口 $interface 的NetworkManager连接"
        return 1
    fi
    
    # 添加IPv6地址
    for addr in "${addresses[@]}"; do
        nmcli connection modify "$connection_name" +ipv6.addresses "$addr" 2>/dev/null
    done
    
    # 重新激活连接
    nmcli connection up "$connection_name" 2>/dev/null
}

# 应用网络配置
apply_network_config() {
    local network_system=$(detect_network_system)
    
    case $network_system in
        "netplan")
            echo -e "${CYAN}应用netplan配置...${NC}"
            
            # 首先验证配置语法
            echo -e "${CYAN}验证netplan配置语法...${NC}"
            local netplan_file=$(get_netplan_config_file)
            
            if netplan generate 2>/dev/null; then
                echo -e "${GREEN}✓${NC} netplan配置语法正确"
            else
                echo -e "${RED}✗${NC} netplan配置语法错误"
                echo -e "${YELLOW}错误详情:${NC}"
                netplan generate 2>&1 | head -10
                return 1
            fi
            
            # 尝试安全应用配置
            echo -e "${CYAN}尝试安全应用配置 (120秒超时)...${NC}"
            if timeout 120 netplan try --timeout=30 2>/dev/null; then
                echo -e "${GREEN}✓${NC} netplan配置应用成功"
                return 0
            else
                echo -e "${YELLOW}⚠${NC} netplan try失败，尝试直接应用..."
                
                # 备用方案：直接应用
                local apply_output=$(netplan apply 2>&1)
                local apply_result=$?
                
                if [[ $apply_result -eq 0 ]]; then
                    echo -e "${GREEN}✓${NC} netplan配置应用成功"
                    return 0
                else
                    echo -e "${RED}✗${NC} netplan配置应用失败"
                    echo -e "${YELLOW}错误详情:${NC}"
                    echo "$apply_output" | head -10
                    
                    # 提供手动解决方案
                    echo
                    echo -e "${BLUE}=== 解决方案 ===${NC}"
                    echo -e "${WHITE}1. 运行netplan修复工具:${NC} ${CYAN}./fix_netplan.sh${NC}"
                    echo -e "${WHITE}2. 检查配置文件:${NC} ${CYAN}sudo nano $netplan_file${NC}"
                    echo -e "${WHITE}3. 验证语法:${NC} ${CYAN}sudo netplan generate${NC}"
                    echo -e "${WHITE}4. 测试配置:${NC} ${CYAN}sudo netplan try${NC}"
                    echo -e "${WHITE}5. 应用配置:${NC} ${CYAN}sudo netplan apply${NC}"
                    echo -e "${WHITE}6. 重启网络:${NC} ${CYAN}sudo systemctl restart systemd-networkd${NC}"
                    
                    echo
                    read -p "是否运行自动修复工具? (y/N): " run_fix
                    if [[ "$run_fix" =~ ^[Yy]$ ]]; then
                        if [[ -f "./fix_netplan.sh" ]]; then
                            echo -e "${CYAN}正在运行netplan修复工具...${NC}"
                            ./fix_netplan.sh
                        else
                            echo -e "${YELLOW}修复工具不存在，请手动解决${NC}"
                        fi
                    fi
                    
                    return 1
                fi
            fi
            ;;
        "interfaces")
            echo -e "${CYAN}重启网络服务...${NC}"
            if systemctl restart networking 2>/dev/null; then
                echo -e "${GREEN}✓${NC} 网络服务重启成功"
                return 0
            else
                echo -e "${RED}✗${NC} 网络服务重启失败"
                echo -e "${YELLOW}尝试其他方法...${NC}"
                
                # 尝试ifdown/ifup
                local interface_name=$(echo "$SELECTED_INTERFACE" | head -1)
                if ifdown "$interface_name" 2>/dev/null && ifup "$interface_name" 2>/dev/null; then
                    echo -e "${GREEN}✓${NC} 接口重启成功"
                    return 0
                else
                    echo -e "${RED}✗${NC} 接口重启失败"
                    return 1
                fi
            fi
            ;;
        "networkmanager")
            echo -e "${GREEN}✓${NC} NetworkManager配置已应用"
            return 0
            ;;
        *)
            echo -e "${YELLOW}⚠${NC} 未知的网络配置系统，请手动重启网络服务"
            return 1
            ;;
    esac
}

# 持久化配置功能
make_persistent() {
    local interface=$1
    shift
    local addresses=("$@")
    
    if [[ ${#addresses[@]} -eq 0 ]]; then
        return 0
    fi
    
    echo
    echo -e "${BLUE}=== 🔒 配置持久化 ===${NC}"
    echo -e "${YELLOW}检测到您添加了 ${#addresses[@]} 个IPv6地址${NC}"
    echo -e "${WHITE}是否要使配置在系统重启后保持？${NC}"
    echo
    
    local network_system=$(detect_network_system)
    echo -e "${CYAN}检测到的网络配置系统: ${GREEN}$network_system${NC}"
    
    case $network_system in
        "netplan")
            echo -e "${WHITE}将使用 netplan 配置文件进行持久化${NC}"
            ;;
        "interfaces")
            echo -e "${WHITE}将使用 /etc/network/interfaces 进行持久化${NC}"
            ;;
        "networkmanager")
            echo -e "${WHITE}将使用 NetworkManager 进行持久化${NC}"
            ;;
        "unknown")
            echo -e "${YELLOW}⚠${NC} 未检测到支持的网络配置系统"
            echo -e "${WHITE}将创建启动脚本进行持久化${NC}"
            ;;
    esac
    
    echo
    echo -e "${GREEN}1.${NC} 创建启动脚本（推荐）"
    echo -e "${GREEN}2.${NC} 创建systemd服务"
    echo -e "${GREEN}3.${NC} 否 - 仅临时配置"
    echo -e "${GREEN}0.${NC} 返回上级菜单"
    echo
    
    local persist_choice
    while true; do
        read -p "请选择持久化方式 (0-3): " persist_choice
        if [[ "$persist_choice" =~ ^[0-3]$ ]]; then
            break
        else
            echo -e "${RED}请输入 0-3 之间的数字${NC}"
        fi
    done
    
    case $persist_choice in
        0)
            return 0
            ;;
        1)
            create_startup_script "$interface" "${addresses[@]}"
            ;;
        2)
            create_systemd_service "$interface" "${addresses[@]}"
            ;;
        3)
            echo -e "${YELLOW}配置未持久化，重启后将丢失${NC}"
            log_message "INFO" "用户选择不持久化配置"
            return 0
            ;;
    esac
}

# 网络连通性测试
test_network_connectivity() {
    echo -e "${CYAN}测试网络连通性...${NC}"
    
    # 测试多个目标
    local test_targets=("8.8.8.8" "1.1.1.1" "114.114.114.114")
    
    for target in "${test_targets[@]}"; do
        if ping -c 1 -W 3 "$target" >/dev/null 2>&1; then
            echo -e "${GREEN}✓${NC} 网络连接正常 ($target)"
            return 0
        fi
    done
    
    echo -e "${RED}✗${NC} 网络连接失败"
    return 1
}

# 安全的配置应用
safe_apply_config() {
    local network_system=$1
    
    echo -e "${YELLOW}⚠️  重要安全提醒 ⚠️${NC}"
    echo -e "${WHITE}应用网络配置可能会暂时中断网络连接${NC}"
    echo -e "${WHITE}如果是远程服务器，请确保有其他方式访问（如VPS控制面板）${NC}"
    echo
    
    # 测试当前网络连通性
    if ! test_network_connectivity; then
        echo -e "${RED}当前网络连接异常，建议先修复网络问题${NC}"
        return 1
    fi
    
    echo -e "${CYAN}准备应用配置，将在30秒后自动回滚（如果网络中断）${NC}"
    read -p "确认继续? (输入 'YES' 确认): " confirm_apply
    
    if [[ "$confirm_apply" != "YES" ]]; then
        echo -e "${YELLOW}配置应用已取消${NC}"
        return 1
    fi
    
    # 创建自动回滚脚本
    local rollback_script="/tmp/network_rollback_$$"
    cat > "$rollback_script" << 'EOF'
#!/bin/bash
sleep 30
if ! ping -c 1 8.8.8.8 >/dev/null 2>&1; then
    echo "网络连接失败，执行自动回滚..."
    if [[ -f /etc/netplan/01-netcfg.yaml.backup.* ]]; then
        latest_backup=$(ls -t /etc/netplan/01-netcfg.yaml.backup.* | head -1)
        cp "$latest_backup" /etc/netplan/01-netcfg.yaml
        netplan apply 2>/dev/null
        systemctl restart systemd-networkd 2>/dev/null
        echo "自动回滚完成"
    fi
fi
rm -f "$0"
EOF
    
    chmod +x "$rollback_script"
    
    # 在后台启动回滚脚本
    "$rollback_script" &
    local rollback_pid=$!
    
    echo -e "${CYAN}正在应用配置...${NC}"
    
    # 应用配置
    local apply_result=false
    if apply_network_config; then
        apply_result=true
    fi
    
    # 等待几秒让网络稳定
    sleep 5
    
    # 测试网络连通性
    if test_network_connectivity; then
        echo -e "${GREEN}✓${NC} 配置应用成功，网络连接正常"
        
        # 停止回滚脚本
        kill $rollback_pid 2>/dev/null
        rm -f "$rollback_script" 2>/dev/null
        
        return 0
    else
        echo -e "${RED}✗${NC} 配置应用后网络连接失败"
        echo -e "${YELLOW}等待自动回滚...${NC}"
        
        # 等待回滚完成
        wait $rollback_pid 2>/dev/null
        
        # 再次测试网络
        sleep 5
        if test_network_connectivity; then
            echo -e "${GREEN}✓${NC} 自动回滚成功，网络已恢复"
        else
            echo -e "${RED}✗${NC} 自动回滚失败，请手动恢复网络"
            echo -e "${CYAN}紧急恢复命令: ./emergency_network_recovery.sh${NC}"
        fi
        
        return 1
    fi
}

# 持久化到配置文件

# 创建启动脚本
create_startup_script() {
    local interface=$1
    shift
    local addresses=("$@")
    
    echo
    echo -e "${BLUE}=== 📜 创建启动脚本 ===${NC}"
    
    local script_file="/etc/rc.local"
    local temp_file=$(mktemp)
    
    # 检查rc.local是否存在
    if [[ -f "$script_file" ]]; then
        # 备份现有文件
        cp "$script_file" "${script_file}.backup.$(date +%Y%m%d_%H%M%S)"
        
        # 移除exit 0行
        grep -v "^exit 0" "$script_file" > "$temp_file"
    else
        # 创建新的rc.local
        cat > "$temp_file" << 'EOF'
#!/bin/bash
# /etc/rc.local
# This script is executed at the end of each multiuser runlevel.
EOF
    fi
    
    # 添加IPv6配置
    echo "" >> "$temp_file"
    echo "# IPv6 addresses added by ipv6_batch_config.sh - $(date)" >> "$temp_file"
    for addr in "${addresses[@]}"; do
        echo "ip -6 addr add $addr dev $interface 2>/dev/null || true" >> "$temp_file"
    done
    
    echo "" >> "$temp_file"
    echo "exit 0" >> "$temp_file"
    
    # 安装脚本
    mv "$temp_file" "$script_file"
    chmod +x "$script_file"
    
    # 确保rc.local服务启用
    if command -v systemctl &> /dev/null; then
        systemctl enable rc-local 2>/dev/null || true
    fi
    
    echo -e "${GREEN}✓${NC} 启动脚本已创建: $script_file"
    log_message "SUCCESS" "IPv6配置启动脚本已创建"
    
    return 0
}

# 创建systemd服务
create_systemd_service() {
    local interface=$1
    shift
    local addresses=("$@")
    
    echo
    echo -e "${BLUE}=== ⚙️ 创建systemd服务 ===${NC}"
    
    local service_name="ipv6-persistent"
    local service_file="/etc/systemd/system/${service_name}.service"
    local script_file="/usr/local/bin/${service_name}.sh"
    
    # 创建配置脚本
    cat > "$script_file" << EOF
#!/bin/bash
# IPv6 Persistent Configuration Script
# Generated by ipv6_batch_config.sh on $(date)

INTERFACE="$interface"
ADDRESSES=($(printf '"%s" ' "${addresses[@]}"))

# 等待网络接口就绪
sleep 5

# 添加IPv6地址
for addr in "\${ADDRESSES[@]}"; do
    echo "Adding IPv6 address: \$addr"
    ip -6 addr add "\$addr" dev "\$INTERFACE" 2>/dev/null || true
done

echo "IPv6 persistent configuration completed"
EOF
    
    chmod +x "$script_file"
    
    # 创建systemd服务文件
    cat > "$service_file" << EOF
[Unit]
Description=IPv6 Persistent Address Configuration
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$script_file
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    
    # 重新加载systemd并启用服务
    systemctl daemon-reload
    systemctl enable "$service_name.service"
    
    echo -e "${GREEN}✓${NC} systemd服务已创建: $service_name"
    echo -e "${GREEN}✓${NC} 配置脚本: $script_file"
    
    # 询问是否立即启动服务
    read -p "是否立即启动服务进行测试? (y/N): " start_now
    if [[ "$start_now" =~ ^[Yy]$ ]]; then
        if systemctl start "$service_name.service"; then
            echo -e "${GREEN}✓${NC} 服务启动成功"
            systemctl status "$service_name.service" --no-pager -l
        else
            echo -e "${RED}✗${NC} 服务启动失败"
        fi
    fi
    
    log_message "SUCCESS" "IPv6配置systemd服务已创建: $service_name"
    
    return 0
}

# 检查配置持久化状态
check_persistence_status() {
    local interface=$1
    
    echo -e "${BLUE}=== 🔍 持久化状态检查 ===${NC}"
    echo
    
    local network_system=$(detect_network_system)
    local has_persistent_config=false
    
    echo -e "${WHITE}网络配置系统: ${GREEN}$network_system${NC}"
    
    case $network_system in
        "netplan")
            local netplan_file=$(get_netplan_config_file)
            if [[ -f "$netplan_file" ]] && grep -q "$interface" "$netplan_file" 2>/dev/null; then
                local ipv6_count=$(grep -c ":" "$netplan_file" 2>/dev/null || echo "0")
                if [[ $ipv6_count -gt 0 ]]; then
                    echo -e "${GREEN}✓${NC} 在netplan配置中找到IPv6地址"
                    has_persistent_config=true
                fi
            fi
            ;;
        "interfaces")
            if [[ -f /etc/network/interfaces ]] && grep -q "$interface.*inet6" /etc/network/interfaces 2>/dev/null; then
                echo -e "${GREEN}✓${NC} 在interfaces配置中找到IPv6地址"
                has_persistent_config=true
            fi
            ;;
    esac
    
    # 检查启动脚本
    if [[ -f /etc/rc.local ]] && grep -q "ip -6 addr add.*$interface" /etc/rc.local 2>/dev/null; then
        echo -e "${GREEN}✓${NC} 在启动脚本中找到IPv6配置"
        has_persistent_config=true
    fi
    
    # 检查systemd服务
    if systemctl list-unit-files | grep -q "ipv6-persistent" 2>/dev/null; then
        echo -e "${GREEN}✓${NC} 找到IPv6持久化systemd服务"
        has_persistent_config=true
    fi
    
    if [[ "$has_persistent_config" == false ]]; then
        echo -e "${YELLOW}⚠${NC} 未找到持久化配置"
        echo -e "${CYAN}当前配置在重启后将丢失${NC}"
    fi
    
    echo
}

# 清理持久化配置
cleanup_persistent_config() {
    local interface=$1
    
    echo -e "${BLUE}=== 🧹 清理持久化配置 ===${NC}"
    echo
    
    echo -e "${YELLOW}⚠${NC} 这将移除所有相关的持久化配置"
    echo -e "${WHITE}包括: 配置文件、启动脚本、systemd服务${NC}"
    echo
    
    read -p "确认清理持久化配置? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}清理操作已取消${NC}"
        return 0
    fi
    
    local cleaned=0
    
    # 清理netplan配置
    local netplan_file=$(get_netplan_config_file)
    if [[ -f "$netplan_file" ]] && grep -q "$interface" "$netplan_file" 2>/dev/null; then
        echo -n "清理netplan配置... "
        # 这里需要更复杂的逻辑来只移除IPv6地址而不影响其他配置
        echo -e "${YELLOW}需要手动编辑${NC}"
        ((cleaned++))
    fi
    
    # 清理rc.local
    if [[ -f /etc/rc.local ]] && grep -q "ip -6 addr add.*$interface" /etc/rc.local 2>/dev/null; then
        echo -n "清理启动脚本... "
        local temp_file=$(mktemp)
        grep -v "ip -6 addr add.*$interface" /etc/rc.local > "$temp_file"
        mv "$temp_file" /etc/rc.local
        echo -e "${GREEN}完成${NC}"
        ((cleaned++))
    fi
    
    # 清理systemd服务
    if systemctl list-unit-files | grep -q "ipv6-persistent" 2>/dev/null; then
        echo -n "清理systemd服务... "
        systemctl disable ipv6-persistent.service 2>/dev/null
        systemctl stop ipv6-persistent.service 2>/dev/null
        rm -f /etc/systemd/system/ipv6-persistent.service
        rm -f /usr/local/bin/ipv6-persistent.sh
        systemctl daemon-reload
        echo -e "${GREEN}完成${NC}"
        ((cleaned++))
    fi
    
    echo
    if [[ $cleaned -gt 0 ]]; then
        echo -e "${GREEN}✓${NC} 清理完成，共处理 $cleaned 项配置"
        log_message "SUCCESS" "持久化配置清理完成"
    else
        echo -e "${YELLOW}未找到需要清理的持久化配置${NC}"
    fi
}

# 显示横幅
show_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                    IPv6 批量配置工具                         ║"
    echo "║                  Ubuntu Server Edition                       ║"
    echo "║                      Version 1.0                            ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo
}

# 获取网络接口列表
get_network_interfaces() {
    ip link show | grep -E "^[0-9]+:" | awk -F': ' '{print $2}' | grep -v lo
}

# 显示当前IPv6配置
show_current_ipv6() {
    echo -e "${BLUE}=== 当前IPv6配置 ===${NC}"
    echo
    
    local interfaces=$(get_network_interfaces)
    if [[ -z "$interfaces" ]]; then
        echo -e "${YELLOW}未找到可用的网络接口${NC}"
        return
    fi
    
    while IFS= read -r interface; do
        echo -e "${WHITE}接口: $interface${NC}"
        local ipv6_addrs=$(ip -6 addr show "$interface" 2>/dev/null | grep "inet6" | grep -v "fe80" | awk '{print $2}')
        
        if [[ -n "$ipv6_addrs" ]]; then
            while IFS= read -r addr; do
                echo -e "  ${GREEN}✓${NC} $addr"
            done <<< "$ipv6_addrs"
        else
            echo -e "  ${YELLOW}无IPv6地址配置${NC}"
        fi
        echo
    done <<< "$interfaces"
}

# 选择网络接口
select_interface() {
    local interfaces=($(get_network_interfaces))
    
    if [[ ${#interfaces[@]} -eq 0 ]]; then
        log_message "ERROR" "未找到可用的网络接口"
        return 1
    fi
    
    echo -e "${BLUE}=== 选择网络接口 ===${NC}"
    echo
    
    for i in "${!interfaces[@]}"; do
        local status=$(ip link show "${interfaces[$i]}" | grep -o "state [A-Z]*" | awk '{print $2}')
        echo -e "${WHITE}$((i+1)).${NC} ${interfaces[$i]} ${GREEN}($status)${NC}"
    done
    echo -e "${WHITE}0.${NC} 返回主菜单"
    
    echo
    while true; do
        read -p "请选择接口编号 (0-${#interfaces[@]}): " choice
        
        if [[ "$choice" == "0" ]]; then
            return 0
        elif [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le ${#interfaces[@]} ]]; then
            SELECTED_INTERFACE="${interfaces[$((choice-1))]}"
            log_message "INFO" "选择了网络接口: $SELECTED_INTERFACE"
            break
        else
            echo -e "${RED}无效选择，请输入 0-${#interfaces[@]} 之间的数字${NC}"
        fi
    done
}

# IPv6地址验证
validate_ipv6() {
    local ipv6=$1
    # 简单的IPv6格式验证
    if [[ $ipv6 =~ ^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$ ]]; then
        return 0
    else
        return 1
    fi
}

# 解析范围输入 (支持 "数字-数字" 或单个数字)
parse_range() {
    local input=$1
    local var_start=$2
    local var_end=$3
    
    if [[ "$input" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        # 范围格式: 1-10
        eval "$var_start=${BASH_REMATCH[1]}"
        eval "$var_end=${BASH_REMATCH[2]}"
        
        if [[ ${BASH_REMATCH[1]} -gt ${BASH_REMATCH[2]} ]]; then
            return 1  # 起始值大于结束值
        fi
    elif [[ "$input" =~ ^[0-9]+$ ]]; then
        # 单个数字: 5
        eval "$var_start=$input"
        eval "$var_end=$input"
    else
        return 2  # 格式错误
    fi
    
    return 0
}

# 生成IPv6地址组合 - 使用迭代方法避免递归问题
generate_ipv6_combinations() {
    local prefix=$1
    local subnet_mask=$2
    local ranges_str="$3"
    
    # 将范围字符串转换为数组
    IFS='|' read -ra ranges <<< "$ranges_str"
    
    # 解析每个段的范围
    local segment_starts=()
    local segment_ends=()
    
    for range_info in "${ranges[@]}"; do
        if [[ "$range_info" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            segment_starts+=(${BASH_REMATCH[1]})
            segment_ends+=(${BASH_REMATCH[2]})
        else
            segment_starts+=($range_info)
            segment_ends+=($range_info)
        fi
    done
    
    # 生成所有组合
    local addresses=()
    generate_combinations_iterative "$prefix" "$subnet_mask" segment_starts segment_ends addresses
    
    # 输出结果到全局变量
    GENERATED_ADDRESSES=("${addresses[@]}")
}

# 迭代生成组合
generate_combinations_iterative() {
    local prefix=$1
    local subnet_mask=$2
    local -n starts=$3
    local -n ends=$4
    local -n result=$5
    
    local num_segments=${#starts[@]}
    
    if [[ $num_segments -eq 1 ]]; then
        # 只有一个段
        for ((i=${starts[0]}; i<=${ends[0]}; i++)); do
            result+=("$prefix:$i/$subnet_mask")
        done
    elif [[ $num_segments -eq 2 ]]; then
        # 两个段
        for ((i=${starts[0]}; i<=${ends[0]}; i++)); do
            for ((j=${starts[1]}; j<=${ends[1]}; j++)); do
                result+=("$prefix:$i:$j/$subnet_mask")
            done
        done
    elif [[ $num_segments -eq 3 ]]; then
        # 三个段
        for ((i=${starts[0]}; i<=${ends[0]}; i++)); do
            for ((j=${starts[1]}; j<=${ends[1]}; j++)); do
                for ((k=${starts[2]}; k<=${ends[2]}; k++)); do
                    result+=("$prefix:$i:$j:$k/$subnet_mask")
                done
            done
        done
    elif [[ $num_segments -eq 4 ]]; then
        # 四个段
        for ((i=${starts[0]}; i<=${ends[0]}; i++)); do
            for ((j=${starts[1]}; j<=${ends[1]}; j++)); do
                for ((k=${starts[2]}; k<=${ends[2]}; k++)); do
                    for ((l=${starts[3]}; l<=${ends[3]}; l++)); do
                        result+=("$prefix:$i:$j:$k:$l/$subnet_mask")
                    done
                done
            done
        done
    else
        # 超过4个段，使用通用方法
        generate_combinations_general "$prefix" "$subnet_mask" starts ends result
    fi
}

# 通用组合生成方法（支持任意段数）
generate_combinations_general() {
    local prefix=$1
    local subnet_mask=$2
    local -n starts=$3
    local -n ends=$4
    local -n result=$5
    
    local num_segments=${#starts[@]}
    local indices=()
    
    # 初始化索引数组
    for ((i=0; i<num_segments; i++)); do
        indices[i]=${starts[i]}
    done
    
    # 生成所有组合
    while true; do
        # 构建当前地址
        local addr="$prefix"
        for ((i=0; i<num_segments; i++)); do
            addr="$addr:${indices[i]}"
        done
        result+=("$addr/$subnet_mask")
        
        # 递增索引（类似进位）
        local carry=1
        for ((i=num_segments-1; i>=0 && carry; i--)); do
            indices[i]=$((indices[i] + carry))
            if [[ ${indices[i]} -le ${ends[i]} ]]; then
                carry=0
            else
                indices[i]=${starts[i]}
            fi
        done
        
        # 如果所有位都进位了，说明完成
        if [[ $carry -eq 1 ]]; then
            break
        fi
    done
}

# 批量添加IPv6地址 - 新的灵活模式
batch_add_ipv6() {
    echo -e "${BLUE}=== IPv6地址批量配置 ===${NC}"
    echo
    
    # 选择网络接口
    select_interface
    if [[ $? -ne 0 ]]; then
        return 1
    fi
    
    echo
    echo -e "${WHITE}当前选择的接口: ${GREEN}$SELECTED_INTERFACE${NC}"
    echo
    
    # 获取IPv6前缀
    echo -e "${BLUE}=== IPv6前缀配置 ===${NC}"
    echo -e "${YELLOW}请输入IPv6前缀 (例如: 2012:f2c4:1:1f34)${NC}"
    echo -e "${CYAN}提示: 输入前面固定不变的部分，后面的段将分别配置${NC}"
    
    local ipv6_prefix
    while true; do
        read -p "IPv6前缀: " ipv6_prefix
        if validate_ipv6_prefix "$ipv6_prefix"; then
            break
        fi
        echo -e "${YELLOW}请重新输入正确的IPv6前缀${NC}"
    done
    
    # 计算已有的段数
    local prefix_segments=$(echo "$ipv6_prefix" | tr ':' '\n' | wc -l)
    local remaining_segments=$((8 - prefix_segments))
    
    if [[ $remaining_segments -le 0 ]]; then
        log_message "ERROR" "IPv6前缀段数过多，请留出至少1段用于配置"
        return 1
    fi
    
    echo
    echo -e "${BLUE}=== 地址段范围配置 ===${NC}"
    echo -e "${WHITE}IPv6前缀: ${GREEN}$ipv6_prefix${NC}"
    echo -e "${WHITE}需要配置的段数: ${GREEN}$remaining_segments${NC}"
    echo -e "${CYAN}输入格式说明:${NC}"
    echo -e "  - 单个值: ${YELLOW}5${NC} (只生成该值)"
    echo -e "  - 范围值: ${YELLOW}1-10${NC} (生成1到10的所有值)"
    echo
    
    # 收集每段的范围配置
    local segment_ranges=()
    local segment_labels=("第1段" "第2段" "第3段" "第4段" "第5段" "第6段" "第7段" "第8段")
    
    for ((i=0; i<remaining_segments; i++)); do
        local segment_num=$((prefix_segments + i + 1))
        local label="${segment_labels[$((segment_num-1))]}"
        
        # 构建当前配置位置的显示
        local current_position="$ipv6_prefix"
        for ((j=0; j<i; j++)); do
            current_position="$current_position:xxxx"
        done
        current_position="$current_position:${YELLOW}[待配置]${NC}"
        for ((j=i+1; j<remaining_segments; j++)); do
            current_position="$current_position:xxxx"
        done
        
        echo
        echo -e "${CYAN}正在配置第${segment_num}段${NC}"
        echo -e "${WHITE}当前位置: ${current_position}${NC}"
        
        while true; do
            read -p "请输入第${segment_num}段的范围 (例如: 1-20 或 5): " range_input
            
            if validate_segment_range "$range_input"; then
                local start_val end_val
                if parse_range "$range_input" start_val end_val; then
                    if [[ $start_val -eq $end_val ]]; then
                        segment_ranges+=("$start_val")
                        echo -e "  ${GREEN}✓${NC} 第${segment_num}段: 固定值 $start_val"
                    else
                        segment_ranges+=("$start_val-$end_val")
                        echo -e "  ${GREEN}✓${NC} 第${segment_num}段: 范围 $start_val-$end_val (共$((end_val-start_val+1))个值)"
                    fi
                    break
                fi
            fi
        done
    done
    
    # 获取子网掩码
    echo
    local subnet_mask
    while true; do
        read -p "子网掩码长度 (默认: 64): " input_mask
        subnet_mask=$(validate_subnet_mask "$input_mask")
        if [[ $? -eq 0 ]]; then
            break
        fi
        echo -e "${YELLOW}请重新输入正确的子网掩码长度${NC}"
    done
    
    # 计算总地址数
    local total_addresses=1
    for range_str in "${segment_ranges[@]}"; do
        if [[ "$range_str" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            local count=$((${BASH_REMATCH[2]} - ${BASH_REMATCH[1]} + 1))
            total_addresses=$((total_addresses * count))
        fi
    done
    
    # 生成示例地址
    local first_addr="$ipv6_prefix"
    for range_str in "${segment_ranges[@]}"; do
        if [[ "$range_str" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            first_addr="$first_addr:${BASH_REMATCH[1]}"
        else
            first_addr="$first_addr:$range_str"
        fi
    done
    
    # 确认配置
    echo
    echo -e "${BLUE}=== 配置确认 ===${NC}"
    echo -e "接口: ${GREEN}$SELECTED_INTERFACE${NC}"
    echo -e "IPv6前缀: ${GREEN}$ipv6_prefix${NC}"
    echo -e "子网掩码: ${GREEN}/$subnet_mask${NC}"
    echo -e "配置段数: ${GREEN}$remaining_segments${NC}"
    
    for ((i=0; i<${#segment_ranges[@]}; i++)); do
        local segment_num=$((prefix_segments + i + 1))
        local label="${segment_labels[$((segment_num-1))]}"
        local range_str="${segment_ranges[$i]}"
        
        if [[ "$range_str" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            echo -e "  ${label}: ${GREEN}${BASH_REMATCH[1]}-${BASH_REMATCH[2]}${NC}"
        else
            echo -e "  ${label}: ${GREEN}$range_str${NC}"
        fi
    done
    
    echo -e "预计生成地址数: ${GREEN}$total_addresses${NC}"
    echo -e "示例地址: ${CYAN}$first_addr/$subnet_mask${NC}"
    echo
    
    # 地址数量警告
    if [[ $total_addresses -gt 100 ]]; then
        echo -e "${YELLOW}⚠️  警告: 将生成 $total_addresses 个地址，这可能需要较长时间${NC}"
        read -p "是否继续? (y/N): " continue_confirm
        if [[ ! "$continue_confirm" =~ ^[Yy]$ ]]; then
            log_message "INFO" "用户取消了大批量操作"
            return 0
        fi
    fi
    
    read -p "确认添加这些IPv6地址? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_message "INFO" "用户取消了操作"
        return 0
    fi
    
    # 创建操作前快照
    echo
    echo -e "${BLUE}=== 创建配置快照 ===${NC}"
    local snapshot_file=$(create_snapshot "$SELECTED_INTERFACE" "add" "批量添加IPv6地址前的备份")
    echo -e "${GREEN}✓${NC} 快照已保存: $(basename "$snapshot_file")"
    
    # 生成所有地址组合
    echo
    echo -e "${BLUE}=== 生成地址列表 ===${NC}"
    
    # 将范围数组转换为字符串（用|分隔）
    local ranges_str=""
    for ((i=0; i<${#segment_ranges[@]}; i++)); do
        if [[ $i -eq 0 ]]; then
            ranges_str="${segment_ranges[i]}"
        else
            ranges_str="$ranges_str|${segment_ranges[i]}"
        fi
    done
    
    # 生成地址组合
    GENERATED_ADDRESSES=()
    generate_ipv6_combinations "$ipv6_prefix" "$subnet_mask" "$ranges_str"
    
    local addresses=("${GENERATED_ADDRESSES[@]}")
    echo -e "成功生成 ${GREEN}${#addresses[@]}${NC} 个IPv6地址"
    
    # 开始批量添加
    echo
    echo -e "${BLUE}=== 开始批量添加IPv6地址 ===${NC}"
    echo
    
    local success_count=0
    local error_count=0
    local progress=0
    
    for ipv6_addr in "${addresses[@]}"; do
        progress=$((progress + 1))
        
        # 显示进度
        if [[ ${#addresses[@]} -gt 20 ]]; then
            local percent=$((progress * 100 / ${#addresses[@]}))
            echo -ne "\r进度: ${GREEN}$progress/${#addresses[@]}${NC} (${percent}%) - 添加 $ipv6_addr"
        else
            echo -n "添加 $ipv6_addr ... "
        fi
        
        # 尝试添加IPv6地址并捕获错误信息
        local error_output
        error_output=$(ip -6 addr add "$ipv6_addr" dev "$SELECTED_INTERFACE" 2>&1)
        local exit_code=$?
        
        if [[ $exit_code -eq 0 ]]; then
            if [[ ${#addresses[@]} -le 20 ]]; then
                echo -e "${GREEN}成功${NC}"
            fi
            log_message "SUCCESS" "成功添加IPv6地址: $ipv6_addr 到接口 $SELECTED_INTERFACE"
            ((success_count++))
        else
            # 分析失败原因
            local failure_reason="未知错误"
            if [[ "$error_output" =~ "File exists" ]] || [[ "$error_output" =~ "RTNETLINK answers: File exists" ]]; then
                failure_reason="地址已存在"
            elif [[ "$error_output" =~ "No such device" ]] || [[ "$error_output" =~ "Cannot find device" ]]; then
                failure_reason="网络接口不存在"
            elif [[ "$error_output" =~ "Invalid argument" ]]; then
                failure_reason="无效的IPv6地址格式"
            elif [[ "$error_output" =~ "Permission denied" ]] || [[ "$error_output" =~ "Operation not permitted" ]]; then
                failure_reason="权限不足"
            elif [[ "$error_output" =~ "Network is unreachable" ]]; then
                failure_reason="网络不可达"
            fi
            
            if [[ ${#addresses[@]} -le 20 ]]; then
                echo -e "${RED}失败 (${failure_reason})${NC}"
            fi
            log_message "ERROR" "添加IPv6地址失败: $ipv6_addr 到接口 $SELECTED_INTERFACE - 原因: $failure_reason"
            ((error_count++))
        fi
        
        # 短暂延迟避免系统过载
        if [[ ${#addresses[@]} -gt 50 ]]; then
            sleep 0.05
        else
            sleep 0.1
        fi
    done
    
    # 清除进度显示
    if [[ ${#addresses[@]} -gt 20 ]]; then
        echo
    fi
    
    echo
    echo -e "${BLUE}=== 批量添加完成 ===${NC}"
    echo -e "成功: ${GREEN}$success_count${NC} 个地址"
    echo -e "失败: ${RED}$error_count${NC} 个地址"
    echo -e "总计: ${WHITE}${#addresses[@]}${NC} 个地址"
    
    if [[ $success_count -gt 0 ]]; then
        log_message "SUCCESS" "灵活模式批量添加完成: 成功 $success_count 个，失败 $error_count 个，总计 ${#addresses[@]} 个"
        
        # 收集成功添加的地址用于持久化
        local successful_addresses=()
        for ipv6_addr in "${addresses[@]}"; do
            # 检查地址是否真的添加成功
            if ip -6 addr show "$SELECTED_INTERFACE" | grep -q "$ipv6_addr" 2>/dev/null; then
                successful_addresses+=("$ipv6_addr")
            fi
        done
        
        # 询问是否进行持久化配置
        echo
        echo -e "${CYAN}是否进行持久化配置？${NC}"
        echo -e "${GREEN}y${NC} - 是，进行持久化配置"
        echo -e "${GREEN}n${NC} - 否，仅临时配置"
        echo
        
        local persist_choice
        while true; do
            read -p "请选择 (y/n): " persist_choice
            case $persist_choice in
                [Yy]|[Yy][Ee][Ss])
                    echo -e "${CYAN}正在检测成功添加的地址...${NC}"
                    # 收集成功添加的地址用于持久化
                    local successful_addresses=()
                    for ipv6_addr in "${addresses[@]}"; do
                        # 检查地址是否真的添加成功
                        if ip -6 addr show "$SELECTED_INTERFACE" | grep -q "$ipv6_addr" 2>/dev/null; then
                            successful_addresses+=("$ipv6_addr")
                            echo -e "${GREEN}✓${NC} 检测到地址: $ipv6_addr"
                        else
                            echo -e "${RED}✗${NC} 未检测到地址: $ipv6_addr"
                        fi
                    done
                    
                    echo -e "${CYAN}检测到 ${#successful_addresses[@]} 个成功添加的地址${NC}"
                    
                    if [[ ${#successful_addresses[@]} -gt 0 ]]; then
                        echo -e "${CYAN}调用持久化配置...${NC}"
                        make_persistent "$SELECTED_INTERFACE" "${successful_addresses[@]}"
                    else
                        echo -e "${YELLOW}没有找到成功添加的地址，无法进行持久化${NC}"
                    fi
                    break
                    ;;
                [Nn]|[Nn][Oo])
                    echo -e "${YELLOW}配置未持久化，重启后将丢失${NC}"
                    break
                    ;;
                *)
                    echo -e "${RED}请输入 y 或 n${NC}"
                    ;;
            esac
        done
    fi
}

# 删除IPv6地址
remove_ipv6() {
    echo -e "${BLUE}=== 批量删除IPv6地址 ===${NC}"
    echo
    
    # 选择网络接口
    select_interface
    if [[ $? -ne 0 ]]; then
        return 1
    fi
    
    echo
    echo -e "${WHITE}当前选择的接口: ${GREEN}$SELECTED_INTERFACE${NC}"
    echo
    
    # 显示当前IPv6地址
    local ipv6_addrs=($(ip -6 addr show "$SELECTED_INTERFACE" 2>/dev/null | grep "inet6" | grep -v "fe80" | awk '{print $2}'))
    
    if [[ ${#ipv6_addrs[@]} -eq 0 ]]; then
        echo -e "${YELLOW}接口 $SELECTED_INTERFACE 上没有配置的IPv6地址${NC}"
        return 0
    fi
    
    echo -e "${BLUE}当前IPv6地址列表:${NC}"
    for i in "${!ipv6_addrs[@]}"; do
        echo -e "${WHITE}$((i+1)).${NC} ${ipv6_addrs[$i]}"
    done
    
    echo
    echo -e "${CYAN}删除选项说明:${NC}"
    echo -e "  - 单个地址: ${YELLOW}5${NC} (删除第5个地址)"
    echo -e "  - 批量删除: ${YELLOW}2-8${NC} (删除第2到第8个地址)"
    echo -e "  - 删除全部: ${YELLOW}all${NC} (删除所有IPv6地址)"
    echo -e "  - 返回菜单: ${YELLOW}0${NC} (返回主菜单)"
    echo
    
    while true; do
        read -p "请输入要删除的地址编号 (0, all, 单个数字, 或 数字-数字): " choice
        
        if [[ "$choice" == "0" ]]; then
            # 返回主菜单
            return 0
        elif [[ "$choice" == "all" ]]; then
            # 删除所有地址
            echo -e "${YELLOW}即将删除所有IPv6地址 (共${#ipv6_addrs[@]}个)${NC}"
            read -p "确认删除所有IPv6地址? (y/N): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                # 创建删除前快照
                echo
                echo -e "${BLUE}=== 创建配置快照 ===${NC}"
                local snapshot_file=$(create_snapshot "$SELECTED_INTERFACE" "delete" "删除所有IPv6地址前的备份")
                echo -e "${GREEN}✓${NC} 快照已保存: $(basename "$snapshot_file")"
                
                local success_count=0
                local error_count=0
                
                echo
                echo -e "${BLUE}=== 开始批量删除 ===${NC}"
                for addr in "${ipv6_addrs[@]}"; do
                    echo -n "删除 $addr ... "
                    if ip -6 addr del "$addr" dev "$SELECTED_INTERFACE" 2>/dev/null; then
                        echo -e "${GREEN}成功${NC}"
                        log_message "SUCCESS" "成功删除IPv6地址: $addr"
                        ((success_count++))
                    else
                        echo -e "${RED}失败${NC}"
                        log_message "ERROR" "删除IPv6地址失败: $addr"
                        ((error_count++))
                    fi
                done
                
                echo
                echo -e "${BLUE}=== 批量删除完成 ===${NC}"
                echo -e "成功: ${GREEN}$success_count${NC} 个地址"
                echo -e "失败: ${RED}$error_count${NC} 个地址"
            fi
            break
            
        elif [[ "$choice" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            # 批量删除范围
            local start_idx=${BASH_REMATCH[1]}
            local end_idx=${BASH_REMATCH[2]}
            
            if [[ $start_idx -lt 1 ]] || [[ $end_idx -gt ${#ipv6_addrs[@]} ]] || [[ $start_idx -gt $end_idx ]]; then
                echo -e "${RED}无效范围，请输入 1-${#ipv6_addrs[@]} 之间的有效范围${NC}"
                continue
            fi
            
            local delete_count=$((end_idx - start_idx + 1))
            echo -e "${YELLOW}即将删除第${start_idx}到第${end_idx}个地址 (共${delete_count}个)${NC}"
            
            # 显示将要删除的地址
            echo -e "${CYAN}将要删除的地址:${NC}"
            for ((i=start_idx-1; i<end_idx; i++)); do
                echo -e "  ${WHITE}$((i+1)).${NC} ${ipv6_addrs[$i]}"
            done
            
            read -p "确认删除这些地址? (y/N): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                # 创建删除前快照
                echo
                echo -e "${BLUE}=== 创建配置快照 ===${NC}"
                local snapshot_file=$(create_snapshot "$SELECTED_INTERFACE" "delete" "批量删除IPv6地址前的备份")
                echo -e "${GREEN}✓${NC} 快照已保存: $(basename "$snapshot_file")"
                
                local success_count=0
                local error_count=0
                
                echo
                echo -e "${BLUE}=== 开始批量删除 ===${NC}"
                for ((i=start_idx-1; i<end_idx; i++)); do
                    local addr="${ipv6_addrs[$i]}"
                    echo -n "删除 $addr ... "
                    if ip -6 addr del "$addr" dev "$SELECTED_INTERFACE" 2>/dev/null; then
                        echo -e "${GREEN}成功${NC}"
                        log_message "SUCCESS" "成功删除IPv6地址: $addr"
                        ((success_count++))
                    else
                        echo -e "${RED}失败${NC}"
                        log_message "ERROR" "删除IPv6地址失败: $addr"
                        ((error_count++))
                    fi
                done
                
                echo
                echo -e "${BLUE}=== 批量删除完成 ===${NC}"
                echo -e "成功: ${GREEN}$success_count${NC} 个地址"
                echo -e "失败: ${RED}$error_count${NC} 个地址"
            fi
            break
            
        elif [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le ${#ipv6_addrs[@]} ]]; then
            # 删除单个地址
            local addr_to_remove="${ipv6_addrs[$((choice-1))]}"
            echo -e "${YELLOW}即将删除: $addr_to_remove${NC}"
            read -p "确认删除此地址? (y/N): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                # 创建删除前快照
                echo
                echo -e "${BLUE}=== 创建配置快照 ===${NC}"
                local snapshot_file=$(create_snapshot "$SELECTED_INTERFACE" "delete" "删除单个IPv6地址前的备份")
                echo -e "${GREEN}✓${NC} 快照已保存: $(basename "$snapshot_file")"
                
                echo -n "删除 $addr_to_remove ... "
                if ip -6 addr del "$addr_to_remove" dev "$SELECTED_INTERFACE" 2>/dev/null; then
                    echo -e "${GREEN}成功${NC}"
                    log_message "SUCCESS" "成功删除IPv6地址: $addr_to_remove"
                else
                    echo -e "${RED}失败${NC}"
                    log_message "ERROR" "删除IPv6地址失败: $addr_to_remove"
                fi
            fi
            break
            
        else
            echo -e "${RED}无效输入，请输入:${NC}"
            echo -e "  - ${YELLOW}0${NC} (删除全部)"
            echo -e "  - ${YELLOW}1-${#ipv6_addrs[@]}${NC} (删除单个地址)"
            echo -e "  - ${YELLOW}数字-数字${NC} (批量删除范围，如: 2-5)"
        fi
    done
}

# 显示系统状态
show_system_status() {
    echo -e "${BLUE}=== 系统状态 ===${NC}"
    echo
    
    # 系统信息
    echo -e "${WHITE}系统信息:${NC}"
    echo -e "  操作系统: $(lsb_release -d 2>/dev/null | cut -f2 || echo "Unknown")"
    echo -e "  内核版本: $(uname -r)"
    echo -e "  运行时间: $(uptime -p 2>/dev/null || uptime)"
    echo
    
    # IPv6支持状态
    echo -e "${WHITE}IPv6支持状态:${NC}"
    if [[ -f /proc/net/if_inet6 ]]; then
        echo -e "  ${GREEN}✓${NC} IPv6已启用"
    else
        echo -e "  ${RED}✗${NC} IPv6未启用"
    fi
    
    # 网络接口统计
    echo
    echo -e "${WHITE}网络接口统计:${NC}"
    local interfaces=($(get_network_interfaces))
    echo -e "  可用接口数: ${GREEN}${#interfaces[@]}${NC}"
    
    local total_ipv6=0
    for interface in "${interfaces[@]}"; do
        local count=$(ip -6 addr show "$interface" 2>/dev/null | grep "inet6" | grep -v "fe80" | wc -l)
        total_ipv6=$((total_ipv6 + count))
    done
    echo -e "  已配置IPv6地址总数: ${GREEN}$total_ipv6${NC}"
    
    # 日志文件信息
    echo
    echo -e "${WHITE}日志信息:${NC}"
    if [[ -f "$LOG_FILE" ]]; then
        local log_size=$(du -h "$LOG_FILE" 2>/dev/null | cut -f1)
        local log_lines=$(wc -l < "$LOG_FILE" 2>/dev/null)
        echo -e "  日志文件: ${GREEN}$LOG_FILE${NC}"
        echo -e "  文件大小: ${GREEN}$log_size${NC}"
        echo -e "  日志条数: ${GREEN}$log_lines${NC}"
    else
        echo -e "  ${YELLOW}暂无日志文件${NC}"
    fi
}

# 查看日志
view_logs() {
    echo -e "${BLUE}=== 查看日志 ===${NC}"
    echo
    
    if [[ ! -f "$LOG_FILE" ]]; then
        echo -e "${YELLOW}日志文件不存在${NC}"
        return 0
    fi
    
    echo -e "${WHITE}日志文件: $LOG_FILE${NC}"
    echo
    
    echo "1. 查看最近20条日志"
    echo "2. 查看所有日志"
    echo "3. 查看错误日志"
    echo "4. 返回主菜单"
    echo
    
    read -p "请选择 (1-4): " choice
    
    case $choice in
        1)
            echo -e "${BLUE}=== 最近20条日志 ===${NC}"
            tail -20 "$LOG_FILE"
            ;;
        2)
            echo -e "${BLUE}=== 所有日志 ===${NC}"
            less "$LOG_FILE"
            ;;
        3)
            echo -e "${BLUE}=== 错误日志 ===${NC}"
            grep "ERROR" "$LOG_FILE" | tail -20
            ;;
        4)
            return 0
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            ;;
    esac
}

# 交互式向导模式
wizard_mode() {
    echo -e "${BLUE}=== 🧙 IPv6配置向导 ===${NC}"
    echo -e "${CYAN}欢迎使用IPv6配置向导！我将引导您完成配置过程。${NC}"
    echo
    
    # 检测用户经验水平
    echo -e "${WHITE}首先，让我了解一下您的经验水平：${NC}"
    echo -e "${GREEN}1.${NC} 新手 - 我是第一次配置IPv6"
    echo -e "${GREEN}2.${NC} 有经验 - 我了解IPv6基础知识"
    echo -e "${GREEN}3.${NC} 专家 - 我需要高级配置选项"
    echo -e "${GREEN}0.${NC} 返回主菜单"
    echo
    
    local user_level
    while true; do
        read -p "请选择您的经验水平 (0-3): " user_level
        if [[ "$user_level" =~ ^[0-3]$ ]]; then
            break
        else
            echo -e "${RED}请输入 0、1、2 或 3${NC}"
        fi
    done
    
    case $user_level in
        0) return 0 ;;
        1) wizard_beginner_mode ;;
        2) wizard_intermediate_mode ;;
        3) wizard_expert_mode ;;
    esac
}

# 新手向导模式
wizard_beginner_mode() {
    echo
    echo -e "${BLUE}=== 🌟 新手向导模式 ===${NC}"
    echo -e "${CYAN}我将为您提供详细的指导和推荐配置。${NC}"
    echo
    
    # 场景选择
    echo -e "${WHITE}请选择您的使用场景：${NC}"
    echo -e "${GREEN}1.${NC} 🏠 家庭服务器 - 配置少量IPv6地址"
    echo -e "${GREEN}2.${NC} 🏢 小型企业 - 配置中等数量的IPv6地址"
    echo -e "${GREEN}3.${NC} 🌐 大型网络 - 配置大量IPv6地址"
    echo -e "${GREEN}4.${NC} 🧪 测试环境 - 快速配置测试地址"
    echo -e "${GREEN}0.${NC} 返回上级菜单"
    echo
    
    local scenario
    while true; do
        read -p "请选择使用场景 (0-4): " scenario
        if [[ "$scenario" =~ ^[0-4]$ ]]; then
            break
        else
            echo -e "${RED}请输入 0-4 之间的数字${NC}"
        fi
    done
    
    case $scenario in
        0) return 0 ;;
        1) wizard_home_server ;;
        2) wizard_small_business ;;
        3) wizard_large_network ;;
        4) wizard_test_environment ;;
    esac
}

# 家庭服务器配置向导
wizard_home_server() {
    echo
    echo -e "${BLUE}=== 🏠 家庭服务器配置向导 ===${NC}"
    echo -e "${CYAN}为家庭服务器配置IPv6地址，通常需要1-10个地址。${NC}"
    echo
    
    # 自动检测和选择接口
    wizard_select_interface
    if [[ $? -ne 0 ]]; then return 1; fi
    
    # 获取IPv6前缀
    echo -e "${WHITE}📝 步骤1: 配置IPv6网段前缀${NC}"
    echo -e "${CYAN}提示: 家庭服务器通常使用ISP分配的/64网段${NC}"
    echo -e "${YELLOW}示例: 2012:f2c4:1:1f34${NC}"
    echo
    
    local ipv6_prefix
    while true; do
        read -p "请输入您的IPv6前缀: " ipv6_prefix
        if validate_ipv6_prefix "$ipv6_prefix"; then
            echo -e "${GREEN}✓${NC} IPv6前缀: $ipv6_prefix"
            break
        fi
        echo -e "${YELLOW}请重新输入正确的IPv6前缀${NC}"
    done
    
    # 推荐配置
    echo
    echo -e "${WHITE}📝 步骤2: 选择地址数量${NC}"
    echo -e "${CYAN}推荐配置:${NC}"
    echo -e "${GREEN}1.${NC} 单个地址 (::1)"
    echo -e "${GREEN}2.${NC} 少量地址 (::1-5, 共5个)"
    echo -e "${GREEN}3.${NC} 中等数量 (::1-10, 共10个)"
    echo -e "${GREEN}4.${NC} 自定义范围"
    echo -e "${YELLOW}0.${NC} 返回上级菜单"
    echo
    
    local addr_choice
    while true; do
        read -p "请选择地址配置 (0-4): " addr_choice
        if [[ "$addr_choice" == "0" ]]; then
            return 1
        elif [[ "$addr_choice" =~ ^[1-4]$ ]]; then
            break
        else
            echo -e "${RED}请输入 0-4 之间的数字${NC}"
        fi
    done
    
    local start_addr end_addr
    case $addr_choice in
        1) start_addr=1; end_addr=1 ;;
        2) start_addr=1; end_addr=5 ;;
        3) start_addr=1; end_addr=10 ;;
        4) 
            echo
            while true; do
                read -p "请输入起始地址编号: " start_addr
                if validate_address_number "$start_addr" "起始地址编号"; then
                    break
                fi
            done
            
            while true; do
                read -p "请输入结束地址编号: " end_addr
                if validate_address_number "$end_addr" "结束地址编号"; then
                    if [[ $end_addr -ge $start_addr ]]; then
                        break
                    else
                        echo -e "${RED}结束地址编号必须大于或等于起始地址编号${NC}"
                    fi
                fi
            done
            ;;
    esac
    
    # 配置预览和确认
    wizard_preview_and_execute "$ipv6_prefix" "$start_addr" "$end_addr" "simple"
}

# 测试环境配置向导
wizard_test_environment() {
    echo
    echo -e "${BLUE}=== 🧪 测试环境配置向导 ===${NC}"
    echo -e "${CYAN}快速配置测试用的IPv6地址。${NC}"
    echo
    
    wizard_select_interface
    if [[ $? -ne 0 ]]; then return 1; fi
    
    echo -e "${WHITE}📝 快速配置选项：${NC}"
    echo -e "${GREEN}1.${NC} 🚀 快速测试 (2012:f2c4:1:1f34::1-3, 共3个地址)"
    echo -e "${GREEN}2.${NC} 📊 压力测试 (2012:f2c4:1:1f34::1-100, 共100个地址)"
    echo -e "${GREEN}3.${NC} 🔧 自定义测试配置"
    echo -e "${YELLOW}0.${NC} 返回上级菜单"
    echo
    
    local test_choice
    while true; do
        read -p "请选择测试配置 (0-3): " test_choice
        if [[ "$test_choice" == "0" ]]; then
            return 1
        elif [[ "$test_choice" =~ ^[1-3]$ ]]; then
            break
        else
            echo -e "${RED}请输入 0-3 之间的数字${NC}"
        fi
    done
    
    case $test_choice in
        1) wizard_preview_and_execute "2012:f2c4:1:1f34" "1" "3" "simple" ;;
        2) 
            echo -e "${YELLOW}⚠️  注意: 这将配置100个IPv6地址，可能需要几分钟时间${NC}"
            read -p "确认继续? (y/N): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                wizard_preview_and_execute "2012:f2c4:1:1f34" "1" "100" "simple"
            fi
            ;;
        3) wizard_custom_configuration ;;
    esac
}

# 中级用户向导模式
wizard_intermediate_mode() {
    echo
    echo -e "${BLUE}=== 🎯 中级向导模式 ===${NC}"
    echo -e "${CYAN}您可以选择预设配置或自定义配置。${NC}"
    echo
    
    echo -e "${WHITE}配置选项：${NC}"
    echo -e "${GREEN}1.${NC} 📋 使用预设模板"
    echo -e "${GREEN}2.${NC} 🔧 自定义配置"
    echo -e "${GREEN}3.${NC} 📁 从配置文件加载"
    echo -e "${YELLOW}0.${NC} 返回上级菜单"
    echo
    
    local config_choice
    while true; do
        read -p "请选择配置方式 (0-3): " config_choice
        if [[ "$config_choice" == "0" ]]; then
            return 1
        elif [[ "$config_choice" =~ ^[1-3]$ ]]; then
            break
        else
            echo -e "${RED}请输入 0-3 之间的数字${NC}"
        fi
    done
    
    case $config_choice in
        1) wizard_template_selection ;;
        2) wizard_custom_configuration ;;
        3) wizard_load_from_file ;;
    esac
}

# 专家向导模式
wizard_expert_mode() {
    echo
    echo -e "${BLUE}=== ⚡ 专家向导模式 ===${NC}"
    echo -e "${CYAN}高级配置选项和批量操作。${NC}"
    echo
    
    echo -e "${WHITE}高级选项：${NC}"
    echo -e "${GREEN}1.${NC} 🔀 多段变化配置"
    echo -e "${GREEN}2.${NC} 📊 批量模板应用"
    echo -e "${GREEN}3.${NC} 🔄 配置迁移和同步"
    echo -e "${GREEN}4.${NC} 🎛️  直接进入标准模式"
    echo -e "${YELLOW}0.${NC} 返回主菜单"
    echo
    
    local expert_choice
    while true; do
        read -p "请选择高级选项 (0-4): " expert_choice
        if [[ "$expert_choice" == "0" ]]; then
            return 1
        elif [[ "$expert_choice" =~ ^[1-4]$ ]]; then
            break
        else
            echo -e "${RED}请输入 0-4 之间的数字${NC}"
        fi
    done
    
    case $expert_choice in
        1) wizard_multi_segment_config ;;
        2) wizard_batch_template ;;
        3) wizard_config_migration ;;
        4) batch_add_ipv6 ;;
    esac
}

# 多段变化配置向导
wizard_multi_segment_config() {
    echo
    echo -e "${BLUE}=== 🔀 多段变化配置向导 ===${NC}"
    echo -e "${CYAN}配置多个IPv6段的复杂组合。${NC}"
    echo
    
    echo -e "${WHITE}💡 提示: 这是高级功能，将进入灵活配置模式${NC}"
    echo -e "${CYAN}您可以配置多个段的不同变化组合${NC}"
    echo
    read -p "按回车键继续..."
    
    batch_add_ipv6
}

# 批量模板应用向导
wizard_batch_template() {
    echo
    echo -e "${BLUE}=== 📊 批量模板应用向导 ===${NC}"
    echo -e "${CYAN}批量应用多个模板或在多个接口上应用模板。${NC}"
    echo
    
    # 选择操作模式
    echo -e "${WHITE}批量应用模式:${NC}"
    echo -e "${GREEN}1.${NC} 在单个接口上应用多个模板"
    echo -e "${GREEN}2.${NC} 在多个接口上应用单个模板"
    echo -e "${GREEN}3.${NC} 在多个接口上应用多个模板"
    echo -e "${YELLOW}0.${NC} 返回上级菜单"
    echo
    
    local batch_mode
    while true; do
        read -p "请选择批量模式 (0-3): " batch_mode
        if [[ "$batch_mode" == "0" ]]; then
            return 1
        elif [[ "$batch_mode" =~ ^[1-3]$ ]]; then
            break
        else
            echo -e "${RED}请输入 0-3 之间的数字${NC}"
        fi
    done
    
    case $batch_mode in
        1) wizard_single_interface_multi_templates ;;
        2) wizard_multi_interface_single_template ;;
        3) wizard_multi_interface_multi_templates ;;
    esac
}

# 单接口多模板应用
wizard_single_interface_multi_templates() {
    echo
    echo -e "${BLUE}=== 📋 单接口多模板应用 ===${NC}"
    
    # 选择接口
    wizard_select_interface
    if [[ $? -ne 0 ]]; then
        return 1
    fi
    
    echo
    echo -e "${WHITE}将在接口 ${GREEN}$SELECTED_INTERFACE${NC} 上应用多个模板${NC}"
    echo
    
    # 列出可用模板
    local template_count
    list_templates
    template_count=$?
    
    if [[ $template_count -eq 0 ]]; then
        return 0
    fi
    
    local templates=($(find "$TEMPLATE_DIR" -name "*.json" -type f 2>/dev/null))
    local selected_templates=()
    
    echo -e "${CYAN}请选择要应用的模板 (可多选，输入0完成选择):${NC}"
    
    while true; do
        read -p "选择模板编号 (1-$template_count, 0=完成): " choice
        
        if [[ "$choice" == "0" ]]; then
            break
        elif [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le $template_count ]]; then
            local template_file="${templates[$((choice-1))]}"
            local template_name=$(grep '"name":' "$template_file" | cut -d'"' -f4)
            
            # 检查是否已选择
            local already_selected=false
            for selected in "${selected_templates[@]}"; do
                if [[ "$selected" == "$template_file" ]]; then
                    already_selected=true
                    break
                fi
            done
            
            if [[ "$already_selected" == false ]]; then
                selected_templates+=("$template_file")
                echo -e "${GREEN}✓${NC} 已选择: $template_name"
            else
                echo -e "${YELLOW}模板已选择: $template_name${NC}"
            fi
        else
            echo -e "${RED}无效选择，请输入 1-$template_count 或 0${NC}"
        fi
    done
    
    if [[ ${#selected_templates[@]} -eq 0 ]]; then
        echo -e "${YELLOW}未选择任何模板${NC}"
        return 0
    fi
    
    # 确认应用
    echo
    echo -e "${BLUE}=== 批量应用确认 ===${NC}"
    echo -e "目标接口: ${GREEN}$SELECTED_INTERFACE${NC}"
    echo -e "选择的模板:"
    for template in "${selected_templates[@]}"; do
        local name=$(grep '"name":' "$template" | cut -d'"' -f4)
        echo -e "  ${WHITE}•${NC} $name"
    done
    
    read -p "确认批量应用这些模板? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}批量应用已取消${NC}"
        return 0
    fi
    
    # 开始批量应用
    echo
    echo -e "${BLUE}=== 🚀 开始批量应用模板 ===${NC}"
    
    local total_success=0
    local total_error=0
    
    for i in "${!selected_templates[@]}"; do
        local template="${selected_templates[$i]}"
        local name=$(grep '"name":' "$template" | cut -d'"' -f4)
        
        echo
        echo -e "${CYAN}[$((i+1))/${#selected_templates[@]}] 应用模板: $name${NC}"
        
        # 应用模板（静默模式）
        local addresses=()
        parse_template_addresses "$template" addresses
        
        local success_count=0
        local error_count=0
        
        for addr in "${addresses[@]}"; do
            if ip -6 addr add "$addr" dev "$SELECTED_INTERFACE" 2>/dev/null; then
                ((success_count++))
                log_message "SUCCESS" "批量模板应用成功添加IPv6地址: $addr"
            else
                ((error_count++))
                log_message "ERROR" "批量模板应用添加IPv6地址失败: $addr"
            fi
        done
        
        echo -e "  成功: ${GREEN}$success_count${NC}, 失败: ${RED}$error_count${NC}"
        
        total_success=$((total_success + success_count))
        total_error=$((total_error + error_count))
        
        sleep 0.5
    done
    
    echo
    echo -e "${BLUE}=== ✅ 批量应用完成 ===${NC}"
    echo -e "应用模板数: ${GREEN}${#selected_templates[@]}${NC}"
    echo -e "总成功数: ${GREEN}$total_success${NC}"
    echo -e "总失败数: ${RED}$total_error${NC}"
    
    log_message "SUCCESS" "批量模板应用完成: ${#selected_templates[@]} 个模板，成功 $total_success 个，失败 $total_error 个"
}

# 多接口单模板应用
wizard_multi_interface_single_template() {
    echo
    echo -e "${BLUE}=== 🌐 多接口单模板应用 ===${NC}"
    
    # 选择模板
    local template_count
    list_templates
    template_count=$?
    
    if [[ $template_count -eq 0 ]]; then
        return 0
    fi
    
    local templates=($(find "$TEMPLATE_DIR" -name "*.json" -type f 2>/dev/null))
    local selected_template=""
    
    while true; do
        read -p "请选择要应用的模板编号 (1-$template_count): " choice
        
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le $template_count ]]; then
            selected_template="${templates[$((choice-1))]}"
            break
        else
            echo -e "${RED}无效选择，请输入 1-$template_count${NC}"
        fi
    done
    
    local template_name=$(grep '"name":' "$selected_template" | cut -d'"' -f4)
    echo -e "${GREEN}✓${NC} 选择了模板: $template_name"
    
    # 选择接口
    echo
    local interfaces=($(get_network_interfaces))
    if [[ ${#interfaces[@]} -eq 0 ]]; then
        echo -e "${RED}❌ 未找到可用的网络接口${NC}"
        return 1
    fi
    
    echo -e "${WHITE}可用的网络接口:${NC}"
    for i in "${!interfaces[@]}"; do
        local status=$(ip link show "${interfaces[$i]}" | grep -o "state [A-Z]*" | awk '{print $2}')
        local status_color="${GREEN}"
        [[ "$status" != "UP" ]] && status_color="${YELLOW}"
        echo -e "${WHITE}$((i+1)).${NC} ${interfaces[$i]} ${status_color}($status)${NC}"
    done
    
    local selected_interfaces=()
    echo
    echo -e "${CYAN}请选择要应用的接口 (可多选，输入0完成选择):${NC}"
    
    while true; do
        read -p "选择接口编号 (1-${#interfaces[@]}, 0=完成): " choice
        
        if [[ "$choice" == "0" ]]; then
            break
        elif [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le ${#interfaces[@]} ]]; then
            local interface="${interfaces[$((choice-1))]}"
            
            # 检查是否已选择
            local already_selected=false
            for selected in "${selected_interfaces[@]}"; do
                if [[ "$selected" == "$interface" ]]; then
                    already_selected=true
                    break
                fi
            done
            
            if [[ "$already_selected" == false ]]; then
                selected_interfaces+=("$interface")
                echo -e "${GREEN}✓${NC} 已选择: $interface"
            else
                echo -e "${YELLOW}接口已选择: $interface${NC}"
            fi
        else
            echo -e "${RED}无效选择，请输入 1-${#interfaces[@]} 或 0${NC}"
        fi
    done
    
    if [[ ${#selected_interfaces[@]} -eq 0 ]]; then
        echo -e "${YELLOW}未选择任何接口${NC}"
        return 0
    fi
    
    # 确认应用
    echo
    echo -e "${BLUE}=== 批量应用确认 ===${NC}"
    echo -e "选择的模板: ${GREEN}$template_name${NC}"
    echo -e "目标接口:"
    for interface in "${selected_interfaces[@]}"; do
        echo -e "  ${WHITE}•${NC} $interface"
    done
    
    read -p "确认在这些接口上应用模板? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}批量应用已取消${NC}"
        return 0
    fi
    
    # 开始批量应用
    echo
    echo -e "${BLUE}=== 🚀 开始批量应用到多个接口 ===${NC}"
    
    local total_success=0
    local total_error=0
    
    for i in "${!selected_interfaces[@]}"; do
        local interface="${selected_interfaces[$i]}"
        
        echo
        echo -e "${CYAN}[$((i+1))/${#selected_interfaces[@]}] 应用到接口: $interface${NC}"
        
        # 应用模板
        local addresses=()
        parse_template_addresses "$selected_template" addresses
        
        local success_count=0
        local error_count=0
        
        for addr in "${addresses[@]}"; do
            if ip -6 addr add "$addr" dev "$interface" 2>/dev/null; then
                ((success_count++))
                log_message "SUCCESS" "多接口模板应用成功添加IPv6地址: $addr 到 $interface"
            else
                ((error_count++))
                log_message "ERROR" "多接口模板应用添加IPv6地址失败: $addr 到 $interface"
            fi
        done
        
        echo -e "  成功: ${GREEN}$success_count${NC}, 失败: ${RED}$error_count${NC}"
        
        total_success=$((total_success + success_count))
        total_error=$((total_error + error_count))
        
        sleep 0.5
    done
    
    echo
    echo -e "${BLUE}=== ✅ 批量应用完成 ===${NC}"
    echo -e "应用接口数: ${GREEN}${#selected_interfaces[@]}${NC}"
    echo -e "总成功数: ${GREEN}$total_success${NC}"
    echo -e "总失败数: ${RED}$total_error${NC}"
    
    log_message "SUCCESS" "多接口模板应用完成: ${#selected_interfaces[@]} 个接口，成功 $total_success 个，失败 $total_error 个"
}

# 多接口多模板应用
wizard_multi_interface_multi_templates() {
    echo
    echo -e "${BLUE}=== 🌐📋 多接口多模板应用 ===${NC}"
    echo -e "${YELLOW}⚠️  注意: 这是最复杂的批量操作模式${NC}"
    echo
    
    read -p "确认继续? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}操作已取消${NC}"
        return 0
    fi
    
    echo -e "${CYAN}提示: 将为每个接口应用所有选择的模板${NC}"
    echo
    
    # 选择模板
    local template_count
    list_templates
    template_count=$?
    
    if [[ $template_count -eq 0 ]]; then
        return 0
    fi
    
    local templates=($(find "$TEMPLATE_DIR" -name "*.json" -type f 2>/dev/null))
    local selected_templates=()
    
    echo -e "${CYAN}请选择要应用的模板 (可多选，输入0完成选择):${NC}"
    
    while true; do
        read -p "选择模板编号 (1-$template_count, 0=完成): " choice
        
        if [[ "$choice" == "0" ]]; then
            break
        elif [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le $template_count ]]; then
            local template_file="${templates[$((choice-1))]}"
            local template_name=$(grep '"name":' "$template_file" | cut -d'"' -f4)
            
            # 检查是否已选择
            local already_selected=false
            for selected in "${selected_templates[@]}"; do
                if [[ "$selected" == "$template_file" ]]; then
                    already_selected=true
                    break
                fi
            done
            
            if [[ "$already_selected" == false ]]; then
                selected_templates+=("$template_file")
                echo -e "${GREEN}✓${NC} 已选择: $template_name"
            else
                echo -e "${YELLOW}模板已选择: $template_name${NC}"
            fi
        else
            echo -e "${RED}无效选择，请输入 1-$template_count 或 0${NC}"
        fi
    done
    
    if [[ ${#selected_templates[@]} -eq 0 ]]; then
        echo -e "${YELLOW}未选择任何模板${NC}"
        return 0
    fi
    
    # 选择接口
    echo
    local interfaces=($(get_network_interfaces))
    if [[ ${#interfaces[@]} -eq 0 ]]; then
        echo -e "${RED}❌ 未找到可用的网络接口${NC}"
        return 1
    fi
    
    echo -e "${WHITE}可用的网络接口:${NC}"
    for i in "${!interfaces[@]}"; do
        local status=$(ip link show "${interfaces[$i]}" | grep -o "state [A-Z]*" | awk '{print $2}')
        local status_color="${GREEN}"
        [[ "$status" != "UP" ]] && status_color="${YELLOW}"
        echo -e "${WHITE}$((i+1)).${NC} ${interfaces[$i]} ${status_color}($status)${NC}"
    done
    
    local selected_interfaces=()
    echo
    echo -e "${CYAN}请选择要应用的接口 (可多选，输入0完成选择):${NC}"
    
    while true; do
        read -p "选择接口编号 (1-${#interfaces[@]}, 0=完成): " choice
        
        if [[ "$choice" == "0" ]]; then
            break
        elif [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le ${#interfaces[@]} ]]; then
            local interface="${interfaces[$((choice-1))]}"
            
            # 检查是否已选择
            local already_selected=false
            for selected in "${selected_interfaces[@]}"; do
                if [[ "$selected" == "$interface" ]]; then
                    already_selected=true
                    break
                fi
            done
            
            if [[ "$already_selected" == false ]]; then
                selected_interfaces+=("$interface")
                echo -e "${GREEN}✓${NC} 已选择: $interface"
            else
                echo -e "${YELLOW}接口已选择: $interface${NC}"
            fi
        else
            echo -e "${RED}无效选择，请输入 1-${#interfaces[@]} 或 0${NC}"
        fi
    done
    
    if [[ ${#selected_interfaces[@]} -eq 0 ]]; then
        echo -e "${YELLOW}未选择任何接口${NC}"
        return 0
    fi
    
    # 计算总操作数
    local total_operations=$((${#selected_templates[@]} * ${#selected_interfaces[@]}))
    
    # 确认应用
    echo
    echo -e "${BLUE}=== 批量应用确认 ===${NC}"
    echo -e "选择的模板数: ${GREEN}${#selected_templates[@]}${NC}"
    echo -e "选择的接口数: ${GREEN}${#selected_interfaces[@]}${NC}"
    echo -e "总操作数: ${YELLOW}$total_operations${NC}"
    echo
    
    if [[ $total_operations -gt 10 ]]; then
        echo -e "${YELLOW}⚠️  警告: 操作数量较多，可能需要较长时间${NC}"
    fi
    
    read -p "确认执行批量应用? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}批量应用已取消${NC}"
        return 0
    fi
    
    # 开始批量应用
    echo
    echo -e "${BLUE}=== 🚀 开始多接口多模板批量应用 ===${NC}"
    
    local total_success=0
    local total_error=0
    local operation_count=0
    
    for interface in "${selected_interfaces[@]}"; do
        echo
        echo -e "${PURPLE}=== 接口: $interface ===${NC}"
        
        for template in "${selected_templates[@]}"; do
            operation_count=$((operation_count + 1))
            local template_name=$(grep '"name":' "$template" | cut -d'"' -f4)
            
            echo -e "${CYAN}[$operation_count/$total_operations] 应用模板: $template_name${NC}"
            
            # 应用模板
            local addresses=()
            parse_template_addresses "$template" addresses
            
            local success_count=0
            local error_count=0
            
            for addr in "${addresses[@]}"; do
                if ip -6 addr add "$addr" dev "$interface" 2>/dev/null; then
                    ((success_count++))
                    log_message "SUCCESS" "多接口多模板应用成功添加IPv6地址: $addr 到 $interface"
                else
                    ((error_count++))
                    log_message "ERROR" "多接口多模板应用添加IPv6地址失败: $addr 到 $interface"
                fi
            done
            
            echo -e "  成功: ${GREEN}$success_count${NC}, 失败: ${RED}$error_count${NC}"
            
            total_success=$((total_success + success_count))
            total_error=$((total_error + error_count))
            
            sleep 0.3
        done
    done
    
    echo
    echo -e "${BLUE}=== ✅ 批量应用完成 ===${NC}"
    echo -e "应用接口数: ${GREEN}${#selected_interfaces[@]}${NC}"
    echo -e "应用模板数: ${GREEN}${#selected_templates[@]}${NC}"
    echo -e "总操作数: ${YELLOW}$total_operations${NC}"
    echo -e "总成功数: ${GREEN}$total_success${NC}"
    echo -e "总失败数: ${RED}$total_error${NC}"
    
    log_message "SUCCESS" "多接口多模板批量应用完成: $total_operations 个操作，成功 $total_success 个，失败 $total_error 个"
}

# 配置迁移和同步向导
wizard_config_migration() {
    echo
    echo -e "${BLUE}=== 🔄 配置迁移和同步向导 ===${NC}"
    echo -e "${CYAN}在服务器之间迁移和同步IPv6配置。${NC}"
    echo
    
    echo -e "${WHITE}迁移和同步选项:${NC}"
    echo -e "${GREEN}1.${NC} 导出当前配置 (准备迁移)"
    echo -e "${GREEN}2.${NC} 导入配置文件 (执行迁移)"
    echo -e "${GREEN}3.${NC} 配置同步检查"
    echo -e "${GREEN}4.${NC} 批量配置部署"
    echo -e "${YELLOW}0.${NC} 返回上级菜单"
    echo
    
    local migration_choice
    while true; do
        read -p "请选择迁移选项 (0-4): " migration_choice
        if [[ "$migration_choice" == "0" ]]; then
            return 1
        elif [[ "$migration_choice" =~ ^[1-4]$ ]]; then
            break
        else
            echo -e "${RED}请输入 0-4 之间的数字${NC}"
        fi
    done
    
    case $migration_choice in
        1) wizard_export_for_migration ;;
        2) wizard_import_for_migration ;;
        3) wizard_config_sync_check ;;
        4) wizard_batch_deployment ;;
    esac
}

# 导出配置用于迁移
wizard_export_for_migration() {
    echo
    echo -e "${BLUE}=== 📤 导出配置用于迁移 ===${NC}"
    
    # 选择接口
    wizard_select_interface
    if [[ $? -ne 0 ]]; then
        return 1
    fi
    
    echo
    echo -e "${WHITE}导出选项:${NC}"
    echo -e "${GREEN}1.${NC} 标准导出 (包含所有IPv6地址)"
    echo -e "${GREEN}2.${NC} 模板导出 (保存为可重用模板)"
    echo -e "${GREEN}3.${NC} 完整导出 (包含系统信息和配置)"
    echo -e "${YELLOW}0.${NC} 返回上级菜单"
    echo
    
    local export_type
    while true; do
        read -p "请选择导出类型 (0-3): " export_type
        if [[ "$export_type" == "0" ]]; then
            return 1
        elif [[ "$export_type" =~ ^[1-3]$ ]]; then
            break
        else
            echo -e "${RED}请输入 0-3 之间的数字${NC}"
        fi
    done
    
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local hostname=$(hostname)
    
    case $export_type in
        1)
            local export_file="$CONFIG_DIR/migration_${hostname}_${SELECTED_INTERFACE}_${timestamp}.json"
            export_config "$SELECTED_INTERFACE" "$export_file"
            ;;
        2)
            echo
            local template_name
            while true; do
                read -p "模板名称: " template_name
                template_name=${template_name:-"Migration_${hostname}_${timestamp}"}
                if validate_template_name "$template_name"; then
                    break
                fi
            done
            save_as_template "$SELECTED_INTERFACE"
            ;;
        3)
            local export_file="$CONFIG_DIR/full_migration_${hostname}_${timestamp}.json"
            wizard_full_export "$SELECTED_INTERFACE" "$export_file"
            ;;
    esac
    
    echo
    echo -e "${GREEN}💡 迁移提示:${NC}"
    echo -e "  • 将导出文件复制到目标服务器"
    echo -e "  • 在目标服务器上运行导入功能"
    echo -e "  • 验证配置是否正确应用"
}

# 完整导出功能
wizard_full_export() {
    local interface=$1
    local export_file=$2
    
    # 获取当前配置
    local ipv6_addrs=($(ip -6 addr show "$interface" 2>/dev/null | grep "inet6" | grep -v "fe80" | awk '{print $2}'))
    
    # 创建完整导出文件
    cat > "$export_file" << EOF
{
    "export_info": {
        "timestamp": "$(date '+%Y-%m-%d %H:%M:%S')",
        "interface": "$interface",
        "hostname": "$(hostname)",
        "script_version": "1.0",
        "export_type": "full_migration"
    },
    "system_info": {
        "os": "$(lsb_release -d 2>/dev/null | cut -f2 || echo "Unknown")",
        "kernel": "$(uname -r)",
        "ipv6_enabled": $([ -f /proc/net/if_inet6 ] && echo "true" || echo "false"),
        "interface_status": "$(ip link show "$interface" | grep -o "state [A-Z]*" | awk '{print $2}')"
    },
    "ipv6_configuration": {
        "interface": "$interface",
        "addresses": [
EOF
    
    # 添加地址列表
    for i in "${!ipv6_addrs[@]}"; do
        local addr="${ipv6_addrs[$i]}"
        if [[ $i -eq $((${#ipv6_addrs[@]} - 1)) ]]; then
            echo "            \"$addr\"" >> "$export_file"
        else
            echo "            \"$addr\"," >> "$export_file"
        fi
    done
    
    cat >> "$export_file" << EOF
        ]
    },
    "network_info": {
        "available_interfaces": [
EOF
    
    # 添加所有接口信息
    local all_interfaces=($(get_network_interfaces))
    for i in "${!all_interfaces[@]}"; do
        local iface="${all_interfaces[$i]}"
        local status=$(ip link show "$iface" | grep -o "state [A-Z]*" | awk '{print $2}')
        
        if [[ $i -eq $((${#all_interfaces[@]} - 1)) ]]; then
            echo "            {\"name\": \"$iface\", \"status\": \"$status\"}" >> "$export_file"
        else
            echo "            {\"name\": \"$iface\", \"status\": \"$status\"}," >> "$export_file"
        fi
    done
    
    cat >> "$export_file" << EOF
        ]
    }
}
EOF
    
    echo -e "${GREEN}✓${NC} 完整配置已导出到: ${GREEN}$export_file${NC}"
    echo -e "地址数量: ${GREEN}${#ipv6_addrs[@]}${NC}"
    echo -e "接口数量: ${GREEN}${#all_interfaces[@]}${NC}"
    
    log_message "SUCCESS" "完整配置导出完成: $export_file"
}

# 导入配置用于迁移
wizard_import_for_migration() {
    echo
    echo -e "${BLUE}=== 📥 导入配置用于迁移 ===${NC}"
    
    echo -e "${WHITE}💡 提示: 请确保配置文件已复制到本服务器${NC}"
    echo
    
    # 调用标准导入功能
    config_import
}

# 配置同步检查
wizard_config_sync_check() {
    echo
    echo -e "${BLUE}=== 🔍 配置同步检查 ===${NC}"
    echo -e "${CYAN}检查当前配置与参考配置的差异。${NC}"
    echo
    
    # 列出可用的配置文件作为参考
    local config_files=($(find "$CONFIG_DIR" -name "*.json" -type f 2>/dev/null))
    
    if [[ ${#config_files[@]} -eq 0 ]]; then
        echo -e "${YELLOW}没有找到参考配置文件${NC}"
        echo -e "${CYAN}请先导出或导入一个配置文件作为参考${NC}"
        return 0
    fi
    
    echo -e "${WHITE}可用的参考配置:${NC}"
    for i in "${!config_files[@]}"; do
        local config_file="${config_files[$i]}"
        local filename=$(basename "$config_file")
        local timestamp=$(grep '"timestamp":' "$config_file" 2>/dev/null | head -1 | cut -d'"' -f4)
        
        echo -e "${WHITE}$((i+1)).${NC} $filename"
        if [[ -n "$timestamp" ]]; then
            echo -e "    时间: ${CYAN}$timestamp${NC}"
        fi
        echo
    done
    
    local reference_file=""
    while true; do
        read -p "请选择参考配置编号 (1-${#config_files[@]}): " choice
        
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le ${#config_files[@]} ]]; then
            reference_file="${config_files[$((choice-1))]}"
            break
        else
            echo -e "${RED}无效选择，请输入 1-${#config_files[@]}${NC}"
        fi
    done
    
    # 选择当前接口
    echo
    wizard_select_interface
    if [[ $? -ne 0 ]]; then
        return 1
    fi
    
    # 执行同步检查
    echo
    echo -e "${BLUE}=== 🔍 执行同步检查 ===${NC}"
    
    # 获取当前配置
    local current_addrs=($(ip -6 addr show "$SELECTED_INTERFACE" 2>/dev/null | grep "inet6" | grep -v "fe80" | awk '{print $2}'))
    
    # 获取参考配置
    local reference_addrs=($(grep -o '"[0-9a-fA-F:]*\/[0-9]*"' "$reference_file" | tr -d '"'))
    
    echo -e "${WHITE}当前配置 (${#current_addrs[@]} 个地址):${NC}"
    for addr in "${current_addrs[@]}"; do
        echo -e "  ${GREEN}•${NC} $addr"
    done
    
    echo
    echo -e "${WHITE}参考配置 (${#reference_addrs[@]} 个地址):${NC}"
    for addr in "${reference_addrs[@]}"; do
        echo -e "  ${CYAN}•${NC} $addr"
    done
    
    # 分析差异
    echo
    echo -e "${BLUE}=== 📊 差异分析 ===${NC}"
    
    # 找出缺失的地址
    local missing_addrs=()
    for ref_addr in "${reference_addrs[@]}"; do
        local found=false
        for curr_addr in "${current_addrs[@]}"; do
            if [[ "$curr_addr" == "$ref_addr" ]]; then
                found=true
                break
            fi
        done
        if [[ "$found" == false ]]; then
            missing_addrs+=("$ref_addr")
        fi
    done
    
    # 找出多余的地址
    local extra_addrs=()
    for curr_addr in "${current_addrs[@]}"; do
        local found=false
        for ref_addr in "${reference_addrs[@]}"; do
            if [[ "$curr_addr" == "$ref_addr" ]]; then
                found=true
                break
            fi
        done
        if [[ "$found" == false ]]; then
            extra_addrs+=("$curr_addr")
        fi
    done
    
    if [[ ${#missing_addrs[@]} -eq 0 && ${#extra_addrs[@]} -eq 0 ]]; then
        echo -e "${GREEN}✅ 配置完全同步，无差异${NC}"
    else
        if [[ ${#missing_addrs[@]} -gt 0 ]]; then
            echo -e "${YELLOW}缺失的地址 (${#missing_addrs[@]} 个):${NC}"
            for addr in "${missing_addrs[@]}"; do
                echo -e "  ${RED}- $addr${NC}"
            done
        fi
        
        if [[ ${#extra_addrs[@]} -gt 0 ]]; then
            echo
            echo -e "${YELLOW}多余的地址 (${#extra_addrs[@]} 个):${NC}"
            for addr in "${extra_addrs[@]}"; do
                echo -e "  ${YELLOW}+ $addr${NC}"
            done
        fi
        
        echo
        read -p "是否要同步配置? (y/N): " sync_confirm
        if [[ "$sync_confirm" =~ ^[Yy]$ ]]; then
            wizard_perform_sync "$SELECTED_INTERFACE" missing_addrs extra_addrs
        fi
    fi
}

# 执行配置同步
wizard_perform_sync() {
    local interface=$1
    local -n missing=$2
    local -n extra=$3
    
    echo
    echo -e "${BLUE}=== 🔄 执行配置同步 ===${NC}"
    
    local total_operations=$((${#missing[@]} + ${#extra[@]}))
    if [[ $total_operations -eq 0 ]]; then
        echo -e "${GREEN}无需同步操作${NC}"
        return 0
    fi
    
    # 创建同步前快照
    local snapshot_file=$(create_snapshot "$interface" "sync" "配置同步前的备份")
    echo -e "${GREEN}✓${NC} 快照已保存: $(basename "$snapshot_file")"
    echo
    
    local success_count=0
    local error_count=0
    
    # 添加缺失的地址
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${CYAN}添加缺失的地址:${NC}"
        for addr in "${missing[@]}"; do
            echo -n "添加 $addr ... "
            # 尝试添加IPv6地址并捕获错误信息
            local error_output
            error_output=$(ip -6 addr add "$addr" dev "$interface" 2>&1)
            local exit_code=$?
            
            if [[ $exit_code -eq 0 ]]; then
                echo -e "${GREEN}成功${NC}"
                log_message "SUCCESS" "同步添加IPv6地址: $addr"
                ((success_count++))
            else
                # 分析失败原因
                local failure_reason="未知错误"
                if [[ "$error_output" =~ "File exists" ]] || [[ "$error_output" =~ "RTNETLINK answers: File exists" ]]; then
                    failure_reason="地址已存在"
                elif [[ "$error_output" =~ "No such device" ]] || [[ "$error_output" =~ "Cannot find device" ]]; then
                    failure_reason="网络接口不存在"
                elif [[ "$error_output" =~ "Invalid argument" ]]; then
                    failure_reason="无效的IPv6地址格式"
                elif [[ "$error_output" =~ "Permission denied" ]] || [[ "$error_output" =~ "Operation not permitted" ]]; then
                    failure_reason="权限不足"
                elif [[ "$error_output" =~ "Network is unreachable" ]]; then
                    failure_reason="网络不可达"
                fi
                
                echo -e "${RED}失败 (${failure_reason})${NC}"
                log_message "ERROR" "同步添加IPv6地址失败: $addr - 原因: $failure_reason"
                ((error_count++))
            fi
        done
    fi
    
    # 删除多余的地址
    if [[ ${#extra[@]} -gt 0 ]]; then
        echo
        echo -e "${CYAN}删除多余的地址:${NC}"
        for addr in "${extra[@]}"; do
            echo -n "删除 $addr ... "
            if ip -6 addr del "$addr" dev "$interface" 2>/dev/null; then
                echo -e "${GREEN}成功${NC}"
                log_message "SUCCESS" "同步删除IPv6地址: $addr"
                ((success_count++))
            else
                echo -e "${RED}失败${NC}"
                log_message "ERROR" "同步删除IPv6地址失败: $addr"
                ((error_count++))
            fi
        done
    fi
    
    echo
    echo -e "${BLUE}=== ✅ 配置同步完成 ===${NC}"
    echo -e "总操作数: ${WHITE}$total_operations${NC}"
    echo -e "成功: ${GREEN}$success_count${NC}"
    echo -e "失败: ${RED}$error_count${NC}"
    
    log_message "SUCCESS" "配置同步完成: $total_operations 个操作，成功 $success_count 个，失败 $error_count 个"
}

# 批量配置部署
wizard_batch_deployment() {
    echo
    echo -e "${BLUE}=== 🚀 批量配置部署 ===${NC}"
    echo -e "${CYAN}在多个接口上部署标准化配置。${NC}"
    echo
    
    echo -e "${WHITE}部署模式:${NC}"
    echo -e "${GREEN}1.${NC} 使用模板部署"
    echo -e "${GREEN}2.${NC} 使用配置文件部署"
    echo -e "${GREEN}3.${NC} 自定义批量部署"
    echo -e "${YELLOW}0.${NC} 返回上级菜单"
    echo
    
    local deploy_mode
    while true; do
        read -p "请选择部署模式 (0-3): " deploy_mode
        if [[ "$deploy_mode" == "0" ]]; then
            return 1
        elif [[ "$deploy_mode" =~ ^[1-3]$ ]]; then
            break
        else
            echo -e "${RED}请输入 0-3 之间的数字${NC}"
        fi
    done
    
    case $deploy_mode in
        1) wizard_template_deployment ;;
        2) wizard_config_file_deployment ;;
        3) wizard_custom_batch_deployment ;;
    esac
}

# 模板部署
wizard_template_deployment() {
    echo
    echo -e "${BLUE}=== 📋 模板批量部署 ===${NC}"
    
    # 直接调用多接口单模板应用
    wizard_multi_interface_single_template
}

# 配置文件部署
wizard_config_file_deployment() {
    echo
    echo -e "${BLUE}=== 📁 配置文件批量部署 ===${NC}"
    
    # 选择配置文件
    local config_files=($(find "$CONFIG_DIR" -name "*.json" -type f 2>/dev/null))
    
    if [[ ${#config_files[@]} -eq 0 ]]; then
        echo -e "${YELLOW}没有找到可部署的配置文件${NC}"
        return 0
    fi
    
    echo -e "${WHITE}可用的配置文件:${NC}"
    for i in "${!config_files[@]}"; do
        local config_file="${config_files[$i]}"
        local filename=$(basename "$config_file")
        local timestamp=$(grep '"timestamp":' "$config_file" 2>/dev/null | head -1 | cut -d'"' -f4)
        
        echo -e "${WHITE}$((i+1)).${NC} $filename"
        if [[ -n "$timestamp" ]]; then
            echo -e "    时间: ${CYAN}$timestamp${NC}"
        fi
        echo
    done
    
    local selected_config=""
    while true; do
        read -p "请选择配置文件编号 (1-${#config_files[@]}): " choice
        
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le ${#config_files[@]} ]]; then
            selected_config="${config_files[$((choice-1))]}"
            break
        else
            echo -e "${RED}无效选择，请输入 1-${#config_files[@]}${NC}"
        fi
    done
    
    # 选择目标接口
    echo
    local interfaces=($(get_network_interfaces))
    if [[ ${#interfaces[@]} -eq 0 ]]; then
        echo -e "${RED}❌ 未找到可用的网络接口${NC}"
        return 1
    fi
    
    echo -e "${WHITE}可用的网络接口:${NC}"
    for i in "${!interfaces[@]}"; do
        local status=$(ip link show "${interfaces[$i]}" | grep -o "state [A-Z]*" | awk '{print $2}')
        local status_color="${GREEN}"
        [[ "$status" != "UP" ]] && status_color="${YELLOW}"
        echo -e "${WHITE}$((i+1)).${NC} ${interfaces[$i]} ${status_color}($status)${NC}"
    done
    
    local selected_interfaces=()
    echo
    echo -e "${CYAN}请选择要部署的接口 (可多选，输入0完成选择):${NC}"
    
    while true; do
        read -p "选择接口编号 (1-${#interfaces[@]}, 0=完成): " choice
        
        if [[ "$choice" == "0" ]]; then
            break
        elif [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le ${#interfaces[@]} ]]; then
            local interface="${interfaces[$((choice-1))]}"
            
            # 检查是否已选择
            local already_selected=false
            for selected in "${selected_interfaces[@]}"; do
                if [[ "$selected" == "$interface" ]]; then
                    already_selected=true
                    break
                fi
            done
            
            if [[ "$already_selected" == false ]]; then
                selected_interfaces+=("$interface")
                echo -e "${GREEN}✓${NC} 已选择: $interface"
            else
                echo -e "${YELLOW}接口已选择: $interface${NC}"
            fi
        else
            echo -e "${RED}无效选择，请输入 1-${#interfaces[@]} 或 0${NC}"
        fi
    done
    
    if [[ ${#selected_interfaces[@]} -eq 0 ]]; then
        echo -e "${YELLOW}未选择任何接口${NC}"
        return 0
    fi
    
    # 确认部署
    echo
    echo -e "${BLUE}=== 批量部署确认 ===${NC}"
    echo -e "配置文件: ${GREEN}$(basename "$selected_config")${NC}"
    echo -e "目标接口:"
    for interface in "${selected_interfaces[@]}"; do
        echo -e "  ${WHITE}•${NC} $interface"
    done
    
    read -p "确认批量部署? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}批量部署已取消${NC}"
        return 0
    fi
    
    # 开始批量部署
    echo
    echo -e "${BLUE}=== 🚀 开始批量部署 ===${NC}"
    
    local total_success=0
    local total_error=0
    
    for i in "${!selected_interfaces[@]}"; do
        local interface="${selected_interfaces[$i]}"
        
        echo
        echo -e "${CYAN}[$((i+1))/${#selected_interfaces[@]}] 部署到接口: $interface${NC}"
        
        # 导入配置到指定接口
        local addresses=($(grep -o '"[0-9a-fA-F:]*\/[0-9]*"' "$selected_config" | tr -d '"'))
        
        local success_count=0
        local error_count=0
        
        for addr in "${addresses[@]}"; do
            if ip -6 addr add "$addr" dev "$interface" 2>/dev/null; then
                ((success_count++))
                log_message "SUCCESS" "批量部署成功添加IPv6地址: $addr 到 $interface"
            else
                ((error_count++))
                log_message "ERROR" "批量部署添加IPv6地址失败: $addr 到 $interface"
            fi
        done
        
        echo -e "  成功: ${GREEN}$success_count${NC}, 失败: ${RED}$error_count${NC}"
        
        total_success=$((total_success + success_count))
        total_error=$((total_error + error_count))
        
        sleep 0.5
    done
    
    echo
    echo -e "${BLUE}=== ✅ 批量部署完成 ===${NC}"
    echo -e "部署接口数: ${GREEN}${#selected_interfaces[@]}${NC}"
    echo -e "总成功数: ${GREEN}$total_success${NC}"
    echo -e "总失败数: ${RED}$total_error${NC}"
    
    log_message "SUCCESS" "配置文件批量部署完成: ${#selected_interfaces[@]} 个接口，成功 $total_success 个，失败 $total_error 个"
}

# 自定义批量部署
wizard_custom_batch_deployment() {
    echo
    echo -e "${BLUE}=== 🎛️  自定义批量部署 ===${NC}"
    echo -e "${CYAN}创建自定义的批量部署配置。${NC}"
    echo
    
    echo -e "${WHITE}💡 提示: 这将引导您创建自定义的批量配置${NC}"
    echo -e "${CYAN}您可以为不同接口配置不同的IPv6地址${NC}"
    echo
    
    read -p "按回车键继续..."
    
    # 调用标准的批量添加功能
    batch_add_ipv6
}

# 向导模式的接口选择
wizard_select_interface() {
    echo -e "${WHITE}📡 步骤: 选择网络接口${NC}"
    
    local interfaces=($(get_network_interfaces))
    if [[ ${#interfaces[@]} -eq 0 ]]; then
        echo -e "${RED}❌ 未找到可用的网络接口${NC}"
        return 1
    fi
    
    if [[ ${#interfaces[@]} -eq 1 ]]; then
        SELECTED_INTERFACE="${interfaces[0]}"
        local status=$(ip link show "${interfaces[0]}" | grep -o "state [A-Z]*" | awk '{print $2}')
        echo -e "${GREEN}✓${NC} 自动选择接口: ${GREEN}$SELECTED_INTERFACE${NC} (${status})"
        return 0
    fi
    
    echo -e "${CYAN}检测到多个网络接口:${NC}"
    for i in "${!interfaces[@]}"; do
        local status=$(ip link show "${interfaces[$i]}" | grep -o "state [A-Z]*" | awk '{print $2}')
        local status_color="${GREEN}"
        [[ "$status" != "UP" ]] && status_color="${YELLOW}"
        echo -e "${WHITE}$((i+1)).${NC} ${interfaces[$i]} ${status_color}($status)${NC}"
    done
    
    echo
    while true; do
        read -p "请选择接口编号 (1-${#interfaces[@]}): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le ${#interfaces[@]} ]]; then
            SELECTED_INTERFACE="${interfaces[$((choice-1))]}"
            echo -e "${GREEN}✓${NC} 选择了接口: ${GREEN}$SELECTED_INTERFACE${NC}"
            break
        else
            echo -e "${RED}无效选择，请输入 1-${#interfaces[@]} 之间的数字${NC}"
        fi
    done
    
    return 0
}

# 配置预览和执行
wizard_preview_and_execute() {
    local prefix=$1
    local start=$2
    local end=$3
    local mode=$4
    
    echo
    echo -e "${BLUE}=== 📋 配置预览 ===${NC}"
    echo -e "接口: ${GREEN}$SELECTED_INTERFACE${NC}"
    echo -e "IPv6前缀: ${GREEN}$prefix${NC}"
    echo -e "地址范围: ${GREEN}$start - $end${NC}"
    echo -e "地址数量: ${GREEN}$((end - start + 1))${NC}"
    echo -e "子网掩码: ${GREEN}/64${NC}"
    
    # 显示示例地址
    echo
    echo -e "${CYAN}将要配置的地址示例:${NC}"
    local count=0
    for ((i=start; i<=end && count<5; i++)); do
        echo -e "  ${WHITE}•${NC} $prefix::$i/64"
        ((count++))
    done
    
    if [[ $((end - start + 1)) -gt 5 ]]; then
        echo -e "  ${YELLOW}... 还有 $((end - start + 1 - 5)) 个地址${NC}"
    fi
    
    echo
    echo -e "${WHITE}⏱️  预计执行时间: ${GREEN}$((end - start + 1))${NC} 秒"
    
    # 安全检查
    if [[ $((end - start + 1)) -gt 50 ]]; then
        echo -e "${YELLOW}⚠️  注意: 将配置大量地址，建议分批执行${NC}"
    fi
    
    echo
    read -p "确认执行配置? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        wizard_execute_simple_config "$prefix" "$start" "$end"
    else
        echo -e "${YELLOW}配置已取消${NC}"
    fi
}

# 执行简单配置
wizard_execute_simple_config() {
    local prefix=$1
    local start=$2
    local end=$3
    
    echo
    echo -e "${BLUE}=== 🚀 开始配置IPv6地址 ===${NC}"
    echo
    
    local success_count=0
    local error_count=0
    
    for ((i=start; i<=end; i++)); do
        local ipv6_addr="$prefix::$i/64"
        
        echo -n "配置 $ipv6_addr ... "
        
        if ip -6 addr add "$ipv6_addr" dev "$SELECTED_INTERFACE" 2>/dev/null; then
            echo -e "${GREEN}成功${NC}"
            log_message "SUCCESS" "向导模式成功添加IPv6地址: $ipv6_addr 到接口 $SELECTED_INTERFACE"
            ((success_count++))
        else
            echo -e "${RED}失败${NC}"
            log_message "ERROR" "向导模式添加IPv6地址失败: $ipv6_addr 到接口 $SELECTED_INTERFACE"
            ((error_count++))
        fi
        
        sleep 0.1
    done
    
    echo
    echo -e "${BLUE}=== ✅ 配置完成 ===${NC}"
    echo -e "成功: ${GREEN}$success_count${NC} 个地址"
    echo -e "失败: ${RED}$error_count${NC} 个地址"
    
    if [[ $success_count -gt 0 ]]; then
        echo
        echo -e "${CYAN}🎉 恭喜！IPv6地址配置成功！${NC}"
        echo -e "${WHITE}您现在可以使用这些IPv6地址了。${NC}"
        
        # 提供后续建议
        echo
        echo -e "${BLUE}💡 后续建议:${NC}"
        echo -e "  • 使用选项1查看当前配置"
        echo -e "  • 测试IPv6连通性: ${YELLOW}ping6 ipv6.google.com${NC}"
        echo -e "  • 查看操作日志了解详细信息"
    fi
}

# 自定义配置向导
wizard_custom_configuration() {
    echo
    echo -e "${BLUE}=== 🔧 自定义配置向导 ===${NC}"
    echo -e "${CYAN}我将引导您完成自定义IPv6配置。${NC}"
    echo
    
    # 调用原有的批量配置功能，但添加向导式提示
    echo -e "${WHITE}💡 提示: 接下来将进入高级配置模式${NC}"
    echo -e "${CYAN}您可以配置复杂的IPv6地址段组合${NC}"
    echo
    read -p "按回车键继续..."
    
    batch_add_ipv6
}

# 模板选择向导
wizard_template_selection() {
    echo
    echo -e "${BLUE}=== 📋 配置模板选择 ===${NC}"
    echo -e "${CYAN}选择预设的配置模板快速完成配置。${NC}"
    echo
    
    echo -e "${WHITE}可用模板:${NC}"
    echo -e "${GREEN}1.${NC} 🏠 家庭服务器模板 (::1-5)"
    echo -e "${GREEN}2.${NC} 🏢 办公网络模板 (::10-50)"
    echo -e "${GREEN}3.${NC} 🧪 开发测试模板 (::100-110)"
    echo -e "${GREEN}4.${NC} 🌐 Web服务器模板 (::80, ::443, ::8080)"
    echo -e "${GREEN}5.${NC} 📧 邮件服务器模板 (::25, ::110, ::143, ::993, ::995)"
    echo -e "${YELLOW}0.${NC} 返回主菜单"
    echo
    
    local template_choice
    while true; do
        read -p "请选择模板 (0-5): " template_choice
        if [[ "$template_choice" == "0" ]]; then
            return 1
        elif [[ "$template_choice" =~ ^[1-5]$ ]]; then
            break
        else
            echo -e "${RED}请输入 0-5 之间的数字${NC}"
        fi
    done
    
    wizard_select_interface
    if [[ $? -ne 0 ]]; then return 1; fi
    
    echo
    local ipv6_prefix
    while true; do
        read -p "请输入IPv6前缀 (例如: 2012:f2c4:1:1f34): " ipv6_prefix
        if validate_ipv6_prefix "$ipv6_prefix"; then
            break
        fi
        echo -e "${YELLOW}请重新输入正确的IPv6前缀${NC}"
    done
    
    case $template_choice in
        1) wizard_preview_and_execute "$ipv6_prefix" "1" "5" "template" ;;
        2) wizard_preview_and_execute "$ipv6_prefix" "10" "50" "template" ;;
        3) wizard_preview_and_execute "$ipv6_prefix" "100" "110" "template" ;;
        4) wizard_execute_service_template "$ipv6_prefix" "80 443 8080" ;;
        5) wizard_execute_service_template "$ipv6_prefix" "25 110 143 993 995" ;;
    esac
}

# 服务端口模板执行
wizard_execute_service_template() {
    local prefix=$1
    local ports=$2
    
    echo
    echo -e "${BLUE}=== 📋 服务端口配置预览 ===${NC}"
    echo -e "接口: ${GREEN}$SELECTED_INTERFACE${NC}"
    echo -e "IPv6前缀: ${GREEN}$prefix${NC}"
    echo -e "服务端口: ${GREEN}$ports${NC}"
    
    echo
    echo -e "${CYAN}将要配置的地址:${NC}"
    for port in $ports; do
        echo -e "  ${WHITE}•${NC} $prefix::$port/64"
    done
    
    echo
    read -p "确认执行配置? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo
        echo -e "${BLUE}=== 🚀 开始配置服务端口地址 ===${NC}"
        
        local success_count=0
        local error_count=0
        
        for port in $ports; do
            local ipv6_addr="$prefix::$port/64"
            echo -n "配置 $ipv6_addr ... "
            
            if ip -6 addr add "$ipv6_addr" dev "$SELECTED_INTERFACE" 2>/dev/null; then
                echo -e "${GREEN}成功${NC}"
                log_message "SUCCESS" "模板配置成功添加IPv6地址: $ipv6_addr"
                ((success_count++))
            else
                echo -e "${RED}失败${NC}"
                log_message "ERROR" "模板配置添加IPv6地址失败: $ipv6_addr"
                ((error_count++))
            fi
            
            sleep 0.1
        done
        
        echo
        echo -e "${BLUE}=== ✅ 服务端口配置完成 ===${NC}"
        echo -e "成功: ${GREEN}$success_count${NC} 个地址"
        echo -e "失败: ${RED}$error_count${NC} 个地址"
    fi
}

# 持久化配置管理菜单
persistence_management() {
    while true; do
        echo -e "${BLUE}=== 🔒 持久化配置管理 ===${NC}"
        echo
        
        # 选择网络接口
        select_interface
        if [[ $? -ne 0 ]]; then
            return 1
        fi
        
        echo -e "${WHITE}当前接口: ${GREEN}$SELECTED_INTERFACE${NC}"
        echo
        
        echo -e "${GREEN}1.${NC} 检查持久化状态"
        echo -e "${GREEN}2.${NC} 为当前IPv6地址创建持久化配置"
        echo -e "${GREEN}3.${NC} 清理持久化配置"
        echo -e "${GREEN}4.${NC} 测试持久化配置"
        echo -e "${GREEN}5.${NC} 返回主菜单"
        echo
        
        read -p "请选择操作 (1-5): " persist_choice
        
        case $persist_choice in
            1)
                echo
                check_persistence_status "$SELECTED_INTERFACE"
                echo
                read -p "按回车键继续..."
                ;;
            2)
                echo
                create_persistence_for_current_addresses
                echo
                read -p "按回车键继续..."
                ;;
            3)
                echo
                cleanup_persistent_config "$SELECTED_INTERFACE"
                echo
                read -p "按回车键继续..."
                ;;
            4)
                echo
                test_persistent_config "$SELECTED_INTERFACE"
                echo
                read -p "按回车键继续..."
                ;;
            5)
                return 0
                ;;
            *)
                echo -e "${RED}无效选择，请输入 1-5 之间的数字${NC}"
                sleep 2
                ;;
        esac
    done
}

# 调试IPv6地址检测
debug_ipv6_detection() {
    local interface=$1
    
    echo -e "${BLUE}=== 🔍 IPv6地址检测调试 ===${NC}"
    echo -e "${WHITE}接口: ${GREEN}$interface${NC}"
    echo
    
    echo -e "${CYAN}原始ip命令输出:${NC}"
    ip -6 addr show "$interface" 2>/dev/null || echo -e "${RED}接口不存在或无IPv6配置${NC}"
    echo
    
    echo -e "${CYAN}scope global地址:${NC}"
    ip -6 addr show "$interface" 2>/dev/null | grep -E "inet6.*scope global" | while read line; do
        echo "  $line"
    done
    echo
    
    echo -e "${CYAN}提取的地址:${NC}"
    ip -6 addr show "$interface" 2>/dev/null | grep -E "inet6.*scope global" | awk '{print "  " $2}'
    echo
}

# 为当前IPv6地址创建持久化配置
create_persistence_for_current_addresses() {
    echo -e "${BLUE}=== 📝 为当前地址创建持久化配置 ===${NC}"
    echo
    
    # 添加调试选项
    read -p "是否显示调试信息? (y/N): " show_debug
    if [[ "$show_debug" =~ ^[Yy]$ ]]; then
        debug_ipv6_detection "$SELECTED_INTERFACE"
    fi
    
    # 获取当前接口的IPv6地址（排除链路本地地址）
    local current_addresses=()
    
    # 方法1: 优先使用scope global过滤
    echo -e "${CYAN}正在检测接口 $SELECTED_INTERFACE 的IPv6地址...${NC}"
    
    # 使用更直接的方法
    while IFS= read -r addr; do
        if [[ -n "$addr" ]]; then
            current_addresses+=("$addr")
        fi
    done < <(ip -6 addr show "$SELECTED_INTERFACE" 2>/dev/null | grep -E "inet6.*scope global" | awk '{print $2}')
    
    # 方法2: 如果没有找到scope global地址，尝试获取所有非链路本地地址
    if [[ ${#current_addresses[@]} -eq 0 ]]; then
        echo -e "${YELLOW}未找到scope global地址，尝试检测其他IPv6地址...${NC}"
        
        while IFS= read -r line; do
            if [[ "$line" =~ inet6[[:space:]]+([^[:space:]]+) ]]; then
                local addr="${BASH_REMATCH[1]}"
                # 排除链路本地地址 (fe80:) 和回环地址 (::1)
                if [[ ! "$addr" =~ ^fe80: ]] && [[ ! "$addr" =~ ^::1/ ]]; then
                    current_addresses+=("$addr")
                fi
            fi
        done < <(ip -6 addr show "$SELECTED_INTERFACE" 2>/dev/null)
    fi
    
    if [[ ${#current_addresses[@]} -eq 0 ]]; then
        echo -e "${YELLOW}⚠${NC} 接口 $SELECTED_INTERFACE 上没有找到有效的IPv6地址"
        echo -e "${WHITE}提示:${NC}"
        echo -e "${WHITE}  • 检查接口是否存在: ${CYAN}ip link show${NC}"
        echo -e "${WHITE}  • 检查IPv6是否启用: ${CYAN}cat /proc/net/if_inet6${NC}"
        echo -e "${WHITE}  • 查看所有IPv6地址: ${CYAN}ip -6 addr show $SELECTED_INTERFACE${NC}"
        return 1
    fi
    
    echo -e "${WHITE}找到 ${GREEN}${#current_addresses[@]}${NC} 个IPv6地址:${NC}"
    for addr in "${current_addresses[@]}"; do
        echo -e "  ${CYAN}$addr${NC}"
    done
    echo
    
    read -p "是否为这些地址创建持久化配置? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}操作已取消${NC}"
        return 0
    fi
    
    # 调用持久化功能
    make_persistent "$SELECTED_INTERFACE" "${current_addresses[@]}"
}

# 测试持久化配置
test_persistent_config() {
    local interface=$1
    
    echo -e "${BLUE}=== 🧪 测试持久化配置 ===${NC}"
    echo
    
    local network_system=$(detect_network_system)
    echo -e "${WHITE}网络配置系统: ${GREEN}$network_system${NC}"
    echo
    
    case $network_system in
        "netplan")
            echo -e "${CYAN}测试netplan配置...${NC}"
            if netplan try --timeout=10 2>/dev/null; then
                echo -e "${GREEN}✓${NC} netplan配置测试通过"
            else
                echo -e "${RED}✗${NC} netplan配置测试失败"
                echo -e "${YELLOW}请检查配置文件语法${NC}"
            fi
            ;;
        "interfaces")
            echo -e "${CYAN}检查interfaces配置文件...${NC}"
            if [[ -f /etc/network/interfaces ]]; then
                if grep -q "$interface.*inet6" /etc/network/interfaces 2>/dev/null; then
                    echo -e "${GREEN}✓${NC} 在interfaces文件中找到IPv6配置"
                else
                    echo -e "${YELLOW}⚠${NC} 在interfaces文件中未找到IPv6配置"
                fi
            else
                echo -e "${RED}✗${NC} interfaces文件不存在"
            fi
            ;;
        "networkmanager")
            echo -e "${CYAN}检查NetworkManager配置...${NC}"
            local connection_name=$(nmcli -t -f NAME,DEVICE connection show --active | grep "$interface" | cut -d: -f1)
            if [[ -n "$connection_name" ]]; then
                echo -e "${GREEN}✓${NC} 找到活动连接: $connection_name"
                nmcli connection show "$connection_name" | grep -i ipv6
            else
                echo -e "${RED}✗${NC} 未找到活动的NetworkManager连接"
            fi
            ;;
    esac
    
    # 检查启动脚本
    echo
    echo -e "${CYAN}检查启动脚本...${NC}"
    if [[ -f /etc/rc.local ]] && grep -q "ip -6 addr add.*$interface" /etc/rc.local 2>/dev/null; then
        local script_count=$(grep -c "ip -6 addr add.*$interface" /etc/rc.local 2>/dev/null)
        echo -e "${GREEN}✓${NC} 在启动脚本中找到 $script_count 条IPv6配置"
    else
        echo -e "${YELLOW}⚠${NC} 启动脚本中未找到IPv6配置"
    fi
    
    # 检查systemd服务
    echo -e "${CYAN}检查systemd服务...${NC}"
    if systemctl list-unit-files | grep -q "ipv6-persistent" 2>/dev/null; then
        local service_status=$(systemctl is-enabled ipv6-persistent.service 2>/dev/null || echo "disabled")
        echo -e "${GREEN}✓${NC} 找到IPv6持久化服务，状态: $service_status"
        
        if systemctl is-active ipv6-persistent.service &>/dev/null; then
            echo -e "${GREEN}✓${NC} 服务当前正在运行"
        else
            echo -e "${YELLOW}⚠${NC} 服务当前未运行"
        fi
    else
        echo -e "${YELLOW}⚠${NC} 未找到IPv6持久化systemd服务"
    fi
    
    echo
    echo -e "${BLUE}=== 建议 ===${NC}"
    echo -e "${WHITE}• 如果配置测试失败，请检查配置文件语法${NC}"
    echo -e "${WHITE}• 建议在测试环境中先验证配置${NC}"
    echo -e "${WHITE}• 可以通过重启系统来完全测试持久化效果${NC}"
}

# 主菜单
show_main_menu() {
    while true; do
        show_banner
        
        echo -e "${WHITE}=== 主菜单 ===${NC}"
        echo
        echo -e "${PURPLE}🧙 向导模式${NC}"
        echo -e "${GREEN}0.${NC} 交互式向导 - 新手推荐"
        echo
        echo -e "${WHITE}📋 标准功能${NC}"
        echo -e "${GREEN}1.${NC} 查看当前IPv6配置"
        echo -e "${GREEN}2.${NC} 批量添加IPv6地址"
        echo -e "${GREEN}3.${NC} 批量删除IPv6地址"
        echo -e "${GREEN}4.${NC} 显示系统状态"
        echo -e "${GREEN}5.${NC} 查看操作日志"
        echo
        echo -e "${CYAN}🔄 回滚管理${NC}"
        echo -e "${GREEN}6.${NC} 回滚和快照管理"
        echo
        echo -e "${PURPLE}⚙️  配置管理${NC}"
        echo -e "${GREEN}7.${NC} 配置文件和模板管理"
        echo -e "${GREEN}8.${NC} 持久化配置管理"
        echo -e "${RED}9.${NC} 退出程序"
        echo
        
        read -p "请选择操作 (0-9): " choice
        
        case $choice in
            0)
                echo
                wizard_mode
                echo
                read -p "按回车键继续..."
                ;;
            1)
                echo
                show_current_ipv6
                echo
                read -p "按回车键继续..."
                ;;
            2)
                echo
                batch_add_ipv6
                ;;
            3)
                echo
                remove_ipv6
                echo
                read -p "按回车键继续..."
                ;;
            4)
                echo
                show_system_status
                echo
                read -p "按回车键继续..."
                ;;
            5)
                echo
                view_logs
                echo
                read -p "按回车键继续..."
                ;;
            6)
                echo
                rollback_management
                echo
                read -p "按回车键继续..."
                ;;
            7)
                echo
                config_management
                echo
                read -p "按回车键继续..."
                ;;
            8)
                echo
                persistence_management
                echo
                read -p "按回车键继续..."
                ;;
            9)
                echo
                log_message "INFO" "用户退出程序"
                echo -e "${GREEN}感谢使用IPv6批量配置工具！${NC}"
                exit 0
                ;;
            *)
                echo
                echo -e "${RED}无效选择，请输入 0-9 之间的数字${NC}"
                sleep 2
                ;;
        esac
    done
}

# 主函数
main() {
    # 检查运行权限
    check_root
    
    # 检查系统依赖
    check_dependencies
    
    # 初始化配置系统
    init_default_config
    
    # 创建内置模板（如果不存在）
    if [[ ! -f "$TEMPLATE_DIR/home_server.json" ]]; then
        create_builtin_templates
    fi
    
    # 记录启动日志
    log_message "INFO" "IPv6批量配置脚本启动"
    
    # 显示主菜单
    show_main_menu
}

# 脚本入口点
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi