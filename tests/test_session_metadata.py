import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import bridge


class SessionMetadataTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="pip-session-metadata-")
        self.addCleanup(temporary.cleanup)
        self.root = bridge.runtime_directory(temporary.name)
        environment = patch.dict(os.environ, {}, clear=True)
        environment.start()
        self.addCleanup(environment.stop)
        probe = patch.object(bridge, "terminal_process_context", return_value=None)
        self.terminal_probe = probe.start()
        self.addCleanup(probe.stop)

    def event(self, **fields):
        return {"hook_event_name": "PreToolUse", "session_id": "session-one", **fields}

    def cache(self, source="claude", session="session-one", **fields):
        bridge.write_json(bridge.session_path(self.root, source, session),
                          {"source": source, "sessionId": session, **fields})

    def test_explicit_name_fields_are_bounded_plain_text(self):
        for field in bridge.SESSION_NAME_FIELDS:
            with self.subTest(field=field):
                result = bridge.session_metadata(self.root, "claude", self.event(
                    **{field: "  Checkout\n  review\t\u202e \x00session  "}))
                self.assertEqual(result, {"sessionName": "Checkout review session"})
        self.assertEqual(bridge.session_metadata(self.root, "claude", self.event(
            session_title="Actual title", session_name="Secondary name")), {"sessionName": "Actual title"})

    def test_invalid_or_oversized_names_are_omitted(self):
        for value in (None, True, 42, [], {}, "", " \n\t", "\x00\u202e", "x" * 513,
                      "é" * 257, "\ud800"):
            with self.subTest(type=type(value).__name__):
                self.assertEqual(bridge.session_metadata(self.root, "claude", self.event(session_title=value)), {})
        self.assertEqual(bridge.session_metadata(self.root, "claude", self.event(
            session_title="é" * 256)), {"sessionName": "é" * 256})

    def test_name_inherits_only_the_same_source_and_session(self):
        self.cache(sessionName="Checkout changes")
        self.assertEqual(bridge.session_metadata(self.root, "claude", self.event()),
                         {"sessionName": "Checkout changes"})
        self.assertEqual(bridge.session_metadata(self.root, "codex", self.event()), {})
        self.assertEqual(bridge.session_metadata(self.root, "claude", self.event(session_id="session-two")), {})
        self.assertEqual(bridge.session_metadata(self.root, "claude", self.event(session_title="New name")),
                         {"sessionName": "New name"})

    def test_misplaced_or_invalid_cached_metadata_is_not_used(self):
        for previous in ([], {"source": "codex", "sessionId": "session-one", "sessionName": "Wrong source"},
                         {"source": "claude", "sessionId": "session-two", "sessionName": "Wrong session"},
                         {"source": "claude", "sessionId": "session-one", "sessionName": "x" * 513}):
            with self.subTest(previous=type(previous).__name__):
                self.assertEqual(bridge.session_metadata(self.root, "claude", self.event(), previous), {})

    def test_unknown_session_cannot_share_a_cached_name(self):
        self.cache(session="unknown", sessionName="Unscoped name")
        for value in (None, "", "unknown", " UNKNOWN ", 1, "x" * 1025):
            with self.subTest(value=type(value).__name__):
                self.assertEqual(bridge.session_metadata(self.root, "claude", self.event(
                    session_id=value, session_title="No owner")), {})

    def test_no_prompt_message_or_transcript_is_used_as_a_title(self):
        outside = self.root / "private-transcript.jsonl"
        outside.write_text(json.dumps({"type": "custom-title", "customTitle": "Do not read this"}) + "\n")
        linked = self.root / "linked-transcript.jsonl"
        linked.symlink_to(outside)
        result = bridge.session_metadata(self.root, "claude", self.event(
            prompt="Private prompt", last_assistant_message="Private reply", transcript_path=str(linked),
            cwd="/private/project", summary="Private summary"))
        self.assertEqual(result, {})
        bridge.session_state(self.root, "claude", self.event(
            prompt="Private prompt", last_assistant_message="Private reply", transcript_path=str(outside)), "working")
        state = bridge.read_json(bridge.session_path(self.root, "claude", "session-one"))
        encoded = json.dumps(state)
        for text in ("Private prompt", "Private reply", "Do not read this", "transcript_path"):
            self.assertNotIn(text, encoded)

    def test_unsafe_ipc_cache_is_ignored(self):
        path = bridge.session_path(self.root, "claude", "session-one")
        outside = self.root / "external.json"
        bridge.write_json(outside, {"source": "claude", "sessionId": "session-one", "sessionName": "Linked name"})
        path.symlink_to(outside)
        self.assertEqual(bridge.session_metadata(self.root, "claude", self.event()), {})
        path.unlink()
        bridge.write_json(path, {"source": "claude", "sessionId": "session-one", "sessionName": "Public name"})
        path.chmod(0o644)
        self.assertEqual(bridge.session_metadata(self.root, "claude", self.event()), {})

    def test_only_recognized_source_specific_host_enums_are_forwarded(self):
        for source, expected in (("claude", "claude-vscode"), ("vscode", "claude-vscode"),
                                 ("codex", "codex-desktop"), ("codex", "codex-vscode"),
                                 ("claude", "apple-terminal"), ("codex", "vscode-terminal")):
            with self.subTest(source=source, expected=expected):
                self.assertEqual(bridge.session_metadata(self.root, source, self.event(session_host=expected)),
                                 {"sessionHost": expected})
        for source, host in (("claude", "codex-desktop"), ("codex", "claude-vscode"),
                             ("chatgpt-work", "codex-desktop"), ("claude", "https://example.test"),
                             ("codex", ["codex-desktop"])):
            with self.subTest(source=source):
                self.assertEqual(bridge.session_metadata(self.root, source, self.event(sessionHost=host)), {})

    def test_known_host_environment_distinguishes_extensions_from_integrated_terminals(self):
        cases = [("claude", "CLAUDE_CODE_ENTRYPOINT", "claude-vscode", "claude-vscode"),
                 ("codex", "CODEX_INTERNAL_ORIGINATOR_OVERRIDE", "Codex Desktop", "codex-desktop"),
                 ("codex", "CODEX_INTERNAL_ORIGINATOR_OVERRIDE", "codex_vscode", "codex-vscode")]
        for source, key, value, expected in cases:
            with self.subTest(source=source, value=value), patch.dict(os.environ, {key: value}, clear=True):
                self.assertEqual(bridge.session_metadata(self.root, source, self.event()), {"sessionHost": expected})
        with patch.dict(os.environ, {"TERM_PROGRAM": "vscode"}, clear=True):
            self.assertEqual(bridge.session_metadata(self.root, "claude", self.event()), {"sessionHost": "vscode-terminal"})
        self.assertEqual(bridge.session_metadata(self.root, "vscode", self.event()), {})

    def test_missing_unknown_or_work_cloud_origin_never_inherits_cached_host(self):
        self.cache(sessionName="Known title", sessionHost="claude-vscode")
        self.assertEqual(bridge.session_metadata(self.root, "claude", self.event()), {"sessionName": "Known title"})
        with patch.dict(os.environ, {"CLAUDE_CODE_ENTRYPOINT": "cli"}, clear=True):
            self.assertEqual(bridge.session_metadata(self.root, "claude", self.event()), {"sessionName": "Known title"})
        self.cache(source="codex", sessionHost="codex-desktop")
        with patch.dict(os.environ, {"CODEX_INTERNAL_ORIGINATOR_OVERRIDE": "codex_work_desktop"}, clear=True):
            self.assertEqual(bridge.session_metadata(self.root, "codex", self.event()), {})

    def test_session_state_preserves_title_but_refreshes_current_host(self):
        with patch.dict(os.environ, {"CLAUDE_CODE_ENTRYPOINT": "claude-vscode"}, clear=True):
            bridge.session_state(self.root, "claude", self.event(session_title="Checkout fix"), "working")
        state = bridge.read_json(bridge.session_path(self.root, "claude", "session-one"))
        self.assertEqual((state["sessionName"], state["sessionHost"]), ("Checkout fix", "claude-vscode"))
        bridge.session_state(self.root, "claude", self.event(hook_event_name="Stop"), "idle")
        state = bridge.read_json(bridge.session_path(self.root, "claude", "session-one"))
        self.assertEqual(state["sessionName"], "Checkout fix")
        self.assertNotIn("sessionHost", state)

    def test_terminal_host_probes_current_ancestry_and_ignores_event_ids(self):
        captured = {"processIds": [900, 800, 700], "tty": "/dev/ttys003",
                    "originPid": 800, "originStartTime": "Wed Oct 28 12:00:00 2026"}
        self.terminal_probe.return_value = captured
        key = "12345678-1234-4234-8234-123456789abc"
        with patch.dict(os.environ, {"TERM_PROGRAM": "vscode", "PIP_VSCODE_WINDOW_KEY": key}, clear=True):
            result = bridge.session_metadata(self.root, "claude", self.event(
                sessionTerminal={"processIds": [999], "tty": "/dev/ttys999"}, sessionWindowKey="forged"))
        self.assertEqual(result, {"sessionHost": "vscode-terminal", "sessionWindowKey": key,
                                  "sessionTerminal": captured})
        self.terminal_probe.assert_called_once_with(source="claude")

    def test_extension_and_desktop_origins_take_precedence_without_terminal_probe(self):
        for source, env, expected in (
            ("claude", {"CLAUDE_CODE_ENTRYPOINT": "claude-vscode", "TERM_PROGRAM": "Apple_Terminal"}, "claude-vscode"),
            ("codex", {"CODEX_INTERNAL_ORIGINATOR_OVERRIDE": "Codex Desktop", "TERM_PROGRAM": "vscode"}, "codex-desktop"),
            ("codex", {"CODEX_INTERNAL_ORIGINATOR_OVERRIDE": "codex_vscode", "TERM_PROGRAM": "vscode"}, "codex-vscode"),
        ):
            with self.subTest(expected=expected), patch.dict(os.environ, env, clear=True):
                self.assertEqual(bridge.session_metadata(self.root, source, self.event()), {"sessionHost": expected})
        self.terminal_probe.assert_not_called()

    def test_work_cloud_and_unknown_terminal_apps_never_probe_or_use_a_window_key(self):
        key = "12345678-1234-4234-8234-123456789abc"
        for source, env in (
            ("codex", {"CODEX_INTERNAL_ORIGINATOR_OVERRIDE": "codex_work_desktop", "TERM_PROGRAM": "vscode"}),
            ("chatgpt-work", {"TERM_PROGRAM": "vscode"}),
            ("claude", {"TERM_PROGRAM": "iTerm.app"}),
        ):
            with self.subTest(source=source), patch.dict(os.environ, {**env, "PIP_VSCODE_WINDOW_KEY": key}, clear=True):
                self.assertEqual(bridge.session_metadata(self.root, source, self.event()), {})
        self.terminal_probe.assert_not_called()

    def test_window_key_is_only_a_fresh_canonical_uuid_from_vscode_environment(self):
        key = "12345678-1234-4234-8234-123456789abc"
        with patch.dict(os.environ, {"PIP_VSCODE_WINDOW_KEY": key.upper()}, clear=True):
            self.assertEqual(bridge.session_metadata(self.root, "claude", self.event(sessionHost="claude-vscode")),
                             {"sessionHost": "claude-vscode", "sessionWindowKey": key})
        for value in ("", "not-a-uuid", key + "/extra", " " + key, "https://example.test", "x" * 1024):
            with self.subTest(value=value[:20]), patch.dict(os.environ, {"PIP_VSCODE_WINDOW_KEY": value}, clear=True):
                self.assertEqual(bridge.session_metadata(self.root, "claude", self.event(sessionHost="claude-vscode")),
                                 {"sessionHost": "claude-vscode"})
        self.cache(sessionWindowKey=key, sessionTerminal={"processIds": [123]})
        self.assertEqual(bridge.session_metadata(self.root, "claude", self.event(
            sessionHost="claude-vscode", sessionWindowKey=key)), {"sessionHost": "claude-vscode"})
        with patch.dict(os.environ, {"PIP_VSCODE_WINDOW_KEY": key, "TERM_PROGRAM": "Apple_Terminal"}, clear=True):
            self.assertEqual(bridge.session_metadata(self.root, "claude", self.event()), {"sessionHost": "apple-terminal"})

    def test_terminal_identity_sanitization_rejects_invalid_ids_and_unrelated_origins(self):
        for ids in ([], [True], [0], [1], [-1], [2_147_483_648], [10, 10], list(range(10, 20)), [[10]]):
            with self.subTest(ids=ids):
                self.assertIsNone(bridge.validated_terminal_context({"processIds": ids, "tty": "/dev/ttys001"}))
        self.assertEqual(bridge.validated_terminal_context({"processIds": [10], "tty": "/dev/ttys002;evil",
            "originPid": 10, "originStartTime": "Wed Oct 28 12:00:00 2026"}), {"processIds": [10]})
        self.assertEqual(bridge.validated_terminal_context({"processIds": [10], "tty": "/dev/ttys002",
            "originPid": 11, "originStartTime": "Wed Oct 28 12:00:00 2026"}),
            {"processIds": [10], "tty": "/dev/ttys002"})

    def test_all_request_kinds_include_title_and_current_host_without_changing_correlation(self):
        bridge.write_json(self.root / "heartbeat.json", {"updatedAt": time.time()})
        event = self.event(session_title="Checkout fix", session_host="claude-vscode", tool_name="Bash",
                           tool_use_id="tool-one", tool_input={"command": "example", "description": "Example action"})
        captured = []
        def wait(root, source, supplied, request, timeout, accepted):
            captured.append(request)
            return None
        with patch.object(bridge, "wait_for_response", side_effect=wait):
            bridge.permission_request(self.root, "claude", event)
            question = {**event, "tool_name": "AskUserQuestion", "tool_input": {"questions": [
                {"question": "Which?", "options": [{"label": "One"}, {"label": "Two"}]}]}}
            bridge.question_request(self.root, "claude", question)
        for supplied, request in zip((event, question), captured):
            self.assertEqual(request["sessionName"], "Checkout fix")
            self.assertEqual(request["sessionHost"], "claude-vscode")
            self.assertEqual(request["correlation"], bridge.correlation(supplied))

        notice = self.event(session_title="Codex task", session_host="codex-desktop", tool_name="request_user_input",
                            tool_input={"questions": []})
        bridge.codex_question_notice(self.root, "codex", notice)
        alert = {**event, "hook_event_name": "Notification", "notification_type": "permission_prompt",
                 "title": "Permission needed", "message": "Example alert"}
        bridge.permission_notification(self.root, "claude", alert)
        requests = [bridge.read_json(p) for p in (self.root / "requests").glob("*.json")]
        self.assertEqual(len(requests), 2)
        self.assertEqual({(r["sessionName"], r["sessionHost"]) for r in requests},
                         {("Codex task", "codex-desktop"), ("Checkout fix", "claude-vscode")})
        self.assertTrue(all(r["canRespond"] is False for r in requests))

    def test_real_hook_round_trip_keeps_metadata_out_of_the_approval_response(self):
        self.cache(sessionName="A renamed session")
        bridge.write_json(self.root / "heartbeat.json", {"updatedAt": time.time()})
        event = self.event(hook_event_name="PermissionRequest", tool_name="Bash", tool_use_id="call-one",
                           tool_input={"command": "example", "description": "Example action"})
        process = subprocess.Popen([sys.executable, str(bridge.PROJECT / "bridge.py"), "hook", "--source", "claude",
                                    "--runtime", str(self.root), "--wait", "2"],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                   env={"CLAUDE_CODE_ENTRYPOINT": "claude-vscode"})
        try:
            process.stdin.write(json.dumps(event))
            process.stdin.close()
            process.stdin = None
            deadline = time.monotonic() + 2
            paths = []
            while time.monotonic() < deadline:
                paths = list((self.root / "requests").glob("*.json"))
                if paths:
                    break
                time.sleep(0.01)
            self.assertEqual(len(paths), 1)
            request = bridge.read_json(paths[0])
            self.assertEqual(request["sessionName"], "A renamed session")
            self.assertEqual(request["sessionHost"], "claude-vscode")
            self.assertEqual(request["correlation"], bridge.correlation(event))
            bridge.write_json(self.root / "decisions" / paths[0].name,
                              {"id": request["id"], "decision": "allow", "decidedAt": time.time()})
            stdout, stderr = process.communicate(timeout=3)
            self.assertEqual(process.returncode, 0, stderr)
            self.assertEqual(json.loads(stdout), {"hookSpecificOutput": {
                "hookEventName": "PermissionRequest", "decision": {"behavior": "allow"}}})
        finally:
            if process.poll() is None:
                process.terminate()
                process.communicate(timeout=3)


