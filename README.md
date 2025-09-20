# IPv6批量配置工具

一个专为Ubuntu服务器设计的IPv6地址批量配置脚本，提供友好的交互式界面，简化IPv6网络配置过程。

## 功能特性

- 🚀 **批量IPv6地址配置** - 自动执行多个`ip -6 addr add`命令
- 🔒 **持久化配置** - 支持多种持久化方式，确保重启后配置保持
- 🖥️ **交互式操作面板** - 用户友好的菜单界面
- 🔧 **网络接口管理** - 自动检测和选择网络接口
- ✅ **配置验证** - 实时验证IPv6地址配置状态
- 📝 **日志记录** - 详细的操作日志和错误追踪
- 🔄 **配置管理** - 支持查看、添加和删除IPv6地址

## 系统要求

- Ubuntu Linux 服务器
- Root权限或sudo访问
- 已安装的系统工具：
  - `ip` (iproute2包)
  - `grep`, `awk`, `sed`

## 安装和使用

### 方法一：使用安装脚本（推荐）

#### 快速安装
```bash
# 下载并运行安装脚本
curl -fsSL https://raw.githubusercontent.com/pjy02/ipv6-interface-manager/refs/heads/main/install.sh | sudo bash

# 或者使用wget
wget -qO- https://raw.githubusercontent.com/pjy02/ipv6-interface-manager/refs/heads/main/install.sh | sudo bash
```

#### 手动安装
```bash
# 下载安装脚本
wget https://raw.githubusercontent.com/pjy02/ipv6-interface-manager/refs/heads/main/install.sh
chmod +x install.sh

# 运行安装
sudo ./install.sh
```

#### 安装后使用
```bash
# 使用快捷命令运行（推荐）
sudo iim

# 显示帮助信息
sudo iim --help

# 启动向导模式
sudo iim --wizard
```

#### 卸载
```bash
# 下载安装脚本后运行卸载
sudo ./install.sh uninstall
```

### 方法二：手动下载运行

#### 1. 下载脚本

```bash
# 从GitHub下载脚本文件
wget https://raw.githubusercontent.com/pjy02/ipv6-interface-manager/main/ipv6_batch_config.sh
```

#### 2. 设置执行权限

```bash
chmod +x ipv6_batch_config.sh
```

#### 3. 运行脚本

```bash
sudo ./ipv6_batch_config.sh
```

## 使用说明

### 主菜单选项

0. **交互式向导** - 新手推荐的引导式配置
1. **查看当前IPv6配置** - 显示所有网络接口的IPv6地址配置
2. **批量添加IPv6地址** - 批量配置IPv6地址到指定接口
3. **批量删除IPv6地址** - 删除指定的IPv6地址
4. **显示系统状态** - 查看系统和网络状态信息
5. **查看操作日志** - 查看详细的操作历史记录
6. **回滚和快照管理** - 配置备份和回滚功能
7. **配置文件和模板管理** - 模板和配置管理
8. **🔒 持久化配置管理** - 管理IPv6地址的持久化配置
9. **退出程序** - 安全退出脚本

### 批量添加IPv6地址

1. 选择目标网络接口（如 eth0）
2. 输入IPv6网段前缀（如 `2012:f2c4:1:1f34`）
3. 设置子网掩码长度（默认64）
4. 指定地址范围（起始和结束后缀）
5. 确认配置并执行批量添加

**示例配置：**
- IPv6前缀: `2012:f2c4:1:1f34`
- 地址范围: 1-10
- 生成地址: `2012:f2c4:1:1f34::1/64` 到 `2012:f2c4:1:1f34::10/64`

### 🔒 持久化配置功能

**重要提醒**: 通过 `ip -6 addr add` 命令添加的IPv6地址是临时的，系统重启后会消失。本脚本提供了多种持久化方式来解决这个问题。

#### 持久化方式

1. **系统配置文件（推荐）**
   - Ubuntu 18.04+: 使用 Netplan 配置
   - Ubuntu 16.04-: 使用 /etc/network/interfaces
   - NetworkManager: 使用 nmcli 配置

