#!/usr/bin/env python3
"""Prepare a reviewable Pip installation, then apply exactly that plan."""

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import secrets
import shutil
import stat
import subprocess
import sys
import tempfile
import types


PROJECT = Path(__file__).absolute().parent
PLAN_NAME = ".install-plan.json"
MARKER_NAME = ".pip-install.json"
INSTALLER = "pip-local-v1"
MAX_JSON = 8 * 1024 * 1024
SCRIPT_NAMES = ("bridge.py", "session_titles.py", "setup_hooks.py", "chat_bridge.py", "telemetry.py")
TELEMETRY_NAME = ".telemetry.json"


class InstallError(ValueError):
    """An installation cannot safely proceed."""


def absolute(path):
    # Do not resolve symlinks before checking them.
    return Path(os.path.abspath(os.path.expanduser(str(path))))


def check_path(path, owned_from=None, kind=None):
    """Reject symlinks in every component and foreign-owned managed paths."""
    path = absolute(path)
    owned_from = absolute(owned_from) if owned_from is not None else path
    for component in (path, *path.parents):
        try:
            info = component.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(info.st_mode):
            raise InstallError("Symlinked installation paths are not supported: " + str(component))
        managed = component == owned_from or owned_from in component.parents
        if managed and info.st_uid != os.getuid():
            raise InstallError("Installation paths must be owned by you: " + str(component))
        if component != path and not stat.S_ISDIR(info.st_mode):
            raise InstallError("An installation parent is not a directory: " + str(component))
    if path.exists():
        info = path.lstat()
        if kind == "file" and not stat.S_ISREG(info.st_mode):
            raise InstallError("Expected a regular file: " + str(path))
        if kind == "directory" and not stat.S_ISDIR(info.st_mode):
            raise InstallError("Expected a directory: " + str(path))
    return path


def read_bytes(path, owned_from=None, private=False):
    path = check_path(path, owned_from, "file")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            raise InstallError("Expected your regular file: " + str(path))
        if private and info.st_mode & 0o077:
            raise InstallError("Installation metadata must be private: " + str(path))
        if info.st_size > MAX_JSON:
            raise InstallError("Installation input is too large: " + str(path))
        data = stream.read(MAX_JSON + 1)
        if len(data) > MAX_JSON:
            raise InstallError("Installation input is too large: " + str(path))
        return data


def digest(data):
    return hashlib.sha256(data).hexdigest()


def load_object(path, owned_from=None, private=False):
    try:
        value = json.loads(read_bytes(path, owned_from, private))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise InstallError("Invalid JSON in " + str(path)) from error
    if not isinstance(value, dict):
        raise InstallError("Expected a JSON object in " + str(path))
    return value


def file_state(path, owned_from):
    path = check_path(path, owned_from, "file")
    return digest(read_bytes(path, owned_from)) if path.exists() else None


def tree_state(path, owned_from, exclusions=()):
    path = check_path(path, owned_from, "directory")
    if not path.exists():
        return None
    entries = []
    for directory, subdirs, files in os.walk(path, followlinks=False):
        root = Path(directory)
        subdirs[:] = sorted(name for name in subdirs if name not in exclusions)
        for name in sorted(subdirs + files):
            if name in exclusions:
                continue
            child = check_path(root / name, owned_from)
            info = child.lstat()
            relative = child.relative_to(path).as_posix()
            if stat.S_ISDIR(info.st_mode):
                entries.append([relative, "directory", stat.S_IMODE(info.st_mode)])
            elif stat.S_ISREG(info.st_mode):
                # Bundle executables can exceed the JSON input limit.
                with child.open("rb") as stream:
                    sha = hashlib.file_digest(stream, "sha256").hexdigest()
                entries.append([relative, "file", stat.S_IMODE(info.st_mode), sha])
            else:
                raise InstallError("Unsupported file in installation tree: " + str(child))
    return digest(json.dumps(sorted(entries), separators=(",", ":")).encode())


def validate_hooks(config, path):
    hooks = config.get("hooks", {})
    if not isinstance(hooks, dict):
        raise InstallError("Hooks must be an object in " + str(path))
    for event, groups in hooks.items():
        if not isinstance(event, str) or not isinstance(groups, list):
            raise InstallError("Hook events must contain arrays in " + str(path))
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                raise InstallError("Invalid hook event entry in " + str(path))
            for hook in group["hooks"]:
                if not isinstance(hook, dict) or not isinstance(hook.get("type"), str):
                    raise InstallError("Invalid hook entry in " + str(path))
                if hook["type"] == "command" and not isinstance(hook.get("command"), str):
                    raise InstallError("Hook commands must be text in " + str(path))
    return hooks


