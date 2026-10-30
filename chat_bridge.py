#!/usr/bin/env python3
"""Stream one local CLI chat turn as a small, credential-free JSONL protocol.

stdin: {"message": "..."}; stdout: delta, complete(sessionId), or error.
No shell is used. Existing CLI authentication and trusted hooks are retained.
"""

import argparse
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import signal
import stat
import subprocess
import sys
import time
import uuid


MAX_INPUT = 256 * 1024
MAX_LINE = 1024 * 1024
MAX_STDOUT = 16 * 1024 * 1024
MAX_STDERR = 32 * 1024
MAX_TEXT = 4 * 1024 * 1024
MAX_ITEMS = 4096
MAX_ERROR = 2048


class ChatError(Exception):
    """A safe error message; raw vendor logs are never included."""


def workspace_for(args):
    """Keep Pip conversations outside project instructions and saved context."""
    root = args.workspace_root
    identifier = args.workspace_id
    if root is None and identifier is None:
        if args.cwd is None or not args.cwd.is_absolute() or not args.cwd.is_dir() or not os.access(args.cwd, os.W_OK):
            raise ChatError("Chat workspace must be an existing writable absolute directory.")
        return args.cwd.resolve()
    if root is None or identifier is None or args.cwd is not None:
        raise ChatError("Use paired chat workspace options without a project working directory.")
    try:
        if str(uuid.UUID(identifier)) != identifier:
            raise ValueError()
    except (ValueError, TypeError, AttributeError) as exc:
        raise ChatError("Invalid chat workspace identifier.") from exc
    if not root.is_absolute() or '..' in root.parts or len(root.parts) < 2:
        raise ChatError("Chat workspace root must be a dedicated absolute directory.")
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    descriptor = os.open('/', flags)
    try:
        # Traverse existing ancestors without following links. Only Pip's three
        # managed levels may be created, and existing permissions stay intact.
        for index, part in enumerate((*root.parts[1:], args.provider, identifier)):
            managed = index >= len(root.parts) - 2
            if managed:
                try:
                    os.mkdir(part, 0o700, dir_fd=descriptor)
                except FileExistsError:
                    pass
            child = os.open(part, flags, dir_fd=descriptor)
            try:
                info = os.fstat(child)
                if managed and (info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700):
                    raise ChatError("Chat workspace folders must be private and owned by you.")
            except BaseException:
                os.close(child)
                raise
            os.close(descriptor)
            descriptor = child
        return root / args.provider / identifier
    except OSError as exc:
        raise ChatError("Chat workspace is unavailable or contains an unsafe link.") from exc
    finally:
        os.close(descriptor)


def vendor_error(provider, frame):
    """Keep structured user-facing error details, without copying CLI logs."""
    details = []
    errors = frame.get("errors")
    if isinstance(errors, list):
        details.extend(value for value in errors if isinstance(value, str))
    error = frame.get("error")
    if isinstance(error, dict) and isinstance(error.get("message"), str):
        details.append(error["message"])
    elif isinstance(error, str):
        details.append(error)
    for key in ("message", "result"):
        if isinstance(frame.get(key), str):
            details.append(frame[key])
    detail = "\n".join(dict.fromkeys(details)).strip()[:MAX_ERROR]
    # Redact recognizable credential formats only. Ordinary error text stays useful.
    detail = re.sub(r"\bsk-[A-Za-z0-9_-]{8,}\b", "[redacted]", detail)
    detail = re.sub(r"(?i)(\bBearer\s+)[A-Za-z0-9._~+/-]+=*", r"\1[redacted]", detail)
    detail = re.sub(r'''(?i)((?:api[_-]?key|access[_-]?token|refresh[_-]?token|authorization)["']?\s*[:=]\s*["']?)[^\s"',;]+''', r"\1[redacted]", detail)
    detail = "".join(char for char in detail if char in "\n\t" or ord(char) >= 32)
    if detail:
        return f"{provider.title()}: {detail}"
    return f"{provider.title()} could not complete this turn. Check CLI sign-in, usage limits, and tool permissions."


