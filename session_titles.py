"""Read title metadata, including bounded ends of one exact Claude session file.

Only dedicated title records are decoded from Claude's JSONL file. Prompts,
assistant replies, summaries and tool records never become title candidates.
"""

import json
import os
from pathlib import Path
import re
import sqlite3
import stat
import time
import unicodedata
import uuid


MAX_TITLE_BYTES = 512
MAX_INDEX_BYTES = 256 * 1024
MAX_INDEX_LINE_BYTES = 8192
MAX_SIDECAR_BYTES = 8192
MAX_DATABASE_BYTES = 64 * 1024 * 1024
SQLITE_SECONDS = 0.03
MAX_CLAUDE_TITLE_WINDOW_BYTES = 65_536
MAX_CLAUDE_TITLE_RECORD_BYTES = 8192
CLAUDE_TITLE_SECONDS = 0.03
_CLAUDE_TITLE_PREFIX = re.compile(rb'^[ \t]*\{[ \t]*"type"[ \t]*:[ \t]*"(?:custom-title|ai-title)"[ \t]*,')


def canonical_session_id(value):
    if not isinstance(value, str) or len(value) != 36:
        return None
    try:
        canonical = str(uuid.UUID(value))
    except ValueError:
        return None
    return canonical if value.lower() == canonical else None


def clean_title(value):
    if not isinstance(value, str):
        return None
    try:
        if len(value.encode("utf-8")) > MAX_TITLE_BYTES:
            return None
    except UnicodeEncodeError:
        return None
    value = " ".join("".join(" " if unicodedata.category(char).startswith("C") else char
                             for char in value).split())
    return value or None


def session_title_candidate(value, session_id=None, cwd=None):
    """Reject technical identifiers and workspace labels as chat subjects."""
    title = clean_title(value)
    if title is None:
        return None
    identity = re.sub(r"^(?:session(?:\s+(?:id|uuid))?|id|uuid)\s*:?\s*", "", title,
                      count=1, flags=re.IGNORECASE).strip().strip("<>()[]{} ")
    if (re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}|[0-9a-f]{32}", identity, re.IGNORECASE)
            or isinstance(session_id, str) and identity.casefold() == (clean_title(session_id) or "").casefold()):
        return None
    if isinstance(cwd, str):
        directory = cwd.strip().replace("\\", "/").rstrip("/").casefold()
        candidate = title.replace("\\", "/").rstrip("/").casefold()
        if directory and candidate in {directory, directory.rsplit("/", 1)[-1]}:
            return None
    return title


def _owned(info, *, directory=False):
    # Provider metadata commonly uses 0644 files inside 0755 config roots.
    # Reject writable-by-other-user paths without changing provider permissions.
    return ((stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode))
            and info.st_uid == os.getuid() and not info.st_mode & 0o022)


def _absolute_path(value):
    try:
        path = Path(value)
    except (TypeError, ValueError):
        return None
    if not path.is_absolute() or ".." in path.parts or len(str(path)) > 4096:
        return None
    return path


def _root_descriptor(root):
    """Walk every component without following symlinks; retain the final fd."""
    root = _absolute_path(root)
    if root is None:
        raise ValueError("Invalid metadata root")
    descriptor = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in root.parts[1:]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK,
                            dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        if not _owned(os.fstat(descriptor), directory=True):
            raise ValueError("Untrusted metadata directory")
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def _file_descriptor(root, parts, limit):
    if not parts or any(not isinstance(part, str) or part in ("", ".", "..") or "/" in part for part in parts):
        raise ValueError("Invalid metadata path")
    directory = _root_descriptor(root)
    try:
        for part in parts[:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK,
                            dir_fd=directory)
            os.close(directory)
            directory = child
            if not _owned(os.fstat(directory), directory=True):
                raise ValueError("Untrusted metadata directory")
        descriptor = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        try:
            info = os.fstat(descriptor)
            if not _owned(info) or (limit is not None and info.st_size > limit):
                raise ValueError("Untrusted or oversized metadata file")
            return descriptor, info
        except BaseException:
            os.close(descriptor)
            raise
    finally:
        os.close(directory)