def merge_hooks(existing, addition, path="settings"):
    """Preserve the entire existing object and deduplicate exact event commands."""
    result = json.loads(json.dumps(existing))
    current = validate_hooks(result, path)
    incoming = validate_hooks(addition, "generated hooks")
    result["hooks"] = current
    for event, groups in incoming.items():
        commands = {
            hook.get("command") for group in current.get(event, []) for hook in group["hooks"]
            if hook.get("type") == "command"
        }
        for group in groups:
            new_group = json.loads(json.dumps(group))
            new_group["hooks"] = [
                hook for hook in new_group["hooks"]
                if hook.get("type") != "command" or hook["command"] not in commands
            ]
            if new_group["hooks"]:
                current.setdefault(event, []).append(new_group)
                commands.update(hook["command"] for hook in new_group["hooks"]
                                if hook.get("type") == "command")
    return result


def validate_telemetry(value):
    if (not isinstance(value, dict) or set(value) != {"version", "host", "port", "token"}
            or type(value["version"]) is not int or value["version"] != 1 or value["host"] != "127.0.0.1"
            or isinstance(value["port"], bool) or not isinstance(value["port"], int)
            or not 49152 <= value["port"] <= 65535
            or not isinstance(value["token"], str) or len(value["token"]) != 64
            or any(character not in "0123456789abcdef" for character in value["token"])):
        raise InstallError("Invalid local Claude approval connection")
    return value


def telemetry_connection(paths):
    installed = paths["support"] / TELEMETRY_NAME
    if installed.exists():
        return validate_telemetry(load_object(installed, paths["home"], private=True))
    if paths["plan"].exists():
        previous = load_object(paths["plan"], paths["project"], private=True)
        previous_install = previous.get("install", {})
        if not isinstance(previous_install, dict):
            raise InstallError("Invalid installation plan")
        candidate = previous_install.get("telemetry")
        if candidate is not None:
            return validate_telemetry(candidate)
    return {"version": 1, "host": "127.0.0.1", "port": 49152 + secrets.randbelow(16384),
            "token": secrets.token_hex(32)}


def telemetry_environment(connection):
    return {
        "CLAUDE_CODE_ENABLE_TELEMETRY": "1", "OTEL_LOGS_EXPORTER": "otlp",
        "OTEL_EXPORTER_OTLP_LOGS_PROTOCOL": "http/json",
        "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT": f"http://127.0.0.1:{connection['port']}/v1/logs",
        "OTEL_EXPORTER_OTLP_LOGS_HEADERS": "X-Pip-Token=" + connection["token"],
        "OTEL_LOGS_EXPORT_INTERVAL": "1000", "OTEL_METRICS_EXPORTER": "none",
        "OTEL_TRACES_EXPORTER": "none", "OTEL_LOG_USER_PROMPTS": "0",
        "OTEL_LOG_ASSISTANT_RESPONSES": "0", "OTEL_LOG_TOOL_DETAILS": "0",
        "OTEL_LOG_TOOL_CONTENT": "0", "OTEL_LOG_MANAGED_SETTINGS": "0",
        "OTEL_LOG_RAW_API_BODIES": "0",
    }


def merge_settings(existing, addition, environment=None, path="settings"):
    result = merge_hooks(existing, addition, path)
    if environment is None:
        return result
    current = result.get("env", {})
    if not isinstance(current, dict):
        raise InstallError("Environment settings must be an object in " + str(path))
    if result.get("otelHeadersHelper"):
        raise InstallError("Existing Claude telemetry headers are preserved; a separate collector setup is required")
    for name, value in current.items():
        if (name.startswith("OTEL_") or name.startswith("CLAUDE_CODE_ENABLE_TELEMETRY")
                or name in {"BETA_TRACING_ENDPOINT", "CLAUDE_CODE_ENHANCED_TELEMETRY_BETA",
                            "ENABLE_ENHANCED_TELEMETRY_BETA", "ENABLE_BETA_TRACING_DETAILED"}):
            if name not in environment or value != environment[name]:
                raise InstallError("Existing Claude telemetry settings are preserved; a separate collector setup is required")
    result["env"] = {**current, **environment}
    return result


