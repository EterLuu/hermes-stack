"""把 .env 中的密钥同步到 data/.env。由 scripts/sync-secrets.sh 在 hermes 容器内调用。

Hermes 网关从 data/.env 读取 bot token、白名单和各类 API Key，不读取容器环境变量；
config.yaml 中的 ${STACK_CUSTOM_API_KEY} 引用也从这里展开。

输入（stdin）：每行 KEY=VALUE，即 data/.env 中应有的全部同步键。
  - 值不同或缺失的键会被写入；
  - 上次同步过、这次不再提供的键会被删除（记录在 data/.stack-synced-env）；
  - 其它键（例如 /sethome 写入的 TELEGRAM_HOME_CHANNEL / DISCORD_HOME_CHANNEL）保持不变。
写入使用 Hermes 自己的 save_env_value / remove_env_value，引号规则和文件锁与 Hermes 一致。

输出：每行 "set|removed|error<TAB>KEY[<TAB>原因]"，最后一行 "ok<TAB>变更数"。不输出任何值。
"""
import os
import sys
from pathlib import Path

from hermes_cli.config import get_env_path, remove_env_value, save_env_value

try:
    from agent.secret_scope import load_env_file  # 与网关使用同一个解析器
except ImportError:  # 较早的 Hermes 版本
    from dotenv import dotenv_values

    def load_env_file(path):
        path = Path(path)
        return {k: v for k, v in dotenv_values(path).items() if v is not None} if path.exists() else {}

env_path = Path(get_env_path())
state = env_path.parent / ".stack-synced-env"

want = {}
for line in sys.stdin.read().splitlines():
    key, sep, value = line.partition("=")
    if sep and key:
        want[key] = value

prev = set(state.read_text().split()) if state.exists() else set()
current = load_env_file(env_path)
changed = 0

for key, value in want.items():
    if current.get(key) == value:
        continue
    try:
        save_env_value(key, value)
    except Exception as exc:  # 例如键名不合法、密钥含非 ASCII 字符
        print(f"error\t{key}\t{str(exc).splitlines()[0][:160]}")
        continue
    if load_env_file(env_path).get(key) == value:
        changed += 1
        print(f"set\t{key}")
    else:
        print(f"error\t{key}\t写入后读回的值不一致（该键可能由托管配置锁定）")

for key in sorted(prev - set(want)):
    if key in current:
        if remove_env_value(key):
            changed += 1
            print(f"removed\t{key}")

tmp = state.with_name(state.name + ".tmp")
tmp.write_text("".join(f"{k}\n" for k in sorted(want)))
os.replace(tmp, state)
print(f"ok\t{changed}")
