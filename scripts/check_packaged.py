#!/usr/bin/env python3
"""Exercise the shipped helper with a minimal PATH and disposable agent settings."""
import argparse
from contextlib import closing
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shlex
import sqlite3
import subprocess
import tempfile
import time
import uuid


def tree_hash(root):
    state = []
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            state.append((str(path.relative_to(root)), "link", os.readlink(path)))
        elif path.is_file():
            state.append((str(path.relative_to(root)), "file", hashlib.sha256(path.read_bytes()).hexdigest()))
    return hashlib.sha256(json.dumps(state).encode()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    args = parser.parse_args()
    app = args.app.resolve()
    helper = app / "Contents/Helpers/PipRuntime.app/Contents/MacOS/PipHelper"
    before = tree_hash(app)
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    checks = 1
    import package_macos
    for binary in package_macos.machos(app):
        dependencies = subprocess.check_output(["/usr/bin/otool", "-L", str(binary)], text=True).splitlines()[1:]
        for line in dependencies:
            dependency = line.strip().split(" (", 1)[0]
            assert dependency.startswith(("@", "/System/Library/", "/usr/lib/")), dependency
    checks += 1
    with tempfile.TemporaryDirectory(prefix="pip-shipped-check-") as folder:
        root = Path(folder).resolve()
        home = root / "home"
        home.mkdir()
        # No Homebrew/user PATH or Python environment. The helper must use its bundle.
        env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": str(root), "LANG": "en_US.UTF-8",
               "PYTHONHOME": str(root / "missing-python"), "PYTHONPATH": str(root / "missing-modules"),
               "HOME": str(home), "CODEX_HOME": str(home / ".codex"), "CLAUDE_CONFIG_DIR": str(home / ".claude")}

        def call(arguments, payload=None):
            result = subprocess.run([str(helper), *arguments], input=json.dumps(payload) if payload is not None else None,
                                    text=True, capture_output=True, env=env, timeout=15)
            assert result.returncode == 0, result.stderr or result.stdout
            return json.loads(result.stdout) if result.stdout.strip() else None

        info = call(["--version"])
        assert info["bundled"] is True
        checks += 1

        def connection(action, *extra):
            return call(["connections", action, "--home", str(home), *extra])

        for provider, relative in (("claude", ".claude/settings.json"), ("codex", ".codex/hooks.json")):
            settings = home / relative
            settings.parent.mkdir(parents=True)
            settings.write_text(json.dumps({"keep": "untouched", "hooks": {"Stop": [{"hooks": [
                {"type": "command", "command": "echo unrelated-hook"}]}]}}))
            original = settings.read_bytes()
            plan = connection("prepare", "--provider", provider)
            assert settings.read_bytes() == original
            connection("apply", "--plan", plan["id"])
            current = json.loads(settings.read_text())
            assert current["keep"] == "untouched"
            assert current["hooks"]["Stop"][0]["hooks"][0]["command"] == "echo unrelated-hook"
            assert list(settings.parent.glob("*.pip-backup"))
            checks += 3
        state = connection("status")
        assert all(p["connected"] for p in state["providers"])
        checks += 1
        runtime = home / "Library/Application Support/AgentCompanion/.runtime"

        # Start from the exact shell-quoted command emitted into agent settings.
        claude = json.loads((home / ".claude/settings.json").read_text())
        command = shlex.split(claude["hooks"]["PermissionRequest"][0]["hooks"][0]["command"])
        assert command[0] == str(helper) and command[1] == "hook"
        codex = json.loads((home / ".codex/hooks.json").read_text())
        codex_permission_command = shlex.split(codex["hooks"]["PermissionRequest"][0]["hooks"][0]["command"])
        assert codex_permission_command[0] == str(helper)
        sentinel = root / "must-never-execute"
        for provider, outcome in (("claude", "allow"), ("claude", "deny"), ("claude", "defer"), ("codex", "defer")):
            (runtime / "heartbeat.json").write_text(json.dumps({"updatedAt": time.time()}))
            (runtime / "heartbeat.json").chmod(0o600)
            event = {"hook_event_name": "PermissionRequest", "session_id": "fixture-session", "tool_name": "Bash",
                     "tool_input": {"command": "touch " + str(sentinel), "description": "Synthetic display only"}}
            child = subprocess.Popen(command if provider == "claude" else codex_permission_command,
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
            try:
                child.stdin.write(json.dumps(event)); child.stdin.close(); child.stdin = None
                deadline = time.monotonic() + 8
                pending = []
                while time.monotonic() < deadline:
                    pending = list((runtime / "requests").glob("*.json"))
                    if pending or child.poll() is not None:
                        break
                    time.sleep(0.02)
                assert len(pending) == 1, "Bundled hook did not publish one request"
                request = json.loads(pending[0].read_text())
                assert request["canDefer"] is True, "Bundled permission hook cannot hand back approval ownership"
                decision = runtime / "decisions" / (request["id"] + ".json")
                decision.write_text(json.dumps({"id": request["id"], "decision": outcome, "decidedAt": time.time()}))
                decision.chmod(0o600)
                output, error = child.communicate(timeout=10)
                assert child.returncode == 0, error
                if outcome == "defer":
                    assert not output.strip(), "Handoff must return no host approval decision"
                else:
                    assert json.loads(output)["hookSpecificOutput"]["decision"]["behavior"] == outcome
                assert not pending[0].exists() and not decision.exists(), "Frozen hook did not retire its exact handoff records"
                assert not sentinel.exists(), "A displayed tool command was executed"
                checks += 4
            finally:
                if child.poll() is None:
                    child.terminate(); child.communicate(timeout=3)

        # Async question acceptance is not the user's answer. Exercise the
        # frozen helper and the exact generated Codex question-hook command.
        codex = json.loads((home / ".codex/hooks.json").read_text())
        question_command = shlex.split(codex["hooks"]["PreToolUse"][0]["hooks"][0]["command"])
        assert question_command[0] == str(helper)
        for late_publication in (False, True):
            (runtime / "heartbeat.json").write_text(json.dumps({"updatedAt": time.time()}))
            event = {"hook_event_name": "PreToolUse", "session_id": str(uuid.uuid4()),
                     "turn_id": str(uuid.uuid4()), "tool_use_id": str(uuid.uuid4()),
                     "tool_name": "functions.request_user_input_async",
                     "tool_input": {"questions": [{"title": "Demo language?", "options": ["TypeScript", "Python"]}]}}
            title_index = home / ".codex/session_index.jsonl"
            title_index.write_text(json.dumps({"id": event["session_id"], "thread_name": "Synthetic Codex subject",
                                               "updated_at": "2026-10-28T12:00:00Z"}) + "\n")
            title_index.chmod(0o600)
            accepted = {**event, "hook_event_name": "PostToolUse", "tool_response": {"accepted": True}}
            if late_publication:
                call(question_command[1:], accepted)
            call(question_command[1:], event)
            pending = list((runtime / "requests").glob("*.json"))
            assert len(pending) == 1, "Async question notice was suppressed by its acknowledgement"
            request = json.loads(pending[0].read_text())
            assert request["canRespond"] is False and request["kind"] == "notice"
            checks += 1
            assert request.get("sessionName") == "Synthetic Codex subject", "Frozen helper did not load title-only index metadata"
            checks += 1
            call(question_command[1:], accepted)
            assert pending[0].exists(), "Async acceptance incorrectly dismissed the waiting notice"
            checks += 1
            call(question_command[1:], {**event, "hook_event_name": "Stop"})
            assert not pending[0].exists(), "Turn completion did not clear the async notice"
            checks += 1

        database_session = str(uuid.uuid4())
        database = home / ".codex/state_5.sqlite"
        with closing(sqlite3.connect(database)) as title_database:
            title_database.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, name TEXT, cwd TEXT)")
            title_database.execute("INSERT INTO threads VALUES (?,?,?)", (database_session, "Stored Codex subject", str(root)))
            title_database.commit()
        database.chmod(0o600)
        database_before = tree_hash(home / ".codex")
        event = {"hook_event_name": "PreToolUse", "session_id": database_session, "cwd": str(root),
                 "turn_id": str(uuid.uuid4()), "tool_use_id": str(uuid.uuid4()),
                 "tool_name": "request_user_input_async", "tool_input": {"questions": []}}
        call(question_command[1:], event)
        pending = list((runtime / "requests").glob("*.json"))
        assert len(pending) == 1 and json.loads(pending[0].read_text()).get("sessionName") == "Stored Codex subject", "Frozen SQLite title lookup failed"
        checks += 1
        call(question_command[1:], {**event, "hook_event_name": "Stop"})
        assert not pending[0].exists() and tree_hash(home / ".codex") == database_before, "Title lookup changed provider metadata"
        checks += 1

        # Claude's generated titles are standalone metadata records inside the
        # exact session JSONL. Verify the shipped runtime handles both those
        # titles and a newer custom rename, without using message text.
        title_session = str(uuid.uuid4())
        project = home / '.claude/projects/title-project'
        project.mkdir(parents=True, mode=0o700)
        title_log = project / (title_session + '.jsonl')
        title_log.write_text(json.dumps({'type': 'user', 'message': {'content': 'Synthetic body must not become a subject'}}) + '\n' +
                             json.dumps({'type': 'ai-title', 'aiTitle': 'Synthetic Claude subject', 'sessionId': title_session}) + '\n')
        title_log.chmod(0o600)
        title_event = {'hook_event_name': 'Notification', 'notification_type': 'permission_prompt',
                       'session_id': title_session, 'cwd': str(root), 'transcript_path': str(title_log),
                       'message': 'Synthetic permission notice'}
        for expected in ('Synthetic Claude subject', 'Renamed Claude subject'):
            if expected == 'Renamed Claude subject':
                custom = project / title_session
                custom.mkdir(mode=0o700)
                (custom / 'custom-title.json').write_text(json.dumps({'customTitle': 'Stale sidecar subject'}))
                with title_log.open('a') as stream:
                    stream.write(json.dumps({'type': 'custom-title', 'customTitle': expected, 'sessionId': title_session}) + '\n')
            provider_before = tree_hash(home / '.claude')
            (runtime / 'heartbeat.json').write_text(json.dumps({'updatedAt': time.time()}))
            call(command[1:], title_event)
            pending = list((runtime / 'requests').glob('*.json'))
            assert len(pending) == 1 and json.loads(pending[0].read_text()).get('sessionName') == expected, 'Frozen Claude title-record lookup failed'
            checks += 1
            call(command[1:], {**title_event, 'hook_event_name': 'SessionEnd'})
            assert not pending[0].exists() and tree_hash(home / '.claude') == provider_before, 'Claude title lookup changed provider files'
            checks += 1

        call(["telemetry", "--runtime", str(runtime)], {"resourceLogs": []})
        checks += 1
        # A fake CLI emits a real streaming protocol; no model/network call occurs.
        fake = root / "fake-codex"
        session = str(uuid.uuid4())
        frames = [{"type": "thread.started", "thread_id": session},
                  {"type": "item.completed", "item": {"id": "answer", "type": "agent_message", "text": "Hello from the bundled runtime"}},
                  {"type": "turn.completed"}]
        fake.write_text("#!/bin/sh\ncat >/dev/null\nprintf '%s\\n' " + " ".join(shlex.quote(json.dumps(f)) for f in frames) + "\n")
        fake.chmod(0o700)
        result = subprocess.run([str(helper), "chat", "--provider", "codex", "--codex-path", str(fake),
                                 "--cwd", str(root)], input='{"message":"hi"}', capture_output=True, text=True, env=env, timeout=15)
        assert result.returncode == 0, result.stderr or result.stdout
        replies = [json.loads(line) for line in result.stdout.splitlines()]
        assert "".join(f["text"] for f in replies if f["type"] == "delta") == "Hello from the bundled runtime"
        assert replies[-1]["type"] == "complete"
        checks += 2
        for provider in ("claude", "codex"):
            plan = connection("prepare", "--provider", provider, "--operation", "disconnect")
            connection("apply", "--plan", plan["id"])
        assert not any(p["connected"] for p in connection("status")["providers"])
        checks += 1
    assert tree_hash(app) == before, "Setup or hook execution modified the signed bundle"
    checks += 1
    print(json.dumps({"checks": checks, "result": "passed", "external_python_required": False,
                      "scope": "Disposable settings; real frozen hooks/chat/setup; no live agent/model calls"}))


if __name__ == "__main__":
    main()