def locations(home, project):
    home, project = absolute(home), absolute(project)
    return {
        "home": home, "project": project,
        "support": home / "Library" / "Application Support" / "AgentCompanion",
        "app": home / "Applications" / "Pip.app",
        "source_app": project / "dist" / "Agent Companion.app",
        "plan": project / PLAN_NAME,
        "settings": (("claude", home / ".claude" / "settings.json"),
                     ("chatgpt-work", home / ".codex" / "hooks.json")),
    }


def check_runtime(path, home):
    check_path(path, home, "directory")
    if not path.exists():
        return
    for directory, subdirs, files in os.walk(path, followlinks=False):
        for child in [Path(directory), *(Path(directory) / name for name in subdirs + files)]:
            check_path(child, home)
            info = child.lstat()
            if not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)) or info.st_mode & 0o077:
                raise InstallError("Runtime files must be private and owned by you: " + str(child))


def managed_state(paths):
    home, support, app = paths["home"], paths["support"], paths["app"]
    check_path(support, home, "directory")
    check_path(app, home, "directory")
    if support.exists() or app.exists():
        marker_path = support / MARKER_NAME
        if not marker_path.exists():
            raise InstallError("An unmanaged Pip installation already exists; it will not be overwritten")
        marker = load_object(marker_path, home, private=True)
        expected = {"installer": INSTALLER, "support": str(support), "app": str(app)}
        if any(marker.get(key) != value for key, value in expected.items()):
            raise InstallError("Existing Pip installation metadata does not match these paths")
        if not isinstance(marker.get("files"), dict):
            raise InstallError("Existing Pip installation file metadata is invalid")
        if set(child.name for child in support.iterdir()) - {MARKER_NAME, *SCRIPT_NAMES, TELEMETRY_NAME, ".runtime", "__pycache__"}:
            raise InstallError("Pip support directory contains unmanaged files")
        for name in (*SCRIPT_NAMES, TELEMETRY_NAME):
            if file_state(support / name, home) != marker.get("files", {}).get(name):
                raise InstallError("Installed Pip file changed; refusing to overwrite " + name)
        if tree_state(app, home) != marker.get("app_sha256"):
            raise InstallError("Installed Pip app changed; refusing to overwrite it")
        check_runtime(support / ".runtime", home)
        # Python can create these while the companion is running. Validate
        # ownership and links, but never overwrite or hash dynamic cache files.
        tree_state(support / "__pycache__", home)
    return {
        "support_sha256": tree_state(support, home, exclusions=(".runtime", "__pycache__")),
        "app_sha256": tree_state(app, home),
    }


def create_plan(home=Path.home(), project=PROJECT):
    paths = locations(home, project)
    home, project, support = paths["home"], paths["project"], paths["support"]
    check_path(home, home, "directory")
    check_path(project, project, "directory")
    before_install = managed_state(paths)
    connection = telemetry_connection(paths)
    source_hashes = {}
    for name in SCRIPT_NAMES:
        source_hashes[name] = file_state(project / name, project)
        if source_hashes[name] is None:
            raise InstallError("Missing installation source: " + name)
    source_hashes["app"] = tree_state(paths["source_app"], project)
    if source_hashes["app"] is None:
        raise InstallError("Build the companion app before preparing installation")
    try:
        plist = plistlib.loads(read_bytes(paths["source_app"] / "Contents" / "Info.plist", project))
    except (plistlib.InvalidFileException, ValueError) as error:
        raise InstallError("Invalid app Info.plist") from error
    if not isinstance(plist, dict):
        raise InstallError("The app Info.plist must be a dictionary")
    runtime = support / ".runtime"
    # Compile the exact hashed source, avoiding stale bytecode and writes to a
    # __pycache__ directory during a preparation-only run.
    generator_path = project / "setup_hooks.py"
    generator_bytes = read_bytes(generator_path, project)
    if digest(generator_bytes) != source_hashes["setup_hooks.py"]:
        raise InstallError("Hook generator changed during preparation; prepare again")
    module = types.ModuleType("pip_install_hook_generator")
    module.__file__ = str(generator_path)
    exec(compile(generator_bytes, str(generator_path), "exec"), module.__dict__)
    settings = []
    for source, target in paths["settings"]:
        before = file_state(target, home)
        existing = load_object(target, home) if before is not None else {}
        validate_hooks(existing, target)
        addition = module.build_config(source, runtime, bridge_path=support / "bridge.py")
        environment = telemetry_environment(connection) if source == "claude" else None
        merge_settings(existing, addition, environment, target)
        settings.append({"source": source, "path": str(target), "before_sha256": before,
                         "add": addition, "env": environment})
    return {
        "version": 1, "installer": INSTALLER, "home": str(home), "project": str(project),
        "sources": {"directory": str(project), "app": str(paths["source_app"]), "sha256": source_hashes},
        "install": {"support": str(support), "runtime": str(runtime), "app": str(paths["app"]),
                    "before": before_install, "telemetry": connection,
                    "launch": {"CompanionPythonPath": sys.executable,
                               "CompanionTelemetryConfigPath": str(support / TELEMETRY_NAME),
                               "CompanionHookBridgePath": str(support / "bridge.py"),
                               "CompanionClaudePath": str(home / ".local" / "bin" / "claude"),
                               "CompanionCodexPath": shutil.which("codex") or ""}},
        "settings": settings,
    }


