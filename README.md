# 夸克网盘一键交互式备份

基于夸克官方 `quarkclouddrive` CLI 的 Linux 服务器备份封装。它不重新实现夸克协议，只调用官方 CLI 完成账号授权、目录创建和断点续传上传。

> **目标机器不需要安装 Hermes、OpenClaw 或任何 AI 智能体。** 安装器会把官方 CLI 作为私有运行依赖安装到当前用户目录；脚本只设置官方 CLI 所需的 Hermes 兼容渠道标识，不会安装、启动或调用 Hermes Agent。

## 支持环境

- Debian / Ubuntu
- root 权限
- 可访问夸克网盘和 GitHub
- 安装器会自动安装 Node.js、curl、Python、tar、cron 等依赖

## 功能

- 终端交互式授权夸克账号
- 选择一个或多个本地文件/目录
- 压缩为 `tar.gz` 后上传到指定夸克网盘文件夹
- 每日或每周定时备份
- 上传成功后自动清理本地临时包，或按需保留
- 并发锁，避免多个备份任务重叠
- 配置及授权文件权限收紧为 `600`
- 无智能体、无 API Key、无常驻服务

## 一键安装

在另一台 Debian/Ubuntu 服务器上以 root 执行：

```bash
curl -fsSL https://raw.githubusercontent.com/LYISTR2/quark-backup/main/install.sh | bash
```

如果希望先审查再执行：

```bash
git clone https://github.com/LYISTR2/quark-backup.git
cd quark-backup
bash install.sh
```

安装完成后运行：

```bash
quark-backup
```

第一次选择 **“登录 / 重新授权”**：

1. 脚本输出夸克授权地址。
2. 在任意手机或电脑浏览器打开并确认授权。
3. 把页面显示的授权码粘贴回服务器终端。
4. 授权成功后即可设置备份路径和定时计划。

授权是按机器保存的，**不要把本机授权配置复制到另一台机器**；每台机器分别授权一次。

## 常用命令

```bash
# 打开菜单
quark-backup

# 登录或重新授权
quark-backup login

# 查看账号、配置和定时状态
quark-backup status

# 交互设置备份
quark-backup setup

# 非交互设置示例
quark-backup setup \
  --source /etc \
  --source /opt/my-app/data \
  --remote-dir 服务器备份 \
  --schedule daily \
  --time 03:30 \
  --keep-local 0 \
  --install-cron

# 立即备份
quark-backup run

# 关闭定时任务
quark-backup disable
```

## 文件位置

- 主程序：`/opt/quark-backup/quark-backup.sh`
- 命令入口：`/usr/local/bin/quark-backup`
- 官方 CLI 私有依赖：`~/.local/share/quark-backup/vendor/quarkclouddrive/`
- 官方 CLI 运行及授权目录：`~/.local/share/quark-backup/runtime/`
- 设置：`~/.config/quark-backup/config.json`
- 默认本地临时包：`/var/backups/quark-backup/`
- 定时日志：`/var/log/quark-backup.log`

## 安全说明

- 仓库不包含夸克账号授权信息、Cookie、Token 或备份内容。
- 安装时从用户提供的夸克官方地址下载官方 CLI，并检查 ZIP 路径穿越和符号链接。
- 备份压缩包不是端到端加密文件，其访问安全依赖夸克账号和官方传输通道。
- 不要直接打包正在写入的 MySQL/PostgreSQL 数据目录作为一致性备份；应先使用数据库原生工具导出快照，再备份快照文件。

## 测试

```bash
bash -n install.sh quark-backup.sh
shellcheck -x install.sh quark-backup.sh
bats tests/quark-backup.bats
```
