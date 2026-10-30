import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
import uuid

import chat_bridge


ROOT = Path(__file__).resolve().parents[1]
SESSION = "0199a213-81c0-7800-8aa1-bbab2a035a53"
WORKSPACE = "696d8861-d32f-4c77-8942-b0f334e40f08"


class ChatAdapterTests(unittest.TestCase):
    def adapter(self, provider, session=None):
        events = []
        return chat_bridge.StreamAdapter(provider, session, events.append), events

    def test_claude_partial_snapshot_result_are_not_duplicated(self):
        adapter, events = self.adapter("claude", SESSION)
        frames = [
            {"type": "system", "subtype": "init", "session_id": SESSION},
            {"type": "stream_event", "event": {"type": "message_start", "message": {"id": "msg_1"}}},
            {"type": "stream_event", "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": "Hello "}}},
            {"type": "stream_event", "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": "world"}}},
            {"type": "assistant", "message": {"id": "msg_1", "content": [{"type": "text", "text": "Hello world"}]}},
            {"type": "result", "subtype": "success", "is_error": False, "session_id": SESSION, "result": "Hello world"},
        ]
        for frame in frames:
            adapter.consume(frame)
        self.assertEqual("".join(e["text"] for e in events), "Hello world")
        self.assertTrue(adapter.completed)

    def test_claude_missing_message_start_and_subagent_text(self):
        adapter, events = self.adapter("claude", SESSION)
        adapter.consume({"type": "stream_event", "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": "Main"}}})
        adapter.consume({"type": "assistant", "message": {"id": "actual", "content": [{"type": "text", "text": "Main"}]}})
        adapter.consume({"type": "assistant", "parent_tool_use_id": "subagent", "message": {"id": "other", "content": [{"type": "text", "text": "Hidden"}]}})
        adapter.consume({"type": "result", "subtype": "success", "result": "Main"})
        self.assertEqual(events, [{"type": "delta", "text": "Main"}])

    def test_claude_multiple_messages_and_result_only(self):
        adapter, events = self.adapter("claude", SESSION)
        for ident, text in (("one", "Checking"), ("two", "Done")):
            adapter.consume({"type": "assistant", "message": {"id": ident, "content": [{"type": "text", "text": text}]}})
        adapter.consume({"type": "result", "subtype": "success", "result": "Done"})
        self.assertEqual("".join(e["text"] for e in events), "Checking\n\nDone")
        only, output = self.adapter("claude", SESSION)
        only.consume({"type": "result", "subtype": "success", "result": "Final only"})
        self.assertEqual(output, [{"type": "delta", "text": "Final only"}])

    def test_codex_snapshots_ignore_tool_output(self):
        adapter, events = self.adapter("codex")
        adapter.consume({"type": "thread.started", "thread_id": SESSION})
        adapter.consume({"type": "item.completed", "item": {"id": "tool", "type": "command_execution", "aggregated_output": "private tool output"}})
        for text in ("", "Hel", "Hello", "Hello"):
            adapter.consume({"type": "item.updated", "item": {"id": "item_1", "type": "agent_message", "text": text}})
        adapter.consume({"type": "turn.completed"})
        self.assertEqual("".join(e["text"] for e in events), "Hello")
        self.assertEqual(adapter.session_id, SESSION)

    def test_session_identity_cannot_change(self):
        for provider in ("claude", "codex"):
            adapter, _ = self.adapter(provider, SESSION)
            with self.assertRaises(chat_bridge.ChatError):
                adapter.identity(str(uuid.uuid4()))

    def test_invalid_frames_and_conflicting_snapshots_fail(self):
        adapter, _ = self.adapter("codex")
        for invalid in ([], {}, {"type": 5}):
            with self.assertRaises(chat_bridge.ChatError):
                adapter.consume(invalid)
        adapter.consume({"type": "item.updated", "item": {"id": "one", "type": "agent_message", "text": "Hi"}})
        with self.assertRaises(chat_bridge.ChatError):
            adapter.consume({"type": "item.completed", "item": {"id": "one", "type": "agent_message", "text": "Different"}})

    def test_structured_vendor_errors_preserve_useful_details(self):
        for provider, frame, expected in (
            ("claude", {"type": "result", "subtype": "error_during_execution", "is_error": True, "errors": ["Tool permission was denied."]}, "Tool permission was denied."),
            ("codex", {"type": "turn.failed", "error": {"message": "Usage limit reached; retry after 12:00."}}, "Usage limit reached; retry after 12:00."),
        ):
            adapter, _ = self.adapter(provider)
            with self.assertRaises(chat_bridge.ChatError) as caught:
                adapter.consume(frame)
            self.assertIn(expected, str(caught.exception))

    def test_invalid_claude_message_identifier_is_a_protocol_error(self):
        adapter, _ = self.adapter("claude", SESSION)
        with self.assertRaises(chat_bridge.ChatError):
            adapter.consume({"type": "assistant", "message": {"id": [], "content": []}})


class ChatProcessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="companion-chat-")
        self.folder = Path(self.temp.name)
        self.capture = self.folder / "capture.json"
        self.binary = self.folder / "fake agent cli"

    def tearDown(self):
        self.temp.cleanup()

    def fake(self, body):
        self.binary.write_text(
            f"#!{sys.executable}\n"
            "import json, os, pathlib, signal, subprocess, sys, time\n"
            "prompt = sys.stdin.read()\n"
            f"pathlib.Path({str(self.capture)!r}).write_text(json.dumps({{'argv':sys.argv[1:],'prompt':prompt,'cwd':os.getcwd()}}))\n"
            "def send(frame):\n"
            "    print(json.dumps(frame), flush=True)\n" + body,
            encoding="utf-8",
        )
        self.binary.chmod(0o700)

    def args(self, provider="codex", extra=()):
        return [sys.executable, "-B", str(ROOT / "chat_bridge.py"), "--provider", provider, "--cwd", str(self.folder), f"--{provider}-path", str(self.binary), *extra]

    def run_bridge(self, provider="codex", message="Hello", extra=()):
        result = subprocess.run(self.args(provider, extra), input=json.dumps({"message": message}), capture_output=True, text=True, timeout=8)
        return result, [json.loads(line) for line in result.stdout.splitlines()]

    def neutral_args(self, provider="codex", workspace_id=WORKSPACE, workspace_root=None, extra=()):
        workspace_root = workspace_root if workspace_root is not None else self.folder.resolve() / "neutral workspaces"
        return [sys.executable, "-B", str(ROOT / "chat_bridge.py"), "--provider", provider,
                "--workspace-root", str(workspace_root), "--workspace-id", workspace_id,
                f"--{provider}-path", str(self.binary), *extra]

    def run_neutral(self, provider="codex", message="Hello", workspace_id=WORKSPACE, extra=(), cwd=None):
        result = subprocess.run(self.neutral_args(provider, workspace_id, extra=extra),
                                input=json.dumps({"message": message}), capture_output=True, text=True, timeout=8, cwd=cwd)
        return result, [json.loads(line) for line in result.stdout.splitlines()]

    def claude_success(self):
        self.fake("args=sys.argv[1:]\nsid=args[args.index('--resume')+1] if '--resume' in args else args[args.index('--session-id')+1]\nsend({'type':'system','subtype':'init','session_id':sid})\nsend({'type':'result','subtype':'success','is_error':False,'session_id':sid,'result':'Answer'})\n")

    def codex_success(self):
        self.fake(f"send({{'type':'thread.started','thread_id':{SESSION!r}}})\nsend({{'type':'item.completed','item':{{'id':'one','type':'agent_message','text':'Answer'}}}})\nsend({{'type':'turn.completed'}})\n")

    def test_codex_new_chat_uses_stdin_and_safe_policy_without_shell(self):
        self.codex_success()
        marker = self.folder / "must-not-exist"
        message = f"$(touch {marker}) ; --dangerously-bypass-approvals-and-sandbox"
        result, events = self.run_bridge(message=message)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(events[-1], {"type": "complete", "sessionId": SESSION})
        capture = json.loads(self.capture.read_text())
        self.assertEqual(capture["prompt"], message + "\n")
        self.assertEqual(capture["cwd"], str(self.folder.resolve()))
        self.assertEqual(capture["argv"], ["exec", "--sandbox", "read-only", "-c", 'approval_policy="on-request"', "--json", "-"])
        self.assertFalse(marker.exists())

    def test_codex_resume_only_explicit_pet_session(self):
        self.codex_success()
        result, events = self.run_bridge(extra=("--session", SESSION, "--sandbox", "workspace-write"))
        self.assertEqual(result.returncode, 0)
        args = json.loads(self.capture.read_text())["argv"]
        self.assertEqual(args[-4:], ["resume", "--json", SESSION, "-"])
        self.assertNotIn("--last", args)
        self.assertNotIn("--dangerously-bypass-hook-trust", args)
        self.assertEqual(events[-1]["sessionId"], SESSION)

    def test_claude_new_uuid_and_resume_do_not_attach_other_sessions(self):
        self.claude_success()
        result, events = self.run_bridge("claude")
        self.assertEqual(result.returncode, 0)
        own_session = events[-1]["sessionId"]
        uuid.UUID(own_session)
        first = json.loads(self.capture.read_text())["argv"]
        self.assertIn("--include-partial-messages", first)
        self.assertEqual(first[first.index("--permission-mode") + 1], "manual")
        result, events = self.run_bridge("claude", extra=("--session", own_session))
        self.assertEqual(result.returncode, 0)
        second = json.loads(self.capture.read_text())["argv"]
        self.assertEqual(second[-2:], ["--resume", own_session])
        self.assertNotIn("--session-id", second)
        self.assertEqual(events[-1]["sessionId"], own_session)

    def test_neutral_codex_chat_uses_private_workspace_instead_of_launching_project(self):
        self.codex_success()
        project = self.folder / "old project"
        project.mkdir(mode=0o700)
        (project / "AGENTS.md").write_text("Old project context must not select the chat workspace.\n")
        marker = project / "must-not-exist"
        message = f"hi; $(touch {marker})"
        result, events = self.run_neutral(message=message, cwd=project)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(events[-1], {"type": "complete", "sessionId": SESSION})
        capture = json.loads(self.capture.read_text())
        root = self.folder.resolve() / "neutral workspaces"
        expected = root / "codex" / WORKSPACE
        self.assertEqual(capture["cwd"], str(expected))
        self.assertEqual(capture["prompt"], message + "\n")
        self.assertNotIn("resume", capture["argv"])
        self.assertNotIn("--last", capture["argv"])
        self.assertIn("--skip-git-repo-check", capture["argv"])
        self.assertLess(capture["argv"].index("--skip-git-repo-check"), capture["argv"].index("--json"))
        self.assertEqual(capture["argv"][capture["argv"].index("--sandbox") + 1], "read-only")
        self.assertIn('approval_policy="on-request"', capture["argv"])
        self.assertNotIn("--dangerously-bypass-approvals-and-sandbox", capture["argv"])
        self.assertNotIn("--dangerously-bypass-hook-trust", capture["argv"])
        self.assertFalse(marker.exists())
        for path in (root, root / "codex", expected):
            self.assertEqual(path.stat().st_mode & 0o777, 0o700)

    def test_neutral_codex_resume_keeps_explicit_session_workspace_and_safe_policy(self):
        self.codex_success()
        result, _ = self.run_neutral()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        first = json.loads(self.capture.read_text())
        result, events = self.run_neutral(message="Follow up", extra=("--session", SESSION))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        resumed = json.loads(self.capture.read_text())
        self.assertEqual(resumed["cwd"], first["cwd"])
        self.assertEqual(resumed["prompt"], "Follow up\n")
        self.assertIn("resume", resumed["argv"])
        self.assertIn(SESSION, resumed["argv"])
        self.assertNotIn("--last", resumed["argv"])
        self.assertIn("--skip-git-repo-check", resumed["argv"])
        self.assertLess(resumed["argv"].index("resume"), resumed["argv"].index("--skip-git-repo-check"))
        self.assertLess(resumed["argv"].index("--skip-git-repo-check"), resumed["argv"].index("--json"))
        self.assertEqual(resumed["argv"][resumed["argv"].index("--sandbox") + 1], "read-only")
        self.assertIn('approval_policy="on-request"', resumed["argv"])
        self.assertLess(resumed["argv"].index("--sandbox"), resumed["argv"].index("resume"))
        self.assertLess(resumed["argv"].index('approval_policy="on-request"'), resumed["argv"].index("resume"))
        self.assertNotIn("--dangerously-bypass-approvals-and-sandbox", resumed["argv"])
        self.assertNotIn("--dangerously-bypass-hook-trust", resumed["argv"])
        self.assertEqual(events[-1]["sessionId"], SESSION)

    def test_neutral_cli_file_writes_stay_private_without_changing_project_umask(self):
        self.fake(
            "os.mkdir('tool-output')\n"
            "pathlib.Path('tool-output/reply.txt').write_text('A locally approved tool result.\\n')\n"
            f"send({{'type':'thread.started','thread_id':{SESSION!r}}})\n"
            "send({'type':'turn.completed'})\n"
        )
        # Supply a known permissive parent umask so this exercises the actual
        # child process policy even when the test runner already uses 077.
        for neutral in (True, False):
            with self.subTest(neutral_workspace=neutral):
                arguments = self.neutral_args() if neutral else self.args()
                result = subprocess.run(arguments, input='{"message":"Hello"}',
                                        capture_output=True, text=True, timeout=8, umask=0o022)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                capture = json.loads(self.capture.read_text())
                output = Path(capture["cwd"]) / "tool-output"
                self.assertEqual(output.stat().st_mode & 0o777, 0o700 if neutral else 0o755)
                self.assertEqual((output / "reply.txt").stat().st_mode & 0o777,
                                 0o600 if neutral else 0o644)

    def test_neutral_claude_new_sessions_are_fresh_and_explicit_resume_keeps_workspace(self):
        self.claude_success()
        sessions = []
        for _ in range(2):
            result, events = self.run_neutral("claude")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            sessions.append(events[-1]["sessionId"])
            uuid.UUID(sessions[-1])
            capture = json.loads(self.capture.read_text())
            self.assertEqual(capture["cwd"], str(self.folder.resolve() / "neutral workspaces" / "claude" / WORKSPACE))
            self.assertIn("--session-id", capture["argv"])
            self.assertNotIn("--resume", capture["argv"])
            self.assertNotIn("--continue", capture["argv"])
            self.assertEqual(capture["argv"][capture["argv"].index("--permission-mode") + 1], "manual")
        self.assertNotEqual(sessions[0], sessions[1])
        result, events = self.run_neutral("claude", extra=("--session", sessions[-1]))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        capture = json.loads(self.capture.read_text())
        self.assertEqual(capture["cwd"], str(self.folder.resolve() / "neutral workspaces" / "claude" / WORKSPACE))
        self.assertEqual(capture["argv"][capture["argv"].index("--resume") + 1], sessions[-1])
        self.assertNotIn("--session-id", capture["argv"])
        self.assertEqual(capture["argv"][capture["argv"].index("--permission-mode") + 1], "manual")
        self.assertNotIn("--dangerously-skip-permissions", capture["argv"])
        self.assertEqual(events[-1]["sessionId"], sessions[-1])

    def test_neutral_workspace_is_separate_for_each_provider_and_new_conversation(self):
        self.codex_success()
        result, _ = self.run_neutral()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        codex_cwd = json.loads(self.capture.read_text())["cwd"]
        retained = Path(codex_cwd) / "existing-chat-file"
        retained.write_text("Keep this existing workspace.\n")
        self.claude_success()
        result, _ = self.run_neutral("claude")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        claude_cwd = json.loads(self.capture.read_text())["cwd"]
        self.assertNotEqual(claude_cwd, codex_cwd)
        fresh_id = str(uuid.uuid4())
        result, _ = self.run_neutral("claude", workspace_id=fresh_id)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        fresh_cwd = json.loads(self.capture.read_text())["cwd"]
        self.assertNotEqual(fresh_cwd, claude_cwd)
        self.assertEqual(Path(fresh_cwd).name, fresh_id)
        self.assertEqual(retained.read_text(), "Keep this existing workspace.\n")

    def test_invalid_neutral_workspace_arguments_never_launch_cli(self):
        self.codex_success()
        args = self.neutral_args()
        invalid_cases = []
        for identity in ("not-a-uuid", "../outside", "--last", "", WORKSPACE.upper(),
                         WORKSPACE.replace("-", ""), "{" + WORKSPACE + "}"):
            invalid = list(args)
            invalid[invalid.index("--workspace-id") + 1] = identity
            invalid_cases.append(invalid)
        relative = list(args)
        relative[relative.index("--workspace-root") + 1] = "."
        invalid_cases.append(relative)
        nondirectory = self.folder.resolve() / "workspace-file"
        nondirectory.write_text("Do not replace this file.\n")
        for root in (nondirectory, self.folder.resolve() / "missing-parent" / "neutral"):
            invalid = list(args)
            invalid[invalid.index("--workspace-root") + 1] = str(root)
            invalid_cases.append(invalid)
        for missing in ("--workspace-root", "--workspace-id"):
            invalid = list(args)
            index = invalid.index(missing)
            del invalid[index:index + 2]
            invalid_cases.append(invalid)
        invalid_cases.append([*args, "--cwd", str(self.folder)])
        for index, invalid in enumerate(invalid_cases):
            with self.subTest(case=index):
                completed = subprocess.run(invalid, input='{"message":"Hi"}', capture_output=True, text=True, timeout=3)
                self.assertNotEqual(completed.returncode, 0)
                self.assertFalse(self.capture.exists())
                self.assertNotIn("Traceback", completed.stdout + completed.stderr)
        self.assertEqual(nondirectory.read_text(), "Do not replace this file.\n")
        self.assertFalse((self.folder / "missing-parent").exists())

    def test_symlinked_neutral_root_parent_provider_or_workspace_never_launches_cli(self):
        self.codex_success()
        destination = self.folder.resolve() / "destination"
        destination.mkdir(mode=0o700)
        for level in ("root", "parent", "provider", "workspace"):
            with self.subTest(level=level):
                base = self.folder.resolve() / ("symlink-" + level)
                if level == "parent":
                    base.symlink_to(destination, target_is_directory=True)
                    root = base / "neutral"
                elif level == "root":
                    base.symlink_to(destination, target_is_directory=True)
                    root = base
                else:
                    root = base
                    root.mkdir(mode=0o700)
                    if level == "provider":
                        (root / "codex").symlink_to(destination, target_is_directory=True)
                    else:
                        (root / "codex").mkdir(mode=0o700)
                        (root / "codex" / WORKSPACE).symlink_to(destination, target_is_directory=True)
                completed = subprocess.run(self.neutral_args(workspace_root=root), input='{"message":"Hi"}',
                                           capture_output=True, text=True, timeout=3)
                self.assertNotEqual(completed.returncode, 0)
                self.assertFalse(self.capture.exists())
                self.assertNotIn("Traceback", completed.stdout + completed.stderr)
        self.assertFalse(list(destination.iterdir()), "Rejected symlinks must not create workspaces in their target")

    def test_public_neutral_root_provider_or_workspace_is_rejected_without_chmod(self):
        self.codex_success()
        for level in ("root", "provider", "workspace"):
            with self.subTest(level=level):
                root = self.folder.resolve() / ("public-" + level)
                root.mkdir(mode=0o700)
                provider = root / "codex"
                provider.mkdir(mode=0o700)
                workspace = provider / WORKSPACE
                workspace.mkdir(mode=0o700)
                unsafe = {"root": root, "provider": provider, "workspace": workspace}[level]
                unsafe.chmod(0o755)
                completed = subprocess.run(self.neutral_args(workspace_root=root), input='{"message":"Hi"}',
                                           capture_output=True, text=True, timeout=3)
                self.assertNotEqual(completed.returncode, 0)
                self.assertFalse(self.capture.exists())
                self.assertEqual(unsafe.stat().st_mode & 0o777, 0o755)
                self.assertNotIn("Traceback", completed.stdout + completed.stderr)

    def test_stderr_is_private_and_recognizable_credentials_are_redacted(self):
        self.fake("sys.stderr.write('private-stderr-' * 10000)\nsys.stderr.flush()\nsend({'type':'error','message':'Authentication failed: Bearer secret-token; api_key=sk-0123456789secret'})\n")
        result, events = self.run_bridge()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(events[-1]["type"], "error")
        self.assertIn("Authentication failed", events[-1]["text"])
        self.assertNotIn("private-stderr", result.stdout + result.stderr)
        self.assertNotIn("secret-token", result.stdout + result.stderr)
        self.assertNotIn("sk-0123456789secret", result.stdout + result.stderr)
        self.assertFalse(any(e["type"] == "complete" for e in events))

    def test_malformed_oversized_and_incomplete_streams(self):
        for body in ("print('not json',flush=True)\n", "print('x' * (1024 * 1024 + 1),flush=True)\n", "send({'type':'turn.started'})\n"):
            with self.subTest(body=body[:30]):
                self.fake(body)
                result, events = self.run_bridge()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(events[-1]["type"], "error")
                self.assertLess(len(result.stdout), 1000)

    def test_nonzero_exit_and_timeout_are_errors(self):
        self.fake("sys.stderr.write('secret')\nsys.exit(7)\n")
        result, events = self.run_bridge()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("status 7", events[-1]["text"])
        self.assertNotIn("secret", result.stdout + result.stderr)
        self.fake("time.sleep(10)\n")
        result, events = self.run_bridge(extra=("--timeout", "0.15"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("timed out", events[-1]["text"])

    def test_cleanup_failure_preserves_vendor_error_and_restores_handlers(self):
        self.fake("send({'type':'error','message':'Usage limit reached.'})\n")
        original_handler = signal.getsignal(signal.SIGTERM)
        stopped = []

        def fail_after_stopping(process):
            stopped.append(process)
            process.terminate()
            raise PermissionError("Synthetic cleanup failure")

        with mock.patch.object(chat_bridge, "stop_process_group", side_effect=fail_after_stopping):
            with self.assertRaises(chat_bridge.ChatError) as caught:
                chat_bridge.stream_turn([str(self.binary)], self.folder, "Hi", chat_bridge.StreamAdapter("codex"))
        self.assertIn("Usage limit reached", str(caught.exception))
        self.assertIn("Could not confirm", str(caught.exception))
        self.assertEqual(signal.getsignal(signal.SIGTERM), original_handler)
        self.assertIsNotNone(stopped[0].returncode)

    def test_invalid_input_and_relative_workspace_do_not_launch_cli(self):
        self.codex_success()
        invalid = subprocess.run(self.args(), input='{"message":42}', capture_output=True, text=True, timeout=3)
        self.assertNotEqual(invalid.returncode, 0)
        self.assertFalse(self.capture.exists())
        args = self.args()
        args[args.index("--cwd") + 1] = "."
        relative = subprocess.run(args, input='{"message":"Hi"}', capture_output=True, text=True, timeout=3)
        self.assertNotEqual(relative.returncode, 0)
        self.assertFalse(self.capture.exists())

    @unittest.skipUnless(os.name == "posix", "Process-group cancellation is POSIX-specific")
    def test_cancel_terminates_chat_child_and_grandchild_only(self):
        pids = self.folder / "pids.json"
        self.fake(
            "child=subprocess.Popen([sys.executable,'-c','import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(30)'])\n"
            f"pathlib.Path({str(pids)!r}).write_text(json.dumps([os.getpid(),child.pid]))\n"
            "time.sleep(30)\n"
        )
        process = subprocess.Popen(self.args(), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        process.stdin.write('{"message":"Hi"}')
        process.stdin.close()
        process.stdin = None
        deadline = time.monotonic() + 3
        while not pids.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(pids.exists())
        process.send_signal(signal.SIGTERM)
        stdout, stderr = process.communicate(timeout=5)
        self.assertIn("cancelled", stdout)
        self.assertEqual(stderr, "")
        for pid in json.loads(pids.read_text()):
            result = subprocess.run(["/bin/ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True)
            self.assertTrue(not result.stdout.strip() or result.stdout.strip().startswith("Z"), f"Chat process {pid} still running")


if __name__ == "__main__":
    unittest.main()
