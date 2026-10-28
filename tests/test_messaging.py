"""平台选择、凭据同步、在线状态与 REST 诊断的离线回归测试。"""
import asyncio
from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
TG = {"TELEGRAM_BOT_TOKEN": "123456789:" + "a" * 35, "TELEGRAM_ALLOWED_USERS": "123456"}
DC = {"DISCORD_BOT_TOKEN": "test-discord-token", "DISCORD_ALLOWED_USERS": "284102345871466496"}


def modules(**entries):
    result = {}
    for name, attributes in entries.items():
        module = types.ModuleType(name)
        module.__dict__.update(attributes)
        result[name] = module
    return result


class MessagingConfigTests(unittest.TestCase):
    def shell(self, env, code):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / ".env"
            path.write_text("".join(f"{k}={v}\n" for k, v in env.items()))
            return subprocess.run(
                ["bash", "-euo", "pipefail", "-c",
                 '. "$1/scripts/lib.sh"; ENV_FILE="$2"; ' + code,
                 "test", str(ROOT), str(path)],
                check=True, text=True, capture_output=True,
            ).stdout

    def problems(self, env):
        return self.shell(env, 'check_messaging_env; for p in "${MESSAGING_PROBLEMS[@]}"; do printf "%s\\n" "$p"; done')

    def test_all_platform_combinations(self):
        for env, expected in ((TG, "telegram\n"), (DC, "discord\n"), (TG | DC, "telegram\ndiscord\n")):
            with self.subTest(expected=expected):
                self.assertEqual(self.shell(env, "enabled_platforms"), expected)
                self.assertEqual(self.problems(env), "")

    def test_no_platform_is_rejected(self):
        self.assertIn("至少配置一个平台", self.problems({}))

    def test_missing_and_invalid_discord_user_are_rejected(self):
        for users in ("", "@someone", "*", "123,", "123,0", "-123", "12 34"):
            with self.subTest(users=users):
                self.assertIn("DISCORD_ALLOWED_USERS", self.problems(DC | {"DISCORD_ALLOWED_USERS": users}))

    def test_enabled_platform_requires_its_own_allowlist(self):
        self.assertIn("TELEGRAM_ALLOWED_USERS", self.problems(DC | {"TELEGRAM_BOT_TOKEN": TG["TELEGRAM_BOT_TOKEN"]}))

    def test_disabled_platform_values_do_not_block_other_platform(self):
        self.assertEqual(self.problems(TG | {"DISCORD_ALLOWED_USERS": "stale-name"}), "")

    def test_numeric_lists_and_single_home_channel(self):
        self.assertEqual(self.problems(DC | {"DISCORD_ALLOWED_USERS": "123, 456", "DISCORD_ALLOWED_CHANNELS": "789,987"}), "")
        self.assertIn("DISCORD_HOME_CHANNEL", self.problems(DC | {"DISCORD_HOME_CHANNEL": "123,456"}))
        self.assertIn("DISCORD_ALLOWED_CHANNELS", self.problems(DC | {"DISCORD_ALLOWED_CHANNELS": "#general"}))

    def test_telegram_token_validation_is_preserved(self):
        self.assertIn("TELEGRAM_BOT_TOKEN", self.problems(TG | {"TELEGRAM_BOT_TOKEN": "invalid"}))

    def test_sync_includes_discord_settings_and_explicit_false(self):
        env = DC | {"DISCORD_PROXY": "'socks5://user:p$a@proxy:1080'", "DISCORD_AUTO_THREAD": "false",
                    "DISCORD_ALLOWED_CHANNELS": "123", "DISCORD_HOME_CHANNEL": "", "STACK_CUSTOM_API_KEY": "abc",
                    "HERMES_DASHBOARD_TEST_TOKEN": "private", "UNRELATED": "ignored"}
        got = dict(line.split("=", 1) for line in self.shell(env, "hermes_secret_lines").splitlines())
        self.assertEqual(got["DISCORD_PROXY"], "socks5://user:p$a@proxy:1080")
        self.assertEqual(got["DISCORD_AUTO_THREAD"], "false")
        self.assertEqual(got["DISCORD_ALLOWED_CHANNELS"], "123")
        self.assertNotIn("DISCORD_HOME_CHANNEL", got)
        self.assertNotIn("HERMES_DASHBOARD_TEST_TOKEN", got)
        self.assertNotIn("UNRELATED", got)


