#!/usr/bin/env bash
# devbox 启动脚本：准备 host key、环境变量和 home 目录，然后以前台方式运行 sshd。
set -euo pipefail

DEV_GROUP="$(id -gn dev)"

# 1. SSH host key 保存在 devbox-hostkeys 卷中，首次启动时生成
for t in ed25519 rsa; do
  f="/etc/ssh/keys/ssh_host_${t}_key"
  [ -f "$f" ] || ssh-keygen -q -t "$t" -N "" -f "$f"
done
chmod 600 /etc/ssh/keys/*_key
mkdir -p /run/sshd

# 2. 生成 /etc/environment。sshd 不会把容器环境变量传给会话，pam_env 会把这里的变量注入每个
#    SSH 会话（包括 Agent 执行的每条命令）；登录 shell 通过 profile.d 读取同一文件。
#    值用单引号包起来，读取时不会展开其中的 $ 或反引号（例如代理密码中的字符）。
put_env() {
  case "$2" in
    *"'"*) echo "[devbox] 警告：$1 的值包含单引号，无法安全写入 /etc/environment，已跳过" >&2 ;;
    *) printf "%s='%s'\n" "$1" "$2" ;;
  esac
}
{
  put_env PATH "$PATH"
  for v in LANG LC_ALL TZ \
           MISE_DATA_DIR MISE_CACHE_DIR MISE_GLOBAL_CONFIG_FILE MISE_YES \
           RUSTUP_HOME CARGO_HOME CARGO_INSTALL_ROOT NPM_CONFIG_PREFIX PNPM_HOME \
           HTTP_PROXY HTTPS_PROXY NO_PROXY \
           PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE REDIS_URL; do
    val="${!v:-}"
    [ -n "$val" ] || continue
    put_env "$v" "$val"
    case "$v" in
      HTTP_PROXY|HTTPS_PROXY|NO_PROXY) put_env "$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')" "$val" ;;
    esac
  done
} > /etc/environment
chmod 644 /etc/environment

# 3. home 卷：首次挂载时修正属主（Docker 会把镜像里的 /home/dev 复制到空卷）；
#    修改 HOST_UID 并重建镜像后，卷中旧文件的属主也需要整体修正一次
if [ ! -f /home/dev/.devbox-initialized ] \
   || [ "$(stat -c %u /home/dev/.devbox-initialized)" != "$(id -u dev)" ]; then
  install -d /home/dev/.local/bin /home/dev/.ssh /home/dev/.config
  touch /home/dev/.devbox-initialized   # 先创建标记再 chown，标记的属主随之更新，下次启动不再重复
  chown -R "dev:${DEV_GROUP}" /home/dev
  chmod 700 /home/dev/.ssh
fi
chown "dev:${DEV_GROUP}" /home/dev

# 4. 挂载了 docker.sock 时，把 dev 用户加入对应的组（与宿主机 docker 组的 GID 一致）
if [ -S /var/run/docker.sock ]; then
  sock_gid="$(stat -c %g /var/run/docker.sock)"
  if [ "$sock_gid" != "0" ]; then
    getent group "$sock_gid" >/dev/null || groupadd -g "$sock_gid" hostdocker
    usermod -aG "$(getent group "$sock_gid" | cut -d: -f1)" dev
  fi
fi

if [ ! -s /run/devbox/authorized_keys ] || [ -d /run/devbox/authorized_keys ]; then
  echo "[devbox] 警告：/run/devbox/authorized_keys 不存在或为空，Hermes 将无法登录。请运行 scripts/init.sh" >&2
fi

/usr/sbin/sshd -t
exec /usr/sbin/sshd -D -e
