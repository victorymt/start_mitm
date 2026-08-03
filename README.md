# mitmweb ShellCrash 管理脚本

`setup_mitmweb.sh` 用于将 mitmweb 作为 systemd 用户服务运行，并把流量转发到
ShellCrash 提供的上游 HTTP(S) 代理。脚本还可以启动使用独立配置目录和独立 NSS
证书库的 Chromium，避免修改日常浏览器配置和全局证书库。

默认监听地址仅限本机：

- 抓包代理：`127.0.0.1:8080`
- mitmweb Web UI：`127.0.0.1:8082`
- ShellCrash 上游代理：`http://127.0.0.1:7890`

## 功能

- 提供交互式配置向导和适用于自动化的非交互安装。
- 使用独立的 mitmproxy 配置、CA、Chromium HOME、Profile 和 NSS 数据库。
- 通过 systemd 用户服务管理 mitmweb，无需 root 权限。
- 支持启动、停止、重启、状态、日志、代理验证和自动启动管理。
- 安装前验证依赖、配置文件和 systemd unit。
- 使用操作锁、原子文件替换和事务快照防止并发操作及普通安装失败。
- 检测残缺安装，并提供修复或清理指引。
- 安全迁移脚本能够识别的旧版 `mitmweb.service`。
- 提供范围受限、可重复执行的卸载命令。

## 依赖

基础运行环境：

- Bash 4.3 或更高版本
- mitmproxy/mitmweb
- systemd 用户管理器
- `curl`、`ss`、`flock` 和常见 GNU/Linux 基础工具

使用隔离 Chromium 时还需要：

- Chromium、Chromium Browser 或 Google Chrome
- `certutil`（通常由 `libnss3-tools` 或 `nss-tools` 提供）
- OpenSSL

运行只读检查确认当前环境：

```bash
./setup_mitmweb.sh doctor
```

## 快速开始

推荐首次使用交互式向导：

```bash
./setup_mitmweb.sh configure
```

向导会读取现有安装值作为默认值，依次询问：

- ShellCrash 上游代理
- 抓包代理和 Web UI 端口
- 是否允许局域网访问抓包代理
- 是否允许远程访问 Web UI
- 是否启动隔离 Chromium
- 是否在该 Chromium 的私有 NSS 数据库中信任 mitmproxy CA
- Chromium 启动 URL
- 是否启用用户会话自动启动

上游代理输入不会回显，最终摘要中的用户名和密码会被隐藏。只有在最后明确确认后，
向导才会修改文件或服务。

安装完成后可以访问：

```text
Web UI: http://127.0.0.1:8082/
Proxy:  http://127.0.0.1:8080
```

## 与 Pikachu 靶场配合使用

本项目可以配合 Docker 运行的 Pikachu Web 安全靶场使用。推荐只把靶场端口绑定到
本机，避免将存在已知漏洞的应用暴露到局域网：

```bash
docker run -d --name pikachu -p 127.0.0.1:8081:80 area39/pikachu
```

你原来的 `docker run -d -p 8081:80 area39/pikachu` 也可以工作，但 Docker 会默认在
所有主机接口上开放 `8081` 端口。

首次安装时，可以直接把隔离 Chromium 的启动地址设为 Pikachu：

```bash
CHROMIUM_MITM_URL=http://127.0.0.1:8081/ \
./setup_mitmweb.sh setup
```

如果 mitmweb 已经安装并运行，无需重新配置，直接打开靶场即可：

```bash
./setup_mitmweb.sh browser http://127.0.0.1:8081/
```

此时端口用途如下：

| 端口 | 用途 |
| --- | --- |
| `8080` | Chromium 使用的 mitmweb 抓包代理 |
| `8081` | Docker 映射到宿主机的 Pikachu Web 服务 |
| `8082` | mitmweb Web UI |

在隔离 Chromium 中操作 `http://127.0.0.1:8081/`，然后通过脚本安装完成时输出的
带 token Web UI 地址查看请求；也可以运行 `./setup_mitmweb.sh status` 再次查看该地址。

不再使用靶场时停止并删除容器：

```bash
docker stop pikachu
docker rm pikachu
```

## 非交互安装

`setup` 不会询问任何问题，适合脚本和自动化环境：

```bash
SHELLCRASH_PROXY=http://127.0.0.1:7890 \
MITMWEB_PROXY_PORT=8080 \
MITMWEB_WEB_PORT=8082 \
./setup_mitmweb.sh setup
```

跳过 Chromium 和 CA 导入：

```bash
MITMWEB_NO_BROWSER=1 ./setup_mitmweb.sh setup
```

允许局域网设备连接抓包代理：

```bash
MITMWEB_ALLOW_LAN=1 \
MITMWEB_LISTEN_HOST=0.0.0.0 \
./setup_mitmweb.sh setup
```

允许远程访问 Web UI 必须同时显式授权并设置监听地址：

```bash
MITMWEB_ALLOW_REMOTE_WEB=1 \
MITMWEB_WEB_HOST=0.0.0.0 \
./setup_mitmweb.sh setup
```

远程 Web UI 可以查看和修改捕获流量，只应在可信网络中开放，并配合主机防火墙限制
来源地址。

## 命令

