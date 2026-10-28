"""用假的 Docker/HTTP 命令运行完整 check.sh，验证平台选择和失败状态传递。"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from test_messaging import DC, TG, ROOT


DOCKER = r'''
import os
import sys
args = sys.argv[1:]
if args[0] == "inspect":
    fmt = args[2]
    if "State.Running" in fmt:
        print("true")
    elif "State.Health.Status" in fmt:
        print("healthy")
    elif "RestartCount" in fmt:
        print(0)
elif args[0] == "info":
    print(2)
elif args[0] == "ps":
    print("hermes 127.0.0.1:9119->9119/tcp")
elif args[0] == "exec":
    if "config" in args and "get" in args:
        print({"terminal.backend": "ssh", "streaming.enabled": "true"}[args[-1]])
    elif "ssh" in args:
        command = args[-1]
        if command == "echo ok":
            print("ok")
        elif "for t in" in command:
            print("git gh node pnpm python uv go cargo docker psql jq rg")
        elif "printf" in command:
            print("node test | Python test | go test")
    elif "sh" in args:
        print('{"ok":true,"result":{"username":"test_bot"}}')
    elif "-i" in args:
        body = sys.stdin.read()
        if "gateway_state.json" in body:
            for platform in args[args.index("-") + 1:]:
                print("OK\t" + platform.capitalize() + " 已连接（Gateway）")
        elif "不发送消息、不连接 Gateway" in body:
            if os.environ.get("REST_FAIL"):
                sys.exit(1)
            print("OK\tDiscord REST 鉴权成功（不代表 Gateway 已连接）")
        else:
            print("OK\t模型已配置")
else:
    raise SystemExit("Unexpected fake Docker call")
'''


class CheckScriptTests(unittest.TestCase):
    def check(self, values, *, rest_fail=False):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            shutil.copytree(ROOT / "scripts", root / "scripts")
            (root / ".env").write_text("".join(f"{k}={v}\n" for k, v in values.items()))
            (root / ".env").chmod(0o600)
            bindir = root / "bin"
            bindir.mkdir()
            for name, body in {
                "docker": f"#!{sys.executable}\n" + DOCKER,
                "curl": "#!/bin/sh\nprintf 401\n",
                "tailscale": "#!/bin/sh\nexit 1\n",
            }.items():
                path = bindir / name
                path.write_text(body)
                path.chmod(0o755)
            env = os.environ | {"PATH": str(bindir) + os.pathsep + os.environ["PATH"]}
            env.pop("REST_FAIL", None)
            if rest_fail:
                env["REST_FAIL"] = "1"
            return subprocess.run(["bash", str(root / "scripts/check.sh")], env=env,
                                  text=True, capture_output=True, timeout=15)

    def test_check_passes_for_all_three_platform_combinations(self):
        for values in (TG, DC, TG | DC):
            with self.subTest(platforms=tuple(values)):
                result = self.check(values)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                if "TELEGRAM_BOT_TOKEN" not in values:
                    self.assertIn("未配置 Telegram，跳过", result.stdout)
                if "DISCORD_BOT_TOKEN" not in values:
                    self.assertIn("未配置 Discord，跳过", result.stdout)

    def test_rest_execution_failure_makes_check_fail(self):
        result = self.check(DC, rest_fail=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Discord REST 诊断运行失败", result.stdout)

    def test_missing_discord_allowlist_makes_check_fail(self):
        result = self.check({"DISCORD_BOT_TOKEN": "fake"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("DISCORD_ALLOWED_USERS", result.stdout)

    def test_no_platform_makes_check_fail(self):
        result = self.check({})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("至少配置一个平台", result.stdout)


if __name__ == "__main__":
    unittest.main()
