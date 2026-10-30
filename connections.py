"""Reviewed, reversible connection setup for the prebuilt app; never modify its bundle."""
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import secrets
import shlex
import socket
import stat
import sys
import time
import uuid

import chat_bridge
import install_local as files
from setup_hooks import build_config

PROVIDERS = ("claude", "codex")
MANIFEST = "connections.json"


def paths_for(home, provider):
    home = files.absolute(home)
    support = home / "Library/Application Support/AgentCompanion"
    return {"home": home, "support": support, "runtime": support / ".runtime",
            "setup": support / ".runtime/setup", "manifest": support / MANIFEST,
            "telemetry": support / files.TELEMETRY_NAME,
            "settings": home / (".claude/settings.json" if provider == "claude" else ".codex/hooks.json")}


def helper_hash(helper):
    helper = files.absolute(helper)
    # Root-owned /Applications bundles are legitimate. User data remains user-owned.
    for part in (helper, *helper.parents):
        info = part.lstat()
        if stat.S_ISLNK(info.st_mode) or info.st_uid not in (0, os.getuid()):
            raise files.InstallError("Pip's installed helper has an unsafe path")
    if not helper.is_file() or not os.access(helper, os.X_OK) or helper.stat().st_mode & 0o022:
        raise files.InstallError("Pip's bundled helper is unavailable")
    with helper.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def document(path, home, private=False):
    files.check_path(path, home, "file")
    return files.load_object(path, home, private=private) if path.exists() else {}


def connection_config(paths):
    if paths["telemetry"].exists():
        return files.validate_telemetry(document(paths["telemetry"], paths["home"], private=True))
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    if not 49152 <= port <= 65535:
        raise files.InstallError("A local approval receiver port is unavailable")
    return {"version": 1, "host": "127.0.0.1", "port": port, "token": secrets.token_hex(32)}


def owned_command(command, paths, provider, helpers):
    try:
        argv = shlex.split(command)
    except (ValueError, TypeError):
        return False
    # Recognize only this install's bridge invocation, never a substring match.
    legacy = str(paths["support"] / "bridge.py")
    if len(argv) >= 3 and argv[1] == legacy and Path(argv[0]).name.lower().startswith("python"):
        rest = argv[2:]
    elif len(argv) >= 2 and argv[0] in helpers:
        rest = argv[1:]
    else:
        return False
    prefix = ["hook", "--source", "claude" if provider == "claude" else "chatgpt-work",
              "--runtime", str(paths["runtime"])]
    # Also migrate Codex definitions using its native source label.
    native = ["hook", "--source", provider, "--runtime", str(paths["runtime"])]
    return (rest[:5] in (prefix, native) and rest[5:] in
            ([], ["--wait", "120"], ["--track-tools"], ["--track-activity"]))


def remove_owned(existing, paths, provider, helpers):
    result = json.loads(json.dumps(existing))
    hooks = files.validate_hooks(result, paths["settings"])
    for event, groups in list(hooks.items()):
        remaining = []
        for group in groups:
            group["hooks"] = [h for h in group["hooks"] if not (
                h["type"] == "command" and owned_command(h["command"], paths, provider, helpers))]
            if group["hooks"]:
                remaining.append(group)
        if remaining:
            hooks[event] = remaining
        else:
            del hooks[event]
    result["hooks"] = hooks
    return result


def proposed(paths, helper, provider, operation, connection):
    existing = document(paths["settings"], paths["home"])
    manifest = document(paths["manifest"], paths["home"], private=True)
    if manifest and (manifest.get("version") != 1 or not isinstance(manifest.get("providers"), dict)):
        raise files.InstallError("Pip connection metadata is invalid")
    manifest = manifest or {"version": 1, "providers": {}}
    previous = manifest["providers"].get(provider, {})
    if not isinstance(previous, dict):
        raise files.InstallError("Pip connection metadata is invalid")
    helpers = {str(helper)}
    if isinstance(previous.get("helper"), str):
        helpers.add(previous["helper"])
    updated = remove_owned(existing, paths, provider, helpers)
    environment = files.telemetry_environment(connection) if provider == "claude" else None
    if operation == "connect":
        addition = build_config(provider, paths["runtime"], command_prefix=[str(helper)])
        updated = files.merge_settings(updated, addition, environment, paths["settings"])
        manifest["providers"][provider] = {"helper": str(helper)}
    else:
        if environment and isinstance(updated.get("env"), dict):
            updated["env"] = {k: v for k, v in updated["env"].items() if k not in environment or environment[k] != v}
        manifest["providers"].pop(provider, None)
    output = {"settings": files.encoded_json(updated), "manifest": files.encoded_json(manifest)}
    if provider == "claude" and operation == "connect":
        output["telemetry"] = files.encoded_json(connection)
    return output


@contextmanager
def setup_lock(paths):
    files.ensure_directory(paths["setup"], paths["home"])
    for folder in (paths["support"], paths["runtime"], paths["setup"]):
        info = folder.stat()
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise files.InstallError("Pip setup directories must be private and owned by you")
    lock = paths["setup"] / "connection.lock"
    fd = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise files.InstallError("Unsafe Pip setup lock")
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def snapshot(paths):
    return {name: files.file_state(paths[name], paths["home"])
            for name in ("settings", "manifest", "telemetry")}