class SyncLifecycleTests(unittest.TestCase):
    def test_update_clear_delete_and_preserve_sethome(self):
        with tempfile.TemporaryDirectory() as tmp:
            env_path = Path(tmp) / ".env"
            env_path.write_text(json.dumps({"DISCORD_HOME_CHANNEL": "999", "OTHER": "keep"}))

            def load(path):
                return json.loads(Path(path).read_text())

            def save(key, value):
                values = load(env_path)
                values[key] = value
                env_path.write_text(json.dumps(values))

            def remove(key):
                values = load(env_path)
                values.pop(key, None)
                env_path.write_text(json.dumps(values))
                return True

            fake = modules(**{"hermes_cli": {}, "agent": {},
                              "hermes_cli.config": {"get_env_path": lambda: env_path, "save_env_value": save, "remove_env_value": remove},
                              "agent.secret_scope": {"load_env_file": load}})

            def sync(lines):
                output = io.StringIO()
                with patch.dict(sys.modules, fake), patch("sys.stdin", io.StringIO(lines)), redirect_stdout(output):
                    runpy.run_path(str(ROOT / "scripts/sync_env.py"), run_name="__main__")
                return output.getvalue()

            self.assertIn("ok\t3", sync("DISCORD_BOT_TOKEN=first\nDISCORD_ALLOWED_USERS=123\nDISCORD_PROXY=http://proxy\n"))
            self.assertIn("ok\t0", sync("DISCORD_BOT_TOKEN=first\nDISCORD_ALLOWED_USERS=123\nDISCORD_PROXY=http://proxy\n"))
            output = sync("DISCORD_BOT_TOKEN=second\nDISCORD_ALLOWED_USERS=456\n")
            self.assertIn("removed\tDISCORD_PROXY", output)
            self.assertEqual(load(env_path)["DISCORD_BOT_TOKEN"], "second")
            self.assertNotIn("second", output)
            sync("")
            self.assertEqual(load(env_path), {"DISCORD_HOME_CHANNEL": "999", "OTHER": "keep"})


class GatewayStatusTests(unittest.TestCase):
    def diagnose(self, env, platforms, *, args=(), stale=False, pid=123):
        with tempfile.TemporaryDirectory() as tmp:
            rt = {"pid": 123, "start_time": 100, "gateway_state": "running", "platforms": platforms}
            fake = modules(**{"agent": {}, "gateway": {},
                              "agent.secret_scope": {"load_env_file": lambda p: env},
                              "hermes_constants": {"get_hermes_home": lambda: tmp},
                              "gateway.status": {"get_running_pid": lambda **kw: pid,
                                                 "read_runtime_status": lambda: rt,
                                                 "runtime_status_is_stale": lambda r: stale}})
            output = io.StringIO()
            with patch.dict(sys.modules, fake), patch.object(sys, "argv", ["gateway_diag.py", *args]), redirect_stdout(output):
                runpy.run_path(str(ROOT / "scripts/gateway_diag.py"), run_name="__main__")
            return output.getvalue()

    def test_only_enabled_platforms_are_required(self):
        for env, platforms in ((TG, {"telegram": {"state": "connected"}}),
                               (DC, {"discord": {"state": "connected"}}),
                               (TG | DC, {"telegram": {"state": "connected"}, "discord": {"state": "connected"}})):
            with self.subTest(env=tuple(env)):
                self.assertNotIn("BAD\t", self.diagnose(env, platforms))

    def test_requested_but_unsynced_token_is_reported(self):
        self.assertIn("没有 DISCORD_BOT_TOKEN", self.diagnose({}, {}, args=("discord",)))

    def test_previous_process_connection_is_not_online(self):
        for info in ({"state": "connected", "writer_pid": 1}, {"state": "connected", "writer_start_time": 50}):
            output = self.diagnose(DC, {"discord": info})
            self.assertIn("网关没有启用 Discord", output)
            self.assertNotIn("Discord 已连接", output)

    def test_runtime_owned_by_old_process_is_not_online(self):
        output = self.diagnose(DC, {"discord": {"state": "connected", "writer_pid": 123}}, pid=456)
        self.assertIn("旧进程", output)
        self.assertNotIn("Discord 已连接", output)

    def test_stopped_gateway_does_not_report_old_connection(self):
        output = self.diagnose(DC, {"discord": {"state": "connected"}}, pid=None)
        self.assertNotIn("Discord 已连接", output)

    def test_current_profile_connection_is_reported(self):
        output = self.diagnose(DC, {"work:discord": {"state": "connected", "writer_pid": 123, "writer_start_time": 100}})
        self.assertIn("Discord（profile work） 已连接", output)

    def test_intent_failure_is_actionable_and_redacts_token(self):
        output = self.diagnose(DC, {"discord": {"state": "failed", "error_message": "4014 privileged " + DC["DISCORD_BOT_TOKEN"]}})
        self.assertIn("Message Content Intent", output)
        self.assertNotIn(DC["DISCORD_BOT_TOKEN"], output)

    def test_channel_permission_failure_is_actionable(self):
        output = self.diagnose(DC, {"discord": {"state": "failed", "error_message": "403 Missing Permissions"}})
        self.assertIn("频道权限覆盖", output)

    def test_heartbeat_and_process_failure(self):
        self.assertIn("心跳已过期", self.diagnose(DC, {}, stale=True))
        self.assertIn("网关没有运行", self.diagnose(DC, {}, pid=None))

    def test_missing_allowlist_is_reported(self):
        self.assertIn("DISCORD_ALLOWED_USERS 为空", self.diagnose({"DISCORD_BOT_TOKEN": "test"}, {}))