def _read_metadata(root, parts, limit):
    descriptor, _ = _file_descriptor(root, parts, limit)
    with os.fdopen(descriptor, "rb") as stream:
        raw = stream.read(limit + 1)
    if len(raw) > limit:
        raise ValueError("Metadata grew beyond its bound")
    return raw


def _read_latest_metadata(root, parts, limit):
    """Read a fixed-size latest window from a growing title-only index."""
    descriptor, initial = _file_descriptor(root, parts, None)
    try:
        length = min(initial.st_size, limit)
        offset = max(0, initial.st_size - length)
        raw = os.pread(descriptor, length, offset)
        if len(raw) != length:
            raise ValueError("Metadata file shrank during reading")
        if offset:
            boundary = raw.find(b"\n")
            raw = raw[boundary + 1:] if boundary >= 0 else b""
        final = os.fstat(descriptor)
        if (not _owned(final) or (initial.st_dev, initial.st_ino) != (final.st_dev, final.st_ino)
                or final.st_size < initial.st_size
                or final.st_size == initial.st_size and final.st_mtime_ns != initial.st_mtime_ns):
            raise ValueError("Metadata changed during reading")
        current_descriptor, current = _file_descriptor(root, parts, None)
        try:
            if ((initial.st_dev, initial.st_ino) != (current.st_dev, current.st_ino)
                    or current.st_size < initial.st_size
                    or current.st_size == initial.st_size and current.st_mtime_ns != initial.st_mtime_ns):
                raise ValueError("Metadata pathname changed during reading")
        finally:
            os.close(current_descriptor)
        return raw
    finally:
        os.close(descriptor)


def _codex_index(root, session_id, cwd=None):
    raw = _read_latest_metadata(root, ("session_index.jsonl",), MAX_INDEX_BYTES)
    for line in reversed(raw.splitlines()):
        if len(line) > MAX_INDEX_LINE_BYTES:
            continue
        try:
            record = json.loads(line, object_pairs_hook=_unique_title_object)
        except (ValueError, UnicodeError, RecursionError):
            continue
        if (isinstance(record, dict) and set(record) == {"id", "thread_name", "updated_at"}
                and all(isinstance(field, str) for field in record.values())
                and canonical_session_id(record.get("id")) == session_id):
            title = session_title_candidate(record.get("thread_name"), session_id, cwd)
            if title:
                return title
    return None


def _same_cwd(record_cwd, event_cwd):
    if not record_cwd:
        return True
    record, event = _absolute_path(record_cwd), _absolute_path(event_cwd)
    return record is not None and event is not None and os.path.normpath(record) == os.path.normpath(event)


def _codex_database(root, session_id, cwd):
    # Immutable read mode never creates journals/shared-memory files and never
    # changes provider state. A very recent WAL-only rename may await the index.
    descriptor, initial = _file_descriptor(root, ("state_5.sqlite",), MAX_DATABASE_BYTES)
    connection = None
    try:
        path = root / "state_5.sqlite"
        connection = sqlite3.connect(path.as_uri() + "?mode=ro&immutable=1", uri=True, timeout=SQLITE_SECONDS)
        deadline = time.monotonic() + SQLITE_SECONDS
        connection.set_progress_handler(lambda: int(time.monotonic() >= deadline), 100)
        connection.execute("PRAGMA query_only=ON")
        connection.execute("PRAGMA trusted_schema=OFF")
        row = connection.execute("SELECT name,cwd FROM threads WHERE id=? LIMIT 1", (session_id,)).fetchone()
        final = os.stat(path, follow_symlinks=False)
        if (not _owned(final) or (initial.st_dev, initial.st_ino, initial.st_size, initial.st_mtime_ns)
                != (final.st_dev, final.st_ino, final.st_size, final.st_mtime_ns)):
            return None
        return session_title_candidate(row[0], session_id, cwd) if row and _same_cwd(row[1], cwd) else None
    finally:
        if connection is not None:
            connection.close()
        os.close(descriptor)