def prepare(home, helper, provider, operation="connect"):
    paths = paths_for(home, provider)
    with setup_lock(paths):
        connection = connection_config(paths) if provider == "claude" else None
        # Validate the merge and all target paths before offering Connect.
        before = snapshot(paths)
        proposed(paths, helper, provider, operation, connection)
        identifier = str(uuid.uuid4())
        plan = {"version": 1, "id": identifier, "created": time.time(), "provider": provider,
                "operation": operation, "helper": str(helper), "helper_sha256": helper_hash(helper),
                "before": before, "connection": connection}
        files.atomic_bytes(paths["setup"] / (identifier + ".json"), files.encoded_json(plan))
    return {"id": identifier, "provider": provider, "operation": operation,
            "settings": str(paths["settings"]), "local_approval_sync": provider == "claude",
            "message": "Existing settings are preserved and changed files are backed up. "
                       "Approval modes and hook trust remain under your agent's control."}


def apply(home, helper, identifier):
    if str(uuid.UUID(identifier)) != identifier:
        raise files.InstallError("Invalid Pip setup plan")
    # Setup plans share a private location; provider comes from the reviewed plan.
    paths = paths_for(home, "claude")
    with setup_lock(paths):
        plan_path = paths["setup"] / (identifier + ".json")
        plan = files.load_object(plan_path, paths["home"], private=True)
        provider, operation = plan.get("provider"), plan.get("operation")
        if provider not in PROVIDERS or operation not in ("connect", "disconnect") or plan.get("version") != 1:
            raise files.InstallError("Invalid Pip setup plan")
        paths = paths_for(home, provider)
        if (plan.get("id") != identifier or plan.get("helper") != str(helper)
                or plan.get("helper_sha256") != helper_hash(helper)
                or not isinstance(plan.get("created"), (int, float))
                or not 0 <= time.time() - plan["created"] <= 900
                or plan.get("before") != snapshot(paths)):
            raise files.InstallError("Pip or your settings changed. Review the connection again.")
        connection = plan.get("connection")
        if provider == "claude":
            files.validate_telemetry(connection)
        proposed_bytes = proposed(paths, helper, provider, operation, connection)
        changes = []
        for name, data in proposed_bytes.items():
            path = paths[name]
            original = files.read_bytes(path, paths["home"]) if path.exists() else None
            if original != data:
                files.ensure_directory(path.parent, paths["home"])
                if original is not None:
                    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
                    backup = path.with_name(path.name + "." + stamp + ".pip-backup")
                    with os.fdopen(os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600), "wb") as stream:
                        stream.write(original)
                changes.append((path, original, data))
        if plan["before"] != snapshot(paths):
            raise files.InstallError("Your settings changed. Review the connection again.")
        written = []
        try:
            for path, original, data in changes:
                files.atomic_bytes(path, data)
                written.append((path, original))
        except BaseException:
            for path, original in reversed(written):
                if original is None:
                    path.unlink()
                else:
                    files.atomic_bytes(path, original)
            raise
        plan_path.unlink()
    return {"provider": provider, "connected": operation == "connect", "changed_files": len(changes),
            "message": ("Connected. Review/trust Pip in Codex /hooks. For Claude Code, reload or restart "
                        "after your current action finishes." if operation == "connect" else
                        "Disconnected. Restart the agent after its current action finishes.")}


def status(home, helper):
    providers = []
    for provider in PROVIDERS:
        paths = paths_for(home, provider)
        existing = document(paths["settings"], paths["home"])
        hooks = files.validate_hooks(existing, paths["settings"])
        expected = build_config(provider, paths["runtime"], command_prefix=[str(helper)])["hooks"]
        connected = all(any(group.get("matcher") == wanted.get("matcher") and
                            all(hook in group["hooks"] for hook in wanted["hooks"])
                            for group in hooks.get(event, []))
                        for event, groups in expected.items() for wanted in groups)
        if connected and provider == "claude":
            connected = paths["telemetry"].exists() and all(
                existing.get("env", {}).get(k) == v for k, v in
                files.telemetry_environment(connection_config(paths)).items())
        try:
            binary = chat_bridge.executable(provider, home=home)
        except chat_bridge.ChatError:
            binary = None
        extensions = Path(home) / ".vscode/extensions"
        extension = any(extensions.glob("anthropic.claude-code-*" if provider == "claude" else "openai.chatgpt-*"))
        providers.append({"id": provider, "detected": bool(binary or extension or paths["settings"].exists()),
                          "connected": bool(connected), "cli_available": binary is not None})
    return {"version": 1, "providers": providers}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("status", "prepare", "apply"))
    parser.add_argument("--provider", choices=PROVIDERS)
    parser.add_argument("--operation", choices=("connect", "disconnect"), default="connect")
    parser.add_argument("--plan")
    parser.add_argument("--home", type=Path, default=Path.home())
    args = parser.parse_args(argv)
    helper = Path(sys.executable)
    try:
        if args.action == "status":
            result = status(args.home, helper)
        elif args.action == "prepare" and args.provider:
            result = prepare(args.home, helper, args.provider, args.operation)
        elif args.action == "apply" and args.plan:
            result = apply(args.home, helper, args.plan)
        else:
            raise files.InstallError("Choose a provider or reviewed setup plan")
        print(json.dumps(result, allow_nan=False))
        return 0
    except (ValueError, OSError, TypeError, KeyError, AttributeError) as error:
        # Static validation errors and paths only; never settings, tokens or provider logs.
        print(json.dumps({"error": str(error)}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
