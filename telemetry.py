"""Decode Claude's permission-decision metadata without retaining log content.

Protocol: https://opentelemetry.io/docs/specs/otlp/#otlphttp
Event: https://code.claude.com/docs/en/monitoring-usage#tool-decision-event
Only the original event time and correlation/decision fields leave this module.
"""

from datetime import datetime, timezone
import math
import re
import time


MAX_RESOURCE_LOGS = 32
MAX_SCOPE_LOGS = 128
MAX_LOG_RECORDS = 2048
MAX_ATTRIBUTES = 128
MAX_KEY_BYTES = 128
MAX_VALUE_BYTES = 4096
MAX_IDENTIFIER_BYTES = 512
CLOCK_SKEW_SECONDS = 5.0
TIMESTAMP_AGREEMENT_SECONDS = 1.0
MAX_UINT64 = (1 << 64) - 1
ANY_VALUE_FIELDS = frozenset(("stringValue", "boolValue", "intValue", "doubleValue",
                              "arrayValue", "kvlistValue", "bytesValue"))
DECISION_SOURCES = {
    "accept": frozenset(("config", "hook", "user_temporary", "user_permanent")),
    "reject": frozenset(("config", "hook", "user_abort", "user_reject")),
}
EVENT_FIELDS = frozenset(("session.id", "prompt.id", "tool_use_id", "decision", "source",
                          "event.name", "event.timestamp"))
RFC3339 = re.compile(
    r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}:\d{2})$"
)
DECIMAL_INTEGER = re.compile(r"^[0-9]{1,20}$")


def _bounded_text(value, limit):
    if not isinstance(value, str) or len(value) > limit:
        return False
    try:
        return len(value.encode("utf-8")) <= limit
    except UnicodeEncodeError:
        return False


def _strings(attributes, wanted):
    """Inspect bounded KeyValues; never coerce a non-string identity to text."""
    if not isinstance(attributes, list) or len(attributes) > MAX_ATTRIBUTES:
        return None
    result, seen = {}, set()
    for attribute in attributes:
        if not isinstance(attribute, dict):
            return None
        key, value = attribute.get("key"), attribute.get("value")
        if (not _bounded_text(key, MAX_KEY_BYTES) or not key or key in seen
                or not isinstance(value, dict)):
            return None
        seen.add(key)
        types = ANY_VALUE_FIELDS.intersection(value)
        if len(types) != 1:
            return None
        if "stringValue" in types:
            text = value["stringValue"]
            if not _bounded_text(text, MAX_VALUE_BYTES):
                return None
        if key in wanted:
            if "stringValue" not in types:
                return None
            result[key] = value["stringValue"]
    return result


def _identifier(value):
    return (value if _bounded_text(value, MAX_IDENTIFIER_BYTES) and value
            and not any(character.isspace() or ord(character) < 32 or ord(character) == 127
                        for character in value) else None)


def _iso_time(value):
    if not isinstance(value, str):
        return None
    match = RFC3339.fullmatch(value)
    if match is None:
        return None
    date, fraction, offset = match.groups()
    if offset != "Z" and (int(offset[1:3]) > 23 or int(offset[4:6]) > 59):
        return None
    try:
        instant = datetime.fromisoformat(date + ("+00:00" if offset == "Z" else offset))
        # Parse the fraction separately so nine-digit input is not silently
        # truncated to datetime's six-digit microsecond precision.
        return instant.astimezone(timezone.utc).timestamp() + int((fraction or "").ljust(9, "0")) / 1_000_000_000
    except (OverflowError, ValueError, OSError):
        return None


def _event_time(record, attributes, now):
    nanos = record.get("timeUnixNano")
    nano_time = None
    if nanos is not None:
        if isinstance(nanos, bool) or not isinstance(nanos, (int, str)):
            return None
        if isinstance(nanos, str):
            if DECIMAL_INTEGER.fullmatch(nanos) is None:
                return None
            nanos = int(nanos)
        if not 0 <= nanos <= MAX_UINT64:
            return None
        if nanos:
            nano_time = nanos / 1_000_000_000
    iso_time = None
    if "event.timestamp" in attributes:
        iso_time = _iso_time(attributes["event.timestamp"])
        if iso_time is None:
            return None
    if (nano_time is not None and iso_time is not None
            and abs(nano_time - iso_time) > TIMESTAMP_AGREEMENT_SECONDS):
        return None
    decided_at = nano_time if nano_time is not None else iso_time
    if (decided_at is None or not math.isfinite(decided_at) or decided_at <= 0
            or decided_at > now + CLOCK_SKEW_SECONDS):
        return None
    return decided_at


def _decision(record, now):
    if not isinstance(record, dict):
        return None
    body = record.get("body")
    if (not isinstance(body, dict) or ANY_VALUE_FIELDS.intersection(body) != {"stringValue"}
            or body.get("stringValue") != "claude_code.tool_decision"):
        return None
    attributes = _strings(record.get("attributes"), EVENT_FIELDS)
    if attributes is None or attributes.get("event.name", "tool_decision") != "tool_decision":
        return None
    session_id = _identifier(attributes.get("session.id"))
    tool_use_id = _identifier(attributes.get("tool_use_id"))
    if session_id is None or tool_use_id is None:
        return None
    prompt_id = None
    if "prompt.id" in attributes:
        prompt_id = _identifier(attributes["prompt.id"])
        if prompt_id is None:
            return None
    decision, source = attributes.get("decision"), attributes.get("source")
    if source not in DECISION_SOURCES.get(decision, ()):
        return None
    decided_at = _event_time(record, attributes, now)
    if decided_at is None:
        return None
    result = {"session_id": session_id, "tool_use_id": tool_use_id, "decision": decision,
              "source": source, "decided_at": decided_at}
    if prompt_id is not None:
        result["prompt_id"] = prompt_id
    return result


def parse_tool_decisions(document, now=None):
    """Return allowlisted decisions from a decoded OTLP/HTTP JSON envelope.

    Invalid records are skipped. Envelopes exceeding traversal limits are
    rejected as a whole. Old batched events retain their original timestamps;
    observedTimeUnixNano and the receiver's arrival time never substitute.
    """
    if now is None:
        now = time.time()
    if isinstance(now, bool) or not isinstance(now, (int, float)):
        return []
    try:
        now = float(now)
    except OverflowError:
        return []
    if not math.isfinite(now) or now <= 0:
        return []
    if not isinstance(document, dict):
        return []
    resources = document.get("resourceLogs")
    if not isinstance(resources, list) or len(resources) > MAX_RESOURCE_LOGS:
        return []
    result, scope_count, record_count = [], 0, 0
    for resource_logs in resources:
        if not isinstance(resource_logs, dict):
            continue
        resource = resource_logs.get("resource")
        if not isinstance(resource, dict):
            continue
        attributes = _strings(resource.get("attributes"), {"service.name"})
        if attributes is None or attributes.get("service.name") != "claude-code":
            continue
        scopes = resource_logs.get("scopeLogs")
        if not isinstance(scopes, list):
            continue
        scope_count += len(scopes)
        if scope_count > MAX_SCOPE_LOGS:
            return []
        for scope_logs in scopes:
            if not isinstance(scope_logs, dict):
                continue
            scope = scope_logs.get("scope")
            if not isinstance(scope, dict) or scope.get("name") != "com.anthropic.claude_code.events":
                continue
            records = scope_logs.get("logRecords")
            if not isinstance(records, list):
                continue
            record_count += len(records)
            if record_count > MAX_LOG_RECORDS:
                return []
            for record in records:
                decision = _decision(record, now)
                if decision is not None:
                    result.append(decision)
    return result