| 命令 | 说明 |
| --- | --- |
| `setup` | 使用环境变量非交互安装或重新配置 |
| `configure` | 交互式配置、摘要确认并安装 |
| `start` | 启动 mitmweb，不改变自动启动状态 |
| `stop` | 停止 mitmweb 和隔离 Chromium |
| `restart` | 重启 mitmweb 并严格验证代理链 |
| `status` | 显示服务状态和已安装配置 |
| `logs` | 显示 mitmweb 和 Chromium 的近期日志 |
| `browser [URL]` | 启动或复用隔离 Chromium |
| `verify` | 验证 HTTPS 是否经过 mitmweb 和 ShellCrash |
| `enable` | 启用用户会话自动启动 |
| `disable` | 禁用用户会话自动启动 |
| `doctor` | 只读检查依赖和配置一致性 |
| `uninstall` | 删除本脚本管理的服务和文件 |
| `help` | 显示命令帮助 |

## 环境变量

安装配置：

| 变量 | 默认值或说明 |
| --- | --- |
| `MITMWEB_BIN` | 自动查找 `mitmweb` |
| `SHELLCRASH_PROXY` | `http://127.0.0.1:7890` |
| `MITMWEB_PROXY_PORT` | `8080` |
| `MITMWEB_WEB_PORT` | `8082` |
| `MITMWEB_LISTEN_HOST` | `127.0.0.1` |
| `MITMWEB_WEB_HOST` | `127.0.0.1` |
| `MITMWEB_CONFDIR` | 专用 mitmproxy 配置和 CA 目录 |
| `MITMWEB_ALLOW_LAN` | 非回环抓包监听必须设为 `1` |
| `MITMWEB_ALLOW_REMOTE_WEB` | 非回环 Web UI 监听必须设为 `1` |
| `CHROMIUM_MITM_BIN` | 自动查找 Chromium/Chrome |
| `CHROMIUM_MITM_HOME` | 私有 Chromium HOME 和 NSS 根目录 |
| `CHROMIUM_MITM_PROFILE` | 位于私有 HOME 内的 Profile 路径 |
| `CHROMIUM_MITM_URL` | `http://mitm.it` |

运行时选项：

| 变量 | 默认值或说明 |
| --- | --- |
| `MITMWEB_READY_TIMEOUT` | 服务就绪超时，默认 `30` 秒 |
| `MITMWEB_VERIFY_URL` | HTTPS 验证地址，默认 `https://example.com` |
| `MITMWEB_NO_BROWSER` | 设为 `1` 时安装后不启动 Chromium |
| `MITMWEB_NO_CERT_INSTALL` | 设为 `1` 时不导入 Chromium CA |

## 文件位置

默认使用 XDG 目录；未设置对应变量时分别回退到 `~/.config` 和
`~/.local/share`。

| 内容 | 默认路径 |
| --- | --- |
| 持久化状态 | `~/.config/mitmweb-shellcrash/state` |
| mitmproxy 配置 | `~/.config/mitmweb-shellcrash/mitmproxy/config.yaml` |
| mitmproxy CA | `~/.config/mitmweb-shellcrash/mitmproxy/` |
| systemd unit | `~/.config/systemd/user/mitmweb-shellcrash.service` |
| Chromium HOME | `~/.local/share/mitmweb-shellcrash/browser-home` |
| Chromium Profile | `~/.local/share/mitmweb-shellcrash/browser-home/profile` |
| Chromium NSS 数据库 | `~/.local/share/mitmweb-shellcrash/browser-home/.pki/nssdb` |
| 操作锁 | `$XDG_RUNTIME_DIR/mitmweb-shellcrash/operation.lock` |

上游代理 URL 可能包含凭据，因此状态文件和 mitmproxy 配置以 `0600` 权限安装。
状态和摘要输出会隐藏 URL 中的用户信息，但磁盘配置必须保留完整 URL 才能连接上游。

## 安全与恢复

- 默认不开放局域网抓包代理和远程 Web UI。
- Chromium CA 只导入专用 NSS 数据库，不修改全局 NSS 数据库。
- 配置、状态和 unit 先在临时目录生成并验证，再原子安装。
- 安装事务会保存旧文件及服务的 active/enabled 状态。
- 普通错误、`Ctrl-C` 和 `TERM` 会触发回滚。
- 联网验证或浏览器启动失败发生在配置提交之后，会返回非零，但保留已正常启动的服务。
- `SIGKILL` 和断电无法执行 Shell trap；再次运行 `setup` 可检查并修复残缺安装。
- 重复运行 `setup` 会收敛到同一配置，但仍会重新启动服务。

常用诊断命令：

```bash
./setup_mitmweb.sh doctor
./setup_mitmweb.sh status
./setup_mitmweb.sh verify
./setup_mitmweb.sh logs
```

## 卸载

```bash
./setup_mitmweb.sh uninstall
```

卸载可以重复执行。它会停止并禁用服务，删除本脚本管理的 unit、默认配置目录、
默认 Chromium 数据，并从私有 NSS 数据库移除脚本管理的 CA。

以下内容会保留：

- 无法确认由本脚本管理的旧版 unit
- 全局 mitmproxy 配置和 CA
- 全局 NSS 数据
- 用户指定的自定义 mitmproxy 目录和 Chromium HOME

自定义 mitmproxy 目录中的受管配置文件会删除，但目录及其他文件会保留。

## 开发与验证

仓库结构：

```text
.
├── README.md
├── setup_mitmweb.sh
└── tests/
    └── test_setup_mitmweb.sh
```

运行全部检查：

```bash
bash -n setup_mitmweb.sh
bash -n tests/test_setup_mitmweb.sh
shellcheck setup_mitmweb.sh tests/test_setup_mitmweb.sh
bash tests/test_setup_mitmweb.sh
```

测试使用隔离的临时 XDG 目录和 systemd 命令桩，不会执行真实安装或修改当前用户服务。