def _claude_project(event, environ):
    transcript = _absolute_path(event.get("transcript_path"))
    session_id = canonical_session_id(event.get("session_id"))
    if transcript is not None and session_id is not None and transcript.name == session_id + ".jsonl":
        return transcript.parent
    project_name = environ.get("CLAUDE_CODE_PROJECT_DIR_NAME")
    if (isinstance(project_name, str) and 0 < len(project_name) <= 255
            and re.fullmatch(r"[A-Za-z0-9_-]+", project_name)):
        return project_name
    cwd = _absolute_path(event.get("cwd"))
    if cwd is not None:
        encoded = re.sub(r"[^A-Za-z0-9]", "-", str(cwd))
        return encoded if len(encoded) <= 255 else None
    return None


def _claude_project_key(root, event, environ):
    project = _claude_project(event, environ)
    if isinstance(project, Path):
        if project.parent != root / "projects":
            return None
        project = project.name
    if not isinstance(project, str):
        return None
    return project


def _claude_sidecar(root, event, environ, session_id):
    project = _claude_project_key(root, event, environ)
    if project is None:
        return None
    raw = _read_metadata(root, ("projects", project, session_id, "custom-title.json"), MAX_SIDECAR_BYTES)
    record = json.loads(raw, object_pairs_hook=_unique_title_object)
    return session_title_candidate(record.get("customTitle"), session_id, event.get("cwd")) if isinstance(record, dict) and set(record) == {"customTitle"} else None


def _unique_title_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate title metadata key")
        result[key] = value
    return result


def _claude_title_record(line, session_id, cwd=None):
    # Verified Claude Code 2.1.312 writes type first. Filtering the top-level
    # prefix before JSON decoding excludes message/tool records and strings
    # containing nested or escaped title-looking text.
    if len(line) > MAX_CLAUDE_TITLE_RECORD_BYTES or not _CLAUDE_TITLE_PREFIX.match(line):
        return None
    try:
        record = json.loads(line, object_pairs_hook=_unique_title_object)
    except (ValueError, UnicodeError, RecursionError):
        return None
    if not isinstance(record, dict):
        return None
    kind = record.get("type")
    field = {"custom-title": "customTitle", "ai-title": "aiTitle"}.get(kind)
    if (field is None or set(record) != {"type", "sessionId", field}
            or canonical_session_id(record.get("sessionId")) != session_id):
        return None
    value = record[field]
    if not isinstance(value, str):
        return None
    try:
        if len(value.encode("utf-8")) > MAX_TITLE_BYTES:
            return None
    except UnicodeEncodeError:
        return None
    # A valid empty latest value clears that kind of title. Invalid records do
    # not count as a rename and cannot introduce a message-derived fallback.
    cleaned = clean_title(value)
    if cleaned is None:
        return kind, None
    candidate = session_title_candidate(cleaned, session_id, cwd)
    return (kind, candidate) if candidate else None


