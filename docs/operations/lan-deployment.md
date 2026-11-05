# 局域网多用户部署

把源码版 SmartPerfetto 部署在 Linux 服务器上，让同网段的其他 PC 通过
`http://<服务器IP>:10000` 访问。单机本地使用不需要这些步骤，直接 `./start.sh`。

## 前置条件

- Linux 服务器，有一个同网段可访问的 IPv4 地址
- Node.js **24** 和 Docker（用于单点登录；`--no-oidc` 时不需要）

Node.js 24 和 Docker 缺失时，`deploy-lan.sh` 会先说明要执行的命令，确认后自动安装：

- **Node.js**：从 nodejs.org 下载官方 tarball，校验 SHA-256 后解压到
  `~/.local/node24`，不需要 root，也不依赖 nvm/volta。
- **Docker**：用 `apt-get install docker.io` 装发行版自带的包，会提示 sudo 密码。

非交互环境（CI、管道输入）下不会自动装，脚本直接报错退出。加 `--yes` 可跳过所有确认。

## 步骤 1：获取源码

```bash
git clone https://github.com/yrzroger/SmartPerfetto.git
cd SmartPerfetto
```

不需要 `--recursive`：仓库已包含预构建的 Perfetto UI。首次启动会自动安装后端依赖并
下载 `trace_processor_shell`，不用手动 `npm ci`。

后续命令都假定当前目录是仓库根目录。

## 步骤 2：部署

```bash
./scripts/deploy-lan.sh --dry-run     # 先看会改什么，不落盘、不需要 sudo
./scripts/deploy-lan.sh               # 实际部署，中途会提示输入 sudo 密码
```

脚本自动完成：生成 `backend/.env`、起 Dex 单点登录、写入 systemd unit、启动服务、
轮询健康检查。局域网地址、OIDC issuer、回调地址、客户端密钥都由本机信息推导，换机器
直接跑即可。

**不要用 `sudo ./scripts/deploy-lan.sh`。** 脚本以服务账号身份运行，只在写 unit 和
`systemctl` 时单独提权。整脚本用 sudo 会让 `backend/.env` 属主变成 root，服务读不到。

选项：

| 选项 | 作用 |
| --- | --- |
| `--dry-run` | 只打印计划，不改系统 |
| `--env-only` | 只生成 `backend/.env`，不动 systemd |
| `--address <ipv4>` | 指定地址而不是自动探测 |
| `--port <n>` | 前端端口（默认 10000） |
| `--user <name>` | 服务运行账号（默认当前用户） |
| `--force` | 覆盖已存在的 `backend/.env`（会丢失原有密钥） |
| `--uninstall` | 停止并删除 unit，保留 `backend/.env` |
| `--no-oidc` | 不起 Dex，改用共享 API key |
| `--dns-name <name>` | OIDC 用该域名而不是局域网地址 |
| `--dex-port <n>` | Dex 端口（默认 5556） |
| `--yes` / `-y` | 自动安装缺失的 Node.js 24 / Docker，不再逐个确认 |

`backend/.env` 已存在时不覆盖，避免丢失 `SMARTPERFETTO_SECRET_STORE_MASTER_KEY`
——该密钥丢失会让已保存的 Provider 密钥永久无法解密。需要重建时显式加 `--force`。

## 步骤 3：放行防火墙

```bash
sudo ufw allow from <网段>/24 to any port 10000 proto tcp
sudo ufw allow from <网段>/24 to any port 3000 proto tcp
```

`ufw` 未启用则跳过。

## 步骤 4：添加用户

单点登录的账号不在仓库里，部署后需要逐个添加：

```bash
deploy/.runtime/dex/add-user.sh you@example.com
```

脚本把账号追加到 `deploy/.runtime/dex/config.yaml` 并重启 Dex，然后等待其就绪。
`userID` 自动生成为 `<用户名>-<时间戳>`。

**Dex 的账号存在内存里，重建容器会清空**，之后需要重新执行本命令。

## 步骤 5：浏览器使用

1. 打开 `http://<服务器IP>:10000`
2. 未登录时页面自动跳转到登录表单，填入第 4 步添加的邮箱即可（无需密码）

首次登录时后端自动创建个人工作区。

配置 AI Provider：AI 助手 → 设置 → **Providers** → 新建配置、填 API 密钥 → **点激活**。
只保存不激活不会生效。

> 设置页的「AI 就绪」会显示为「否（需完成 Provider 配置）」，即使已正确配置并激活。
> 这是 OIDC 模式下的已知显示问题，不影响实际分析。以能否正常出分析结果为准。

## 日常运维

```bash
systemctl status smartperfetto
sudo systemctl restart smartperfetto     # 改完 backend/.env 后需要
sudo systemctl stop smartperfetto
journalctl -u smartperfetto -f
sudo docker logs smartperfetto-dex       # 单点登录日志
```

卸载（保留 `backend/.env`）：

```bash
./scripts/deploy-lan.sh --uninstall
```

## 验证

```bash
ss -ltn | grep -E ':(3000|10000) '     # 应为 0.0.0.0
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:10000/health
curl -s http://127.0.0.1:3000/api/auth/session
```

最后一条返回 `"authMode":"oidc"` 即为生效。

从同网段另一台 PC：

```bash
curl -i http://<服务器IP>:3000/api/runtime-health
```

返回 **401**（不是 403）表示配置正确。

## 相关文件

| 路径 | 说明 |
| --- | --- |
| `backend/.env` | 生成的配置与密钥，mode 600，不提交 |
| `deploy/.runtime/dex/` | Dex 渲染结果与挂载源，不提交，不要删除 |
| `deploy/dex/` | 登录页与配置模板，仓库自带 |
| `/etc/systemd/system/smartperfetto.service` | 服务 unit |
