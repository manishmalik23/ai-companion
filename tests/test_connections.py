import json
import os
from pathlib import Path
import shlex
import tempfile
import unittest
from unittest import mock

import connections
import install_local as files
from setup_hooks import build_config


class ConnectionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pip-connections-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.home = self.root / "home"
        self.home.mkdir()
        self.helper = self.root / "Pip.app/Contents/Helpers/PipRuntime/PipHelper"
        self.helper.parent.mkdir(parents=True)
        self.helper.write_bytes(b"test executable")
        self.helper.chmod(0o755)

    def path(self, provider="claude"):
        return connections.paths_for(self.home, provider)

    def connect(self, provider="claude", operation="connect"):
        plan = connections.prepare(self.home, self.helper, provider, operation)
        return connections.apply(self.home, self.helper, plan["id"])

    def seed(self, provider, data):
        paths = self.path(provider)
        paths["settings"].parent.mkdir(parents=True, exist_ok=True)
        paths["settings"].write_text(json.dumps(data))

    def test_prepare_does_not_change_agent_settings_or_leak_tokens(self):
        self.seed("claude", {"apiKey": "secret sentinel", "permissions": {"defaultMode": "plan"}})
        original = self.path()["settings"].read_bytes()
        plan = connections.prepare(self.home, self.helper, "claude")
        self.assertEqual(self.path()["settings"].read_bytes(), original)
        self.assertFalse(self.path()["telemetry"].exists())
        self.assertNotIn("secret sentinel", json.dumps(plan))
        self.assertNotIn("token", json.dumps(plan))
        self.assertEqual((self.path()["setup"] / (plan["id"] + ".json")).stat().st_mode & 0o777, 0o600)

    def test_connect_preserves_other_hooks_and_permissions_and_disconnect_restores_them(self):
        other = {"type": "command", "command": "echo keep-this-hook"}
        original = {"permissions": {"defaultMode": "plan"}, "env": {"KEEP": "yes"},
                    "hooks": {"Stop": [{"hooks": [other]}]}}
        self.seed("claude", original)
        before_helper = self.helper.read_bytes()
        self.connect()
        result = json.loads(self.path()["settings"].read_text())
        self.assertEqual(result["permissions"], original["permissions"])
        self.assertEqual(result["env"]["KEEP"], "yes")
        self.assertIn(other, result["hooks"]["Stop"][0]["hooks"])
        command = result["hooks"]["PermissionRequest"][0]["hooks"][0]["command"]
        self.assertEqual(shlex.split(command)[:2], [str(self.helper), "hook"])
        self.assertNotIn("python", command)
        self.assertEqual(self.helper.read_bytes(), before_helper)
        self.assertTrue(list(self.path()["settings"].parent.glob("*.pip-backup")))
        self.connect(operation="disconnect")
        self.assertEqual(json.loads(self.path()["settings"].read_text()), original)

    def test_update_is_idempotent_and_providers_do_not_replace_one_another(self):
        self.connect("claude")
        self.connect("codex")
        previous = {p: self.path(p)["settings"].read_bytes() for p in connections.PROVIDERS}
        self.assertEqual(self.connect("claude")["changed_files"], 0)
        self.assertTrue(all(self.path(p)["settings"].read_bytes() == data for p, data in previous.items()))
        status = connections.status(self.home, self.helper)
        self.assertTrue(all(p["connected"] for p in status["providers"]))
        self.connect("codex", "disconnect")
        self.assertEqual(self.path("claude")["settings"].read_bytes(), previous["claude"])

    def test_changed_settings_and_changed_helper_require_new_review(self):
        for target in ("settings", "helper"):
            with self.subTest(target=target):
                plan = connections.prepare(self.home, self.helper, "codex")
                if target == "settings":
                    self.seed("codex", {"changed": True})
                else:
                    self.helper.write_bytes(b"different executable")
                with self.assertRaisesRegex(files.InstallError, "changed"):
                    connections.apply(self.home, self.helper, plan["id"])

    def test_existing_telemetry_is_never_overwritten(self):
        self.seed("claude", {"env": {"OTEL_EXPORTER_OTLP_LOGS_ENDPOINT": "http://existing.invalid"}})
        previous = self.path()["settings"].read_bytes()
        with self.assertRaisesRegex(files.InstallError, "preserved"):
            connections.prepare(self.home, self.helper, "claude")
        self.assertEqual(self.path()["settings"].read_bytes(), previous)

    def test_migrates_exact_legacy_commands_without_touching_similarly_named_hooks(self):
        paths = self.path()
        legacy = build_config("claude", paths["runtime"], bridge_path=paths["support"] / "bridge.py")
        foreign = {"type": "command", "command": "/usr/bin/python3 /other/bridge.py hook --source claude"}
        legacy["hooks"]["Stop"].append({"hooks": [foreign]})
        self.seed("claude", legacy)
        self.connect()
        result = json.loads(paths["settings"].read_text())
        commands = [h["command"] for groups in result["hooks"].values() for g in groups for h in g["hooks"]]
        self.assertIn(foreign["command"], commands)
        self.assertTrue(all(str(paths["support"] / "bridge.py") not in c for c in commands))

    def test_rejects_symlinked_agent_settings(self):
        outside = self.root / "untouched.json"
        outside.write_text("{}")
        target = self.path()["settings"]
        target.parent.mkdir()
        target.symlink_to(outside)
        with self.assertRaises(files.InstallError):
            connections.prepare(self.home, self.helper, "claude")
        self.assertEqual(outside.read_text(), "{}")

    def test_failure_rolls_back_settings_and_keeps_backup(self):
        self.seed("codex", {"keep": "original"})
        previous = self.path("codex")["settings"].read_bytes()
        plan = connections.prepare(self.home, self.helper, "codex")
        atomic = files.atomic_bytes

        def fail_manifest(path, data, mode=0o600):
            if Path(path).name == connections.MANIFEST:
                raise OSError("simulated disk failure")
            return atomic(path, data, mode)

        with mock.patch.object(files, "atomic_bytes", side_effect=fail_manifest):
            with self.assertRaises(OSError):
                connections.apply(self.home, self.helper, plan["id"])
        self.assertEqual(self.path("codex")["settings"].read_bytes(), previous)


if __name__ == "__main__":
    unittest.main()
