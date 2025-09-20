#!/bin/bash

# IPv6 Interface Manager 安装脚本
# 版本: 1.0
# 作者: pjy02
# 许可证: MIT

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# 配置变量
SCRIPT_URL="https://raw.githubusercontent.com/pjy02/ipv6-interface-manager/refs/heads/main/ipv6_batch_config.sh"
INSTALL_DIR="/etc/ipv6-interface-manager"
SCRIPT_NAME="ipv6_batch_config.sh"
COMMAND_NAME="iim"
SYMLINK_PATH="/usr/local/bin/$COMMAND_NAME"

# 打印带颜色的消息
print_message() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# 打印标题
print_title() {
    echo
    print_message $CYAN "=================================="
    print_message $WHITE "  IPv6 Interface Manager 安装器"
    print_message $CYAN "=================================="
    echo
}

# 检查是否为root用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_message $RED "错误: 此脚本需要root权限运行"
        print_message $YELLOW "请使用: sudo $0"
        exit 1
    fi
}

# 检查系统依赖
check_dependencies() {
    print_message $BLUE "检查系统依赖..."
    
    local missing_deps=()
    
    # 检查必需的命令
    for cmd in curl wget; do
        if ! command -v $cmd &> /dev/null; then
            missing_deps+=($cmd)
        fi
    done
    
    if [ ${#missing_deps[@]} -eq 2 ]; then
        print_message $RED "错误: 需要安装 curl 或 wget"
        print_message $YELLOW "请运行: apt update && apt install -y curl"
        exit 1
    fi
    
    print_message $GREEN "✓ 系统依赖检查完成"
}

# 创建安装目录
create_install_dir() {
    print_message $BLUE "创建安装目录..."
    
    if [ -d "$INSTALL_DIR" ]; then
        print_message $YELLOW "警告: 安装目录已存在，将进行覆盖安装"
        read -p "是否继续? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_message $YELLOW "安装已取消"
            exit 0
        fi
    fi
    
    mkdir -p "$INSTALL_DIR"
    chmod 755 "$INSTALL_DIR"
    
    print_message $GREEN "✓ 安装目录创建完成: $INSTALL_DIR"
}

# 下载主脚本
download_script() {
    print_message $BLUE "下载IPv6接口管理器脚本..."
    
    local script_path="$INSTALL_DIR/$SCRIPT_NAME"
    
    # 尝试使用curl下载
    if command -v curl &> /dev/null; then
        if curl -fsSL "$SCRIPT_URL" -o "$script_path"; then
            print_message $GREEN "✓ 使用curl下载成功"
        else
            print_message $RED "curl下载失败，尝试使用wget..."
            if command -v wget &> /dev/null; then
                if wget -q "$SCRIPT_URL" -O "$script_path"; then
                    print_message $GREEN "✓ 使用wget下载成功"
                else
                    print_message $RED "错误: 下载失败"
                    exit 1
                fi
            else
                print_message $RED "错误: 无法下载脚本文件"
                exit 1
            fi
        fi
    elif command -v wget &> /dev/null; then
        if wget -q "$SCRIPT_URL" -O "$script_path"; then
            print_message $GREEN "✓ 使用wget下载成功"
        else
            print_message $RED "错误: 下载失败"
            exit 1
        fi
    fi
    
    # 设置执行权限
    chmod +x "$script_path"
    
    print_message $GREEN "✓ 脚本下载完成: $script_path"
}

# 创建快捷命令
create_shortcut() {
    print_message $BLUE "创建快捷命令 '$COMMAND_NAME'..."
    
    local script_path="$INSTALL_DIR/$SCRIPT_NAME"
    
    # 删除现有的符号链接（如果存在）
    if [ -L "$SYMLINK_PATH" ] || [ -f "$SYMLINK_PATH" ]; then
        rm -f "$SYMLINK_PATH"
    fi
    
    # 创建符号链接
    ln -s "$script_path" "$SYMLINK_PATH"
    
    # 验证符号链接
    if [ -L "$SYMLINK_PATH" ] && [ -x "$SYMLINK_PATH" ]; then
        print_message $GREEN "✓ 快捷命令创建成功: $COMMAND_NAME"
    else
        print_message $RED "错误: 快捷命令创建失败"
        exit 1
    fi
}

# 验证安装
verify_installation() {
    print_message $BLUE "验证安装..."
    
    local script_path="$INSTALL_DIR/$SCRIPT_NAME"
    
    # 检查脚本文件
    if [ ! -f "$script_path" ]; then
        print_message $RED "错误: 脚本文件不存在"
        exit 1
    fi
    
    if [ ! -x "$script_path" ]; then
        print_message $RED "错误: 脚本文件不可执行"
        exit 1
    fi
    
    # 检查快捷命令
    if ! command -v "$COMMAND_NAME" &> /dev/null; then
        print_message $RED "错误: 快捷命令不可用"
        exit 1
    fi
    
    # 检查脚本是否能正常运行（显示帮助信息）
    if "$COMMAND_NAME" --help &> /dev/null; then
        print_message $GREEN "✓ 安装验证成功"
    else
        print_message $YELLOW "警告: 脚本可能无法正常运行，但安装已完成"
    fi
}

# 显示安装完成信息
show_completion_info() {
    echo
    print_message $GREEN "🎉 IPv6 Interface Manager 安装完成！"
    echo
    print_message $CYAN "安装信息:"
    print_message $WHITE "  • 安装目录: $INSTALL_DIR"
    print_message $WHITE "  • 脚本文件: $INSTALL_DIR/$SCRIPT_NAME"
    print_message $WHITE "  • 快捷命令: $COMMAND_NAME"
    echo
    print_message $CYAN "使用方法:"
    print_message $WHITE "  • 运行脚本: $COMMAND_NAME"
    print_message $WHITE "  • 显示帮助: $COMMAND_NAME --help"
    print_message $WHITE "  • 向导模式: $COMMAND_NAME --wizard"
    echo
    print_message $YELLOW "注意: 首次运行需要root权限"
    print_message $YELLOW "示例: sudo $COMMAND_NAME"
    echo
}

# 卸载函数
uninstall() {
    print_message $YELLOW "开始卸载 IPv6 Interface Manager..."
    
    # 删除符号链接
    if [ -L "$SYMLINK_PATH" ] || [ -f "$SYMLINK_PATH" ]; then
        rm -f "$SYMLINK_PATH"
        print_message $GREEN "✓ 快捷命令已删除"
    fi
    
    # 删除安装目录
    if [ -d "$INSTALL_DIR" ]; then
        rm -rf "$INSTALL_DIR"
        print_message $GREEN "✓ 安装目录已删除"
    fi
    
    print_message $GREEN "🗑️  IPv6 Interface Manager 卸载完成"
}

# 显示帮助信息
show_help() {
    echo
    print_message $CYAN "IPv6 Interface Manager 安装脚本"
    echo
    print_message $WHITE "用法:"
    print_message $WHITE "  $0 [选项]"
    echo
    print_message $WHITE "选项:"
    print_message $WHITE "  install     安装 IPv6 Interface Manager (默认)"
    print_message $WHITE "  uninstall   卸载 IPv6 Interface Manager"
    print_message $WHITE "  --help, -h  显示此帮助信息"
    echo
    print_message $WHITE "示例:"
    print_message $WHITE "  sudo $0                # 安装"
    print_message $WHITE "  sudo $0 install        # 安装"
    print_message $WHITE "  sudo $0 uninstall      # 卸载"
    echo
}

# 主函数
main() {
    case "${1:-install}" in
        "install")
            print_title
            check_root
            check_dependencies
            create_install_dir
            download_script
            create_shortcut
            verify_installation
            show_completion_info
            ;;
        "uninstall")
            check_root
            uninstall
            ;;
        "--help"|"-h"|"help")
            show_help
            ;;
        *)
            print_message $RED "错误: 未知选项 '$1'"
            show_help
            exit 1
            ;;
    esac
}

# 运行主函数
main "$@"