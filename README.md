# hermes-stack

在自己的服务器上部署 [Hermes Agent](https://hermes-agent.nousresearch.com)，通过 Telegram 或 Discord 随时使用。Agent 在一个隔离的开发容器里写代码、跑命令、排查问题；你也可以用 SSH 或 VS Code 进入同一个环境，接着它的工作继续。

- **一条命令部署**：`init.sh` 校验配置、生成密钥、构建镜像、启动服务、写入推荐配置并自检。
- **隔离执行**：Agent 的所有命令都在 devbox 容器里运行，接触不到 Hermes 的 API Key，也不需要挂载 `docker.sock`。
- **完整开发环境**：Ubuntu 24.04，Node、Python、Go、Rust、gh、Docker CLI 和常用数据库客户端。
- **任意模型**：Hermes 内置的 provider，或任何 OpenAI / Anthropic 兼容端点，包括自建的 vLLM 和 Ollama。
- **不开放入站端口**：Telegram 使用长轮询，Discord 使用出站 WebSocket；Dashboard 和 SSH 只监听 `127.0.0.1`。
- **运维脚本**：自检、备份、恢复、升级。

## 工作方式

```
 Telegram / Discord（手机 / 电脑）
        │  长轮询 / WebSocket：Hermes 主动向外连接，无需开放端口
        ▼
┌──────────────────────────────── 服务器 ─────────────────────────────────┐
│                                                                         │
│  hermes   官方镜像 nousresearch/hermes-agent                            │
│   ├─ 多平台网关、会话、记忆、skills、定时任务     ./data → /opt/data │
│   ├─ Dashboard :9119，只监听 127.0.0.1                                  │
│   └─ terminal.backend = ssh ─────────┐                                  │
│                                      ▼  内部网络，ed25519 公钥认证      │
│  devbox   Ubuntu 24.04 开发环境                                         │
│   ├─ git gh node pnpm python uv go rust docker-cli rg jq yq …           │
│   ├─ /workspace ← ./workspace（代码，宿主机上可直接访问）               │
│   └─ :22 → 127.0.0.1:2222（你用 SSH / VS Code 进入同一个环境）          │
│                                                                         │
│  postgres / redis   可选，COMPOSE_PROFILES=db                           │
│  ollama             可选，COMPOSE_PROFILES=ollama                       │
└─────────────────────────────────────────────────────────────────────────┘
```

Hermes 使用 SSH 执行后端：Agent 的每条命令、每次文件读写都通过 SSH 在 devbox 中完成。你发给 bot 的附件会自动同步到 devbox 的 `~/.hermes/cache/`；Agent 在回复中写 `MEDIA:<路径>` 时，Hermes 会把该文件发回给你。

为什么用两个容器，而不是把开发工具装进 Hermes 容器：

- Hermes 保持官方镜像不变，可以随时升级；
- devbox 可以随意安装软件、使用 sudo，出了问题也只影响它自己；
- Agent 执行的命令拿不到 Hermes 持有的 API Key；
- 不需要把 `docker.sock` 交给 Agent（那等于宿主机 root 权限）。

## 快速开始

### 准备

- 一台 Linux 服务器：至少 2 核 4 GB 内存，推荐 4 核 8 GB；预留 20 GB 以上磁盘（devbox 镜像约 3~4 GB）。
- Docker Engine 24 或更高版本，以及 Docker Compose v2 插件。请按 [Docker 官方文档](https://docs.docker.com/engine/install/) 安装，不要使用 snap 版本。
- Telegram 或 Discord 账号，任选其一，也可以同时使用。

### 1. 创建消息平台 Bot

选择 Telegram 或 Discord；同时配置两个平台时，同一网关会同时提供服务。

#### Telegram

1. 打开 [@BotFather](https://t.me/BotFather)，发送 `/newbot`，按提示创建，记下 bot token。
2. 打开 [@userinfobot](https://t.me/userinfobot)，记下你的**数字用户 ID**。
3. 可选设置（在 BotFather 中）：
   - 打开 Threaded Mode（Mini App → My bots → 你的 bot → Bot Settings → Threads Settings）：之后可以在私聊中用 `/topic` 开多个独立会话，例如每个项目一个。
   - `/setinline` 打开 inline 模式：之后可以在任意聊天中输入 `@你的bot 关键词` 搜索命令和 skill。

#### Discord

1. 打开 [Discord Developer Portal](https://discord.com/developers/applications)，创建 Application，在 **Bot** 页面获取 Bot token。
2. 在 **Privileged Gateway Intents** 开启 **Message Content Intent** 并保存。使用数字用户 ID 白名单时无需 Server Members Intent；如果额外配置角色白名单，需要开启它。
3. 在 **Installation → Guild Install** 设置 scopes：`bot`、`applications.commands`。权限选择 **View Channels、Send Messages、Embed Links、Attach Files、Read Message History、Create Public Threads、Send Messages in Threads、Add Reactions**。
   也可以使用邀请链接，把 `<APPLICATION_ID>` 换成应用 ID：

   ```text
   https://discord.com/oauth2/authorize?client_id=<APPLICATION_ID>&scope=bot+applications.commands&permissions=309237763136
   ```

4. 用具有管理服务器权限的账号打开邀请链接，将 Bot 加入服务器。还需检查目标频道的权限覆盖允许上述操作。
5. 在 Discord **用户设置 → 高级 → 开发者模式** 中打开开发者模式，右键自己的头像，选择 **复制用户 ID**。频道 ID 也可右键复制。

保持 **Interactions Endpoint URL** 为空，让 Hermes 通过 Gateway 接收 slash commands 和按钮事件。普通聊天、附件和命令均不需要公网回调地址。

### 2. 填写配置

```bash
git clone <本仓库地址> hermes-stack && cd hermes-stack
cp .env.example .env && chmod 600 .env
```

编辑 `.env`，填写所选平台的 token 和数字用户 ID。例如仅使用 Discord：

```ini
DISCORD_BOT_TOKEN=你的BotToken
DISCORD_ALLOWED_USERS=你的数字用户ID
```

仅使用 Telegram：

```ini
TELEGRAM_BOT_TOKEN=123456789:AAH...
TELEGRAM_ALLOWED_USERS=你的数字用户ID
```

两个平台都填写即可同时启用；不使用的平台 token 留空。每个启用的平台必须设置自己的用户白名单，多个 ID 用逗号分隔。将 `HOST_UID` / `HOST_GID` 改为宿主机 `id -u` / `id -g` 的结果（不能为 0）。

模型可以现在配置（见 [模型](#模型)），也可以部署后用 `make model` 交互选择。如果服务器无法直接访问 Telegram、Discord 或模型 API，同时配置 [网络代理](#网络代理)。

### 3. 初始化

```bash
make init        # 即 ./scripts/init.sh
```

脚本会依次：检查 Docker 环境，校验 `.env`，补全 UID/GID、时区和随机密码，生成 Hermes 访问 devbox 用的 SSH 密钥，构建 devbox 镜像，启动服务，安装 Agent 人设（`templates/SOUL.md`），写入推荐配置，最后运行自检。配置有误时会在构建前停下并说明原因。脚本可以重复运行，不会覆盖已有的数据和密钥。

### 4. 验证

`make check` 应该全部通过。`make check-llm` 会额外实际调用一次模型（消耗少量 token）。

然后在所选平台中私聊 Bot，发送以下消息。Discord 也可以在服务器频道中 `@Bot 你好`，并在自动创建的线程中继续：

```
你好
/sethome
在 devbox 里执行 whoami && node -v && python -V && go version
```

再试一个完整的任务：

```
把 https://github.com/<you>/<repo> clone 到 /workspace，安装依赖并运行测试，告诉我结果
```

启用 Discord 后，还应在真实服务器上验证：频道中 `@Bot` 创建线程、线程内继续对话、`/model` 与 `/stop`、审批和澄清按钮、上传文件与 `MEDIA:` 回传，以及 `/sethome` 后的定时任务投递。用未授权账号确认无法触发 Agent，并检查超过 2000 字符的回复能够完整分片。

## 使用

### Telegram

| 操作           | 作用                                                                              |
| -------------- | --------------------------------------------------------------------------------- |
| `/new`         | 开始新会话（清空上下文）                                                          |
| `/model`       | 切换模型                                                                          |
| `/topic`       | 在私聊中开启多会话，每个 Topic 是一个独立会话                                     |
| `/stop`        | 中断当前任务                                                                      |
| `/sethome`     | 把当前聊天设为定时任务结果的发送位置                                              |
| `/whoami`      | 查看自己的权限                                                                    |
| `/commands`    | 列出全部命令                                                                      |
| 发送语音       | 自动转写为文字（使用 `GROQ_API_KEY`，或本地 whisper，首次使用时自动安装）         |
| 发送文件或图片 | Agent 在 devbox 的 `~/.hermes/cache/` 下读取；Telegram Bot API 限制单个文件 20 MB |

Agent 要执行有风险的命令时，Hermes 会先让一个审核模型判断（`approvals.mode: smart`），需要你决定的会发到聊天中，5 分钟内回复 `yes` 或 `no`。本项目还禁止了 force push，即使你批准也不会执行。

### Discord

- **私聊**：白名单用户直接发送消息即可。
- **服务器频道**：默认 `@Bot` 开始任务，Bot 自动创建线程；之后在线程内继续，无需重复提及。
- **独立会话**：不同线程、不同用户分别维护上下文；Telegram 与 Discord 的会话也分别维护。它们共用同一 Agent 的模型配置、记忆和 devbox。
- **常用命令**：`/new`、`/model`、`/stop`、`/sethome`、`/whoami`。命令通过原生 `/` 菜单使用；Telegram 的 `/topic` 对应 Discord 的线程使用方式。
- **文件与审批**：支持文件、图片、`MEDIA:` 回传，以及审批与澄清按钮。长回复由 Hermes 按 Discord 的 2000 字符限制分片。接收附件默认最多 32 MiB，实际发送上限由 Discord 当前频道或交互限制决定。
- **定时任务**：在需要接收通知的位置运行 `/sethome`，Hermes 会保存 `DISCORD_HOME_CHANNEL`。两平台可分别设置 home；定时任务按其配置的投递平台和目标发送。

可选配置写在 `.env` 中，修改后运行 `make up`：

```ini
# 只允许在这些服务器频道响应；线程继承父频道范围，私聊仍由用户白名单控制。
DISCORD_ALLOWED_CHANNELS=123456789012345678
# 某个频道免 @Bot，默认在频道内直接回复。
DISCORD_FREE_RESPONSE_CHANNELS=123456789012345678
# 多 Bot 共用线程时也要求 @Bot。
DISCORD_THREAD_REQUIRE_MENTION=true
```

`DISCORD_ALLOWED_CHANNELS` 是频道范围设置，项目仍要求填写 `DISCORD_ALLOWED_USERS`。可额外配置 `DISCORD_ALLOWED_ROLES`，它与用户白名单按「或」授权，并需要 Server Members Intent。第一版推荐使用数字用户 ID；语音频道实时通话属于可选能力，参考 [Hermes Discord 文档](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/discord)。

### 进入开发环境

在服务器上：

```bash
make shell        # 即 ssh -p 2222 dev@127.0.0.1
```

从自己的电脑连接，在 `~/.ssh/config` 中添加：

```
Host hermes-devbox
  HostName 127.0.0.1
  Port 2222
  User dev
  ProxyJump <你的服务器>
```

然后用 VS Code / Cursor 的 Remote-SSH 连接 `hermes-devbox`，打开 `/workspace`，就能和 Agent 在同一份代码上协作。`init.sh` 会自动授权服务器上当前用户的公钥；其它电脑的公钥写入 `secrets/extra_authorized_keys` 后重新运行 `make init`。

要让 Agent 访问 GitHub 私有仓库或创建 PR，在 devbox 中运行一次 `gh auth login`。登录状态保存在 devbox 的 home 卷中，重建镜像后仍然有效。

### Dashboard

Dashboard 只监听服务器的 `127.0.0.1:9119`，不能直接通过公网 IP 或 Tailscale IP 访问。默认账号是 `admin`，密码见 `.env` 中的 `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD`。

**通过 SSH 隧道**，在自己的电脑上运行：

```bash
ssh -L 9119:127.0.0.1:9119 <你的服务器>
```

然后打开 <http://localhost:9119>。

**通过 Tailscale**（手机上也能用），在服务器上运行：

```bash
sudo tailscale serve --bg 9119      # 只对你的 tailnet 开放，自动配置 HTTPS，重启后仍然有效
tailscale serve status              # 显示访问地址，如 https://<机器名>.<tailnet>.ts.net/
```

在 tailnet 内的任意设备上打开显示的地址即可。首次使用时，Tailscale 可能会提示你在管理后台启用 HTTPS 证书。取消转发：`sudo tailscale serve --https=443 off`。不要使用 `tailscale funnel`，它会把服务公开到互联网。

### 常用命令

| 命令                          | 作用                                                                            |
| ----------------------------- | ------------------------------------------------------------------------------- |
| `make up`                     | 启动服务；修改 `.env` 后用它应用                                                |
| `make down`                   | 停止服务（数据保留）                                                            |
| `make restart`                | 重启网关（修改 `config.yaml` 或 `SOUL.md` 后）                                  |
| `make logs`                   | 查看网关日志                                                                    |
| `make check`                  | 自检；`make check-llm` 额外调用一次模型，`make doctor` 额外运行 `hermes doctor` |
| `make test`                   | 离线回归测试，无需 Docker 或 Bot 凭据；也可运行 `python3 -m unittest discover -s tests -v` |
| `make model`                  | 交互选择模型                                                                    |
| `make config`                 | 编辑 Hermes 的 `config.yaml`                                                    |
| `make configure`              | 重新写入推荐配置和 `.env` 中的模型设置                                          |
| `make cli`                    | 在服务器终端里和 Agent 对话                                                     |
| `make shell`                  | 进入 devbox                                                                     |
| `make backup` / `make update` | 备份 / 备份后升级                                                               |

运行 `make` 查看全部命令。

## 模型

模型有两种管理方式，任选其一：

- **在 `.env` 中配置**（推荐，便于重新部署）：设置 `STACK_MODEL_PROVIDER` 等变量后运行 `make configure`。此后模型设置以 `.env` 为准，每次 `make configure` 都会按 `.env` 重写。
- **交互选择**：`STACK_MODEL_PROVIDER` 留空，用 `make model` 或聊天中的 `/model` 选择。`make configure` 不会改动模型设置。

### 内置 provider

填写对应的 API Key，再指定 provider 和模型 ID，例如：

```ini
OPENROUTER_API_KEY=sk-or-...
STACK_MODEL_PROVIDER=openrouter
STACK_MODEL=anthropic/claude-sonnet-5
```

常用 provider 有 `openrouter`、`anthropic`、`openai`、`deepseek`、`nous`、`zai`、`kimi-coding`、`xai`。可用的模型 ID 以 `make model` 中的列表为准。

### custom 端点

适用于任何 OpenAI 或 Anthropic 兼容的 API：第三方 API 服务、one-api / new-api 等网关，以及自建的 vLLM、Ollama、LM Studio、llama.cpp。

| 变量                    | 说明                                                                                                |
| ----------------------- | --------------------------------------------------------------------------------------------------- |
| `STACK_MODEL_PROVIDER`  | `custom`                                                                                            |
| `STACK_MODEL`           | 端点上的模型 ID，即 `<base_url>/models` 返回的 id（区分大小写）                                     |
| `STACK_CUSTOM_BASE_URL` | API 根地址，通常以 `/v1` 结尾，不要带 `/chat/completions`                                           |
| `STACK_CUSTOM_API_KEY`  | 端点的 API Key；无鉴权的本地服务留空                                                                |
| `STACK_CUSTOM_API_MODE` | 留空自动判断；也可以指定 `chat_completions`（OpenAI 兼容）或 `anthropic_messages`（Anthropic 兼容） |
| `STACK_CONTEXT_LENGTH`  | 模型的上下文窗口（token），建议填写，至少 64000                                                     |
| `STACK_CUSTOM_NAME`     | 在聊天 `/model` 菜单中显示的名字（可选）                                                       |

`STACK_CUSTOM_BASE_URL` 的常见写法：

| 场景                                  | 地址                                   | 说明                                                                                |
| ------------------------------------- | -------------------------------------- | ----------------------------------------------------------------------------------- |
| 第三方 API 服务（OpenAI 兼容）        | `https://api.example.com/v1`           | 填写 API Key                                                                        |
| Anthropic 兼容的服务                  | `https://api.example.com`              | 设置 `STACK_CUSTOM_API_MODE=anthropic_messages`；末尾写不写 `/v1` 都可以            |
| 宿主机上的 Ollama / LM Studio         | `http://host.docker.internal:11434/v1` | 服务需要监听 `0.0.0.0`（Ollama 设置 `OLLAMA_HOST=0.0.0.0`），防火墙放行 Docker 网段 |
| 本项目自带的 Ollama                   | `http://ollama:11434/v1`               | 设置 `COMPOSE_PROFILES=ollama`，`make configure` 会自动下载 `STACK_MODEL`           |
| 局域网或 tailnet 中的 vLLM、llama.cpp | `http://192.168.1.20:8000/v1`          |                                                                                     |

> 容器里的 `localhost` 和 `127.0.0.1` 指 hermes 容器自身，不是宿主机。`init.sh` 和 `make configure` 会拒绝这种写法。

`make configure` 写入 `config.yaml` 的内容如下，API Key 只以引用形式出现：

```yaml
model:
  provider: custom
  base_url: https://api.example.com/v1
  default: qwen3-coder-plus
  api_key: ${STACK_CUSTOM_API_KEY}
  context_length: 131072
custom_providers: # 之后可以在聊天 /model 菜单中切回这个端点
  - name: api.example.com
    base_url: https://api.example.com/v1
    key_env: STACK_CUSTOM_API_KEY
    model: qwen3-coder-plus
```

使用 custom 端点时请注意：

- **API Key 需要单独填写。** Hermes 不会把 `OPENAI_API_KEY` 等其它 provider 的 Key 发给 custom 端点，必须设置 `STACK_CUSTOM_API_KEY`。Key 错误时表现为 401。
- **上下文窗口。** 窗口小于 64K 的模型无法使用。Hermes 获取不到窗口大小时会按 256K 处理，如果模型实际更小，长对话会出现请求超长，所以请填写 `STACK_CONTEXT_LENGTH`。
- **本地推理服务要开足上下文**：Ollama 用 `OLLAMA_CONTEXT_LENGTH`（本项目默认 65536），vLLM 用 `--max-model-len`，llama.cpp 用 `-c`。
- **需要支持工具调用。** vLLM 需要 `--enable-auto-tool-choice --tool-call-parser <解析器>`，llama.cpp 需要 `--jinja`，Ollama 需要选择支持 tools 的模型。
- **图片。** 纯文本模型无法分析图片；需要时在 `config.yaml` 的 `auxiliary.vision` 中单独指定一个视觉模型。

`make check` 的「模型」部分会显示实际使用的端点、协议和密钥状态，并检查端点是否可达、模型名是否存在、上下文窗口是否足够。

## 网络代理

如果服务器无法直接访问 Telegram、Discord、模型 API、GitHub 或 npm 等站点，在 `.env` 中配置代理：

| 变量                         | 作用                                                                           |
| ---------------------------- | ------------------------------------------------------------------------------ |
| `DISCORD_PROXY`              | 只用于 Discord 的 REST、Gateway WebSocket 和附件连接，支持 `http://`、`https://`、`socks5://`；优先于通用代理 |
| `TELEGRAM_PROXY`             | 只用于连接 Telegram，支持 `http://` 和 `socks5://`                             |
| `HTTPS_PROXY` / `HTTP_PROXY` | 模型 API、网页工具，以及 devbox 中的 git、npm、pip；构建 devbox 镜像时也会使用 |
| `NO_PROXY`                   | 不经过代理的地址。默认已包含本机、compose 服务名和私有网段                     |

代理运行在宿主机上时，地址写 `host.docker.internal:<端口>`，并让代理监听 `0.0.0.0` 或 Docker 网桥地址（如 `172.17.0.1`）。如果开启了防火墙，需要放行 Docker 网段访问该端口。

custom 端点位于本机或内网时必须绕过代理。`make configure` 会检查这一点，必要时把主机名追加到 `NO_PROXY`。

修改后运行 `make up`。注意：docker compose 会优先使用当前 shell 中同名的环境变量，如果你在 `.bashrc` 中 export 了 `HTTPS_PROXY`，它会覆盖 `.env` 中的值。

## 配置说明

### `.env` 与 `data/.env`

- 项目根目录的 `.env`：你需要维护的配置文件。
- `data/.env`：Hermes 自己的配置文件。Hermes 网关从这里读取 bot token、白名单和 API Key，而不是从容器环境变量读取。

`make up` 会把 `.env` 中的 `TELEGRAM_*`、`DISCORD_*`、`*_API_KEY` 和 `*_TOKEN` 同步到 `data/.env`，有变化时重启网关（`init`、`configure`、`update` 和 `restore` 也会同步）。从 `.env` 中删除的键，也会从 `data/.env` 中删除；Hermes 自己写入的键，例如 `/sethome` 设置且未由根目录 `.env` 管理的 `TELEGRAM_HOME_CHANNEL` / `DISCORD_HOME_CHANNEL`，不受影响。

因此，**修改 `.env` 后请运行 `make up`**，而不是 `docker compose up -d`。`make check` 会列出修改后还没有同步的键。

### 推荐配置

`make configure` 通过 `hermes config set` 写入以下设置：

| 设置                                                 | 值                          | 说明                                                  |
| ---------------------------------------------------- | --------------------------- | ----------------------------------------------------- |
| `terminal.backend`、`ssh_*`、`cwd`                   | ssh → dev@devbox:/workspace | 所有命令在 devbox 中执行                              |
| `terminal.timeout`                                   | 600                         | 单条命令的超时时间（秒）                              |
| `terminal.persistent_shell`                          | true                        | 同一会话中的命令共享 shell 状态（当前目录、环境变量） |
| `streaming.enabled`、`streaming.transport`           | true、edit                  | 回复逐步显示在同一条消息中                            |
| `platforms.telegram.extra.disable_link_previews`     | true                        | 回复中的链接不显示预览                                |
| `platforms.telegram.extra.drop_pending_on_cold_boot` | false                       | 网关重启期间收到的消息，重启后照常处理                |
| `discord.require_mention`、`discord.auto_thread` | true、true | Discord 频道中提及 Bot 自动创建线程 |
| `discord.thread_require_mention` | false | 在线程内继续对话时无需重复提及 |
| `discord.allow_mentions.everyone`、`roles` | false、false | 回复不触发全体或角色通知 |
| `group_sessions_per_user` | true | 共享频道中按用户隔离会话 |
| `timezone`                                           | `.env` 中的 `TZ`            | 定时任务使用的时区                                    |
| `compression.idle_compact_after_seconds`             | 1800                        | 间隔 30 分钟以上再继续对话时，先压缩旧上下文          |
| `approvals.deny`                                     | force push 相关的命令       | 即使批准也不会执行                                    |
| `model.*`、`custom_providers`                        | 来自 `.env`                 | 见 [模型](#模型)；`STACK_MODEL_PROVIDER` 为空时不修改 |

Discord 推荐设置只在配置了 `DISCORD_BOT_TOKEN` 时写入；等效 `DISCORD_*` 环境变量优先。已有部署增加 Discord 时，在 `.env` 填写凭据后运行 `make up && make configure`，然后运行 `make check`。其它设置可以用 `make config` 编辑，修改后运行 `make restart`。查看全部设置：`docker exec hermes hermes config`。

### 自定义

| 需求                       | 方法                                                                                                                                                              |
| -------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 更换语言版本               | 修改 `devbox/mise.toml`，然后运行 `docker compose build devbox && make up`                                                                                        |
| 添加系统软件包             | 修改 `devbox/Dockerfile` 中的 apt 列表，同上。临时安装可以用 `sudo apt install`，重建后会丢失                                                                     |
| 修改 Agent 的人设和规则    | 编辑 `data/SOUL.md`，然后运行 `make restart`                                                                                                                      |
| 开发用数据库               | 在 `.env` 中设置 `COMPOSE_PROFILES=db` 后运行 `make up`；devbox 中直接使用 `psql`、`redis-cli -u "$REDIS_URL"`                                                    |
| 本地模型                   | 设置 `COMPOSE_PROFILES=ollama`，模型配置见 [custom 端点](#custom-端点)                                                                                            |
| 让 Agent 使用宿主机 Docker | 取消 `docker-compose.yml` 中 `docker.sock` 一行的注释。**这等同于宿主机 root 权限**，确有需要再开启                                                               |
| 减少确认                   | 把 `approvals.mode` 改为 `off`（命令仍然只在 devbox 中执行）                                                                                                      |
| 在群组中使用               | 在 BotFather 中关闭 privacy mode 或把 bot 设为管理员；在 `.env` 中设置 `TELEGRAM_GROUP_ALLOWED_CHATS`，并在 `config.yaml` 中设置 `telegram.require_mention: true` |
| 多个 Agent（如工作和个人） | 运行 `docker exec hermes hermes profile create work`，把另一个 bot 的 token 写入 `data/profiles/work/.env`，然后 `make restart`。同一个网关会同时服务所有 profile |
| 固定 Hermes 版本           | 在 `.env` 中设置 `HERMES_TAG=<版本号>`                                                                                                                            |

## 安全

本项目默认：

- 不开放任何入站端口：Telegram 使用长轮询，Discord 使用出站 WebSocket，Dashboard 和 devbox SSH 只监听 `127.0.0.1`（`make check` 会检查）；
- 每个启用的平台必须设置数字用户 ID 白名单（`TELEGRAM_ALLOWED_USERS` / `DISCORD_ALLOWED_USERS`）；额外配置 Discord 角色白名单会授予对应角色成员访问权限；
- Dashboard 需要账号密码登录；
- devbox 只允许公钥登录，禁止 root 登录；
- Agent 在 devbox 中执行命令，与持有 API Key 的 Hermes 进程隔离，devbox 中看不到 `.env`；
- `.env`、`secrets/`、`backups/` 只有所有者可读，并已加入 `.gitignore`。

需要你注意：

- 不要对外开放 Hermes 的 API 端口（8642）。确实需要时设置 `API_SERVER_KEY`，并放在反向代理或 VPN 之后。
- 不要挂载 `docker.sock`，除非清楚后果。
- bot token 泄露时，Telegram 在 BotFather 中 `/revoke`，Discord 在 Developer Portal 重置 Bot token；更新 `.env` 后运行 `make up`。
- 定期备份，并把 `backups/` 同步到另一台机器。

## 备份、恢复与升级

```bash
make backup                                   # 备份到 backups/<时间戳>/，保留最近 14 份
./scripts/backup.sh --with-workspace          # 同时备份 workspace/（不含 node_modules、.venv 等）
./scripts/restore.sh backups/<时间戳>         # 恢复；当前数据会先改名保留
make update                                   # 备份，然后升级 Hermes 镜像并重建 devbox
```

备份包括 Hermes 的全部状态（配置、密钥、会话、记忆、skills、定时任务）和 devbox 的 home 卷。Hermes 运行时会先生成数据库快照，保证备份一致。

定时备份：运行 `crontab -e`，添加

```
30 4 * * * /path/to/hermes-stack/scripts/backup.sh >/dev/null 2>&1
```

## 常见问题

遇到问题先运行 `make check`，大多数情况下它会直接指出原因。

| 现象                                          | 处理方法                                                                                                                                                                                                        |
| --------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| bot 没有任何回复                              | 看 `make check` 的消息网关与对应平台部分。最常见的原因是 `data/.env` 中没有 bot token：运行 `make up`。其它可能：token 无效、同一个 token 在别处使用、服务器无法连接 Telegram（设置 `TELEGRAM_PROXY` 或 `HTTPS_PROXY`） |
| bot 只回复配对码，或回复 unauthorized         | 你的用户 ID 不在白名单中。`TELEGRAM_ALLOWED_USERS` 要填数字 ID，不是用户名；`make check` 会列出最近被拒绝的用户 ID。修改后运行 `make up`                                                                        |
| Discord 离线，日志出现 intents / 4014 | Developer Portal → Bot 开启 Message Content Intent；角色白名单还需要 Server Members Intent。保存后运行 `make restart` |
| Discord REST 成功但不回复 | REST 成功只证明 HTTP 和 token 可用。看网关是否已连接，检查用户白名单、频道范围、是否 @Bot、Interactions Endpoint URL 是否为空 |
| Discord 报 403 / Missing Access / Missing Permissions | 检查服务器角色以及父分类、频道权限覆盖，尤其是创建公开线程和在线程发送消息权限；修改邀请权限后需重新授权 |
| 修改 `.env` 后没有生效                        | 需要运行 `make up`。值中含有 `$` 时要用单引号包起来                                                                                                                                                             |
| 回复时好时坏，日志中反复出现 polling conflict | 同一个 bot token 在另一处也在运行，停止其中一处                                                                                                                                                                 |
| 通过 Tailscale IP 打不开 9119 端口            | Dashboard 只监听 `127.0.0.1`，请使用 `tailscale serve`，见 [Dashboard](#dashboard)                                                                                                                              |
| 命令执行时报 SSH 错误                         | 看 `make check` 的 SSH 部分，以及 `docker compose logs devbox`                                                                                                                                                  |
| SSH 报 host identification has changed        | devbox-hostkeys 卷被删除过：`docker exec -u hermes hermes ssh-keygen -R devbox`                                                                                                                                 |
| Agent 找不到 node 或 python                   | 用最新的 Dockerfile 重建 devbox：`docker compose build devbox && make up`                                                                                                                                       |
| 容器无法启动：Range of CPUs is from 0.01 to N | `.env` 中的 CPU 上限超过了本机核数。运行 `make configure` 自动调整，或手动修改 `HERMES_CPU_LIMIT` / `DEVBOX_CPU_LIMIT`                                                                                          |
| `init.sh` 提示 data 目录不可写                | 之前直接运行过 `docker compose up`，目录归 root 所有：按提示 `sudo chown` 后重新运行                                                                                                                            |
| `./data` 权限错误                             | `.env` 中的 `HOST_UID` / `HOST_GID` 要与数据目录的属主一致（`ls -n data`），且不能为 0                                                                                                                          |
| 构建 devbox 时下载失败                        | 服务器无法访问软件源时，在 `.env` 中设置 `HTTPS_PROXY`，构建会自动使用                                                                                                                                          |
| 浏览器工具崩溃                                | 调大 `.env` 中的 `HERMES_MEM_LIMIT`                                                                                                                                                                             |
| `make configure` 中某项设置失败               | Hermes 新版本可能更改了配置项名称，参考输出中的提示，或用 `make config` 手动修改                                                                                                                                |
| macOS 的 Docker Desktop 上出现 state.db 警告  | 把 `./data` 换成 Docker 命名卷，参见 Hermes Docker 文档中的 Filesystem requirements                                                                                                                             |
| custom 端点返回 401                           | `STACK_CUSTOM_API_KEY` 错误，或协议不匹配（Anthropic 兼容的服务需要 `STACK_CUSTOM_API_MODE=anthropic_messages`）。修改后运行 `make configure`                                                                   |
| custom 端点提示模型不存在                     | `STACK_MODEL` 要与 `/models` 返回的 id 完全一致；`make check` 会列出可用模型                                                                                                                                    |
| 无法连接 custom 端点                          | 地址不能用 `localhost`，宿主机上的服务请用 `host.docker.internal` 并监听 `0.0.0.0`；配置了代理时，确认端点在 `NO_PROXY` 中                                                                                      |
| base_url 中的 `/v1` 写错                      | `make check` 会尝试两种写法，并给出正确的地址                                                                                                                                                                   |
| 对话变长后提示上下文超长                      | 填写 `STACK_CONTEXT_LENGTH` 为模型的实际窗口，然后运行 `make configure`                                                                                                                                         |
| 提示 context window too small 或 at least 64K | 换用上下文不少于 64K 的模型，或调大本地推理服务的上下文                                                                                                                                                         |

## 目录结构

```
hermes-stack/
├── docker-compose.yml
├── .env.example            配置模板
├── Makefile                常用命令（运行 make 查看）
├── devbox/                 开发环境镜像
│   ├── Dockerfile
│   ├── mise.toml           语言版本
│   ├── entrypoint.sh
│   ├── profile.sh
│   └── sshd_config
├── scripts/
│   ├── init.sh             首次部署
│   ├── configure.sh        写入推荐配置和模型设置
│   ├── sync-secrets.sh     把 .env 中的密钥同步到 data/.env
│   ├── check.sh            自检
│   ├── backup.sh           备份
│   ├── restore.sh          恢复
│   ├── update.sh           升级
│   ├── lib.sh              公共函数
│   ├── sync_env.py         ┐
│   ├── model_diag.py       ├ 在 hermes 容器内运行的辅助脚本
│   ├── gateway_diag.py     │
│   └── discord_diag.py     ┘
├── tests/                  离线回归测试（make test）
├── templates/SOUL.md       Agent 的人设和工作规则
│
├── data/                   运行后生成：Hermes 的全部状态
├── workspace/              运行后生成：代码
├── secrets/                运行后生成：devbox 的授权公钥
└── backups/                运行后生成：备份
```

## 参考

- [Hermes Agent：Docker 部署](https://hermes-agent.nousresearch.com/docs/user-guide/docker)
- [Hermes Agent：Discord](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/discord)
- [Discord Gateway 与 intents](https://docs.discord.com/developers/events/gateway)
- [Hermes Agent：Telegram](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/telegram)
- [Hermes Agent：配置与终端后端](https://hermes-agent.nousresearch.com/docs/user-guide/configuration)
- [Hermes Agent：模型配置](https://hermes-agent.nousresearch.com/docs/user-guide/configuring-models)
- [Tailscale Serve](https://tailscale.com/kb/1242/tailscale-serve)