def atomic_bytes(path, data, mode=0o600):
    path = Path(path)
    fd, temporary = tempfile.mkstemp(prefix=".pip-write-", dir=path.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def encoded_json(value):
    return (json.dumps(value, ensure_ascii=True, allow_nan=False, indent=2) + "\n").encode()


def prepare(home=Path.home(), project=PROJECT):
    plan = create_plan(home, project)
    paths = locations(home, project)
    check_path(paths["plan"], paths["project"], "file")
    atomic_bytes(paths["plan"], encoded_json(plan))
    return plan


def ensure_directory(path, home, mode=0o700, created=None):
    check_path(path, home, "directory")
    if not path.exists():
        missing = []
        parent = path
        while not parent.exists():
            missing.append(parent)
            parent = parent.parent
        for directory in reversed(missing):
            try:
                directory.mkdir(mode=mode)
            except FileExistsError:
                check_path(directory, home, "directory")
            else:
                if created is not None:
                    created.append(directory)
    check_path(path, home, "directory")


@contextmanager
def newly_created_directories():
    created = []
    try:
        yield created
    except BaseException:
        # Only remove directories this install actually created and only when
        # empty. Existing directories, runtime files, caches and backups stay.
        for directory in reversed(created):
            try:
                directory.rmdir()
            except OSError:
                pass
        raise


def sign_bundle(app):
    """Seal the final local bundle, then verify it before publishing anything."""
    commands = (
        ["/usr/bin/codesign", "--force", "--sign", "-", "--identifier",
         "dev.local.agent-companion", str(app)],
        ["/usr/bin/codesign", "--verify", "--strict", str(app)],
    )
    for command in commands:
        try:
            subprocess.run(command, check=True, shell=False, timeout=30,
                           stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL)
        except (OSError, subprocess.SubprocessError):
            raise InstallError("Pip bundle signing or verification failed; no installation changes were made") from None


def apply(home=Path.home(), project=PROJECT):
    paths = locations(home, project)
    plan = load_object(paths["plan"], paths["project"], private=True)
    if plan != create_plan(home, project):
        raise InstallError("Installation sources or target settings changed; run --prepare and review again")
    # Build the app in a temporary directory before changing any destination.
    with newly_created_directories() as created, tempfile.TemporaryDirectory(prefix="pip-install-") as temporary:
        # macOS's system temporary root uses /var -> /private/var. This is our
        # newly created private stage; user-supplied paths are never resolved.
        temporary_root = Path(temporary).resolve()
        staged_app = temporary_root / "Pip.app"
        shutil.copytree(paths["source_app"], staged_app)
        if tree_state(staged_app, temporary_root) != plan["sources"]["sha256"]["app"]:
            raise InstallError("Source app changed during copying; prepare again")
        info_path = staged_app / "Contents" / "Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info["CompanionRuntimePath"] = str(paths["support"] / ".runtime")
        info["CompanionBridgePath"] = str(paths["support"] / "chat_bridge.py")
        info.update(plan["install"]["launch"])
        info_path.write_bytes(plistlib.dumps(info, sort_keys=True))
        sign_bundle(staged_app)
        app_hash = tree_state(staged_app, temporary_root)
        scripts = {name: read_bytes(paths["project"] / name, paths["project"])
                   for name in SCRIPT_NAMES}
        if any(digest(data) != plan["sources"]["sha256"][name] for name, data in scripts.items()):
            raise InstallError("Source scripts changed during copying; prepare again")
        settings = []
        for target in plan["settings"]:
            path = Path(target["path"])
            old = read_bytes(path, paths["home"]) if target["before_sha256"] is not None else None
            existing = load_object(path, paths["home"]) if old is not None else {}
            new = encoded_json(merge_settings(existing, target["add"], target.get("env"), path))
            settings.append((path, old, new))
        # Fail on changes during staging as well as changes since review.
        if plan != create_plan(home, project):
            raise InstallError("Installation sources or targets changed during preparation; prepare again")
        for path, old, _ in settings:
            ensure_directory(path.parent, paths["home"], created=created)
            if old is not None:
                stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
                backup = path.with_name(path.name + "." + stamp + ".pip-backup")
                fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                os.fchmod(fd, 0o600)
                with os.fdopen(fd, "wb") as stream:
                    stream.write(old)
        support = paths["support"]
        support_before = {
            name: read_bytes(support / name, paths["home"]) if (support / name).exists() else None
            for name in (*SCRIPT_NAMES, TELEMETRY_NAME, MARKER_NAME)
        }
        ensure_directory(support, paths["home"], created=created)
        ensure_directory(support / ".runtime", paths["home"], created=created)
        check_runtime(support / ".runtime", paths["home"])
        ensure_directory(paths["app"].parent, paths["home"], created=created)
        # Use a same-volume app stage, keeping any existing managed app until swap.
        app_stage = Path(tempfile.mkdtemp(prefix=".Pip-install-", dir=paths["app"].parent))
        displaced = None
        app_published = False
        published_support = []
        published_settings = []
        keep_stage = False
        scripts[TELEMETRY_NAME] = encoded_json(validate_telemetry(plan["install"]["telemetry"]))
        try:
            shutil.copytree(staged_app, app_stage / "Pip.app")
            if paths["app"].exists():
                displaced = app_stage / "previous.app"
                os.replace(paths["app"], displaced)
            try:
                os.replace(app_stage / "Pip.app", paths["app"])
            except OSError:
                if displaced is not None:
                    os.replace(displaced, paths["app"])
                    displaced = None
                raise
            app_published = True
            for name, data in scripts.items():
                atomic_bytes(support / name, data)
                published_support.append(name)
            for path, old, new in settings:
                atomic_bytes(path, new)
                published_settings.append((path, old))
            marker = {"installer": INSTALLER, "support": str(support), "app": str(paths["app"]),
                      "files": {name: digest(data) for name, data in scripts.items()}, "app_sha256": app_hash}
            atomic_bytes(support / MARKER_NAME, encoded_json(marker))
            published_support.append(MARKER_NAME)
        except Exception:
            try:
                for path, old in reversed(published_settings):
                    if old is None:
                        path.unlink()
                    else:
                        atomic_bytes(path, old)
                for name in reversed(published_support):
                    old = support_before[name]
                    if old is None:
                        (support / name).unlink()
                    else:
                        atomic_bytes(support / name, old)
                if app_published:
                    os.replace(paths["app"], app_stage / "failed.app")
                    if displaced is not None:
                        os.replace(displaced, paths["app"])
            except OSError:
                keep_stage = True
                raise InstallError("Installation rollback needs attention; preserved app staging at " + str(app_stage))
            raise
        finally:
            if not keep_stage:
                shutil.rmtree(app_stage)
    return plan


def summary(plan):
    return {"app": plan["install"]["app"], "support": plan["install"]["support"],
            "local_claude_approval_sync": {"host": "127.0.0.1", "port": plan["install"]["telemetry"]["port"],
                                          "export_interval_ms": 1000, "content_logging": False},
            "targets": [{"path": target["path"], "events": sorted(target["add"]["hooks"])}
                        for target in plan["settings"]]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_mutually_exclusive_group(required=True)
    actions.add_argument("--prepare", action="store_true")
    actions.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    try:
        plan = prepare() if args.prepare else apply()
    except (InstallError, OSError, TypeError, KeyError, AttributeError) as error:
        parser.exit(1, "Pip installation stopped: " + str(error) + "\n")
    print(json.dumps(summary(plan), indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