2. **启动脚本**
   - 在 /etc/rc.local 中添加配置命令
   - 系统启动时自动执行

3. **Systemd服务**
   - 创建专用的systemd服务
   - 更好的服务管理和依赖控制

#### 使用持久化功能

1. **自动询问**: 添加IPv6地址后，脚本会自动询问是否持久化
2. **手动管理**: 通过主菜单选项8进入持久化管理
3. **状态检查**: 检查当前持久化配置状态
4. **配置测试**: 验证持久化配置的正确性

#### 持久化测试

运行测试脚本检查系统兼容性：
```bash
./test_persistence.sh
```

详细的持久化配置指南请参考：[PERSISTENCE_GUIDE.md](PERSISTENCE_GUIDE.md)

## 配置示例

### 基本用法

假设您的服务器分配了IPv6网段 `2012:f2c4:1:1f34::/64`，您想要添加地址 `::1` 到 `::100`：

1. 运行脚本: `sudo ./ipv6_batch_config.sh`
2. 选择 "2. 批量添加IPv6地址"
3. 选择网络接口 (通常是 eth0)
4. 输入IPv6前缀: `2012:f2c4:1:1f34`
5. 子网掩码: `64` (默认)
6. 起始地址后缀: `1`
7. 结束地址后缀: `100`
8. 确认并执行

### 手动命令对比

**传统方式（需要逐个执行）：**
```bash
ip -6 addr add 2012:f2c4:1:1f34::1/64 dev eth0
ip -6 addr add 2012:f2c4:1:1f34::2/64 dev eth0
ip -6 addr add 2012:f2c4:1:1f34::3/64 dev eth0
# ... 继续手动添加
```

**使用本脚本：**
- 一次性配置所有地址
- 自动错误处理和日志记录
- 实时进度显示

## 日志系统

脚本会自动创建日志目录并记录所有操作：

- **日志位置**: `./logs/ipv6_config_YYYYMMDD.log`
- **日志级别**: INFO, WARN, ERROR, SUCCESS
- **日志内容**: 时间戳、操作类型、详细信息

### 查看日志

通过主菜单的"查看操作日志"选项，可以：
- 查看最近20条日志
- 浏览所有日志记录
- 筛选错误日志

## 安全注意事项

- ⚠️ **需要Root权限** - 网络配置需要管理员权限
- 🔒 **配置验证** - 脚本会验证输入参数的有效性
- 📋 **操作确认** - 重要操作前会要求用户确认
- 🔄 **可逆操作** - 支持删除已配置的IPv6地址

## 故障排除

### 常见问题

1. **权限不足**
   ```
   错误: 此脚本需要root权限运行
   解决: 使用 sudo ./ipv6_batch_config.sh
   ```

2. **IPv6未启用**
   ```
   检查: cat /proc/net/if_inet6
   启用: echo 'net.ipv6.conf.all.disable_ipv6 = 0' >> /etc/sysctl.conf
   ```

3. **网络接口不存在**
   ```
   检查: ip link show
   确认: 接口名称是否正确（如eth0, ens3等）
   ```

### 日志分析

查看详细错误信息：
```bash
# 查看今天的日志
tail -f logs/ipv6_config_$(date +%Y%m%d).log

# 查看错误日志
grep ERROR logs/ipv6_config_*.log
```

## 版本历史

- **v1.1** - 持久化功能版本
  - ✅ 新增持久化配置功能
  - ✅ 支持Netplan、Interfaces、启动脚本、Systemd服务四种持久化方式
  - ✅ 持久化状态检查和管理
  - ✅ 配置测试和验证功能
  - ✅ 持久化配置清理功能
  - ✅ 新增持久化测试脚本
  - ✅ 详细的持久化配置指南

- **v1.0** - 初始版本
  - 基本的IPv6批量配置功能
  - 交互式用户界面
  - 日志记录系统
  - 配置验证和错误处理

## 贡献

欢迎提交问题报告和功能建议！

## 许可证

本项目采用MIT许可证。

---

**注意**: 在生产环境中使用前，请先在测试环境中验证脚本功能。网络配置错误可能导致服务器连接中断。