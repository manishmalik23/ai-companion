#!/usr/bin/env python3
"""Forward supported local agent hooks to the companion. Never run tool commands."""

import argparse
import concurrent.futures
from contextlib import contextmanager
import datetime
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid

from session_titles import lookup_session_title, session_title_candidate

PROJECT = Path(__file__).resolve().parent
DEFAULT_RUNTIME = PROJECT / ".runtime"
MAX_INPUT = 512 * 1024
MAX_REQUEST = 1024 * 1024
HEARTBEAT_AGE = 5.0
LABELS = {
    "claude": "Claude Code",
    "codex": "Codex",
    "chatgpt-work": "ChatGPT Work",
    "vscode": "Claude in VS Code",
}
STATES = {
    "SessionStart": "idle",
    "UserPromptSubmit": "working",
    "PreToolUse": "working",
    "PostToolUse": "working",
    "PostToolUseFailure": "working",
    "Stop": "idle",
    "StopFailure": "idle",
    "Interrupt": "idle",
    "SessionEnd": "offline",
}
TOOL_COMPLETION_EVENTS = {"PostToolUse", "PostToolUseFailure"}
TURN_COMPLETION_EVENTS = {"Stop", "StopFailure", "Interrupt", "SessionEnd"}
TOOL_DECISION_EVENT = "ToolDecision"
DECISION_SOURCES = {"accept": {"config", "hook", "user_temporary", "user_permanent"},
                    "reject": {"config", "hook", "user_abort", "user_reject"}}
MAX_ACTIVE_CALLS = 128
MAX_IDENTIFIER_BYTES = 1024
MAX_ACTIVE_METADATA = 256 * 1024
MAX_RETIREMENT_METADATA = 128 * 1024
CORRELATION_FIELDS = {"sessionId", "turnId", "promptId", "agentId", "agentType", "toolUseId", "toolName", "toolInputHash"}
IDENTITY_INPUT_FIELDS = {"session_id", "turn_id", "prompt_id", "agent_id", "agent_type", "tool_use_id", "tool_name"}
MAX_SESSION_NAME_BYTES = 512
SESSION_NAME_FIELDS = ("session_title", "session_name", "custom_title", "sessionName")
SESSION_HOSTS = {
    "claude": {"claude-vscode", "vscode-terminal", "apple-terminal"},
    "vscode": {"claude-vscode", "vscode-terminal", "apple-terminal"},
    "codex": {"codex-desktop", "codex-vscode", "vscode-terminal", "apple-terminal"},
    "chatgpt-work": set(),
}
VSCODE_SESSION_HOSTS = {"claude-vscode", "codex-vscode", "vscode-terminal"}
TERMINAL_SESSION_HOSTS = {"vscode-terminal", "apple-terminal"}
MAX_TERMINAL_PROBE_SECONDS = 0.25
MAX_TERMINAL_PROCESS_IDS = 9
MAX_PROCESS_ID = 2_147_483_647