def _claude_title_records(root, event, environ, session_id, sidecar=None):
    fallback = (sidecar, "claude-custom-title") if sidecar else (None, None)
    project = _claude_project_key(root, event, environ)
    if project is None:
        return fallback
    deadline = time.monotonic() + CLAUDE_TITLE_SECONDS
    parts = ("projects", project, session_id + ".jsonl")
    descriptor, initial = _file_descriptor(root, parts, None)
    try:
        size = initial.st_size
        if size <= 0:
            return fallback
        windows = [(0, min(size, MAX_CLAUDE_TITLE_WINDOW_BYTES))]
        tail_start = max(0, size - MAX_CLAUDE_TITLE_WINDOW_BYTES)
        if size > MAX_CLAUDE_TITLE_WINDOW_BYTES:
            windows.append((tail_start, MAX_CLAUDE_TITLE_WINDOW_BYTES))
        records = {}
        for offset, length in windows:
            if time.monotonic() >= deadline:
                return fallback
            raw = os.pread(descriptor, length, offset)
            if len(raw) != length:
                return fallback
            line_offset = offset
            if offset:
                # Its first byte is boundary context. Discard everything up to
                # the first newline, so a suffix of a message cannot imitate a
                # complete title record. Any overlap with the head is harmless.
                boundary = raw.find(b"\n")
                line_offset += boundary + 1 if boundary >= 0 else len(raw)
                raw = raw[boundary + 1:] if boundary >= 0 else b""
            boundary = raw.rfind(b"\n")
            raw = raw[:boundary] if boundary >= 0 else b""
            for line in raw.split(b"\n"):
                if time.monotonic() >= deadline:
                    return fallback
                record = _claude_title_record(line, session_id, event.get("cwd"))
                if record is not None:
                    records[line_offset] = record
                line_offset += len(line) + 1
        final = os.fstat(descriptor)
        if (not _owned(final) or (initial.st_dev, initial.st_ino) != (final.st_dev, final.st_ino)
                or final.st_size < initial.st_size
                or final.st_size == initial.st_size and final.st_mtime_ns != initial.st_mtime_ns):
            return fallback
        # A descriptor remains valid when its pathname is replaced. Walk and
        # reopen the exact path without following links before trusting its old
        # snapshot, so retired/replaced files cannot keep a stale header alive.
        current_descriptor, current = _file_descriptor(root, parts, None)
        try:
            if ((initial.st_dev, initial.st_ino) != (current.st_dev, current.st_ino)
                    or current.st_size < initial.st_size):
                return fallback
        finally:
            os.close(current_descriptor)
        # Appends may proceed while the hook runs. Both windows were bounded by
        # the original size, and only newline-terminated snapshot records count.
        head, tail = {}, {}
        for offset, (kind, value) in sorted(records.items()):
            (tail if offset >= tail_start else head)[kind] = value
        # Match the installed extension: tail custom, manual sidecar, head
        # custom, then tail/head AI. Absolute offsets deduplicate overlapping
        # windows and make every record in a small file a tail candidate.
        if "custom-title" in tail:
            if tail["custom-title"]:
                return tail["custom-title"], "claude-custom-title-record"
            # A deliberate clear must not resurrect an older sidecar/head name.
        elif sidecar:
            return fallback
        elif head.get("custom-title"):
            return head["custom-title"], "claude-custom-title-record"
        if "ai-title" in tail:
            if tail["ai-title"]:
                return tail["ai-title"], "claude-ai-title-record"
        elif head.get("ai-title"):
            return head["ai-title"], "claude-ai-title-record"
        return None, None
    finally:
        os.close(descriptor)


def lookup_session_title(source, event, *, home=None, environ=None):
    """Return (title, metadata source); never use prompts, replies or summaries."""
    if not isinstance(event, dict) or (session_id := canonical_session_id(event.get("session_id"))) is None:
        return None, None
    home = Path.home() if home is None else Path(home)
    environ = os.environ if environ is None else environ
    config = "CODEX_HOME" if source == "codex" else "CLAUDE_CONFIG_DIR"
    if source not in ("codex", "claude", "vscode"):
        return None, None
    root = _absolute_path(environ.get(config) or home / (".codex" if source == "codex" else ".claude"))
    if root is None:
        return None, None
    if source in ("claude", "vscode"):
        sidecar = None
        try:
            sidecar = _claude_sidecar(root, event, environ, session_id)
        except (OSError, ValueError, TypeError, UnicodeError, RecursionError):
            pass
        try:
            return _claude_title_records(root, event, environ, session_id, sidecar)
        except (OSError, ValueError, TypeError, UnicodeError, RecursionError):
            return (sidecar, "claude-custom-title") if sidecar else (None, None)
    readers = (("codex-index", lambda: _codex_index(root, session_id, event.get("cwd"))),
               ("codex-database", lambda: _codex_database(root, session_id, event.get("cwd"))))
    for label, read in readers:
        try:
            title = read()
        except (OSError, ValueError, TypeError, UnicodeError, sqlite3.Error, RecursionError):
            continue
        if title:
            return title, label
    return None, None
