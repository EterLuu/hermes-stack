# devbox：Agent 通过 SSH 在这里执行所有命令，你也可以用 SSH / VS Code 进入同一个环境。
#   - 语言运行时由 mise 管理，安装在镜像内的 /opt/mise，重建镜像即可升级
#   - 用户级全局工具（npm -g、uv tool install、go install、cargo install）安装到 ~/.local 和 ~/go，
#     位于 devbox-home 卷中，重建镜像后仍然保留
FROM ubuntu:24.04

ARG DEV_UID=1000
ARG DEV_GID=1000
ARG DEV_SUDO=true
ARG INSTALL_RUST=true

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    MISE_DATA_DIR=/opt/mise \
    MISE_CACHE_DIR=/opt/mise/cache \
    MISE_GLOBAL_CONFIG_FILE=/etc/mise/config.toml \
    MISE_YES=1 \
    RUSTUP_HOME=/opt/rust/rustup \
    CARGO_HOME=/opt/rust/cargo \
    CARGO_INSTALL_ROOT=/home/dev/.local \
    NPM_CONFIG_PREFIX=/home/dev/.local \
    PNPM_HOME=/home/dev/.local/share/pnpm \
    PATH=/home/dev/.local/bin:/home/dev/.local/share/pnpm:/home/dev/go/bin:/opt/mise/shims:/opt/rust/cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN if [ "${DEV_UID}" = "0" ] || [ "${DEV_GID}" = "0" ]; then \
      echo "DEV_UID/DEV_GID 不能为 0（请用 scripts/init.sh 生成 .env）" >&2; exit 1; \
    fi

# ---- 系统包：编译工具链、常用命令行工具、数据库客户端 ----
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget gnupg lsb-release \
      openssh-server openssh-client sudo tzdata locales \
      build-essential pkg-config cmake make autoconf automake libtool \
      libssl-dev zlib1g-dev libffi-dev libbz2-dev libreadline-dev libsqlite3-dev \
      liblzma-dev libncurses-dev libxml2-dev libyaml-dev xz-utils tk-dev \
      git git-lfs jq ripgrep fd-find fzf bat tree tmux vim neovim nano htop less \
      unzip zip rsync file lsof procps psmisc iproute2 iputils-ping dnsutils netcat-openbsd \
      shellcheck sqlite3 postgresql-client default-mysql-client redis-tools \
      python3 python3-venv \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
    && ln -sf /usr/bin/batcat /usr/local/bin/bat \
    && rm -rf /var/lib/apt/lists/*

# ---- GitHub CLI 和 Docker CLI（官方软件源） ----
RUN install -d -m 0755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
         -o /etc/apt/keyrings/githubcli.gpg \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/githubcli.gpg /etc/apt/keyrings/docker.asc \
    && arch="$(dpkg --print-architecture)" \
    && echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" \
         > /etc/apt/sources.list.d/github-cli.list \
    && echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
         > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh docker-ce-cli docker-buildx-plugin docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# ---- 开发用户：与宿主机 UID/GID 一致，/workspace 中的文件属主保持一致 ----
RUN (userdel -r ubuntu 2>/dev/null || true) \
    && (getent group "${DEV_GID}" >/dev/null || groupadd -g "${DEV_GID}" dev) \
    && useradd -m -s /bin/bash -u "${DEV_UID}" -g "${DEV_GID}" dev \
    && usermod -p '*' dev \
    && (getent group docker >/dev/null || groupadd docker) && usermod -aG docker dev \
    && if [ "${DEV_SUDO}" = "true" ]; then \
         echo 'dev ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/dev && chmod 0440 /etc/sudoers.d/dev; \
       fi \
    && mkdir -p /workspace /home/dev/.local/bin /home/dev/.local/share/pnpm /home/dev/.ssh /home/dev/.config \
    && chown -R "${DEV_UID}:${DEV_GID}" /workspace /home/dev \
    && chmod 700 /home/dev/.ssh \
    && git config --system init.defaultBranch main \
    && git config --system safe.directory '*'

# ---- 语言运行时（mise）：Node LTS、Python、Go、uv、pnpm、yq ----
COPY mise.toml /etc/mise/config.toml
RUN curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh \
    && mise install \
    && mise reshim \
    && chown -R "${DEV_UID}:${DEV_GID}" /opt/mise \
    && node --version && python --version && go version && uv --version && pnpm --version

# ---- Rust（可选） ----
RUN if [ "${INSTALL_RUST}" = "true" ]; then \
      curl -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile minimal -c rustfmt -c clippy \
      && chown -R "${DEV_UID}:${DEV_GID}" /opt/rust \
      && cargo --version; \
    fi

# ---- 环境变量：SSH 非交互命令通过 pam_env 读取 /etc/environment，登录和交互 shell 通过 profile.d 读取同一文件 ----
COPY profile.sh /etc/profile.d/10-devbox.sh
RUN sed -i '1i [ -r /etc/profile.d/10-devbox.sh ] && . /etc/profile.d/10-devbox.sh' /etc/bash.bashrc

# ---- sshd ----
COPY sshd_config /etc/ssh/sshd_config
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh \
    && rm -f /etc/ssh/ssh_host_* \
    && mkdir -p /run/sshd /etc/ssh/keys /run/devbox

WORKDIR /workspace
EXPOSE 22
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