@contextmanager
def mailbox_lock(root):
    """Serialize bridge publication, source completion, and response acceptance."""
    descriptor = os.open(root / "bridge.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        info = os.fstat(descriptor)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077):
            raise ValueError("Invalid companion bridge lock")
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        os.close(descriptor)


def identifier(value):
    if not isinstance(value, str) or not value.strip() or value.strip().lower() == "unknown":
        return None
    try:
        return value if len(value.encode("utf-8")) <= MAX_IDENTIFIER_BYTES else None
    except UnicodeEncodeError:
        return None


def valid_scope(scope):
    return (isinstance(scope, dict) and not set(scope) - CORRELATION_FIELDS
            and all(identifier(value) is not None for value in scope.values()))


def bounded_records(records, budget):
    """Keep the newest bounded metadata, reporting any lost call ambiguity."""
    sizes = [len(json.dumps(record, ensure_ascii=True, allow_nan=False).encode()) + 2 for record in records]
    size = 2 + sum(sizes)
    first = 0
    while size > budget and first < len(records):
        size -= sizes[first]
        first += 1
    return records[first:], bool(first)


def correlation(event):
    """Keep host identifiers and a digest, never a second copy of tool arguments."""
    result = {}
    for input_name, output_name in (("session_id", "sessionId"), ("turn_id", "turnId"), ("prompt_id", "promptId"),
                                    ("agent_id", "agentId"), ("agent_type", "agentType"),
                                    ("tool_use_id", "toolUseId"), ("tool_name", "toolName")):
        value = identifier(event.get(input_name))
        if value is not None:
            result[output_name] = value
    if "tool_input" in event:
        encoded = json.dumps(event["tool_input"], sort_keys=True, separators=(",", ":"),
                             ensure_ascii=True, allow_nan=False).encode()
        result["toolInputHash"] = hashlib.sha256(encoded).hexdigest()
    return result


def session_path(root, source, session_id):
    key = hashlib.sha256((source + ":" + session_id).encode()).hexdigest()
    return root / "sessions" / (key + ".json")


def session_document(root, source, session_id):
    try:
        value = read_json(session_path(root, source, session_id))
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def display_session_name(value, session_id=None, cwd=None):
    """Bound a plain-text label without inferring it from chat content."""
    return session_title_candidate(value, session_id, cwd)


def session_window_key(value):
    if not isinstance(value, str) or len(value) != 36:
        return None
    try:
        canonical = str(uuid.UUID(value))
    except ValueError:
        return None
    return canonical if value.lower() == canonical else None


def process_id(value):
    return value if isinstance(value, int) and not isinstance(value, bool) and 1 < value <= MAX_PROCESS_ID else None


def terminal_tty(value):
    if not isinstance(value, str) or len(value) > 16:
        return None
    value = value if value.startswith("/dev/") else "/dev/" + value
    return value if re.fullmatch(r"/dev/ttys[0-9]{1,4}", value) else None


def process_start_time(value):
    if not isinstance(value, str) or len(value) > 64:
        return None
    fields = value.split()
    if len(fields) != 5:
        return None
    weekday, month, day, timestamp, year = fields
    months = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
    weekdays = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
    if (weekday not in weekdays or month not in months or not re.fullmatch(r"[0-9]{1,2}", day)
            or not re.fullmatch(r"[0-9]{4}", year) or not re.fullmatch(r"[0-9]{2}:[0-9]{2}:[0-9]{2}", timestamp)):
        return None
    try:
        stamp = datetime.datetime(int(year), months.index(month) + 1, int(day), *map(int, timestamp.split(":")))
    except ValueError:
        return None
    if weekdays[stamp.weekday()] != weekday:
        return None
    return f"{weekday} {month} {int(day)} {timestamp} {year}"


def provider_process_kind(source, executable):
    """Classify only the executable path, never a process's command arguments."""
    if not isinstance(executable, str) or len(executable) > 1024:
        return None
    path = Path(executable)
    if source in ("claude", "vscode"):
        if (path.name == "claude" or (path.parent.name == "versions" and path.parent.parent.name == "claude"
                                     and re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9._-]+)?", path.name))):
            return "provider"
        if path.name in ("node", "bun"):
            return "runtime"
    if source == "codex" and path.name == "codex":
        return "provider"
    return None


def terminal_process_context(*, source=None, run_process=None, current_pid=None, clock=None):
    """Read only this process's bounded ancestry and controlling tty on macOS."""
    if sys.platform != "darwin":
        return None
    run_process = run_process or subprocess.run
    clock = clock or time.monotonic
    target = process_id(os.getpid() if current_pid is None else current_pid)
    if target is None:
        return None
    deadline = clock() + MAX_TERMINAL_PROBE_SECONDS
    process_ids, tty, candidates = [], None, []
    for _ in range(MAX_TERMINAL_PROCESS_IDS):
        remaining = deadline - clock()
        if remaining <= 0 or target in process_ids:
            break
        try:
            result = run_process(["/bin/ps", "-p", str(target), "-o", "pid=,ppid=,tty=,lstart=,comm="],
                                 stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                 text=True, check=False, timeout=min(0.1, remaining),
                                 env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"})
        except (OSError, subprocess.SubprocessError):
            break
        if result.returncode != 0 or not isinstance(result.stdout, str) or len(result.stdout) > 2048:
            break
        fields = result.stdout.strip().split(maxsplit=8)
        if len(fields) != 9 or not all(re.fullmatch(r"[0-9]{1,10}", value) for value in fields[:2]):
            break
        actual, parent = map(int, fields[:2])
        if actual != target or not 0 <= parent <= MAX_PROCESS_ID:
            break
        process_ids.append(actual)
        current_tty = terminal_tty(fields[2])
        tty = tty or current_tty
        start = process_start_time(" ".join(fields[3:8]))
        kind = provider_process_kind(source, fields[8])
        if len(process_ids) > 1 and kind and start:
            candidates.append((kind, actual, current_tty, start))
        target = process_id(parent)
        if target is None:
            break
    if not process_ids:
        return None
    result = {"processIds": process_ids, **({"tty": tty} if tty else {})}
    for kind in ("provider", "runtime"):
        origin = next((candidate for candidate in candidates if candidate[0] == kind and tty
                       and candidate[2] == tty), None)
        if origin:
            result.update(originPid=origin[1], originStartTime=origin[3])
            break
    return result


def validated_terminal_context(value):
    """Keep only bounded identity data returned by the local probe."""
    if not isinstance(value, dict) or not isinstance(value.get("processIds"), list):
        return None
    process_ids = value["processIds"]
    if (not 1 <= len(process_ids) <= MAX_TERMINAL_PROCESS_IDS
            or any(process_id(value) is None for value in process_ids)
            or len(set(process_ids)) != len(process_ids)):
        return None
    tty = terminal_tty(value.get("tty"))
    result = {"processIds": process_ids, **({"tty": tty} if tty else {})}
    origin = process_id(value.get("originPid"))
    start = process_start_time(value.get("originStartTime"))
    if tty and origin in process_ids and start:
        result.update(originPid=origin, originStartTime=start)
    return result


def session_metadata(root, source, event, previous=None, terminal_probe=None):
    """Use only explicit labels and known origins for this exact host/session."""
    session_id = identifier(event.get("session_id"))
    if source not in SESSION_HOSTS or session_id is None:
        return {}
    if previous is None:
        previous = session_document(root, source, session_id)
    if (not isinstance(previous, dict) or previous.get("source") != source
            or previous.get("sessionId") != session_id):
        previous = {}
    result = {}
    cwd = event.get("cwd")
    candidate = lambda value: display_session_name(value, session_id, cwd)
    name = next((name for field in SESSION_NAME_FIELDS
                 if (name := candidate(event.get(field))) is not None), None)
    cached = candidate(previous.get("sessionName"))
    invalid_hook_name = name is None and any(field in event for field in SESSION_NAME_FIELDS)
    invalid_cached_name = cached is None and "sessionName" in previous
    tool_name = event.get("tool_name", "")
    refresh_title = (event.get("hook_event_name") in ("SessionStart", "UserPromptSubmit", "PermissionRequest", "Notification")
                     or event.get("hook_event_name") == "PreToolUse" and isinstance(tool_name, str)
                     and tool_name.split(".")[-1] in ("AskUserQuestion", "request_user_input", "request_user_input_async"))
    if name is None and (refresh_title or invalid_hook_name or invalid_cached_name):
        name = candidate(lookup_session_title(source, event)[0])
    name = name or cached
    if name:
        result["sessionName"] = name

    allowed = SESSION_HOSTS[source]
    explicit_host = next((field for field in ("session_host", "sessionHost") if field in event), None)
    if explicit_host:
        host = event[explicit_host]
    else:
        origin = (os.environ.get("CLAUDE_CODE_ENTRYPOINT") if source in ("claude", "vscode")
                  else os.environ.get("CODEX_INTERNAL_ORIGINATOR_OVERRIDE"))
        host = ({"claude-vscode": "claude-vscode"}.get(origin) if source in ("claude", "vscode")
                else {"Codex Desktop": "codex-desktop", "codex_vscode": "codex-vscode"}.get(origin))
        if host is None and origin != "codex_work_desktop":
            host = {"vscode": "vscode-terminal", "Apple_Terminal": "apple-terminal"}.get(os.environ.get("TERM_PROGRAM"))
        # A cached origin cannot identify this hook's live IDE or terminal.
    if isinstance(host, str) and host in allowed:
        result["sessionHost"] = host
        if host in VSCODE_SESSION_HOSTS:
            window_key = session_window_key(os.environ.get("PIP_VSCODE_WINDOW_KEY"))
            if window_key:
                result["sessionWindowKey"] = window_key
        if host in TERMINAL_SESSION_HOSTS:
            context = validated_terminal_context(terminal_probe() if terminal_probe else terminal_process_context(source=source))
            if context:
                result["sessionTerminal"] = context
    return result


def retirement_records(document):
    records = document.get("retirements", [])
    if not isinstance(records, list):
        return []
    return [{"eventName": record["eventName"], "correlation": record["correlation"],
             "observedAt": record["observedAt"], "backgroundWork": bool(record.get("backgroundWork"))}
            for record in records[-32:]
            if isinstance(record, dict) and isinstance(record.get("eventName"), str)
            and record["eventName"] in TURN_COMPLETION_EVENTS | TOOL_COMPLETION_EVENTS | {TOOL_DECISION_EVENT}
            and valid_scope(record.get("correlation"))
            and finite_number(record.get("observedAt"))]


def already_retired(root, source, request):
    # Fingerprints alone cannot safely replay against a later identical call.
    previous = session_document(root, source, request["sessionId"])
    return any(completion_match(request, record, publication=True) in ("session", "turn", "tool")
               for record in retirement_records(previous))


def completion_match(request, record, publication=False):
    request_scope = request.get("correlation", {})
    event_scope = record["correlation"]
    if (not isinstance(request_scope, dict) or not identifier(request_scope.get("sessionId"))
            or request_scope.get("sessionId") != event_scope.get("sessionId")
            or not finite_number(request.get("createdAt"))):
        return None
    event_name = record["eventName"]
    request_tool_name = request_scope.get("toolName")
    if (event_name == "PostToolUse" and request.get("source") in ("codex", "chatgpt-work")
            and request.get("kind") == "notice" and request.get("canRespond") is False
            and isinstance(request_tool_name, str)
            and request_tool_name.split(".")[-1] == "request_user_input_async"):
        # This tool completes when the host accepts the question, before the
        # user answers. Its acknowledgement must not retire the waiting alert.
        return None
    if event_name == TOOL_DECISION_EVENT and request.get("canRespond") is False and request["createdAt"] > record["observedAt"]:
        return None  # An earlier Bash approval cannot answer a later network prompt.
    if request["createdAt"] > record["observedAt"]:
        # Stop/StopFailure are attempts: another hook or recovery can continue
        # the same prompt. Only a confirmed Codex interruption is timeless.
        exact_ended_turn = (event_name == "Interrupt" and request.get("source") in ("codex", "chatgpt-work")) and any(
            event_scope.get(field) and event_scope[field] == request_scope.get(field)
            for field in ("turnId", "promptId"))
        exact_completed_tool = (event_name in TOOL_COMPLETION_EVENTS | {TOOL_DECISION_EVENT} and event_scope.get("toolUseId")
                                and event_scope["toolUseId"] == request_scope.get("toolUseId"))
        if not publication or not (exact_ended_turn or exact_completed_tool):
            return None
    if event_name == "SessionEnd":
        return "session"
    request_tool_id, event_tool_id = request_scope.get("toolUseId"), event_scope.get("toolUseId")
    exact_tool = (event_name in TOOL_COMPLETION_EVENTS | {TOOL_DECISION_EVENT} and request_tool_id and event_tool_id
                  and request_tool_id == event_tool_id)
    # A shared call ID survives omitted optional metadata, while explicit
    # scope conflicts still identify a different agent or turn. Fingerprint
    # matches and lifecycle-only notices keep their stricter scope requirement.
    for field in ("agentId", "turnId", "promptId"):
        request_value, event_value = request_scope.get(field), event_scope.get(field)
        if request_value != event_value and (not exact_tool or request_value is not None and event_value is not None):
            return None
    shared_agent_id = request_scope.get("agentId") and request_scope.get("agentId") == event_scope.get("agentId")
    if not shared_agent_id:
        request_type, event_type = request_scope.get("agentType"), event_scope.get("agentType")
        if request_type != event_type and (not exact_tool or request_type is not None and event_type is not None):
            return None
    if event_name in TURN_COMPLETION_EVENTS:
        return None if record.get("backgroundWork") else "turn"
    if request_tool_id and event_tool_id:
        return "tool" if request_tool_id == event_tool_id else None
    if event_name == TOOL_DECISION_EVENT:
        return None  # Telemetry never resolves a card by input similarity alone.
    if (request_scope.get("toolName") and request_scope.get("toolInputHash")
            and request_scope.get("toolName") == event_scope.get("toolName")
            and request_scope.get("toolInputHash") == event_scope.get("toolInputHash")):
        return "fingerprint"
    return None


def retire_requests(root, source, event):
    """Retire only completed host requests; never manufacture a user decision."""
    scope = correlation(event)
    if not scope.get("sessionId"):
        return None
    record = {"eventName": event["hook_event_name"], "correlation": scope,
              "observedAt": event["decided_at"] if event["hook_event_name"] == TOOL_DECISION_EVENT else time.time(),
              "backgroundWork": bool(event.get("background_tasks") or event.get("session_crons"))}
    matches = []
    for path in (root / "requests").glob("*.json"):
        try:
            request = read_json(path, MAX_REQUEST)
            if (not isinstance(request, dict) or request.get("source") != source
                    or path.stem != request.get("id")):
                continue
            match = completion_match(request, record)
            if match == "fingerprint":
                owners = [call for call in active_calls(session_document(root, source, scope["sessionId"]))
                          if completion_match({"source": source, "createdAt": call["observedAt"],
                                               "correlation": {key: value for key, value in call["correlation"].items()
                                                               if key != "toolUseId"}}, record) == "fingerprint"]
                if len(owners) > 1:
                    continue
            if match:
                matches.append((path, request, match))
        except (OSError, ValueError):
            continue
    # Two identical concurrent calls without shared tool IDs cannot be distinguished.
    ambiguous = sum(match == "fingerprint" for _, _, match in matches) > 1
    for path, request, match in matches:
        if match == "fingerprint" and ambiguous:
            continue
        remove_if_present(path)
        remove_if_present(root / "decisions" / (request["id"] + ".json"))
    return record


def active_calls(document):
    calls = document.get("activeToolCalls", [])
    if not isinstance(calls, list):
        return []
    return [{"correlation": call["correlation"], "observedAt": call["observedAt"], "background": call["background"]}
            for call in calls[-MAX_ACTIVE_CALLS:]
            if isinstance(call, dict) and valid_scope(call.get("correlation"))
            and identifier(call["correlation"].get("sessionId")) and identifier(call["correlation"].get("toolUseId"))
            and finite_number(call.get("observedAt")) and isinstance(call.get("background"), bool)]


def ambiguous_ledger(document):
    calls = document.get("activeToolCalls", [])
    return (document.get("activeToolOverflow") is True or not isinstance(calls, list)
            or len(calls) != len(active_calls(document)))


def track_tool(root, source, event):
    if source not in ("claude", "vscode") or event.get("hook_event_name") != "PreToolUse":
        return
    def mark_ambiguity():
        session_id = identifier(event.get("session_id"))
        if session_id:
            with mailbox_lock(root):
                previous = session_document(root, source, session_id)
                session_state(root, source, {"session_id": session_id, "cwd": previous.get("cwd", "")},
                              previous.get("status", "working"), previous.get("message", ""), active_overflow=True)
    try:
        validate_structure(event)
        scope = correlation(event)
    except (ValueError, TypeError, RecursionError):
        mark_ambiguity()
        raise
    if not all(scope.get(field) for field in ("sessionId", "toolUseId", "toolName", "toolInputHash")):
        mark_ambiguity()
        return
    tool_input = event.get("tool_input")
    background = isinstance(tool_input, dict) and tool_input.get("run_in_background") is True
    with mailbox_lock(root):
        previous = session_document(root, source, scope["sessionId"])
        calls = active_calls(previous)
        if any(call["correlation"]["toolUseId"] == scope["toolUseId"] for call in calls):
            return
        calls.append({"correlation": scope, "observedAt": time.time(), "background": background})
        overflow = ambiguous_ledger(previous) or len(calls) > MAX_ACTIVE_CALLS
        session_state(root, source, event, previous.get("status", "working"), active_tools=calls[-MAX_ACTIVE_CALLS:], active_overflow=overflow)


def bind_tool_identity(root, source, request):
    """Link only an unambiguous observed call; do not infer a user decision."""
    scope = request["correlation"]
    if not scope.get("sessionId") or scope.get("toolUseId"):
        return
    previous = session_document(root, source, scope["sessionId"])
    if ambiguous_ledger(previous):
        return
    calls = active_calls(previous)
    if request.get("canRespond") is False:
        # Notification lacks even subagent identity. Count the entire session,
        # including other prompts/agents and background calls, before binding.
        if len(calls) != 1 or calls[0]["background"]:
            return
        candidates = calls
        owner = calls[0]["correlation"]
        if scope.get("promptId") and owner.get("promptId") and scope["promptId"] != owner["promptId"]:
            return
        for path in (root / "requests").glob("*.json"):
            try:
                other = read_json(path, MAX_REQUEST)
                if (isinstance(other, dict) and other.get("source") == source
                        and other.get("sessionId") == request["sessionId"]
                        and finite_number(other.get("expiresAt")) and other["expiresAt"] > time.time()
                        and other.get("correlation", {}).get("toolUseId") != owner["toolUseId"]):
                    return
            except (OSError, ValueError, AttributeError):
                return
    else:
        candidates = [call for call in calls if all(call["correlation"].get(field) == scope.get(field)
                      for field in ("sessionId", "promptId", "turnId", "agentId", "toolName", "toolInputHash"))
                      and (scope.get("agentId") or call["correlation"].get("agentType") == scope.get("agentType"))]
    if len(candidates) == 1 and candidates[0]["observedAt"] <= request["createdAt"]:
        request["correlation"] = dict(candidates[0]["correlation"])


def remaining_tools(root, source, event, record):
    previous = session_document(root, source, str(event.get("session_id", "unknown")))
    if record is None:
        return active_calls(previous)
    if record["eventName"] == "SessionEnd":
        return []
    return [call for call in active_calls(previous)
            if (call["background"] and record["eventName"] in TURN_COMPLETION_EVENTS | {"PostToolUse"})
            or not completion_match({"source": source, "createdAt": call["observedAt"], "correlation": call["correlation"]}, record)]


def handle_telemetry_decision(root, source, event):
    """Observe the originating host's decision; never return or write one."""
    if (not isinstance(event, dict) or source not in ("claude", "vscode") or event.get("decision") not in ("accept", "reject")
            or not isinstance(event.get("source"), str) or event["source"] not in DECISION_SOURCES[event["decision"]] or not identifier(event.get("session_id"))
            or not identifier(event.get("tool_use_id")) or not finite_number(event.get("decided_at"))
            or event["decided_at"] <= 0 or event["decided_at"] > time.time() + 2
            or "prompt_id" in event and not identifier(event["prompt_id"])):
        return
    with mailbox_lock(root):
        previous = session_document(root, source, event["session_id"])
        active_owners = [call for call in active_calls(previous) if call["correlation"]["toolUseId"] == event["tool_use_id"]]
        if active_owners and event["decided_at"] < min(call["observedAt"] for call in active_owners) - 2:
            return
        owners = [call["correlation"] for call in active_owners]
        if not owners:
            owners = [record["correlation"] for record in retirement_records(previous)
                      if record["eventName"] in TOOL_COMPLETION_EVENTS
                      and record["correlation"].get("toolUseId") == event["tool_use_id"]]
            owners = list({json.dumps(owner, sort_keys=True): owner for owner in owners}.values())
        if len(owners) != 1:
            return
        owner = owners[0]
        if event.get("prompt_id") and owner.get("promptId") and event["prompt_id"] != owner["promptId"]:
            return
        completed = {"hook_event_name": TOOL_DECISION_EVENT, "session_id": event["session_id"],
                     "decided_at": event["decided_at"], "tool_use_id": event["tool_use_id"]}
        for input_name, output_name in (("prompt_id", "promptId"), ("turn_id", "turnId"), ("agent_id", "agentId"),
                                        ("agent_type", "agentType"), ("tool_name", "toolName")):
            if owner.get(output_name):
                completed[input_name] = owner[output_name]
        record = retire_requests(root, source, completed)
        session_event = {"session_id": event["session_id"], "cwd": previous.get("cwd", "")}
        status, message = previous.get("status", "working"), previous.get("message", "")
        if active_owners and status == "attention":
            pending = False
            for path in (root / "requests").glob("*.json"):
                try:
                    request = read_json(path, MAX_REQUEST)
                    if (isinstance(request, dict) and request.get("source") == source
                            and request.get("sessionId") == event["session_id"]
                            and finite_number(request.get("expiresAt")) and request["expiresAt"] > time.time()):
                        pending = True
                        break
                except (OSError, ValueError):
                    pending = True  # An unreadable pending card cannot prove the session is clear.
                    break
            if not pending:
                status, message = "working", ""
        session_state(root, source, session_event, status, message, retirement=record)


def runtime_directory(value):
    """Use a private, same-user directory; refuse symlinked or public IPC dirs."""
    root = Path(os.path.abspath(os.path.expanduser(str(value))))
    for directory in (root, root / "requests", root / "decisions", root / "sessions", root / "activities"):
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        info = directory.lstat()
        if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
                or info.st_mode & 0o077):
            raise ValueError("Companion runtime must be a private directory owned by you")
    return root


def write_json(path, value):
    encoded = json.dumps(value, ensure_ascii=True, allow_nan=False).encode("utf-8")
    if len(encoded) > MAX_REQUEST:
        raise ValueError("Companion IPC payload is too large")
    fd, temporary = tempfile.mkstemp(prefix=".write-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(encoded)
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def read_json(path, limit=MAX_INPUT * 4):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        info = os.fstat(stream.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or info.st_mode & 0o077 or info.st_size > limit):
            raise ValueError("Invalid companion IPC file")
        raw = stream.read(limit + 1)
        if len(raw) > limit:
            raise ValueError("Companion IPC file is too large")
        return json.loads(raw)


def finite_number(value):
    try:
        return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)
    except OverflowError:
        return False


def validate_structure(value):
    # Bound indentation expansion as well as raw input size before formatting.
    if isinstance(value, dict):
        for field in IDENTITY_INPUT_FIELDS:
            identity = value.get(field)
            if isinstance(identity, str):
                try:
                    if len(identity.encode("utf-8")) > MAX_IDENTIFIER_BYTES:
                        raise ValueError("Hook identity is too large")
                except UnicodeEncodeError as error:
                    raise ValueError("Hook identity is invalid UTF-8") from error
    pending = [(value, 0)]
    count = 0
    while pending:
        node, depth = pending.pop()
        count += 1
        if depth > 32 or count > 50000:
            raise ValueError("Hook input is too complex; use the original approval prompt")
        if isinstance(node, dict):
            pending.extend((child, depth + 1) for child in node.values())
        elif isinstance(node, list):
            pending.extend((child, depth + 1) for child in node)


def companion_alive(root):
    try:
        heartbeat = read_json(root / "heartbeat.json", 4096)
        timestamp = heartbeat.get("updatedAt")
        return finite_number(timestamp) and -2 <= time.time() - timestamp <= HEARTBEAT_AGE
    except (OSError, ValueError, AttributeError):
        return False


def session_state(root, source, event, status, message="", retirement=None, active_tools=None, active_overflow=None):
    session_id = identifier(event.get("session_id")) or "unknown"
    previous = session_document(root, source, session_id)
    retirements = retirement_records(previous)
    if retirement is not None:
        additions = retirement if isinstance(retirement, list) else [retirement]
        retirements = retirement_records({"retirements": retirements + additions})
    retirements, _ = bounded_records(retirements, MAX_RETIREMENT_METADATA)
    calls = active_calls(previous) if active_tools is None else active_calls({"activeToolCalls": active_tools})
    invalid_calls = active_tools is not None and len(calls) != len(active_tools)
    calls, dropped_calls = bounded_records(calls, MAX_ACTIVE_METADATA)
    overflow = ambiguous_ledger(previous) if active_overflow is None else active_overflow
    updated_at = time.time()
    receipts = previous.get("activityReceipts", {})
    receipts = {name: {key: field for key, field in value.items()
                       if (key == "receivedAt" and finite_number(field)) or
                       (key in ("hasSession", "hasTurn", "hasAgentId", "hasAgentType", "hasReplyText", "replyIsShort") and isinstance(field, bool))}
                for name, value in receipts.items()
                if name in ("UserPromptSubmit", "Stop", "Interrupt", "SessionEnd") and isinstance(value, dict)} if isinstance(receipts, dict) else {}
    event_name = event.get("hook_event_name")
    if source in ("codex", "chatgpt-work") and event_name in ("UserPromptSubmit", "Stop", "Interrupt", "SessionEnd"):
        reply = event.get("last_assistant_message")
        receipts[event_name] = {
            "receivedAt": updated_at, "hasSession": identifier(event.get("session_id")) is not None,
            "hasTurn": identifier(event.get("turn_id")) is not None,
            "hasAgentId": bool(event.get("agent_id")), "hasAgentType": bool(event.get("agent_type")),
            "hasReplyText": isinstance(reply, str) and bool(reply.strip()),
            "replyIsShort": isinstance(reply, str) and 0 < len(reply.strip()) <= 240,
        }
    write_json(session_path(root, source, session_id), {
        "source": source,
        "sourceLabel": LABELS[source],
        "sessionId": session_id,
        **session_metadata(root, source, event, previous),
        "cwd": str(event.get("cwd", ""))[:4096],
        "status": status if isinstance(status, str) and status in {"idle", "working", "attention", "offline"} else "working",
        "message": str(message)[:4096],
        "updatedAt": updated_at,
        "retirements": retirements,
        "activeToolCalls": calls,
        "activeToolOverflow": bool(overflow or invalid_calls or dropped_calls),
        "activityReceipts": receipts,
    })
    return updated_at


def remove_if_present(path):
    try:
        path.unlink()
    except OSError:
        pass


def wait_for_response(root, source, event, request, wait, accepted):
    """Publish one immutable request and accept only its correlated response."""
    request_id = request["id"]
    request_path = root / "requests" / (request_id + ".json")
    decision_path = root / "decisions" / (request_id + ".json")
    deadline = time.monotonic() + wait
    result = None
    published = False
    cancelled = False
    attention_at = None
    if len(json.dumps(request, ensure_ascii=True, allow_nan=False).encode()) > MAX_REQUEST:
        raise ValueError("Request is too large; continue in the original app")
    try:
        with mailbox_lock(root):
            bind_tool_identity(root, source, request)
            # A completion can arrive while this hook is formatting its card.
            if already_retired(root, source, request):
                return None
            attention_at = session_state(root, source, event, "attention")
            write_json(request_path, request)
            published = True
        while time.monotonic() < deadline and time.time() < request["expiresAt"]:
            if not companion_alive(root):
                break
            with mailbox_lock(root):
                try:
                    if read_json(request_path, MAX_REQUEST) != request:
                        cancelled = True
                        break
                except (OSError, ValueError):
                    cancelled = True
                    break
                try:
                    response = read_json(decision_path, 4096)
                    decided_at = response.get("decidedAt")
                    if (response.get("id") == request_id and finite_number(decided_at)
                            and request["createdAt"] <= decided_at <= min(time.time(), request["expiresAt"])
                            and accepted(response)):
                        result = response
                        break
                except (OSError, ValueError, AttributeError):
                    pass
            time.sleep(0.1)
    finally:
        with mailbox_lock(root):
            remove_if_present(request_path)
            remove_if_present(decision_path)
            if published and not cancelled:
                try:
                    current = session_document(root, source, request["sessionId"])
                    if current.get("updatedAt") == attention_at:
                        answered = result is not None and result.get("decision") != "defer"
                        session_state(root, source, event, "working" if answered else "attention",
                                      "" if answered else "Continue in the original app")
                except (OSError, ValueError):
                    pass
    return result


def accepts_permission_response(request, response):
    if not isinstance(response, dict) or set(response) != {"id", "decision", "decidedAt"}:
        return False
    decision = response.get("decision")
    return decision in ("allow", "deny") or decision == "defer" and request.get("canDefer") is True


def permission_request(root, source, event, wait=120, is_demo=False):
    # No UI, no decision: return to the originating agent's normal approval flow.
    if not companion_alive(root):
        return None
    if not isinstance(event.get("tool_name"), str) or not event["tool_name"]:
        raise ValueError("PermissionRequest has no tool name")
    if "tool_input" not in event:
        raise ValueError("PermissionRequest has no tool input")
    validate_structure(event)
    created = time.time()
    request_id = uuid.uuid4().hex
    input_value = event["tool_input"]
    reason = input_value.get("description", "") if isinstance(input_value, dict) else ""
    request = {
        "schemaVersion": 1,
        "id": request_id,
        "source": source,
        "sourceLabel": LABELS[source],
        "sessionId": str(event.get("session_id", "unknown")),
        **session_metadata(root, source, event),
        "toolName": event["tool_name"],
        "cwd": str(event.get("cwd", "")),
        "reason": str(reason or "Review the complete tool input before deciding."),
        "detailText": json.dumps(input_value, indent=2, ensure_ascii=True, allow_nan=False),
        "isDemo": is_demo,
        "canRespond": True,
        "canDefer": True,
        "kind": "permission",
        "correlation": correlation(event),
        "createdAt": created,
        "expiresAt": created + wait,
    }
    result = wait_for_response(root, source, event, request, wait,
                               lambda response: accepts_permission_response(request, response))
    if result is None or result["decision"] == "defer":
        return None
    decision_output = {"behavior": result["decision"]}
    if result["decision"] == "deny":
        decision_output["message"] = "Denied by the user in Agent Companion."
    return {"hookSpecificOutput": {
        "hookEventName": "PermissionRequest", "decision": decision_output,
    }}


def validate_questions(tool_input):
    if not isinstance(tool_input, dict):
        raise ValueError("Question tool input must be an object")
    questions = tool_input.get("questions")
    if not isinstance(questions, list) or not 1 <= len(questions) <= 4:
        raise ValueError("Expected one to four questions")
    question_texts = []
    for question in questions:
        if not isinstance(question, dict) or not isinstance(question.get("question"), str) or not question["question"].strip():
            raise ValueError("Question text must be nonempty")
        question_texts.append(question["question"])
        options = question.get("options")
        if not isinstance(options, list) or not 2 <= len(options) <= 4:
            raise ValueError("Expected two to four question options")
        labels = [option.get("label") if isinstance(option, dict) else None for option in options]
        if any(not isinstance(label, str) or not label.strip() for label in labels) or len(set(labels)) != len(labels):
            raise ValueError("Question options must have distinct text labels")
        if "multiSelect" in question and not isinstance(question["multiSelect"], bool):
            raise ValueError("multiSelect must be boolean")
    if len(set(question_texts)) != len(question_texts):
        raise ValueError("Question text must be unique")
    return questions


def question_request(root, source, event, wait=120, is_demo=False):
    if not companion_alive(root):
        return None
    validate_structure(event)
    tool_input = event.get("tool_input")
    questions = validate_questions(tool_input)
    created = time.time()
    request = {
        "schemaVersion": 1, "id": uuid.uuid4().hex, "source": source,
        "sourceLabel": LABELS[source], "sessionId": str(event.get("session_id", "unknown")),
        **session_metadata(root, source, event),
        "toolName": "AskUserQuestion", "cwd": str(event.get("cwd", "")),
        "reason": "Choose an answer to continue.", "detailText": json.dumps(tool_input, indent=2, ensure_ascii=True),
        "isDemo": is_demo, "canRespond": True, "kind": "question", "questions": questions,
        "correlation": correlation(event),
        "createdAt": created, "expiresAt": created + wait,
    }
    expected = {question["question"] for question in questions}

    def accepts(response):
        if response.get("decision") == "defer":
            return True
        answers = response.get("answers")
        return (response.get("decision") == "answer" and isinstance(answers, dict)
                and set(answers) == expected
                and all(isinstance(value, str) and value.strip() for value in answers.values()))

    response = wait_for_response(root, source, event, request, wait, accepts)
    if response is None or response["decision"] == "defer":
        return None
    # Keep every original tool argument, including the exact question array.
    updated = dict(tool_input)
    updated["answers"] = response["answers"]
    return {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow", "updatedInput": updated}}


def codex_question_notice(root, source, event):
    if not companion_alive(root):
        return
    created = time.time()
    request = {
        "schemaVersion": 1, "id": uuid.uuid4().hex, "source": source,
        "sourceLabel": LABELS[source], "sessionId": str(event.get("session_id", "unknown")),
        **session_metadata(root, source, event),
        "toolName": "Question", "cwd": str(event.get("cwd", "")),
        "reason": "A question is waiting. Answer it in the original app.",
        "detailText": json.dumps(event.get("tool_input", {}), indent=2, ensure_ascii=True),
        "isDemo": False, "canRespond": False, "kind": "notice",
        "correlation": correlation(event),
        "createdAt": created, "expiresAt": created + 120,
    }
    with mailbox_lock(root):
        bind_tool_identity(root, source, request)
        if already_retired(root, source, request):
            return
        write_json(root / "requests" / (request["id"] + ".json"), request)
        session_state(root, source, event, "working")


def permission_notification(root, source, event):
    # Claude sandbox network prompts have an alert hook but no decision hook.
    if event.get("notification_type") != "permission_prompt" or not companion_alive(root):
        return
    title, message = event.get("title", "Permission needed"), event.get("message", "")
    if not isinstance(title, str) or not isinstance(message, str):
        raise ValueError("Notification title and message must be text")
    created = time.time()
    request_id = uuid.uuid4().hex
    request = {
        "schemaVersion": 1, "id": request_id, "source": source,
        "sourceLabel": LABELS[source], "sessionId": str(event.get("session_id", "unknown")),
        **session_metadata(root, source, event),
        "toolName": "Permission alert", "cwd": str(event.get("cwd", "")),
        "reason": title or "Permission needed",
        "detailText": json.dumps({"message": message, "notification_type": "permission_prompt"},
                                 indent=2, ensure_ascii=True),
        "isDemo": False, "canRespond": False, "createdAt": created, "expiresAt": created + 120,
        "correlation": correlation(event),
    }
    with mailbox_lock(root):
        bind_tool_identity(root, source, request)
        if already_retired(root, source, request):
            return
        write_json(root / "requests" / (request_id + ".json"), request)
        session_state(root, source, event, "attention", "Continue in the original app")


def handle_hook(root, source, event, wait=120):
    if not isinstance(event, dict):
        raise ValueError("Hook input must be a JSON object")
    validate_structure(event)
    event_name = event.get("hook_event_name")
    if not isinstance(event_name, str):
        raise ValueError("Hook event name must be text")
    if event_name == "PermissionRequest":
        with mailbox_lock(root):
            publish_codex_activity(root, source, event)
        return permission_request(root, source, event, wait)
    if event_name == "PreToolUse":
        tool_name = event.get("tool_name", "")
        if tool_name == "AskUserQuestion" and source in ("claude", "vscode"):
            return question_request(root, source, event, wait)
        if source in ("codex", "chatgpt-work") and isinstance(tool_name, str) and tool_name.split(".")[-1] in ("request_user_input", "request_user_input_async"):
            codex_question_notice(root, source, event)
            return None
    if event_name == "Notification" and source in ("claude", "vscode"):
        permission_notification(root, source, event)
    if event_name == "PostToolBatch" and source in ("claude", "vscode"):
        calls = event.get("tool_calls")
        if not isinstance(calls, list):
            raise ValueError("PostToolBatch tool_calls must be an array")
        with mailbox_lock(root):
            records = []
            for call in calls:
                if isinstance(call, dict):
                    completed = {**event, "hook_event_name": "PostToolUse"}
                    for field in ("tool_name", "tool_input", "tool_use_id", "tool_response"):
                        if field in call:
                            completed[field] = call[field]
                    record = retire_requests(root, source, completed)
                    if record is not None:
                        records.append(record)
                        session_state(root, source, event, "working", active_tools=remaining_tools(root, source, completed, record))
            session_state(root, source, event, "working", retirement=records)
        return None
    if event_name in STATES:
        with mailbox_lock(root):
            publish_codex_activity(root, source, event)
            retirement = None
            if event_name in TOOL_COMPLETION_EVENTS | TURN_COMPLETION_EVENTS:
                retirement = retire_requests(root, source, event)
            session_state(root, source, event, STATES[event_name], retirement=retirement,
                          active_tools=remaining_tools(root, source, event, retirement),
                          active_overflow=False if event_name == "SessionEnd" else None)
    return None


def publish_codex_activity(root, source, event):
    """A bounded, transient feed of official hook payloads, never transcripts."""
    if source not in ("codex", "chatgpt-work") or event.get("agent_id") or event.get("agent_type"):
        return
    phases = {"UserPromptSubmit": "thinking", "Stop": "completed", "Interrupt": "reset", "SessionEnd": "reset",
              "PreToolUse": "working", "PostToolUse": "working", "PermissionRequest": "working"}
    phase = phases.get(event.get("hook_event_name"))
    session = identifier(event.get("session_id"))
    turn = identifier(event.get("turn_id"))
    if not phase or not session or (not turn and event.get("hook_event_name") != "SessionEnd"):
        return
    try:
        heartbeat = read_json(root / "heartbeat.json", 4096)
        if not companion_alive(root) or heartbeat.get("codexActivity") is not True:
            return
    except (OSError, ValueError, AttributeError):
        return
    now = time.time()
    directory = root / "activities"
    for path in sorted(directory.glob("*.json"), key=lambda path: path.name)[:-63]:
        remove_if_present(path)
    for path in directory.glob("*.json"):
        try:
            item = read_json(path, 8192)
            if not finite_number(item.get("createdAt")) or now - item["createdAt"] > 10:
                remove_if_present(path)
        except (OSError, ValueError, AttributeError):
            remove_if_present(path)
    # The complete reply must be short. Never publish a prefix of a long answer.
    reply = event.get("last_assistant_message")
    reply = reply.strip() if isinstance(reply, str) else None
    if phase != "completed" or not reply or len(reply) > 240 or len(reply.encode("utf-8")) > 2048:
        reply = None
    digest = lambda value: hashlib.sha256(value.encode("utf-8")).hexdigest()
    event_id = uuid.uuid4().hex
    write_json(directory / (event_id + ".json"), {
        "id": event_id, "session": digest(source + ":" + session),
        "turn": digest(source + ":" + session + ":" + turn) if turn else None,
        "phase": phase, "reply": reply, "createdAt": now,
    })


def demonstration(root, wait):
    if not companion_alive(root):
        print("Start Agent Companion with ./run.sh before running the demo.", file=sys.stderr)
        return 1
    samples = [
        ("claude", "Bash", {"command": "npm install", "description": "Install project dependencies"}),
        ("chatgpt-work", "Bash", {"command": "git push origin feature/example", "description": "Push the example branch"}),
        ("vscode", "Edit", {"file_path": "/example/project/src/App.tsx", "old_string": "Hello", "new_string": "Hello from the companion"}),
    ]
    print("DEMO: three simulated requests. No displayed commands will be executed.", flush=True)

    def one(sample):
        source, tool, tool_input = sample
        event = {"session_id": "demo-" + source, "cwd": "/example/project",
                 "tool_name": tool, "tool_input": tool_input}
        output = permission_request(root, source, event, wait, is_demo=True)
        outcome = output["hookSpecificOutput"]["decision"]["behavior"] if output else "no decision"
        session_state(root, source, event, "idle")
        print(LABELS[source] + ": " + outcome + " (simulation only)", flush=True)

    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as executor:
        for completed in concurrent.futures.as_completed([executor.submit(one, x) for x in samples]):
            completed.result()
    return 0


def bounded_wait(value):
    number = float(value)
    if not math.isfinite(number) or not 0 < number <= 300:
        raise argparse.ArgumentTypeError("wait must be between 0 and 300 seconds")
    return number


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for name in ("hook", "demo", "telemetry"):
        subparser = subparsers.add_parser(name)
        subparser.add_argument("--runtime", default=os.environ.get("PET_RUNTIME_DIR", str(DEFAULT_RUNTIME)))
        subparser.add_argument("--wait", type=bounded_wait, default=120)
        if name == "hook":
            subparser.add_argument("--source", choices=LABELS, required=True)
            subparser.add_argument("--track-tools", action="store_true")
            subparser.add_argument("--track-activity", action="store_true")
    arguments = parser.parse_args()
    try:
        root = runtime_directory(arguments.runtime)
        if arguments.command == "demo":
            return demonstration(root, arguments.wait)
        raw = sys.stdin.buffer.read(MAX_INPUT + 1)
        if len(raw) > MAX_INPUT:
            raise ValueError("Hook input is too large; use the original approval prompt")
        event = json.loads(raw)
        if arguments.command == "telemetry":
            from telemetry import parse_tool_decisions
            if not isinstance(event, dict) or not isinstance(event.get("resourceLogs"), list):
                raise ValueError("Telemetry input must be an OTLP JSON logs envelope")
            for decision in parse_tool_decisions(event):
                handle_telemetry_decision(root, "claude", decision)
            return 0
        if arguments.track_activity:
            if not isinstance(event, dict) or event.get("hook_event_name") != "PreToolUse":
                raise ValueError("Activity tracking requires a PreToolUse event")
            validate_structure(event)
            with mailbox_lock(root):
                publish_codex_activity(root, arguments.source, event)
            return 0
        if arguments.track_tools:
            if not isinstance(event, dict):
                raise ValueError("Hook input must be a JSON object")
            track_tool(root, arguments.source, event)
            return 0
        output = handle_hook(root, arguments.source, event, arguments.wait)
        if output is not None:
            print(json.dumps(output, allow_nan=False), flush=True)
    except (OSError, ValueError, TypeError, RecursionError, KeyboardInterrupt) as error:
        print("Agent Companion: " + str(error) + "; use the original app's approval prompt.", file=sys.stderr)
        return 0 if arguments.command == "hook" else 1
    return 0


if __name__ == "__main__":
    def terminated(*_):
        raise KeyboardInterrupt()

    signal.signal(signal.SIGTERM, terminated)
    sys.exit(main())
