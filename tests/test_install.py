import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shlex
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


PROJECT = Path(__file__).absolute().parent.parent
spec = importlib.util.spec_from_file_location("pip_installer", PROJECT / "install_local.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)

GENERATOR = '''import shlex
def build_config(source, runtime, bridge_path=None):
    command = shlex.join(["/usr/bin/python3", str(bridge_path), "hook", "--source", source,
                          "--runtime", str(runtime)])
    return {"hooks": {
        "PermissionRequest": [{"matcher": "*", "hooks": [
            {"type": "command", "command": command + " --wait 120", "timeout": 130}]}],
        "SessionStart": [{"hooks": [{"type": "command", "command": command, "timeout": 2}]}]
    }}
'''


class InstallerTests(unittest.TestCase):
    def setUp(self):
        # The installation fixtures contain a text placeholder executable. Only
        # this bundle-signing boundary is mocked; staging and publication stay real.
        self.real_sign_bundle = installer.sign_bundle
        signing = mock.patch.object(installer, "sign_bundle")
        self.sign_bundle = signing.start()
        self.addCleanup(signing.stop)
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.home = self.root / "home"
        self.project = self.root / "project"
        self.home.mkdir()
        self.project.mkdir()
        (self.project / "bridge.py").write_text("# permission bridge\n")
        (self.project / "session_titles.py").write_text("# title metadata reader\n")
        (self.project / "chat_bridge.py").write_text("# chat bridge\n")
        (self.project / "telemetry.py").write_text("# local decision parser\n")
        (self.project / "setup_hooks.py").write_text(GENERATOR)
        app = self.project / "dist" / "Agent Companion.app" / "Contents"
        (app / "MacOS").mkdir(parents=True)
        (app / "MacOS" / "AgentCompanion").write_bytes(b"local test app")
        os.chmod(app / "MacOS" / "AgentCompanion", 0o755)
        (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleName": "Pip"}))
        self.paths = installer.locations(self.home, self.project)
        self.claude = self.home / ".claude" / "settings.json"
        self.codex = self.home / ".codex" / "hooks.json"

    def write_settings(self, path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value))

    def prepare(self):
        return installer.prepare(self.home, self.project)

    def apply(self):
        return installer.apply(self.home, self.project)

    def test_prepare_is_private_and_does_not_write_home(self):
        self.write_settings(self.claude, {"apiKey": "secret sentinel", "permissions": {"defaultMode": "plan"}})
        old = self.claude.read_bytes()
        plan = self.prepare()
        self.assertEqual(stat.S_IMODE(self.paths["plan"].stat().st_mode), 0o600)
        self.assertEqual(self.claude.read_bytes(), old)
        self.assertFalse(self.codex.exists())
        self.assertFalse(self.paths["app"].exists())
        self.assertFalse(self.paths["support"].exists())
        self.assertNotIn("secret sentinel", self.paths["plan"].read_text())
        self.assertNotIn("permissions", self.paths["plan"].read_text())
        self.assertEqual(plan["settings"][0]["before_sha256"], installer.digest(old))
        self.assertIsNone(plan["settings"][1]["before_sha256"])
        self.assertEqual(set(plan["sources"]["sha256"]), {*installer.SCRIPT_NAMES, "app"})
        self.assertFalse((self.project / "__pycache__").exists())
        self.sign_bundle.assert_not_called()

    def test_signing_seals_final_plist_before_any_destination_is_published(self):
        self.write_settings(self.claude, {"keep": "original settings"})
        original_settings = self.claude.read_bytes()
        original_source = installer.tree_state(self.paths["source_app"], self.project)
        plan = self.prepare()
        signed_info = []

        def seal_final_bundle(app):
            self.assertFalse(self.paths["app"].exists())
            self.assertFalse(self.paths["support"].exists())
            self.assertEqual(self.claude.read_bytes(), original_settings)
            self.assertFalse(self.codex.exists())
            self.assertEqual(list(self.claude.parent.glob("*.pip-backup")), [])
            info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
            self.assertEqual(info["CompanionRuntimePath"], str(self.paths["support"] / ".runtime"))
            self.assertEqual(info["CompanionBridgePath"], str(self.paths["support"] / "chat_bridge.py"))
            for name, value in plan["install"]["launch"].items():
                self.assertEqual(info[name], value)
            signed_info.append(info)
            signature = app / "Contents/_CodeSignature"
            signature.mkdir()
            (signature / "CodeResources").write_bytes(b"fixture signature of final bundle")

        self.sign_bundle.side_effect = seal_final_bundle
        self.apply()
        self.sign_bundle.assert_called_once()
        installed_info = plistlib.loads((self.paths["app"] / "Contents/Info.plist").read_bytes())
        self.assertEqual(installed_info, signed_info[0])
        self.assertEqual(installer.tree_state(self.paths["source_app"], self.project), original_source)
        self.assertTrue((self.paths["app"] / "Contents/_CodeSignature/CodeResources").is_file())
        marker = json.loads((self.paths["support"] / installer.MARKER_NAME).read_bytes())
        self.assertEqual(marker["app_sha256"], installer.tree_state(self.paths["app"], self.home))
        installer.managed_state(self.paths)

    def test_signing_failure_does_not_create_a_new_installation_or_backups(self):
        self.write_settings(self.claude, {"keep": "existing"})
        self.prepare()
        before_home = installer.tree_state(self.home, self.home)
        self.sign_bundle.side_effect = installer.InstallError("bundle signing failed")
        with self.assertRaises(installer.InstallError):
            self.apply()
        self.assertEqual(installer.tree_state(self.home, self.home), before_home)
        self.assertFalse(self.paths["app"].exists())
        self.assertFalse(self.paths["support"].exists())

    def test_signing_or_verification_failure_keeps_existing_installation_unchanged(self):
        self.prepare()
        self.apply()
        (self.project / "bridge.py").write_text("# updated permission bridge")
        self.prepare()
        before_home = installer.tree_state(self.home, self.home)
        for failed_step in (0, 1):
            with self.subTest(failed_step=failed_step):
                results = [None] * failed_step + [subprocess.CalledProcessError(
                    1, "/usr/bin/codesign", stderr=b"private diagnostic sentinel")]
                self.sign_bundle.side_effect = self.real_sign_bundle
                with mock.patch.object(installer.subprocess, "run", side_effect=results):
                    with self.assertRaises(installer.InstallError) as failure:
                        self.apply()
                self.assertNotIn("private diagnostic sentinel", str(failure.exception))
                self.assertEqual(installer.tree_state(self.home, self.home), before_home)
                installer.managed_state(self.paths)

    def test_real_hook_generator_uses_installed_paths_and_events(self):
        (self.project / "setup_hooks.py").write_bytes((PROJECT / "setup_hooks.py").read_bytes())
        plan = self.prepare()
        self.assertIn("Notification", plan["settings"][0]["add"]["hooks"])
        claude_hooks = plan["settings"][0]["add"]["hooks"]
        codex_hooks = plan["settings"][1]["add"]["hooks"]
        for event in ("PostToolUseFailure", "PostToolBatch", "StopFailure"):
            self.assertIn(event, claude_hooks)
            self.assertNotIn(event, codex_hooks)
        self.assertIn("Interrupt", codex_hooks)
        self.assertNotIn("Interrupt", claude_hooks)
        for target in plan["settings"]:
            self.assertIn("PreToolUse", target["add"]["hooks"])
            for groups in target["add"]["hooks"].values():
                for group in groups:
                    for hook in group["hooks"]:
                        args = shlex.split(hook["command"])
                        self.assertEqual(args[1], str(self.paths["support"] / "bridge.py"))
                        self.assertEqual(args[args.index("--runtime") + 1], str(self.paths["support"] / ".runtime"))
                        self.assertEqual(args[args.index("--source") + 1], target["source"])

    def test_fresh_source_install_runs_real_bridge_with_its_title_dependency(self):
        for name in ("bridge.py", "session_titles.py"):
            (self.project / name).write_bytes((PROJECT / name).read_bytes())
        self.prepare()
        self.apply()
        installed = self.paths["support"]
        self.assertEqual((installed / "session_titles.py").read_bytes(), (PROJECT / "session_titles.py").read_bytes())
        # Ignore PYTHONPATH/user packages and run away from the source tree, so
        # an omitted sibling module cannot be hidden by the developer checkout.
        result = subprocess.run([sys.executable, "-E", "-s", "-B", str(installed / "bridge.py"), "--help"],
                                cwd=self.home, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("{hook,demo,telemetry}", result.stdout)
        self.assertFalse((installed / "__pycache__").exists())

    def test_install_preserves_settings_and_adds_hooks_with_private_backups(self):
        existing_hook = {"matcher": "Read", "hooks": [{"type": "command", "command": "existing-hook"}]}
        existing = {"apiKey": "keep private", "permissions": {"defaultMode": "plan"},
                    "disableAllHooks": False, "hooks": {"PermissionRequest": [existing_hook],
                    "OtherEvent": [{"hooks": [{"type": "command", "command": "other"}]}]}}
        self.write_settings(self.claude, existing)
        original_bytes = self.claude.read_bytes()
        self.prepare()
        self.apply()
        installed = json.loads(self.claude.read_text())
        for key in ("apiKey", "permissions", "disableAllHooks"):
            self.assertEqual(installed[key], existing[key])
        self.assertEqual(installed["hooks"]["PermissionRequest"][0], existing_hook)
        self.assertEqual(installed["hooks"]["OtherEvent"], existing["hooks"]["OtherEvent"])
        self.assertEqual(len(installed["hooks"]["PermissionRequest"]), 2)
        backup = list(self.claude.parent.glob("settings.json.*.pip-backup"))
        self.assertEqual(len(backup), 1)
        self.assertEqual(backup[0].read_bytes(), original_bytes)
        self.assertEqual(stat.S_IMODE(backup[0].stat().st_mode), 0o600)
        for target in (self.claude, self.codex):
            self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)
        for name in installer.SCRIPT_NAMES:
            self.assertEqual((self.paths["support"] / name).read_bytes(), (self.project / name).read_bytes())
        self.assertEqual(stat.S_IMODE((self.paths["support"] / ".runtime").stat().st_mode), 0o700)
        info = plistlib.loads((self.paths["app"] / "Contents" / "Info.plist").read_bytes())
        self.assertEqual(info["CompanionRuntimePath"], str(self.paths["support"] / ".runtime"))
        self.assertEqual(info["CompanionBridgePath"], str(self.paths["support"] / "chat_bridge.py"))
        self.assertEqual(info["CompanionClaudePath"], str(self.home / ".local" / "bin" / "claude"))
        self.assertNotIn("CompanionDefaultCwd", info)
        self.assertTrue(info["CompanionPythonPath"])
        self.assertTrue(os.access(self.paths["app"] / "Contents" / "MacOS" / "AgentCompanion", os.X_OK))

    def test_reinstall_is_idempotent_and_keeps_runtime(self):
        self.prepare()
        self.apply()
        runtime_file = self.paths["support"] / ".runtime" / "heartbeat.json"
        runtime_file.write_text('{"updatedAt": 1}')
        os.chmod(runtime_file, 0o600)
        before = {path: path.read_bytes() for path in (self.claude, self.codex)}
        self.prepare()
        self.apply()
        for path, data in before.items():
            self.assertEqual(path.read_bytes(), data)
            self.assertEqual(len(json.loads(data)["hooks"]["PermissionRequest"]), 1)
        self.assertEqual(runtime_file.read_text(), '{"updatedAt": 1}')

    def test_local_connection_is_private_stable_and_does_not_export_content(self):
        self.write_settings(self.claude, {"env": {"UNRELATED": "keep"}})
        first = self.prepare()
        connection = first["install"]["telemetry"]
        self.assertEqual(connection["host"], "127.0.0.1")
        self.assertEqual(len(connection["token"]), 64)
        self.assertEqual(self.prepare()["install"]["telemetry"], connection)
        self.assertNotIn(connection["token"], json.dumps(installer.summary(first)))
        self.apply()
        private_config = self.paths["support"] / installer.TELEMETRY_NAME
        self.assertEqual(stat.S_IMODE(private_config.stat().st_mode), 0o600)
        self.assertEqual(json.loads(private_config.read_bytes()), connection)
        env = json.loads(self.claude.read_bytes())["env"]
        self.assertEqual(env["UNRELATED"], "keep")
        self.assertEqual(env["OTEL_EXPORTER_OTLP_LOGS_ENDPOINT"], f"http://127.0.0.1:{connection['port']}/v1/logs")
        self.assertEqual(env["OTEL_EXPORTER_OTLP_LOGS_HEADERS"], "X-Pip-Token=" + connection["token"])
        self.assertEqual(env["OTEL_LOGS_EXPORT_INTERVAL"], "1000")
        for key in ("OTEL_LOG_USER_PROMPTS", "OTEL_LOG_ASSISTANT_RESPONSES", "OTEL_LOG_TOOL_DETAILS",
                    "OTEL_LOG_TOOL_CONTENT", "OTEL_LOG_MANAGED_SETTINGS", "OTEL_LOG_RAW_API_BODIES"):
            self.assertEqual(env[key], "0")
        for key in ("OTEL_METRICS_EXPORTER", "OTEL_TRACES_EXPORTER"):
            self.assertEqual(env[key], "none")
        info = plistlib.loads((self.paths["app"] / "Contents/Info.plist").read_bytes())
        self.assertEqual(info["CompanionTelemetryConfigPath"], str(private_config))
        self.assertEqual(info["CompanionHookBridgePath"], str(self.paths["support"] / "bridge.py"))
        self.assertEqual(self.prepare()["install"]["telemetry"], connection)

    def test_existing_telemetry_is_not_replaced(self):
        existing = [
            {"env": {"OTEL_EXPORTER_OTLP_ENDPOINT": "https://existing-collector.example"}},
            {"env": {"OTEL_LOGS_EXPORTER": "console"}},
            {"env": {"CLAUDE_CODE_ENABLE_TELEMETRY": "0"}},
            {"env": {"ENABLE_ENHANCED_TELEMETRY_BETA": "1"}},
            {"otelHeadersHelper": "existing-helper"},
            {"env": []},
        ]
        for config in existing:
            with self.subTest(config=config):
                self.write_settings(self.claude, config)
                before = self.claude.read_bytes()
                with self.assertRaises(installer.InstallError):
                    self.prepare()
                self.assertEqual(self.claude.read_bytes(), before)
                self.assertFalse(self.paths["support"].exists())
                self.assertFalse(self.paths["plan"].exists())

    def test_connection_plan_rejects_remote_host_and_bad_token(self):
        for key, value in (("host", "0.0.0.0"), ("port", 80), ("port", True),
                           ("token", "short"), ("version", True)):
            with self.subTest(key=key, value=value):
                plan = self.prepare()
                plan["install"]["telemetry"][key] = value
                self.paths["plan"].write_text(json.dumps(plan))
                with self.assertRaises(installer.InstallError):
                    self.apply()
                self.assertFalse(self.paths["app"].exists())
                self.paths["plan"].unlink()

    def test_upgrade_from_original_three_script_installation(self):
        self.prepare()
        self.apply()
        marker_path = self.paths["support"] / installer.MARKER_NAME
        marker = json.loads(marker_path.read_bytes())
        for name in ("telemetry.py", "session_titles.py", installer.TELEMETRY_NAME):
            (self.paths["support"] / name).unlink()
            marker["files"].pop(name)
        installer.atomic_bytes(marker_path, installer.encoded_json(marker))
        settings = json.loads(self.claude.read_bytes())
        settings.pop("env")
        self.claude.write_bytes(installer.encoded_json(settings))
        self.prepare()
        self.apply()
        self.assertTrue((self.paths["support"] / "telemetry.py").is_file())
        self.assertTrue((self.paths["support"] / "session_titles.py").is_file())
        self.assertTrue((self.paths["support"] / installer.TELEMETRY_NAME).is_file())
        installer.managed_state(self.paths)

    def test_modified_or_public_connection_is_not_overwritten(self):
        self.prepare()
        self.apply()
        connection_path = self.paths["support"] / installer.TELEMETRY_NAME
        original = connection_path.read_bytes()
        connection_path.write_bytes(original + b" ")
        with self.assertRaises(installer.InstallError):
            self.prepare()
        connection_path.write_bytes(original)
        os.chmod(connection_path, 0o644)
        with self.assertRaises(installer.InstallError):
            self.prepare()

    def test_exact_command_already_present_is_deduplicated(self):
        initial = self.prepare()
        command = initial["settings"][0]["add"]["hooks"]["PermissionRequest"][0]["hooks"][0]["command"]
        existing = {"hooks": {"PermissionRequest": [{"matcher": "*", "hooks": [
            {"type": "command", "command": command, "timeout": 400}]}]}}
        self.write_settings(self.claude, existing)
        self.prepare()
        self.apply()
        installed = json.loads(self.claude.read_text())
        self.assertEqual(installed["hooks"]["PermissionRequest"], existing["hooks"]["PermissionRequest"])

    def test_settings_changed_after_review_are_rejected_before_install(self):
        self.write_settings(self.claude, {"original": True})
        self.prepare()
        self.write_settings(self.claude, {"changed": True})
        with self.assertRaises(installer.InstallError):
            self.apply()
        self.assertEqual(json.loads(self.claude.read_text()), {"changed": True})
        self.assertFalse(self.paths["support"].exists())
        self.assertFalse(self.paths["app"].exists())
        self.assertEqual(list(self.claude.parent.glob("*.pip-backup")), [])

    def test_target_created_after_review_is_rejected(self):
        self.prepare()
        self.write_settings(self.codex, {})
        with self.assertRaises(installer.InstallError):
            self.apply()
        self.assertFalse(self.paths["app"].exists())

    def test_source_changes_invalidate_plan(self):
        for source in (self.project / "bridge.py", self.project / "chat_bridge.py",
                       self.project / "setup_hooks.py", self.project / "session_titles.py",
                       self.paths["source_app"] / "Contents" / "MacOS" / "AgentCompanion"):
            with self.subTest(source=source.name):
                original = source.read_bytes()
                self.prepare()
                source.write_bytes(original + b"\n# changed\n")
                with self.assertRaises(installer.InstallError):
                    self.apply()
                self.assertFalse(self.paths["app"].exists())
                source.write_bytes(original)

    def test_tampered_plan_commands_are_rejected(self):
        plan = self.prepare()
        plan["settings"][0]["add"]["hooks"]["PermissionRequest"][0]["hooks"][0]["command"] = "different-command"
        self.paths["plan"].write_text(json.dumps(plan))
        with self.assertRaises(installer.InstallError):
            self.apply()
        self.assertFalse(self.claude.exists())

    def test_foreign_project_plan_is_rejected(self):
        plan = self.prepare()
        plan["sources"]["app"] = "/some/other/Pip.app"
        self.paths["plan"].write_text(json.dumps(plan))
        with self.assertRaises(installer.InstallError):
            self.apply()

    def test_plan_must_be_private(self):
        self.prepare()
        os.chmod(self.paths["plan"], 0o644)
        with self.assertRaises(installer.InstallError):
            self.apply()

    def test_invalid_json_and_hook_shapes_fail_without_home_changes(self):
        invalid = ["not json", "[]", '{"hooks":[]}', '{"hooks":{"Stop":{}}}',
                   '{"hooks":{"Stop":[null]}}', '{"hooks":{"Stop":[{"hooks":"bad"}]}}',
                   '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":2}]}]}}']
        self.claude.parent.mkdir()
        for raw in invalid:
            with self.subTest(raw=raw):
                self.claude.write_text(raw)
                with self.assertRaises(installer.InstallError):
                    self.prepare()
                self.assertEqual(self.claude.read_text(), raw)
                self.assertFalse(self.paths["plan"].exists())
                self.assertFalse(self.codex.exists())
                self.assertFalse(self.paths["support"].exists())

    def test_symlinked_settings_are_rejected(self):
        outside = self.root / "outside.json"
        outside.write_text("{}")
        self.claude.parent.mkdir()
        self.claude.symlink_to(outside)
        with self.assertRaises(installer.InstallError):
            self.prepare()
        self.assertEqual(outside.read_text(), "{}")

    def test_symlinked_parent_is_rejected(self):
        outside = self.root / "outside"
        outside.mkdir()
        (self.home / ".codex").symlink_to(outside, target_is_directory=True)
        with self.assertRaises(installer.InstallError):
            self.prepare()

    def test_symlinked_source_is_rejected(self):
        outside = self.root / "outside.py"
        outside.write_text("# outside")
        source = self.project / "bridge.py"
        source.unlink()
        source.symlink_to(outside)
        with self.assertRaises(installer.InstallError):
            self.prepare()

    def test_symlinked_bundle_entry_is_rejected(self):
        (self.paths["source_app"] / "Contents" / "alias").symlink_to(self.project / "bridge.py")
        with self.assertRaises(installer.InstallError):
            self.prepare()

    def test_foreign_owned_paths_are_rejected(self):
        with mock.patch.object(installer.os, "getuid", return_value=os.getuid() + 1000):
            with self.assertRaises(installer.InstallError):
                self.prepare()

    def test_unmanaged_destination_app_or_support_are_rejected(self):
        for target in (self.paths["app"], self.paths["support"]):
            with self.subTest(target=target.name):
                target.mkdir(parents=True)
                (target / "valuable-file").write_text("keep")
                with self.assertRaises(installer.InstallError):
                    self.prepare()
                self.assertEqual((target / "valuable-file").read_text(), "keep")
                (target / "valuable-file").unlink()
                target.rmdir()

    def test_modified_managed_installation_is_not_overwritten(self):
        self.prepare()
        self.apply()
        installed = self.paths["support"] / "bridge.py"
        installed.write_text("# locally changed")
        with self.assertRaises(installer.InstallError):
            self.prepare()
        self.assertEqual(installed.read_text(), "# locally changed")

    def test_managed_app_replaced_by_other_bundle_is_rejected(self):
        self.prepare()
        self.apply()
        installed = self.paths["app"] / "Contents" / "MacOS" / "AgentCompanion"
        installed.write_bytes(b"different app")
        with self.assertRaises(installer.InstallError):
            self.prepare()

    def test_public_runtime_is_rejected(self):
        self.prepare()
        self.apply()
        os.chmod(self.paths["support"] / ".runtime", 0o755)
        with self.assertRaises(installer.InstallError):
            self.prepare()

    def test_python_cache_does_not_block_reinstallation(self):
        self.prepare()
        self.apply()
        cache = self.paths["support"] / "__pycache__"
        cache.mkdir()
        (cache / "bridge.cpython-314.pyc").write_bytes(b"runtime generated cache")
        self.prepare()
        self.apply()
        self.assertEqual((cache / "bridge.cpython-314.pyc").read_bytes(), b"runtime generated cache")

    def test_summary_only_contains_target_paths_and_event_names(self):
        plan = self.prepare()
        summary = json.dumps(installer.summary(plan))
        self.assertIn("PermissionRequest", summary)
        self.assertNotIn("--source", summary)
        self.assertNotIn("sha256", summary)

    def test_failure_rolls_back_new_files_and_app(self):
        self.write_settings(self.claude, {"keep": "existing"})
        original = self.claude.read_bytes()
        self.prepare()
        original_atomic = installer.atomic_bytes

        def fail_codex(path, data, mode=0o600):
            if Path(path) == self.codex:
                raise OSError("simulated write failure")
            return original_atomic(path, data, mode)

        with mock.patch.object(installer, "atomic_bytes", side_effect=fail_codex):
            with self.assertRaises(OSError):
                self.apply()
        self.assertEqual(self.claude.read_bytes(), original)
        self.assertFalse(self.codex.exists())
        self.assertFalse(self.paths["app"].exists())
        self.assertFalse((self.paths["support"] / "bridge.py").exists())
        self.assertFalse((self.paths["support"] / installer.MARKER_NAME).exists())
        self.assertFalse(self.paths["support"].exists())
        self.prepare()
        self.apply()
        self.assertTrue(self.paths["app"].exists())
        self.assertTrue((self.paths["support"] / installer.MARKER_NAME).exists())

    def test_failure_cleanup_preserves_existing_parent_directories(self):
        self.paths["app"].parent.mkdir(parents=True)
        (self.home / "Library" / "Application Support").mkdir(parents=True)
        self.codex.parent.mkdir()
        (self.codex.parent / "keep-file").write_text("preserve this directory")
        self.prepare()
        original_atomic = installer.atomic_bytes

        def fail_codex(path, data, mode=0o600):
            if Path(path) == self.codex:
                raise OSError("simulated write failure")
            return original_atomic(path, data, mode)

        with mock.patch.object(installer, "atomic_bytes", side_effect=fail_codex):
            with self.assertRaises(OSError):
                self.apply()
        self.assertTrue(self.paths["app"].parent.exists())
        self.assertTrue((self.home / "Library" / "Application Support").exists())
        self.assertEqual((self.codex.parent / "keep-file").read_text(), "preserve this directory")
        self.assertFalse(self.paths["support"].exists())

    def test_failure_rolls_back_existing_managed_installation(self):
        self.prepare()
        self.apply()
        before_app = installer.tree_state(self.paths["app"], self.home)
        before_support = installer.tree_state(self.paths["support"], self.home, exclusions=(".runtime",))
        before_settings = self.claude.read_bytes()
        (self.project / "bridge.py").write_text("# updated bridge")
        self.prepare()
        original_atomic = installer.atomic_bytes

        def fail_codex(path, data, mode=0o600):
            if Path(path) == self.codex:
                raise OSError("simulated write failure")
            return original_atomic(path, data, mode)

        with mock.patch.object(installer, "atomic_bytes", side_effect=fail_codex):
            with self.assertRaises(OSError):
                self.apply()
        self.assertEqual(installer.tree_state(self.paths["app"], self.home), before_app)
        self.assertEqual(installer.tree_state(self.paths["support"], self.home, exclusions=(".runtime",)), before_support)
        self.assertEqual(self.claude.read_bytes(), before_settings)


class BundleSigningTests(unittest.TestCase):
    def test_signs_and_strictly_verifies_the_entire_bundle_without_shell_or_output(self):
        bundle = Path("/private/tmp/Pip signing fixture/Pip.app")
        with mock.patch.object(installer.subprocess, "run") as runner:
            installer.sign_bundle(bundle)
        options = {"check": True, "shell": False, "timeout": 30,
                   "stdin": subprocess.DEVNULL, "stdout": subprocess.DEVNULL,
                   "stderr": subprocess.DEVNULL}
        self.assertEqual(runner.call_args_list, [
            mock.call(["/usr/bin/codesign", "--force", "--sign", "-", "--identifier",
                       "dev.local.agent-companion", str(bundle)], **options),
            mock.call(["/usr/bin/codesign", "--verify", "--strict", str(bundle)], **options),
        ])

    def test_signing_failure_never_runs_verification_or_exposes_diagnostics(self):
        error = subprocess.CalledProcessError(1, "/usr/bin/codesign",
                                             output=b"private output", stderr=b"private error")
        with mock.patch.object(installer.subprocess, "run", side_effect=error) as runner:
            with self.assertRaises(installer.InstallError) as failure:
                installer.sign_bundle(Path("/private/tmp/Pip.app"))
        runner.assert_called_once()
        self.assertNotIn("private output", str(failure.exception))
        self.assertNotIn("private error", str(failure.exception))

    def test_timeout_and_unavailable_signer_fail_with_a_safe_message(self):
        errors = [subprocess.TimeoutExpired("/usr/bin/codesign", 30, output=b"private timeout"),
                  FileNotFoundError("private executable detail")]
        for error in errors:
            with self.subTest(error=type(error).__name__):
                with mock.patch.object(installer.subprocess, "run", side_effect=error):
                    with self.assertRaises(installer.InstallError) as failure:
                        installer.sign_bundle(Path("/private/tmp/Pip.app"))
                self.assertEqual(str(failure.exception),
                                 "Pip bundle signing or verification failed; no installation changes were made")


if __name__ == "__main__":
    unittest.main()