def emit(event):
    sys.stdout.write(json.dumps(event, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def validate_session(value, provider):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,127}", value):
        raise ChatError("Invalid chat session identifier.")
    if provider == "claude":
        try:
            uuid.UUID(value)
        except ValueError as exc:
            raise ChatError("Claude chat session identifier must be a UUID.") from exc
    return value


def executable(provider, override=None, home=None):
    home = Path(home) if home is not None else Path.home()
    if override:
        candidates = [Path(override).expanduser()]
    else:
        discovered = shutil.which(provider)
        candidates = [Path(discovered)] if discovered else []
        # Finder-launched apps do not inherit a developer's interactive PATH.
        candidates.extend([home / ".local/bin" / provider,
                           Path("/opt/homebrew/bin") / provider,
                           Path("/usr/local/bin") / provider])
        if provider == "claude":
            candidates.append(home / ".local/bin/claude")
        else:
            extensions = home / ".vscode/extensions"
            import platform
            arch = "macos-aarch64" if platform.machine() == "arm64" else "macos-x86_64"
            versions = list(extensions.glob("openai.chatgpt-*/bin/" + arch + "/codex"))
            versions.sort(key=lambda p: tuple(int(n) for n in re.findall(r"\d+", p.parents[2].name)), reverse=True)
            candidates.extend(versions)
    for path in candidates:
        if path.is_file() and os.access(path, os.X_OK):
            return str(path.resolve())
    raise ChatError(f"{provider.title()} CLI was not found. Install or select its executable and sign in there.")


def command_for(args):
    """Return argv and our expected session, never a shell command string."""
    session_id = validate_session(args.session, args.provider) if args.session else None
    override = args.claude_path if args.provider == "claude" else args.codex_path
    binary = executable(args.provider, override)
    if args.provider == "claude":
        command = [binary, "-p", "--verbose", "--output-format", "stream-json", "--include-partial-messages", "--permission-mode", "manual"]
        if session_id:
            command.extend(["--resume", session_id])
        else:
            session_id = str(uuid.uuid4())
            command.extend(["--session-id", session_id])
    else:
        # Explicit least-privilege policy also applies to resumed pet chats.
        command = [binary, "exec", "--sandbox", args.sandbox, "-c", 'approval_policy="on-request"']
        workspace_options = ["--skip-git-repo-check"] if getattr(args, "workspace_root", None) is not None else []
        if session_id:
            command.extend(["resume", *workspace_options, "--json", session_id, "-"])
        else:
            command.extend([*workspace_options, "--json", "-"])
    return command, session_id


class StreamAdapter:
    def __init__(self, provider, session_id=None, output=emit):
        self.provider = provider
        self.session_id = session_id
        self.output = output
        self.completed = False
        self.text_bytes = 0
        self.messages = {}
        self.current = None
        self.last_text_key = None
        self.saw_text = False
        self.serial = 0

    def identity(self, value):
        value = validate_session(value, self.provider)
        if self.session_id is not None and value != self.session_id:
            raise ChatError("CLI returned a different chat session; the turn was stopped.")
        self.session_id = value

    def text(self, value):
        if not value:
            return
        if not isinstance(value, str):
            raise ChatError("CLI returned invalid text data.")
        self.text_bytes += len(value.encode("utf-8"))
        if self.text_bytes > MAX_TEXT:
            raise ChatError("Chat response exceeded the local output limit.")
        self.output({"type": "delta", "text": value})
        self.saw_text = True

    def key(self, value=None):
        if value is not None and (not isinstance(value, str) or len(value) > 256):
            raise ChatError("CLI returned an invalid message identifier.")
        if value is None:
            self.serial += 1
            value = f"local-message-{self.serial}"
        if value not in self.messages:
            if len(self.messages) >= MAX_ITEMS:
                raise ChatError("Chat response exceeded the local event limit.")
            self.messages[value] = ""
        self.current = value
        return value

    def append(self, key, value):
        if not isinstance(value, str):
            raise ChatError("CLI returned invalid text data.")
        if not value:
            return
        if self.last_text_key != key and self.saw_text:
            self.text("\n\n")
        self.text(value)
        self.messages[key] += value
        self.last_text_key = key

    def snapshot(self, key, value):
        if not isinstance(value, str):
            raise ChatError("CLI returned invalid text data.")
        previous = self.messages[key]
        if value.startswith(previous):
            self.append(key, value[len(previous):])
        elif previous.startswith(value):
            return  # A repeated or older snapshot adds no text.
        else:
            raise ChatError("CLI sent inconsistent response snapshots; the turn was stopped.")

    def consume(self, frame):
        if not isinstance(frame, dict) or not isinstance(frame.get("type"), str):
            raise ChatError("CLI returned an invalid stream event.")
        if self.provider == "claude":
            self.claude(frame)
        else:
            self.codex(frame)

    def claude(self, frame):
        # Forward only the main conversation, not subagent transcripts.
        if frame.get("parent_tool_use_id") is not None:
            return
        if frame.get("session_id") is not None:
            self.identity(frame["session_id"])
        kind = frame["type"]
        if kind == "stream_event":
            event = frame.get("event")
            if not isinstance(event, dict):
                raise ChatError("Claude returned an invalid streaming event.")
            if event.get("type") == "message_start":
                message = event.get("message")
                if not isinstance(message, dict):
                    raise ChatError("Claude returned an invalid message.")
                self.key(message.get("id"))
            elif event.get("type") == "content_block_delta":
                delta = event.get("delta")
                if not isinstance(delta, dict):
                    raise ChatError("Claude returned an invalid text delta.")
                if delta.get("type") == "text_delta":
                    key = self.current if self.current is not None else self.key()
                    self.append(key, delta.get("text"))
            elif event.get("type") == "content_block_start":
                block = event.get("content_block")
                if isinstance(block, dict) and block.get("type") == "text":
                    key = self.current if self.current is not None else self.key()
                    self.append(key, block.get("text", ""))
        elif kind == "assistant":
            message = frame.get("message")
            if not isinstance(message, dict) or not isinstance(message.get("content"), list):
                raise ChatError("Claude returned an invalid assistant message.")
            message_id = message.get("id")
            if message_id is not None and (not isinstance(message_id, str) or len(message_id) > 256):
                raise ChatError("Claude returned an invalid message identifier.")
            if message_id and message_id not in self.messages and self.current and self.current.startswith("local-message-"):
                # Older streams can omit message_start before the first delta.
                previous = self.current
                self.messages[message_id] = self.messages.pop(previous)
                if self.last_text_key == previous:
                    self.last_text_key = message_id
                self.current = message_id
            key = self.key(message_id) if message_id else (self.current or self.key())
            blocks = message["content"]
            texts = [block.get("text") for block in blocks if isinstance(block, dict) and block.get("type") == "text"]
            if any(not isinstance(value, str) for value in texts):
                raise ChatError("Claude returned invalid assistant text.")
            self.snapshot(key, "".join(texts))
        elif kind == "result":
            if frame.get("is_error") or frame.get("subtype") != "success":
                raise ChatError(vendor_error("claude", frame))
            result = frame.get("result")
            if result is not None:
                key = self.last_text_key or self.current or self.key()
                self.snapshot(key, result)
            self.completed = True

    def codex(self, frame):
        kind = frame["type"]
        if kind == "thread.started":
            self.identity(frame.get("thread_id"))
        elif kind in ("item.started", "item.updated", "item.completed"):
            item = frame.get("item")
            if not isinstance(item, dict):
                raise ChatError("Codex returned an invalid item event.")
            if item.get("type") == "agent_message":
                if not isinstance(item.get("id"), str) or not item["id"]:
                    raise ChatError("Codex returned an invalid message identifier.")
                key = self.key(item["id"])
                self.snapshot(key, item.get("text", ""))
        elif kind == "turn.completed":
            self.completed = True
        elif kind in ("turn.failed", "error"):
            raise ChatError(vendor_error("codex", frame))


def stop_process_group(process):
    """Terminate only the private process group created for this chat turn."""
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        process.wait(timeout=2)
        return
    deadline = time.monotonic() + 1
    while time.monotonic() < deadline:
        # Do not probe the group with signal 0: process-inspection policies can
        # reject that probe even after allowing TERM. Keep the leader unreaped
        # during the grace period so its PID cannot be reused for another group.
        time.sleep(0.02)
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    finally:
        # Reap the leader even if inspecting/signalling its now-empty group is
        # denied. Otherwise an already-stopped CLI can remain an unreaped child.
        process.wait(timeout=2)


def stream_turn(command, cwd, message, adapter, timeout=900, private_workspace=False):
    process = subprocess.Popen(command, cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True, umask=0o077 if private_workspace else -1)
    cancelled = [False]
    previous_handlers = {}
    selector = selectors.DefaultSelector()
    stdout_buffer = bytearray()
    stderr_tail = bytearray()
    stdout_size = 0
    prompt = (message + "\n").encode("utf-8")
    sent = 0
    started = time.monotonic()

    def cancel(_signum, _frame):
        cancelled[0] = True

    def line(raw):
        if not raw.strip():
            return
        if len(raw) > MAX_LINE:
            raise ChatError("CLI stream event exceeded the local size limit.")
        try:
            frame = json.loads(raw.decode("utf-8"))
        except (UnicodeError, ValueError, RecursionError) as exc:
            raise ChatError("CLI returned malformed JSON stream data.") from exc
        adapter.consume(frame)

    try:
        for signum in (signal.SIGINT, signal.SIGTERM):
            previous_handlers[signum] = signal.signal(signum, cancel)
        for stream, label in ((process.stdin, "stdin"), (process.stdout, "stdout"), (process.stderr, "stderr")):
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_WRITE if label == "stdin" else selectors.EVENT_READ, label)
        while selector.get_map():
            if cancelled[0]:
                raise ChatError("Chat turn cancelled.")
            if time.monotonic() - started > timeout:
                raise ChatError("Chat turn timed out. Try again or continue in the agent CLI.")
            for key, _events in selector.select(timeout=0.1):
                stream = key.fileobj
                if key.data == "stdin":
                    try:
                        sent += os.write(stream.fileno(), prompt[sent:sent + 16384])
                    except BrokenPipeError:
                        sent = len(prompt)
                    if sent >= len(prompt):
                        selector.unregister(stream)
                        stream.close()
                    continue
                chunk = os.read(stream.fileno(), 65536)
                if not chunk:
                    selector.unregister(stream)
                    stream.close()
                    if key.data == "stdout" and stdout_buffer:
                        line(bytes(stdout_buffer))
                        stdout_buffer.clear()
                    continue
                if key.data == "stderr":
                    stderr_tail.extend(chunk)
                    del stderr_tail[:-MAX_STDERR]
                    continue
                stdout_size += len(chunk)
                if stdout_size > MAX_STDOUT:
                    raise ChatError("CLI output exceeded the local stream limit.")
                stdout_buffer.extend(chunk)
                while b"\n" in stdout_buffer:
                    raw, _, remainder = stdout_buffer.partition(b"\n")
                    stdout_buffer = bytearray(remainder)
                    line(bytes(raw))
                if len(stdout_buffer) > MAX_LINE:
                    raise ChatError("CLI stream event exceeded the local size limit.")
        while process.poll() is None:
            if cancelled[0]:
                raise ChatError("Chat turn cancelled.")
            if time.monotonic() - started > timeout:
                raise ChatError("Chat turn timed out. Try again or continue in the agent CLI.")
            time.sleep(0.05)
        if process.returncode:
            # stderr is drained and bounded, but never copied into UI/log output.
            raise ChatError(f"{adapter.provider.title()} CLI exited with status {process.returncode}. Check its sign-in and permissions in the CLI.")
        if not adapter.completed or adapter.session_id is None:
            raise ChatError("CLI ended without a completed chat turn and session identifier.")
        return adapter.session_id
    finally:
        active_error = sys.exception()
        cleanup_errors = []
        operations = [lambda: stop_process_group(process), lambda: process.wait(timeout=2), selector.close]
        operations.extend(stream.close for stream in (process.stdin, process.stdout, process.stderr)
                          if stream is not None and not stream.closed)
        operations.extend(lambda signum=signum, handler=handler: signal.signal(signum, handler)
                          for signum, handler in previous_handlers.items())
        for operation in operations:
            try:
                operation()
            except (OSError, subprocess.TimeoutExpired) as exc:
                cleanup_errors.append(exc)
        if cleanup_errors:
            detail = "Could not confirm that all chat processes stopped."
            if active_error is None:
                raise ChatError(detail) from cleanup_errors[0]
            if isinstance(active_error, ChatError):
                active_error.args = (str(active_error) + " " + detail,)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--provider", choices=("claude", "codex"), required=True)
    parser.add_argument("--cwd", type=Path, help="Explicit project workspace for direct CLI use")
    parser.add_argument("--workspace-root", type=Path, help="Private root for Pip's neutral chat workspaces")
    parser.add_argument("--workspace-id", help="Pip-owned conversation workspace UUID")
    parser.add_argument("--session")
    parser.add_argument("--claude-path")
    parser.add_argument("--codex-path")
    parser.add_argument("--sandbox", choices=("read-only", "workspace-write"), default="read-only", help="Codex sandbox (default: read-only)")
    parser.add_argument("--timeout", type=float, default=900, help="Maximum turn duration in seconds (default: 900)")
    try:
        args = parser.parse_args(argv)
        cwd = workspace_for(args)
        if not 0 < args.timeout <= 3600:
            raise ChatError("Chat timeout must be between zero and 3600 seconds.")
        raw = sys.stdin.buffer.read(MAX_INPUT + 1)
        if len(raw) > MAX_INPUT:
            raise ChatError("Chat input exceeded the local size limit.")
        try:
            payload = json.loads(raw)
        except (UnicodeError, ValueError, RecursionError) as exc:
            raise ChatError("Chat input must be one JSON object containing a message.") from exc
        if not isinstance(payload, dict) or not isinstance(payload.get("message"), str) or not payload["message"].strip():
            raise ChatError("Enter a non-empty chat message.")
        command, session_id = command_for(args)
        adapter = StreamAdapter(args.provider, session_id)
        result = stream_turn(command, cwd, payload["message"], adapter, args.timeout,
                             private_workspace=args.workspace_root is not None)
        emit({"type": "complete", "sessionId": result})
        return 0
    except ChatError as exc:
        emit({"type": "error", "text": str(exc)})
        return 1
    except BrokenPipeError:
        return 1
    except OSError:
        emit({"type": "error", "text": "Could not start or communicate with the local agent CLI."})
        return 1
    except UnicodeError:
        emit({"type": "error", "text": "Chat input or CLI output contained invalid Unicode text."})
        return 1


if __name__ == "__main__":
    sys.exit(main())
