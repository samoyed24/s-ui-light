# alpine-s-ui-light

适用于小内存 Alpine Linux / Debian 的 [s-ui](https://github.com/alireza0/s-ui) 面板部署方案。

GitHub Action 每日自动同步 s-ui 最新版本，Alpine / Debian 安装脚本一键部署。

## Alpine Linux

### 快速安装

```bash
wget -O install.sh https://raw.githubusercontent.com/samoyed24/alpine-s-ui-light/main/scripts/install-alpine.sh && chmod +x install.sh && ./install.sh
```

### 服务管理

```bash
rc-service s-ui start               # 启动
rc-service s-ui stop                # 停止
rc-service s-ui restart             # 重启
rc-service s-ui status              # 状态
tail -f /var/log/s-ui.log           # 查看日志
```

服务使用 OpenRC 管理，已配置开机自启和崩溃自动重启。

## Debian / Ubuntu

### 快速安装

```bash
wget -O install.sh https://raw.githubusercontent.com/samoyed24/alpine-s-ui-light/main/scripts/install-debian.sh && chmod +x install.sh && ./install.sh
```

### 服务管理

```bash
systemctl start s-ui                # 启动
systemctl stop s-ui                 # 停止
systemctl restart s-ui              # 重启
systemctl status s-ui               # 状态
tail -f /var/log/s-ui.log           # 查看日志
```

服务使用 systemd 管理，已配置开机自启和崩溃自动重启。

## 选项（两个脚本通用）

```bash
./install.sh --arch arm64           # 指定架构（默认自动检测）
./install.sh --version v1.4.2       # 指定版本（默认最新）
./install.sh --uninstall            # 卸载
```
