# shellcheck shell=sh
# /etc/profile.d/10-devbox.sh
# 让登录 shell 和交互 shell 与 SSH 非交互命令使用同一份环境：
# SSH 非交互命令（Agent 执行的命令）通过 pam_env 读取 /etc/environment，
# 这里让其它 shell 也读取它，PATH、mise、代理、PG* 等变量因此保持一致。
if [ -r /etc/environment ]; then
  set -a
  . /etc/environment
  set +a
fi
export EDITOR="${EDITOR:-vim}"
export PAGER="${PAGER:-less}"