class TerminalProcessContextTests(unittest.TestCase):
    def setUp(self):
        platform = patch.object(bridge.sys, "platform", "darwin")
        platform.start()
        self.addCleanup(platform.stop)
        self.calls = []

    def probe(self, rows, source="claude", clock=lambda: 0, current_pid=900):
        def runner(argv, **kwargs):
            self.calls.append((argv, kwargs))
            self.assertEqual(argv[:2], ["/bin/ps", "-p"])
            self.assertEqual(argv[3:], ["-o", "pid=,ppid=,tty=,lstart=,comm="])
            self.assertEqual(kwargs["env"], {"PATH": "/usr/bin:/bin", "LC_ALL": "C"})
            self.assertGreater(kwargs["timeout"], 0)
            self.assertLessEqual(kwargs["timeout"], 0.1)
            value = rows[int(argv[2])]
            if isinstance(value, Exception):
                raise value
            return SimpleNamespace(returncode=0, stdout=value)
        return bridge.terminal_process_context(source=source, run_process=runner, current_pid=current_pid, clock=clock)

    @staticmethod
    def row(pid, parent, executable, tty="ttys003", start="Wed Oct 28 12:00:00 2026"):
        return f"  {pid} {parent} {tty} {start} {executable}\n"

    def test_captures_ancestry_and_provider_start_without_shell_or_helper_origin(self):
        rows = {900: self.row(900, 800, "/Applications/Pip.app/Contents/MacOS/PipHelper"),
                800: self.row(800, 700, "/bin/sh"),
                700: self.row(700, 600, "/usr/bin/python3"),
                600: self.row(600, 500, "/Users/example/.local/share/claude/versions/2.1.312"),
                500: self.row(500, 1, "/bin/zsh")}
        self.assertEqual(self.probe(rows), {"processIds": [900, 800, 700, 600, 500], "tty": "/dev/ttys003",
            "originPid": 600, "originStartTime": "Wed Oct 28 12:00:00 2026"})
        self.assertEqual(len(self.calls), 5)

    def test_codex_binary_is_preferred_over_wrappers(self):
        rows = {900: self.row(900, 800, "/tmp/PipHelper"),
                800: self.row(800, 700, "/Users/example/Library/Application Support/Code/extensions/openai/codex"),
                700: self.row(700, 1, "/bin/zsh")}
        self.assertEqual(self.probe(rows, source="codex")["originPid"], 800)

    def test_strong_provider_takes_precedence_over_closest_node_runtime(self):
        rows = {900: self.row(900, 800, "/tmp/PipHelper"),
                800: self.row(800, 700, "/opt/bin/node"),
                700: self.row(700, 600, "/opt/bin/claude"),
                600: self.row(600, 1, "/bin/zsh")}
        self.assertEqual(self.probe(rows)["originPid"], 700)

    def test_claude_can_use_the_nearest_node_or_bun_runtime_only(self):
        rows = {900: self.row(900, 800, "/tmp/PipHelper"),
                800: self.row(800, 700, "/opt/bin/bun"),
                700: self.row(700, 600, "/opt/bin/node"),
                600: self.row(600, 1, "/bin/zsh")}
        self.assertEqual(self.probe(rows)["originPid"], 800)
        self.assertNotIn("originPid", self.probe(rows, source="codex"))

    def test_ambiguous_tty_or_bad_start_omits_the_origin_pair(self):
        for tty, start in (("ttys004", "Wed Oct 28 12:00:00 2026"),
                           ("ttys003", "not a process start date"),
                           ("ttys003", "Thu Oct 28 12:00:00 2026")):
            with self.subTest(tty=tty, start=start):
                rows = {900: self.row(900, 800, "/tmp/PipHelper"),
                        800: self.row(800, 1, "/usr/bin/claude", tty=tty, start=start)}
                self.assertNotIn("originPid", self.probe(rows))
        rows = {900: self.row(900, 1, "/opt/bin/claude")}
        self.assertNotIn("originPid", self.probe(rows), "The short-lived hook process cannot be its own provider origin")

    def test_no_controlling_tty_still_captures_ids_without_terminal_origin(self):
        rows = {900: self.row(900, 800, "/tmp/PipHelper", tty="??"),
                800: self.row(800, 1, "/opt/bin/claude", tty="??")}
        self.assertEqual(self.probe(rows), {"processIds": [900, 800]})

    def test_depth_cycle_and_time_budget_are_bounded(self):
        rows = {pid: self.row(pid, pid - 1, "/bin/sh") for pid in range(880, 901)}
        self.assertEqual(len(self.probe(rows)["processIds"]), 9)
        self.assertEqual(len(self.calls), 9)
        self.calls.clear()
        rows = {900: self.row(900, 800, "/tmp/PipHelper"), 800: self.row(800, 900, "/bin/sh")}
        self.assertEqual(self.probe(rows)["processIds"], [900, 800])
        self.assertEqual(len(self.calls), 2)
        self.calls.clear()
        times = iter([0, 0, 0.3])
        self.assertEqual(self.probe(rows, clock=lambda: next(times))["processIds"], [900])
        self.assertEqual(len(self.calls), 1)

    def test_invalid_rows_fail_closed_and_ps_timeout_is_optional(self):
        for row in ("", "900 1 ttys003", "901 1 ttys003 Wed Oct 28 12:00:00 2026 /bin/zsh", "x" * 2049,
                    subprocess.TimeoutExpired("/bin/ps", 0.1), PermissionError("restricted")):
            with self.subTest(row=type(row).__name__):
                self.assertIsNone(self.probe({900: row}))
        for pid in (0, 1, -1, True, 2_147_483_648):
            with self.subTest(pid=pid):
                self.assertIsNone(self.probe({}, current_pid=pid))

    def test_start_time_and_tty_validation_use_strict_c_format(self):
        self.assertEqual(bridge.process_start_time("Wed Oct  7 12:00:00 2026"), "Wed Oct 7 12:00:00 2026")
        for value in ("Wed Oct 32 12:00:00 2026", "Wed Oct 28 25:00:00 2026", "Wed Oct 28 12:00:00 26",
                      "Wed Oct 28 12:00:00 2026;evil", "x" * 65, None):
            with self.subTest(value=value):
                self.assertIsNone(bridge.process_start_time(value))
        for value in ("/dev/ttys0", "/dev/ttys9999", "ttys003"):
            self.assertIsNotNone(bridge.terminal_tty(value))
        for value in ("/dev/tty", "/dev/ttyS0", "/dev/ttys00000", "/tmp/ttys003", "/dev/ttys003\n"):
            self.assertIsNone(bridge.terminal_tty(value))


if __name__ == "__main__":
    unittest.main()