class DiscordRestTests(unittest.TestCase):
    def diagnose(self, *, content=True, members=False, error=None, env=None, missing=False):
        self.calls = []

        class LoginFailure(Exception):
            pass

        class Forbidden(Exception):
            pass

        class HTTPException(Exception):
            status = 429

        flags = types.SimpleNamespace(gateway_message_content=content, gateway_message_content_limited=False,
                                      gateway_guild_members=members, gateway_guild_members_limited=False)
        calls = self.calls

        class Client:
            user = types.SimpleNamespace(name="test-bot")

            def __init__(self, **kwargs):
                calls.append(("client", kwargs))

            async def __aenter__(self):
                return self

            async def __aexit__(self, *args):
                calls.append(("closed",))

            async def login(self, token):
                calls.append(("login",))
                if error == "token":
                    raise LoginFailure("SECRET")
                if error == "forbidden":
                    raise Forbidden("SECRET")
                if error == "limited":
                    raise HTTPException("SECRET")
                if error == "network":
                    raise OSError("SECRET proxy-password")

            async def application_info(self):
                return types.SimpleNamespace(flags=flags)

        fake = modules(**{"discord": {"Client": Client, "Intents": types.SimpleNamespace(none=lambda: None),
                                       "LoginFailure": LoginFailure, "Forbidden": Forbidden, "HTTPException": HTTPException},
                          "agent": {}, "hermes_cli": {}, "gateway": {}, "gateway.platforms": {},
                          "agent.secret_scope": {"load_env_file": lambda p: DC | (env or {})},
                          "hermes_cli.config": {"get_env_path": lambda: "/fake/.env"},
                          "gateway.platforms.base": {"resolve_proxy_url": lambda **kw: os.environ.get(kw["platform_env_var"]),
                                                     "proxy_kwargs_for_bot": lambda p: {"proxy": p}}})
        if missing:
            fake["discord"] = None
        output = io.StringIO()
        with patch.dict(sys.modules, fake), patch.dict(os.environ, {}, clear=True), redirect_stdout(output):
            runpy.run_path(str(ROOT / "scripts/discord_diag.py"), run_name="__main__")
        return output.getvalue()

    def test_rest_success_does_not_claim_gateway_online(self):
        output = self.diagnose()
        self.assertIn("REST 鉴权成功", output)
        self.assertIn("不代表 Gateway 已连接", output)
        self.assertNotIn("BAD\t", output)
        self.assertIn(("closed",), self.calls)

    def test_message_content_intent_required(self):
        self.assertIn("Message Content Intent 未开启", self.diagnose(content=False))

    def test_members_intent_only_required_for_role_auth(self):
        self.assertNotIn("Server Members Intent", self.diagnose())
        self.assertIn("需要 Server Members Intent", self.diagnose(env={"DISCORD_ALLOWED_ROLES": "123"}))
        self.assertNotIn("BAD\t", self.diagnose(env={"DISCORD_ALLOWED_ROLES": "123"}, members=True))

    def test_proxy_uses_synced_configuration(self):
        self.diagnose(env={"DISCORD_PROXY": "socks5://fake-proxy:1080"})
        self.assertEqual(self.calls[0][1]["proxy"], "socks5://fake-proxy:1080")

    def test_network_auth_and_permission_errors_hide_credentials(self):
        for error, expected in (("token", "401"), ("forbidden", "403"), ("limited", "429"), ("network", "DISCORD_PROXY")):
            with self.subTest(error=error):
                output = self.diagnose(error=error)
                self.assertIn(expected, output)
                self.assertNotIn("SECRET", output)
                self.assertNotIn("proxy-password", output)

    def test_missing_dependency_and_token(self):
        self.assertIn("缺少 discord.py", self.diagnose(missing=True))
        self.assertIn("没有 DISCORD_BOT_TOKEN", self.diagnose(env={"DISCORD_BOT_TOKEN": ""}))

    def test_timeout_is_bounded_and_reported(self):
        script = runpy.run_path(str(ROOT / "scripts/discord_diag.py"))

        async def timeout(coro, **kwargs):
            coro.close()
            raise asyncio.TimeoutError

        output = io.StringIO()
        with patch("asyncio.wait_for", timeout), redirect_stdout(output):
            asyncio.run(script["main"]())
        self.assertIn("超过 25 秒", output.getvalue())


if __name__ == "__main__":
    unittest.main()
