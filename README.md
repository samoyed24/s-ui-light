# alpine-s-ui-light

适用于小内存 Alpine Linux / Debian / Ubuntu 的 [s-ui](https://github.com/alireza0/s-ui) 面板部署方案。

GitHub Action 每日自动同步 s-ui 最新版本，单一安装脚本自动检测系统与架构，一键部署。

## 快速安装

```bash
wget -O install.sh https://raw.githubusercontent.com/samoyed24/alpine-s-ui-light/main/scripts/install.sh && chmod +x install.sh && ./install.sh
```

脚本会自动检测操作系统与架构：

- **Alpine Linux** → OpenRC 服务（`rc-service` / `rc-update`）
- **Debian / Ubuntu** → systemd 服务（`systemctl`）

## 安装后会做什么

安装完服务后，脚本会依次询问并完成三件事：

1. **重置管理员密码**（无需询问）。用户名保持 `admin`，密码改为随机生成的 24 位强密码，
   并在最后打印出来。s-ui 只存密码哈希，**这串密码只会显示这一次，请立刻保存**。

2. **是否给面板启用 HTTPS**（y/N）。选 yes 会生成自签证书，并让 s-ui 面板走 HTTPS。
   自签证书浏览器会提示不安全，属正常现象。

3. **是否部署 Hysteria2 节点**（y/N）。选 yes 会创建一个 Hysteria2 入站：

   - 复用上面生成的自签证书（第 2 步选了 no 就现在生成）
   - 端口随机取 20000 以上
   - SNI 从几个热门站点中随机选一个
   - 已开启「允许不安全」（`client.insecure`），客户端无需校验证书

   脚本只创建节点，**不创建客户端**。要拿到订阅链接，需在面板里自行新增客户端并勾选该入站。

> 部署完成后请自行放行对应的 UDP 端口。脚本会打印端口号。

### 证书说明

自签证书为 ECDSA P-256、有效期 10 年，存放在 `/usr/local/s-ui/cert/`，私钥权限 600。

Alpine 的 OpenSSL 是 LibreSSL，用 `-newkey ec` 生成的证书会把曲线写成显式参数，
Go 无法解析（s-ui 会报 `x509: invalid ECDSA parameters`）。脚本因此改用
`ecparam -param_enc named_curve`，该写法在 Alpine 的 LibreSSL 与 Debian/Ubuntu 的
OpenSSL 3 上都能被 s-ui 正常加载。

## 服务管理

### Alpine Linux

```bash
rc-service s-ui start               # 启动
rc-service s-ui stop                # 停止
rc-service s-ui restart             # 重启
rc-service s-ui status              # 状态
tail -f /var/log/s-ui.log           # 查看日志
```

### Debian / Ubuntu

```bash
systemctl start s-ui                # 启动
systemctl stop s-ui                 # 停止
systemctl restart s-ui              # 重启
systemctl status s-ui               # 状态
tail -f /var/log/s-ui.log           # 查看日志
```

服务已配置开机自启和崩溃自动重启。

## 选项

```bash
./install.sh --arch arm64           # 指定架构（默认自动检测）
./install.sh --version v1.4.2       # 指定版本（默认最新）
./install.sh --uninstall            # 卸载
./install.sh --no-prompt            # 全部交互问题都答 no（无人值守）
./install.sh --yes                  # 全部交互问题都答 yes
```

`--no-prompt` 适合脚本化部署：跳过 HTTPS 与 Hysteria2，只装服务并重置密码。
没有终端时（如 `curl | sh`、cron）交互问题同样一律按 no 处理，不会卡住等待输入。

密码重置始终执行 —— 装完却保留 `admin/admin` 默认密码，是最容易被扫到的风险。
