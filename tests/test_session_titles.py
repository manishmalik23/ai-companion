import json
from contextlib import closing
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import bridge
import session_titles as titles


SESSION = "12345678-1234-4234-8234-123456789abc"
OTHER_SESSION = "12345678-1234-4234-8234-123456789def"


class SessionTitleTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="pip-session-titles-")
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name).resolve()
        self.codex = self.home / ".codex"
        self.claude = self.home / ".claude"
        self.codex.mkdir(mode=0o755)
        self.claude.mkdir(mode=0o755)
        self.event = {"session_id": SESSION, "cwd": "/work/project"}

    def lookup(self, source="codex", event=None, environ=None):
        return titles.lookup_session_title(source, self.event if event is None else event,
                                           home=self.home, environ={} if environ is None else environ)

    def index(self, records):
        path = self.codex / "session_index.jsonl"
        path.write_text("".join(json.dumps(record) + "\n" for record in records))
        path.chmod(0o644)
        return path

    def record(self, name="Fix checkout navigation", session=SESSION, **fields):
        return {"id": session, "thread_name": name, "updated_at": "2026-10-29T00:00:00Z", **fields}

    def database(self, name="Database session name", cwd="/work/project", session=SESSION):
        path = self.codex / "state_5.sqlite"
        with closing(sqlite3.connect(path)) as connection:
            connection.execute("CREATE TABLE threads(id TEXT PRIMARY KEY,name TEXT,cwd TEXT,title TEXT,first_user_message TEXT)")
            connection.execute("INSERT INTO threads VALUES(?,?,?,?,?)",
                               (session, name, cwd, "Legacy prompt must not become a title", "Private body"))
            connection.commit()
        path.chmod(0o644)
        return path

    def sidecar(self, title="Claude custom name", project="-work-project", session=SESSION):
        path = self.claude / "projects" / project / session / "custom-title.json"
        path.parent.mkdir(mode=0o700, parents=True)
        path.write_text(json.dumps({"customTitle": title}))
        path.chmod(0o600)
        return path

    def claude_record(self, title="PROJ-123 sample feature title", *, kind="ai-title", session=SESSION):
        field = "customTitle" if kind == "custom-title" else "aiTitle"
        return {"type": kind, field: title, "sessionId": session}

    def claude_records(self, records=(), *, raw=None, project="-work-project", session=SESSION):
        path = self.claude / "projects" / project / (session + ".jsonl")
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        path.write_bytes(raw if raw is not None else b"".join(json.dumps(record).encode() + b"\n" for record in records))
        path.chmod(0o600)
        return path

    def test_index_selects_exact_session_and_latest_display_title(self):
        self.index([self.record("Old name"), self.record("Other chat", OTHER_SESSION),
                    self.record("  Review\n checkout\u202e \x00 changes  ")])
        self.assertEqual(self.lookup(), ("Review checkout changes", "codex-index"))
        self.assertEqual(self.lookup(event={**self.event, "session_id": OTHER_SESSION}), ("Other chat", "codex-index"))

    def test_index_ignores_unknown_schema_and_invalid_titles_without_prompt_fallback(self):
        records = [self.record("Wrong schema", prompt="Private prompt"),
                   self.record("x" * 513), self.record(None), self.record("\ud800")]
        self.index(records)
        self.assertEqual(self.lookup(), (None, None))
        self.assertEqual(self.lookup(event={**self.event, "prompt": "Private prompt", "summary": "Private summary"}),
                         (None, None))

    def test_session_candidates_reject_workspace_and_technical_id_labels_but_keep_real_subjects(self):
        invalid = [SESSION, OTHER_SESSION, SESSION.replace("-", ""), "ID: " + SESSION,
                   "Session " + OTHER_SESSION, "Session ID: <" + SESSION + ">", "UUID: [" + OTHER_SESSION + "]",
                   "project", "PROJECT", "/work/project", "/WORK/PROJECT///", "\\work\\project\\"]
        for value in invalid:
            with self.subTest(value=value):
                self.assertIsNone(titles.session_title_candidate(value, SESSION, "/work/project"))
        self.assertIsNone(titles.session_title_candidate("ID: local-technical-id", "local-technical-id", "/work/project"))
        self.assertIsNone(titles.session_title_candidate("C:\\Work\\Project\\", SESSION, "c:/work/project"))
        for value in ["Fix project navigation", "Session: Fix checkout", "Investigate " + SESSION + " race", "Project delivery review"]:
            self.assertEqual(titles.session_title_candidate(value, SESSION, "/work/project"), value)

    def test_large_codex_index_uses_only_latest_bounded_tail_and_latest_real_subject(self):
        path = self.index([])
        body = b"x" * (titles.MAX_INDEX_BYTES + 4000) + b"\n"
        body += json.dumps(self.record("Older subject")).encode() + b"\n"
        body += json.dumps(self.record("Fresh provider subject")).encode() + b"\n"
        body += json.dumps(self.record("project")).encode() + b"\n"
        path.write_bytes(body)
        calls, real_pread = [], os.pread

        def bounded(fd, length, offset):
            calls.append((length, offset))
            return real_pread(fd, length, offset)

        with patch.object(titles.os, "pread", side_effect=bounded):
            self.assertEqual(self.lookup(), ("Fresh provider subject", "codex-index"))
        self.assertEqual(calls, [(titles.MAX_INDEX_BYTES, len(body) - titles.MAX_INDEX_BYTES)])

    def test_codex_index_accepts_complete_eof_records_and_rejects_duplicate_keys(self):
        path = self.index([])
        path.write_bytes(json.dumps(self.record("Complete EOF title")).encode())
        self.assertEqual(self.lookup(), ("Complete EOF title", "codex-index"))
        self.database("Database fallback")
        path.write_text('{"id":"' + SESSION + '","thread_name":"First","thread_name":"Duplicate","updated_at":"now"}\n')
        self.assertEqual(self.lookup(), ("Database fallback", "codex-database"))
        path.write_text(json.dumps(self.record("Good complete row")) + '\n{"id":"' + SESSION + '","thread_name":')
        self.assertEqual(self.lookup(), ("Good complete row", "codex-index"))

    def test_bad_codex_index_or_database_labels_do_not_become_session_subjects(self):
        path = self.index([])
        database = self.database("Real stored subject")
        for value in ["project", "/work/project", SESSION, "Session ID: " + OTHER_SESSION]:
            with self.subTest(value=value):
                path.write_text(json.dumps(self.record(value)) + "\n")
                self.assertEqual(self.lookup(), ("Real stored subject", "codex-database"))
        path.unlink()
        for value in ["PROJECT", "/WORK/PROJECT/", OTHER_SESSION, "ID: " + SESSION]:
            with self.subTest(database_name=value), closing(sqlite3.connect(database)) as connection:
                connection.execute("UPDATE threads SET name=?", (value,))
                connection.commit()
                self.assertEqual(self.lookup(), (None, None))

    def test_codex_index_replacement_during_read_uses_database_fallback(self):
        path = self.index([self.record("Retired index title")])
        self.database("Stored fallback")
        real_pread = os.pread

        def replace_after_read(fd, length, offset):
            raw = real_pread(fd, length, offset)
            path.rename(path.with_suffix(".old"))
            path.write_text(json.dumps(self.record("Replacement title")) + "\n")
            return raw

        with patch.object(titles.os, "pread", side_effect=replace_after_read):
            self.assertEqual(self.lookup(), ("Stored fallback", "codex-database"))

    def test_index_accepts_default_provider_permissions_but_rejects_other_writers(self):
        path = self.index([self.record()])
        self.assertEqual(self.lookup()[1], "codex-index")
        for target, mode in ((path, 0o666), (self.codex, 0o777)):
            with self.subTest(target=target.name):
                original = target.stat().st_mode & 0o777
                target.chmod(mode)
                self.assertEqual(self.lookup(), (None, None))
                target.chmod(original)
        with patch.object(titles.os, "getuid", return_value=os.getuid() + 1):
            self.assertEqual(self.lookup(), (None, None))

    def test_symlinked_metadata_file_or_config_directory_is_never_followed(self):
        outside = self.home / "outside.jsonl"
        outside.write_text(json.dumps(self.record()) + "\n")
        path = self.codex / "session_index.jsonl"
        path.symlink_to(outside)
        self.assertEqual(self.lookup(), (None, None))
        path.unlink()
        self.codex.rmdir()
        actual = self.home / "other-codex"
        actual.mkdir()
        (actual / path.name).write_text(outside.read_text())
        self.codex.symlink_to(actual, target_is_directory=True)
        self.assertEqual(self.lookup(), (None, None))

    def test_oversized_nonregular_and_malformed_indexes_fail_without_blocking(self):
        path = self.index([])
        with path.open("wb") as stream:
            stream.truncate(titles.MAX_INDEX_BYTES + 1)
        self.assertEqual(self.lookup(), (None, None))
        path.write_bytes(b'not json\n\xff\n' + b'x' * (titles.MAX_INDEX_LINE_BYTES + 1))
        self.assertEqual(self.lookup(), (None, None))
        path.unlink()
        os.mkfifo(path, 0o600)
        self.assertEqual(self.lookup(), (None, None))

    def test_invalid_session_ids_and_cloud_sources_never_open_provider_metadata(self):
        for session in (None, "", "unknown", "../" + SESSION, SESSION + "/file", "x" * 1024):
            with self.subTest(session=session), patch.object(titles, "_file_descriptor") as opening:
                self.assertEqual(self.lookup(event={**self.event, "session_id": session}), (None, None))
                opening.assert_not_called()
        with patch.object(titles, "_file_descriptor") as opening:
            self.assertEqual(self.lookup("chatgpt-work"), (None, None))
            opening.assert_not_called()

    def test_config_root_override_is_explicit_absolute_and_symlink_safe(self):
        self.index([self.record()])
        self.assertEqual(self.lookup(environ={"CODEX_HOME": str(self.codex)}),
                         ("Fix checkout navigation", "codex-index"))
        for value in ("relative", str(self.codex / ".." / ".codex"), str(self.codex) + "/missing"):
            with self.subTest(value=value):
                self.assertEqual(self.lookup(environ={"CODEX_HOME": value}), (None, None))

    def test_database_name_fallback_is_read_only_and_does_not_select_chat_columns(self):
        path = self.database()
        original, modified = path.read_bytes(), path.stat().st_mtime_ns
        before = set(self.codex.iterdir())
        queries = []
        real_connect = sqlite3.connect

        def connect(*args, **kwargs):
            self.assertIn("mode=ro&immutable=1", args[0])
            connection = real_connect(*args, **kwargs)
            connection.set_trace_callback(queries.append)
            return connection

        with patch.object(titles.sqlite3, "connect", side_effect=connect):
            self.assertEqual(self.lookup(), ("Database session name", "codex-database"))
        selects = [query for query in queries if query.startswith("SELECT")]
        self.assertEqual(len(selects), 1)
        self.assertTrue(selects[0].startswith("SELECT name,cwd FROM threads WHERE id="))
        self.assertEqual(path.read_bytes(), original)
        self.assertEqual(path.stat().st_mtime_ns, modified)
        self.assertEqual(set(self.codex.iterdir()), before)

    def test_index_is_preferred_over_database_and_database_uses_exact_session(self):
        self.database()
        self.index([self.record("Fresh indexed name")])
        self.assertEqual(self.lookup(), ("Fresh indexed name", "codex-index"))
        self.assertEqual(self.lookup(event={**self.event, "session_id": OTHER_SESSION}), (None, None))

    def test_database_never_falls_back_to_legacy_prompt_title(self):
        self.database(name=None)
        self.assertEqual(self.lookup(), (None, None))

    def test_database_rejects_mismatched_cwd_and_oversized_or_symlinked_files(self):
        path = self.database(cwd="/other/workspace")
        self.assertEqual(self.lookup(), (None, None))
        path.unlink()
        outside = self.home / "database.sqlite"
        outside.write_bytes(b"not a database")
        path.symlink_to(outside)
        self.assertEqual(self.lookup(), (None, None))
        path.unlink()
        with path.open("wb") as stream:
            stream.truncate(titles.MAX_DATABASE_BYTES + 1)
        self.assertEqual(self.lookup(), (None, None))

    def test_database_progress_deadline_interrupts_an_unindexed_scan(self):
        path = self.codex / "state_5.sqlite"
        with closing(sqlite3.connect(path)) as connection:
            connection.execute("CREATE TABLE threads(id TEXT,name TEXT,cwd TEXT)")
            connection.executemany("INSERT INTO threads VALUES(?,?,?)", [(str(i), "Name", "/work/project") for i in range(500)])
            connection.commit()
        with patch.object(titles.time, "monotonic", side_effect=[0, 1]):
            self.assertEqual(self.lookup(), (None, None))

    def test_claude_custom_sidecar_uses_exact_project_and_uuid_without_opening_transcript(self):
        path = self.sidecar()
        event = {**self.event, "transcript_path": str(path.parent.parent / (SESSION + ".jsonl")),
                 "prompt": "Private prompt", "last_assistant_message": "Private reply"}
        self.assertFalse(Path(event["transcript_path"]).exists())
        self.assertEqual(self.lookup("claude", event), ("Claude custom name", "claude-custom-title"))
        self.assertEqual(self.lookup("vscode", event), ("Claude custom name", "claude-custom-title"))
        self.assertEqual(self.lookup("claude", {**event, "session_id": OTHER_SESSION}), (None, None))

    def test_claude_sidecar_supports_safe_cwd_and_provider_project_key(self):
        self.sidecar()
        self.assertEqual(self.lookup("claude"), ("Claude custom name", "claude-custom-title"))
        self.sidecar("Configured project name", project="provider-project-key")
        self.assertEqual(self.lookup("claude", environ={"CLAUDE_CODE_PROJECT_DIR_NAME": "provider-project-key"}),
                         ("Configured project name", "claude-custom-title"))

    def test_claude_duplicate_sidecar_keys_do_not_mask_valid_session_metadata(self):
        path = self.sidecar()
        path.write_text('{"customTitle":"First","customTitle":"Duplicate"}')
        self.claude_records([self.claude_record("Actual session subject")])
        self.assertEqual(self.lookup("claude"), ("Actual session subject", "claude-ai-title-record"))

    def test_claude_never_reads_an_outside_or_symlinked_sidecar_or_prompt_fallback(self):
        path = self.sidecar()
        outside = self.home / "outside.json"
        outside.write_text(json.dumps({"customTitle": "Outside title"}))
        path.unlink()
        path.symlink_to(outside)
        self.assertEqual(self.lookup("claude"), (None, None))
        self.assertEqual(self.lookup("claude", {**self.event, "transcript_path": "/outside/" + SESSION + ".jsonl"}),
                         (None, None))
        path.unlink()
        path.write_text(json.dumps({"summary": "Prompt-derived fallback", "aiTitle": "Unrecognized sidecar"}))
        self.assertEqual(self.lookup("claude"), (None, None))

    def test_claude_ai_title_uses_verified_record_format_and_exact_session(self):
        path = self.claude_records([self.claude_record("Old title"),
                                   self.claude_record("Other session", session=OTHER_SESSION),
                                   self.claude_record("  PROJ-123\n sample\u202e feature title  ")])
        event = {**self.event, "transcript_path": str(path)}
        expected = ("PROJ-123 sample feature title", "claude-ai-title-record")
        self.assertEqual(self.lookup("claude", event), expected)
        self.assertEqual(self.lookup("vscode", event), expected)
        self.assertEqual(self.lookup("claude", {**self.event, "session_id": OTHER_SESSION}), (None, None))

    def test_claude_latest_custom_record_overrides_ai_and_stale_manual_sidecar(self):
        self.sidecar("Old sidecar name")
        self.claude_records([self.claude_record("AI name"), self.claude_record("Old custom", kind="custom-title"),
                             self.claude_record("New custom", kind="custom-title"), self.claude_record("Later AI")])
        self.assertEqual(self.lookup("claude"), ("New custom", "claude-custom-title-record"))

    def test_claude_empty_latest_records_clear_earlier_titles_without_prompt_fallback(self):
        self.sidecar("Stale sidecar")
        path = self.claude_records([self.claude_record("AI name"), self.claude_record("Old custom", kind="custom-title"),
                                    self.claude_record(" \n\t ", kind="custom-title")])
        self.assertEqual(self.lookup("claude"), ("AI name", "claude-ai-title-record"))
        with path.open("ab") as stream:
            stream.write(json.dumps(self.claude_record("")).encode() + b"\n")
        self.assertEqual(self.lookup("claude", {**self.event, "prompt": "Not a session title"}), (None, None))

    def test_claude_messages_tools_summaries_and_nested_title_text_are_not_decoded(self):
        marker = self.claude_record("A message must not become a title")
        messages = [{"type": "user", "message": {"content": [marker]}},
                    {"type": "assistant", "message": {"content": json.dumps(marker)}},
                    {"type": "user", "toolUseResult": marker},
                    {"type": "summary", "summary": "Private summary"},
                    {"type": "last-prompt", "lastPrompt": "Private prompt"}]
        raw = b"".join(json.dumps(record).encode() + b"\n" for record in messages)
        raw += b'{"type":"user","message":"' + b'x' * 9000 + b'"}\n'
        raw += b'{"type":"assistant","message":"\xff"}\n'
        raw += json.dumps(self.claude_record("Actual metadata title")).encode() + b"\n"
        self.claude_records(raw=raw)
        real_loads = json.loads
        parsed = []

        def metadata_only(value, *args, **kwargs):
            self.assertIsInstance(value, bytes)
            self.assertRegex(value, rb'^\{"type":\s*"(?:ai-title|custom-title)"')
            parsed.append(value)
            return real_loads(value, *args, **kwargs)

        with patch.object(titles.json, "loads", side_effect=metadata_only):
            self.assertEqual(self.lookup("claude"), ("Actual metadata title", "claude-ai-title-record"))
        self.assertEqual(len(parsed), 1)

    def test_claude_invalid_duplicate_unknown_or_nonscalar_records_cannot_supply_a_title(self):
        candidates = [self.claude_record("Foreign", session=OTHER_SESSION), self.claude_record(123),
                      self.claude_record("x" * 513), self.claude_record("\ud800"),
                      {**self.claude_record("Extra field"), "message": "Private body"},
                      {"type": "ai-title", "customTitle": "Wrong field", "sessionId": SESSION},
                      {"type": "ai-title", "aiTitle": {"nested": "Not a title"}, "sessionId": SESSION}]
        raw = b"".join(json.dumps(record).encode() + b"\n" for record in candidates)
        raw += ('{"type":"ai-title","aiTitle":"First","aiTitle":"Duplicate","sessionId":"' + SESSION + '"}\n').encode()
        raw += b'{"type":"ai-title",invalid}\n'
        raw += b'{"type":"ai-title","aiTitle":"' + b'x' * 8192 + b'"}\n'
        self.claude_records(raw=raw)
        self.assertEqual(self.lookup("claude"), (None, None))

    def test_claude_large_file_reads_only_bounded_head_tail_and_prefers_tail(self):
        path = self.claude_records([self.claude_record("Head AI"), self.claude_record("Head custom", kind="custom-title")])
        tail = b"\n" + json.dumps(self.claude_record("Tail AI")).encode() + b"\n"
        with path.open("r+b") as stream:
            stream.seek(6_800_000 - len(tail))
            stream.write(tail)
        self.sidecar("Manual sidecar")
        calls = []
        real_pread = os.pread

        def bounded(fd, length, offset):
            calls.append((length, offset))
            return real_pread(fd, length, offset)

        with patch.object(titles.os, "pread", side_effect=bounded):
            self.assertEqual(self.lookup("claude"), ("Manual sidecar", "claude-custom-title"))
        self.assertEqual(calls, [(65_536, 0), (65_536, 6_800_000 - 65_536)])
        self.assertEqual(sum(length for length, _ in calls), 131_072)
        with path.open("ab") as stream:
            stream.write(json.dumps(self.claude_record("Tail custom rename", kind="custom-title")).encode() + b"\n")
        self.assertEqual(self.lookup("claude"), ("Tail custom rename", "claude-custom-title-record"))

    def test_claude_head_custom_precedes_tail_ai_when_no_sidecar_exists(self):
        path = self.claude_records([self.claude_record("Head custom", kind="custom-title")])
        tail = b"\n" + json.dumps(self.claude_record("Tail AI")).encode() + b"\n"
        with path.open("r+b") as stream:
            stream.seek(4 * titles.MAX_CLAUDE_TITLE_WINDOW_BYTES - len(tail))
            stream.write(tail)
        self.assertEqual(self.lookup("claude"), ("Head custom", "claude-custom-title-record"))

    def test_claude_overlapping_windows_deduplicate_offsets_and_keep_latest_tail_custom(self):
        first = json.dumps(self.claude_record("Head custom", kind="custom-title")).encode() + b"\n"
        overlap = json.dumps(self.claude_record("Overlap custom", kind="custom-title")).encode() + b"\n"
        raw = first + b"\n" * 40_000 + overlap + b"\n" * 40_000
        self.claude_records(raw=raw)
        self.sidecar("Stale manual sidecar")
        self.assertEqual(self.lookup("claude"), ("Overlap custom", "claude-custom-title-record"))

    def test_claude_partial_window_and_eof_lines_cannot_imitate_title_records(self):
        fake = json.dumps(self.claude_record("Cut-line imitation")).encode()
        raw = b'x' * (2 * titles.MAX_CLAUDE_TITLE_WINDOW_BYTES) + fake + b"\n"
        self.claude_records(raw=raw)
        self.assertEqual(self.lookup("claude"), (None, None))
        raw += json.dumps(self.claude_record("Complete title")).encode() + b"\n"
        raw += json.dumps(self.claude_record("Unterminated record")).encode()
        self.claude_records(raw=raw)
        self.assertEqual(self.lookup("claude"), ("Complete title", "claude-ai-title-record"))

    def test_claude_record_files_reject_symlinks_nonregular_files_and_other_writers(self):
        path = self.claude_records([self.claude_record()])
        outside = self.home / "outside-records.jsonl"
        outside.write_bytes(path.read_bytes())
        path.unlink()
        path.symlink_to(outside)
        self.assertEqual(self.lookup("claude"), (None, None))
        path.unlink()
        os.mkfifo(path, 0o600)
        self.assertEqual(self.lookup("claude"), (None, None))
        path.unlink()
        self.claude_records([self.claude_record()])
        for target, mode in ((path, 0o666), (path.parent, 0o777)):
            original = target.stat().st_mode & 0o777
            target.chmod(mode)
            self.assertEqual(self.lookup("claude"), (None, None))
            target.chmod(original)
        with patch.object(titles.os, "getuid", return_value=os.getuid() + 1):
            self.assertEqual(self.lookup("claude"), (None, None))

    def test_claude_growth_uses_original_snapshot_but_in_place_rewrite_is_rejected(self):
        path = self.claude_records([self.claude_record("Old title")])
        real_pread = os.pread
        changed = False

        def append_after_read(fd, length, offset):
            nonlocal changed
            raw = real_pread(fd, length, offset)
            if not changed:
                changed = True
                with path.open("ab") as stream:
                    stream.write(json.dumps(self.claude_record("Appended title")).encode() + b"\n")
            return raw

        with patch.object(titles.os, "pread", side_effect=append_after_read):
            self.assertEqual(self.lookup("claude"), ("Old title", "claude-ai-title-record"))
        self.assertEqual(self.lookup("claude"), ("Appended title", "claude-ai-title-record"))
        self.claude_records([self.claude_record("Old title")])
        initial = path.stat()

        def rewrite_after_read(fd, length, offset):
            raw = real_pread(fd, length, offset)
            path.write_bytes(raw.replace(b"Old title", b"New title"))
            os.utime(path, ns=(initial.st_atime_ns, initial.st_mtime_ns + 1_000_000))
            return raw

        with patch.object(titles.os, "pread", side_effect=rewrite_after_read):
            self.assertEqual(self.lookup("claude"), (None, None))

    def test_claude_title_processing_deadline_exits_before_reading(self):
        self.claude_records([self.claude_record()])
        with patch.object(titles.time, "monotonic", side_effect=[0, 1]), patch.object(titles.os, "pread") as reading:
            self.assertEqual(self.lookup("claude"), (None, None))
            reading.assert_not_called()

    def test_claude_path_replacement_or_symlink_during_read_cannot_reuse_old_snapshot(self):
        real_pread = os.pread
        for replace_with_link in (False, True):
            with self.subTest(link=replace_with_link):
                path = self.claude_records([self.claude_record("Retired file title")])
                outside = self.home / "replacement.jsonl"
                outside.write_text(json.dumps(self.claude_record("Outside replacement")) + "\n")

                def replace_after_read(fd, length, offset):
                    raw = real_pread(fd, length, offset)
                    path.rename(path.with_suffix(".old"))
                    if replace_with_link:
                        path.symlink_to(outside)
                    else:
                        path.write_text(json.dumps(self.claude_record("New file title")) + "\n")
                        path.chmod(0o600)
                    return raw

                with patch.object(titles.os, "pread", side_effect=replace_after_read):
                    self.assertEqual(self.lookup("claude"), (None, None))
                path.unlink()

    def test_bridge_refreshes_actual_titles_on_requests_but_uses_cache_for_activity(self):
        runtime = bridge.runtime_directory(self.home / "runtime")
        previous = {"source": "codex", "sessionId": SESSION, "sessionName": "Old indexed name"}
        with patch.object(bridge, "lookup_session_title", return_value=("Renamed session", "codex-index")) as lookup:
            activity = {**self.event, "hook_event_name": "PostToolUse", "tool_name": "Bash"}
            self.assertEqual(bridge.session_metadata(runtime, "codex", activity, previous)["sessionName"], "Old indexed name")
            lookup.assert_not_called()
            events = ["SessionStart", "UserPromptSubmit", "PermissionRequest", "Notification"]
            for name in events:
                result = bridge.session_metadata(runtime, "codex", {**self.event, "hook_event_name": name}, previous)
                self.assertEqual(result["sessionName"], "Renamed session")
            for tool_name in ("AskUserQuestion", "request_user_input", "functions.request_user_input_async"):
                result = bridge.session_metadata(runtime, "codex", {**self.event, "hook_event_name": "PreToolUse", "tool_name": tool_name}, previous)
                self.assertEqual(result["sessionName"], "Renamed session")
            self.assertEqual(lookup.call_count, 7)
            result = bridge.session_metadata(runtime, "codex", {**self.event, "hook_event_name": "PermissionRequest", "session_title": "Explicit hook title"}, previous)
            self.assertEqual(result["sessionName"], "Explicit hook title")
            self.assertEqual(lookup.call_count, 7)

    def test_bridge_invalid_hook_names_cannot_mask_fresh_provider_titles(self):
        runtime = bridge.runtime_directory(self.home / "runtime")
        previous = {"source": "codex", "sessionId": SESSION, "sessionName": "Old cached subject"}
        for label in ["project", "/WORK/PROJECT/", SESSION, "ID: " + OTHER_SESSION]:
            for field in bridge.SESSION_NAME_FIELDS:
                with self.subTest(label=label, field=field), patch.object(bridge, "lookup_session_title", return_value=("Fresh provider subject", "codex-index")) as lookup:
                    result = bridge.session_metadata(runtime, "codex", {**self.event, "hook_event_name": "PermissionRequest", field: label}, previous)
                    self.assertEqual(result["sessionName"], "Fresh provider subject")
                    lookup.assert_called_once()

    def test_bridge_activity_heals_invalid_cache_or_hook_labels_without_leaking_them(self):
        runtime = bridge.runtime_directory(self.home / "runtime")
        activity = {**self.event, "hook_event_name": "PostToolUse", "tool_name": "Bash"}
        for bad in ["PROJECT", "/work/project", OTHER_SESSION, "Session ID: " + SESSION]:
            previous = {"source": "codex", "sessionId": SESSION, "sessionName": bad}
            with self.subTest(bad=bad), patch.object(bridge, "lookup_session_title", return_value=("Resolved subject", "codex-index")) as lookup:
                self.assertEqual(bridge.session_metadata(runtime, "codex", activity, previous)["sessionName"], "Resolved subject")
                lookup.assert_called_once()
            with patch.object(bridge, "lookup_session_title", return_value=(bad, "codex-index")):
                self.assertNotIn("sessionName", bridge.session_metadata(runtime, "codex", activity, previous))
        previous = {"source": "codex", "sessionId": SESSION, "sessionName": "Valid cached subject"}
        with patch.object(bridge, "lookup_session_title", return_value=("Fresh subject", "codex-index")) as lookup:
            result = bridge.session_metadata(runtime, "codex", {**activity, "session_title": SESSION}, previous)
            self.assertEqual(result["sessionName"], "Fresh subject")
            lookup.assert_called_once()


if __name__ == "__main__":
    unittest.main()
