import json
from contextlib import contextmanager
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import bridge


class BridgeIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="agent-companion-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = bridge.runtime_directory(self.temporary.name)
        self.processes = []
        self.addCleanup(self.stop_processes)

    def stop_processes(self):
        for process in self.processes:
            if process.poll() is None:
                process.terminate()
                process.communicate(timeout=3)

    def heartbeat(self, timestamp=None):
        bridge.write_json(self.root / "heartbeat.json", {"updatedAt": time.time() if timestamp is None else timestamp})

    def start_hook(self, event=None, source="claude", wait=2):
        event = event or {"hook_event_name": "PermissionRequest", "session_id": "session-one",
                          "cwd": "/example/project", "tool_name": "Bash",
                          "tool_input": {"command": "example --arg 'literal text'", "description": "Demo operation"}}
        process = subprocess.Popen(
            [sys.executable, str(bridge.PROJECT / "bridge.py"), "hook", "--source", source,
             "--runtime", str(self.root), "--wait", str(wait)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.processes.append(process)
        process.stdin.write(json.dumps(event))
        process.stdin.close()
        process.stdin = None
        return process

    def wait_requests(self, count=1):
        return {request["source"]: request for request in self.wait_pending(count)}

    def wait_pending(self, count=1):
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            requests = list((self.root / "requests").glob("*.json"))
            if len(requests) == count:
                return [bridge.read_json(path) for path in requests]
            time.sleep(0.01)
        self.fail("Hook did not publish the expected requests")

    def decide(self, request, outcome, request_id=None, decided_at=None):
        bridge.write_json(self.root / "decisions" / (request["id"] + ".json"), {
            "id": request["id"] if request_id is None else request_id,
            "decision": outcome,
            "decidedAt": time.time() if decided_at is None else decided_at,
        })

    def output(self, process):
        stdout, stderr = process.communicate(timeout=4)
        self.assertEqual(process.returncode, 0, stderr)
        return json.loads(stdout) if stdout else None

    def test_concurrent_approvals_are_correlated_and_commands_are_preserved(self):
        self.heartbeat()
        claude = self.start_hook(source="claude")
        codex = self.start_hook(source="codex")
        requests = self.wait_requests(2)
        self.assertIn("example --arg 'literal text'", requests["claude"]["detailText"])
        self.assertFalse(requests["claude"]["isDemo"])
        self.decide(requests["codex"], "deny")
        self.assertEqual(self.output(codex)["hookSpecificOutput"]["decision"]["behavior"], "deny")
        self.assertIsNone(claude.poll(), "Denying Codex must not answer Claude")
        self.decide(requests["claude"], "allow")
        self.assertEqual(self.output(claude), {"hookSpecificOutput": {
            "hookEventName": "PermissionRequest", "decision": {"behavior": "allow"}}})
        self.assertFalse(list((self.root / "requests").glob("*.json")))
        self.assertFalse(list((self.root / "decisions").glob("*.json")))

    def test_absent_or_stale_companion_does_not_answer_permission(self):
        self.assertIsNone(self.output(self.start_hook()))
        self.heartbeat(time.time() - 30)
        self.assertIsNone(self.output(self.start_hook()))
        self.assertFalse(list((self.root / "requests").glob("*.json")))

    def test_expired_requests_return_to_original_approval_without_allowing(self):
        self.heartbeat()
        process = self.start_hook(wait=0.25)
        self.wait_requests()
        self.assertIsNone(self.output(process))
        self.assertFalse(list((self.root / "requests").glob("*.json")))

    def test_permission_defer_returns_to_each_host_without_tool_control(self):
        for source in ("claude", "codex"):
            with self.subTest(source=source):
                self.heartbeat()
                process = self.start_hook(source=source, wait=5)
                request = self.wait_requests()[source]
                self.assertIs(request["canDefer"], True)
                self.decide(request, "defer")
                stdout, stderr = process.communicate(timeout=2)
                self.assertEqual(process.returncode, 0, stderr)
                self.assertEqual(stdout, "", "Handoff must never emit a host permission decision")
                self.assertEqual(stderr, "")
                self.assertFalse(list((self.root / "requests").glob("*.json")))
                self.assertFalse(list((self.root / "decisions").glob("*.json")))
                state = bridge.session_document(self.root, source, request["sessionId"])
                self.assertEqual(state["status"], "attention")
                self.assertEqual(state["message"], "Continue in the original app")

    def test_permission_defer_leaves_an_unrelated_request_waiting(self):
        self.heartbeat()
        claude = self.start_hook(source="claude", wait=5)
        codex = self.start_hook(source="codex", wait=5)
        requests = self.wait_requests(2)
        self.decide(requests["codex"], "defer")
        self.assertIsNone(self.output(codex))
        self.assertIsNone(claude.poll())
        self.assertEqual([card["id"] for card in self.wait_pending()], [requests["claude"]["id"]])
        self.decide(requests["claude"], "deny")
        self.assertEqual(self.output(claude)["hookSpecificOutput"]["decision"]["behavior"], "deny")

    def test_permission_response_requires_capability_and_exact_shape(self):
        response = {"id": "a" * 32, "decision": "defer", "decidedAt": time.time()}
        for capability in (None, False, 1, "true"):
            request = {} if capability is None else {"canDefer": capability}
            self.assertFalse(bridge.accepts_permission_response(request, response))
        self.assertTrue(bridge.accepts_permission_response({"canDefer": True}, response))
        for decision in ("allow", "deny"):
            self.assertTrue(bridge.accepts_permission_response({}, {**response, "decision": decision}))
        for key in response:
            self.assertFalse(bridge.accepts_permission_response({"canDefer": True},
                {field: value for field, value in response.items() if field != key}))
        self.assertFalse(bridge.accepts_permission_response({"canDefer": True}, []))

    def test_permission_defer_rejects_wrong_identity_and_invalid_time(self):
        self.heartbeat()
        process = self.start_hook(source="codex", wait=5)
        request = self.wait_requests()["codex"]
        invalid = [{"id": "b" * 32}, {"decidedAt": request["createdAt"] - 1},
                   {"decidedAt": time.time() + 1}, {"decidedAt": request["expiresAt"] + 1},
                   {"decidedAt": None}, {"decidedAt": True}]
        for changes in invalid:
            bridge.write_json(self.root / "decisions" / (request["id"] + ".json"),
                              {"id": request["id"], "decision": "defer", "decidedAt": time.time(), **changes})
            time.sleep(0.15)
            self.assertIsNone(process.poll(), "An invalid handoff must leave the exact permission waiting")
        self.decide(request, "defer")
        self.assertIsNone(self.output(process))

    def test_permission_responses_with_answers_or_extra_fields_cannot_decide(self):
        self.heartbeat()
        process = self.start_hook(wait=5)
        request = self.wait_requests()["claude"]
        for decision in ("allow", "deny", "defer"):
            for extra in ({"answers": None}, {"answers": {}}, {"unexpected": True}):
                bridge.write_json(self.root / "decisions" / (request["id"] + ".json"),
                    {"id": request["id"], "decision": decision, "decidedAt": time.time(), **extra})
                time.sleep(0.15)
                self.assertIsNone(process.poll(), "Malformed responses must not approve, deny, or hand off")
        self.decide(request, "defer")
        self.assertIsNone(self.output(process))

    def test_changed_permission_snapshot_cannot_accept_handoff(self):
        self.heartbeat()
        process = self.start_hook(source="codex", wait=5)
        request = self.wait_requests()["codex"]
        with bridge.mailbox_lock(self.root):
            bridge.write_json(self.root / "requests" / (request["id"] + ".json"),
                              {**request, "detailText": "changed after navigation began"})
            self.decide(request, "defer")
        self.assertIsNone(self.output(process))
        self.assertFalse(list((self.root / "requests").glob("*.json")))
        self.assertFalse(list((self.root / "decisions").glob("*.json")))

    def test_permission_defer_preserves_newer_lifecycle_status(self):
        self.heartbeat()
        event = self.permission_event(session="handoff-lifecycle", turn_id="old-turn")
        process = self.start_hook(event, source="codex", wait=5)
        request = self.wait_requests()["codex"]
        bridge.handle_hook(self.root, "codex", {"hook_event_name": "UserPromptSubmit",
                           "session_id": event["session_id"], "turn_id": "new-turn"})
        self.decide(request, "defer")
        self.assertIsNone(self.output(process))
        state = bridge.session_document(self.root, "codex", event["session_id"])
        self.assertEqual(state["status"], "working")
        self.assertEqual(state["message"], "")

    def test_source_cancellation_wins_over_a_late_permission_handoff(self):
        self.heartbeat()
        event = self.permission_event(turn_id="handoff-turn")
        process = self.start_hook(event, source="codex", wait=5)
        request = self.wait_requests()["codex"]
        with bridge.mailbox_lock(self.root):
            completion = {"hook_event_name": "Interrupt", "session_id": event["session_id"],
                          "turn_id": event["turn_id"]}
            retirement = bridge.retire_requests(self.root, "codex", completion)
            bridge.session_state(self.root, "codex", completion, "idle", retirement=retirement)
            self.decide(request, "defer")
        self.assertIsNone(self.output(process))
        state = bridge.session_document(self.root, "codex", event["session_id"])
        self.assertEqual(state["status"], "idle")
        self.assertFalse(list((self.root / "decisions").glob("*.json")))

    def test_duplicate_handoff_after_a_decision_does_not_answer_a_new_request(self):
        self.heartbeat()
        first = self.start_hook(source="codex", wait=5)
        original = self.wait_requests()["codex"]
        self.decide(original, "allow")
        self.assertEqual(self.output(first)["hookSpecificOutput"]["decision"]["behavior"], "allow")
        second = self.start_hook(source="codex", wait=5)
        current = self.wait_requests()["codex"]
        self.assertNotEqual(original["id"], current["id"])
        self.decide(original, "defer")
        time.sleep(0.15)
        self.assertIsNone(second.poll(), "A stale duplicate must not act on the next identical tool call")
        self.assertEqual(self.wait_pending()[0]["id"], current["id"])
        self.decide(current, "defer")
        self.assertIsNone(self.output(second))

    def test_mismatched_and_old_decisions_cannot_approve(self):
        self.heartbeat()
        process = self.start_hook(wait=0.35)
        request = self.wait_requests()["claude"]
        self.decide(request, "allow", request_id="some-other-request")
        time.sleep(0.1)
        self.assertIsNone(process.poll())
        self.decide(request, "allow", decided_at=request["createdAt"] - 1)
        self.assertIsNone(self.output(process))

    def test_closing_companion_cancels_pending_request_without_allowing(self):
        self.heartbeat()
        process = self.start_hook()
        self.wait_requests()
        (self.root / "heartbeat.json").unlink()
        self.assertIsNone(self.output(process))
        self.assertFalse(list((self.root / "requests").glob("*.json")))

    def test_lifecycle_updates_status_and_does_not_return_hook_control(self):
        process = self.start_hook({"hook_event_name": "UserPromptSubmit", "session_id": "work-1",
                                   "cwd": "/project", "prompt": "Do not retain this prompt"})
        self.assertIsNone(self.output(process))
        states = list((self.root / "sessions").glob("*.json"))
        self.assertEqual(len(states), 1)
        value = bridge.read_json(states[0])
        self.assertEqual(value["status"], "working")
        self.assertNotIn("prompt", value)
        self.assertEqual(states[0].stat().st_mode & 0o777, 0o600)

    def test_public_and_symlinked_runtime_are_rejected(self):
        public = self.root / "public"
        public.mkdir(mode=0o755)
        with self.assertRaises(ValueError):
            bridge.runtime_directory(public)
        linked = self.root / "linked"
        linked.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(ValueError):
            bridge.runtime_directory(linked)

    def test_invalid_json_and_unsupported_event_never_approve(self):
        process = self.start_hook({"hook_event_name": "NotAnEvent", "session_id": "anything"})
        self.assertIsNone(self.output(process))
        completed = subprocess.run(
            [sys.executable, str(bridge.PROJECT / "bridge.py"), "hook", "--source", "claude",
             "--runtime", str(self.root)], input="not json", text=True, capture_output=True, timeout=3)
        self.assertEqual(completed.stdout, "")
        self.assertEqual(completed.returncode, 0)

    def test_malformed_event_names_and_deep_inputs_fall_back_cleanly(self):
        for raw in ('{"hook_event_name":[]}',
                    '{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":'
                    + '[' * 1000 + '0' + ']' * 1000 + '}'):
            completed = subprocess.run(
                [sys.executable, str(bridge.PROJECT / "bridge.py"), "hook", "--source", "claude",
                 "--runtime", str(self.root)], input=raw, text=True, capture_output=True, timeout=3)
            self.assertEqual(completed.stdout, "")
            self.assertEqual(completed.returncode, 0)
            self.assertNotIn("Traceback", completed.stderr)
        self.assertFalse(list((self.root / "requests").glob("*.json")))

    def test_claude_permission_alert_is_not_an_approval(self):
        self.heartbeat()
        process = self.start_hook({"hook_event_name": "Notification", "session_id": "network-request",
                                   "notification_type": "permission_prompt", "title": "Claude needs permission",
                                   "message": "Allow network access to example.test?"})
        self.assertIsNone(self.output(process))
        request = self.wait_requests()["claude"]
        self.assertFalse(request["canRespond"])
        self.assertNotIn("canDefer", request)
        self.assertEqual(request["toolName"], "Permission alert")
        self.assertFalse(list((self.root / "decisions").glob("*.json")))

    def test_nested_tool_inputs_are_displayed_without_omitting_arguments(self):
        self.heartbeat()
        tool_input = {"path": "with\ncontrol", "flags": [True, None, {"scope": "one"}]}
        process = self.start_hook({"hook_event_name": "PermissionRequest", "tool_name": "mcp__files__write",
                                   "tool_input": tool_input, "session_id": "mcp-1"})
        request = self.wait_requests()["claude"]
        self.assertEqual(json.loads(request["detailText"]), tool_input)
        self.decide(request, "deny")
        self.assertEqual(self.output(process)["hookSpecificOutput"]["decision"]["behavior"], "deny")

    def question_event(self):
        return {"hook_event_name": "PreToolUse", "session_id": "questions-one", "tool_name": "AskUserQuestion",
                "cwd": "/example/project", "tool_input": {"questions": [
                    {"question": "Continue?", "header": "Continue", "multiSelect": False,
                     "options": [{"label": "Yes", "description": "Continue the task"},
                                 {"label": "No", "description": "Stop here"}]},
                    {"question": "Which features?", "header": "Features", "multiSelect": True,
                     "options": [{"label": "Alerts"}, {"label": "Chat"}]},
                ], "metadata": "preserve this extra input"}}

    def test_claude_question_answers_preserve_original_questions_and_other_fields(self):
        self.heartbeat()
        event = self.question_event()
        process = self.start_hook(event)
        request = self.wait_requests()["claude"]
        self.assertEqual(request["kind"], "question")
        self.assertEqual(request["questions"], event["tool_input"]["questions"])
        answers = {"Continue?": "No", "Which features?": "Alerts,Chat"}
        bridge.write_json(self.root / "decisions" / (request["id"] + ".json"), {
            "id": request["id"], "decision": "answer", "answers": answers, "decidedAt": time.time(),
        })
        output = self.output(process)["hookSpecificOutput"]
        self.assertEqual(output["hookEventName"], "PreToolUse")
        self.assertEqual(output["permissionDecision"], "allow")
        self.assertEqual(output["updatedInput"], {**event["tool_input"], "answers": answers})

    def test_question_cannot_be_answered_by_a_permission_allow_or_incomplete_answer(self):
        self.heartbeat()
        process = self.start_hook(self.question_event(), wait=0.45)
        request = self.wait_requests()["claude"]
        self.decide(request, "allow")
        time.sleep(0.1)
        self.assertIsNone(process.poll())
        bridge.write_json(self.root / "decisions" / (request["id"] + ".json"), {
            "id": request["id"], "decision": "answer", "answers": {"Continue?": "Yes"}, "decidedAt": time.time(),
        })
        self.assertIsNone(self.output(process))

    def test_question_defer_returns_no_tool_control(self):
        self.heartbeat()
        process = self.start_hook(self.question_event())
        request = self.wait_requests()["claude"]
        self.assertNotIn("canDefer", request)
        self.decide(request, "defer")
        self.assertIsNone(self.output(process))

    def test_codex_question_is_an_alert_without_answer_injection(self):
        self.heartbeat()
        process = self.start_hook({"hook_event_name": "PreToolUse", "tool_name": "request_user_input",
                                   "session_id": "codex-question", "tool_input": {"questions": [{"question": "Continue?"}]}},
                                  source="codex")
        self.assertIsNone(self.output(process))
        request = self.wait_requests()["codex"]
        self.assertFalse(request["canRespond"])
        self.assertIn("Continue?", request["detailText"])

    def permission_event(self, command="first", session="session-one", **scope):
        return {"hook_event_name": "PermissionRequest", "session_id": session, "tool_name": "Bash",
                "tool_input": {"command": command, "description": "Review this action"}, **scope}

    def test_source_tool_completion_cancels_only_the_matching_pending_permission(self):
        self.heartbeat()
        completed = self.permission_event()
        target = self.start_hook(completed)
        others = [self.start_hook(self.permission_event("different")),
                  self.start_hook(self.permission_event(session="other-session")),
                  self.start_hook(completed, source="codex")]
        cards = self.wait_pending(4)
        event = {**completed, "hook_event_name": "PostToolUse", "tool_use_id": "completed-call"}
        self.assertIsNone(self.output(self.start_hook(event)))
        self.assertIsNone(self.output(target), "Source completion must never grant permission")
        remaining = self.wait_pending(3)
        self.assertEqual(len({card["id"] for card in cards} - {card["id"] for card in remaining}), 1)
        for process in others:
            self.assertIsNone(process.poll(), "Other tools, sources, and sessions must keep waiting")
        for card in remaining:
            self.decide(card, "deny")
        for process in others:
            self.assertEqual(self.output(process)["hookSpecificOutput"]["decision"]["behavior"], "deny")

    def test_exact_question_completion_cancels_without_answers_and_preserves_lifecycle_status(self):
        self.heartbeat()
        event = {**self.question_event(), "tool_use_id": "question-call", "prompt_id": "prompt-one"}
        process = self.start_hook(event)
        request = self.wait_pending()[0]
        finished = {**event, "hook_event_name": "PostToolUse",
                    "tool_input": {**event["tool_input"], "answers": {"Continue?": "Yes"}}}
        self.assertIsNone(self.output(self.start_hook(finished)))
        self.assertIsNone(self.output(process))
        state = bridge.read_json(bridge.session_path(self.root, "claude", event["session_id"]))
        self.assertEqual(state["status"], "working")
        self.assertEqual(state["message"], "")
        self.assertFalse((self.root / "decisions" / (request["id"] + ".json")).exists())

    def test_source_cancellation_wins_over_a_late_companion_allow(self):
        self.heartbeat()
        event = self.permission_event(turn_id="turn-one")
        process = self.start_hook(event, source="codex")
        request = self.wait_pending()[0]
        bridge.handle_hook(self.root, "codex", {"hook_event_name": "Interrupt", "session_id": event["session_id"],
                                                "turn_id": "turn-one"})
        self.decide(request, "allow")
        self.assertIsNone(self.output(process), "A withdrawn request must ignore a racing approval")
        state = bridge.read_json(bridge.session_path(self.root, "codex", event["session_id"]))
        self.assertEqual(state["status"], "idle")
        self.assertFalse(list((self.root / "requests").glob("*.json")))

    def test_same_input_concurrent_calls_without_ids_are_not_guessed(self):
        self.heartbeat()
        event = self.permission_event()
        processes = [self.start_hook(event), self.start_hook(event)]
        cards = self.wait_pending(2)
        bridge.handle_hook(self.root, "claude", {**event, "hook_event_name": "PostToolUse", "tool_use_id": "one-call"})
        self.assertEqual({card["id"] for card in self.wait_pending(2)}, {card["id"] for card in cards})
        for process in processes:
            self.assertIsNone(process.poll())
        bridge.handle_hook(self.root, "claude", {"hook_event_name": "SessionEnd", "session_id": event["session_id"]})
        for process in processes:
            self.assertIsNone(self.output(process))

    def test_stop_preserves_other_prompts_agents_and_background_work(self):
        self.heartbeat()
        base = {"hook_event_name": "Notification", "notification_type": "permission_prompt", "session_id": "shared",
                "title": "Permission", "message": "Continue in the source", "prompt_id": "prompt-one"}
        for scope in ({}, {"agent_id": "subagent"}, {"prompt_id": "prompt-two"}):
            bridge.handle_hook(self.root, "claude", {**base, **scope})
        bridge.handle_hook(self.root, "claude", {"hook_event_name": "Stop", "session_id": "shared",
                                                "prompt_id": "prompt-one", "background_tasks": [{"id": "background"}]})
        self.assertEqual(len(self.wait_pending(3)), 3)
        bridge.handle_hook(self.root, "claude", {"hook_event_name": "Stop", "session_id": "shared", "prompt_id": "prompt-one"})
        remaining = self.wait_pending(2)
        self.assertTrue(all(card["correlation"].get("agentId") == "subagent" or
                            card["correlation"].get("promptId") == "prompt-two" for card in remaining))
        bridge.handle_hook(self.root, "claude", {"hook_event_name": "SessionEnd", "session_id": "shared"})
        self.assertFalse(list((self.root / "requests").glob("*.json")))
        self.assertFalse(list((self.root / "decisions").glob("*.json")))

    def test_missing_empty_unknown_or_invalid_session_ids_never_bulk_clear(self):
        self.heartbeat()
        for value in (None, "", "unknown", [], "  "):
            event = {"hook_event_name": "Notification", "notification_type": "permission_prompt", "message": "Review", "title": "Permission"}
            if value is not None:
                event["session_id"] = value
            bridge.handle_hook(self.root, "claude", event)
            bridge.handle_hook(self.root, "claude", {**event, "hook_event_name": "SessionEnd"})
        self.assertEqual(len(list((self.root / "requests").glob("*.json"))), 5)

    def test_generic_notice_is_not_cleared_by_an_unrelated_completed_tool(self):
        self.heartbeat()
        notice = {"hook_event_name": "Notification", "notification_type": "permission_prompt", "session_id": "shared",
                  "message": "Allow network access?", "title": "Permission", "prompt_id": "prompt-one"}
        bridge.handle_hook(self.root, "claude", notice)
        card = self.wait_pending()[0]
        bridge.handle_hook(self.root, "claude", {**self.permission_event(session="shared", prompt_id="prompt-one"),
                                                "hook_event_name": "PostToolUse", "tool_use_id": "another-tool"})
        self.assertTrue((self.root / "requests" / (card["id"] + ".json")).exists())
        bridge.handle_hook(self.root, "claude", {"hook_event_name": "Stop", "session_id": "shared", "prompt_id": "prompt-one"})
        self.assertFalse((self.root / "requests" / (card["id"] + ".json")).exists())

    def test_batch_completion_uses_common_scope_and_only_matching_resolved_calls(self):
        self.heartbeat()
        completed = self.permission_event(prompt_id="prompt-one")
        processes = [self.start_hook(completed), self.start_hook(self.permission_event("unrelated", prompt_id="prompt-one")),
                     self.start_hook(self.permission_event(session="other-session", prompt_id="prompt-one"))]
        self.wait_pending(3)
        batch = {"hook_event_name": "PostToolBatch", "session_id": completed["session_id"], "prompt_id": "prompt-one",
                 "tool_calls": [{"tool_name": "Bash", "tool_input": completed["tool_input"], "tool_use_id": "resolved-call",
                                 "tool_response": "Completed in the original app", "session_id": "other-session"}]}
        self.assertIsNone(self.output(self.start_hook(batch)))
        self.assertIsNone(self.output(processes[0]))
        self.wait_pending(2)
        self.assertIsNone(processes[1].poll())
        self.assertIsNone(processes[2].poll())

    def test_confirmed_failure_retires_card_without_synthesizing_deny(self):
        self.heartbeat()
        event = self.permission_event(prompt_id="prompt-one")
        process = self.start_hook(event)
        self.wait_pending()
        bridge.handle_hook(self.root, "claude", {**event, "hook_event_name": "PostToolUseFailure", "tool_use_id": "failed-call",
                                                "error": "Tool failed", "is_interrupt": True})
        self.assertIsNone(self.output(process))
        self.assertFalse(list((self.root / "decisions").glob("*.json")))

    def test_completion_before_publication_does_not_resurrect_a_cancelled_turn(self):
        self.heartbeat()
        event = self.permission_event(turn_id="turn-one")
        created = time.time()
        request = {"id": "a" * 32, "source": "codex", "sessionId": event["session_id"],
                   "correlation": bridge.correlation(event), "createdAt": created, "expiresAt": created + 2}
        bridge.handle_hook(self.root, "codex", {"hook_event_name": "Interrupt", "session_id": event["session_id"], "turn_id": "turn-one"})
        result = bridge.wait_for_response(self.root, "codex", event, request, 2, lambda response: True)
        self.assertIsNone(result)
        self.assertFalse(list((self.root / "requests").glob("*.json")))
        state = bridge.read_json(bridge.session_path(self.root, "codex", event["session_id"]))
        self.assertEqual(state["status"], "idle")

    def test_source_completion_racing_notice_publication_preserves_newer_state(self):
        self.heartbeat()
        original_lock = bridge.mailbox_lock
        for source, event in (
            ("claude", {"hook_event_name": "Notification", "notification_type": "permission_prompt", "session_id": "claude-race",
                        "prompt_id": "prompt-one", "title": "Permission", "message": "Continue in the source"}),
            ("codex", {"hook_event_name": "PreToolUse", "tool_name": "request_user_input", "session_id": "codex-race",
                       "turn_id": "turn-one", "tool_use_id": "question-one", "tool_input": {"questions": []}}),
        ):
            @contextmanager
            def completion_then_lock(root):
                with original_lock(root):
                    end_event = {**event, "hook_event_name": "Stop"}
                    record = bridge.retire_requests(root, source, end_event)
                    bridge.session_state(root, source, end_event, "idle", retirement=record)
                with original_lock(root):
                    yield

            with patch.object(bridge, "mailbox_lock", completion_then_lock):
                self.assertIsNone(bridge.handle_hook(self.root, source, event))
            self.assertFalse(list((self.root / "requests").glob("*.json")))
            state = bridge.read_json(bridge.session_path(self.root, source, event["session_id"]))
            self.assertEqual(state["status"], "idle")

    def test_delayed_ended_turn_hook_is_suppressed_but_a_new_turn_can_publish(self):
        self.heartbeat()
        ended = {"hook_event_name": "Interrupt", "session_id": "same-session", "turn_id": "ended-turn"}
        bridge.handle_hook(self.root, "codex", ended)
        delayed_notice = {**ended, "hook_event_name": "PreToolUse", "tool_name": "request_user_input",
                          "tool_use_id": "late-question", "tool_input": {"questions": []}}
        self.assertIsNone(bridge.handle_hook(self.root, "codex", delayed_notice))
        self.assertIsNone(self.output(self.start_hook(self.permission_event(session="same-session", turn_id="ended-turn"), source="codex")))
        self.assertFalse(list((self.root / "requests").glob("*.json")))
        state = bridge.read_json(bridge.session_path(self.root, "codex", "same-session"))
        self.assertEqual(state["status"], "idle")
        bridge.handle_hook(self.root, "codex", {**delayed_notice, "turn_id": "new-turn", "tool_use_id": "new-question"})
        self.assertEqual(self.wait_pending()[0]["correlation"]["turnId"], "new-turn")

    def test_stop_attempt_clears_old_cards_but_allows_same_prompt_to_continue(self):
        self.heartbeat()
        for event_name in ("Stop", "StopFailure"):
            with self.subTest(event=event_name):
                session = "continued-" + event_name
                permission = self.permission_event(session=session, prompt_id="same-prompt")
                notice = {"hook_event_name": "Notification", "notification_type": "permission_prompt", "session_id": session,
                          "prompt_id": "same-prompt", "title": "Permission", "message": "Review in the source"}
                old_process = self.start_hook(permission)
                self.wait_pending()
                bridge.handle_hook(self.root, "claude", notice)
                self.wait_pending(2)
                bridge.handle_hook(self.root, "claude", {"hook_event_name": event_name, "session_id": session,
                                                        "prompt_id": "same-prompt"})
                self.assertIsNone(self.output(old_process))
                self.assertFalse(list((self.root / "requests").glob("*.json")))

                # Another Stop hook can keep this same user prompt running.
                bridge.handle_hook(self.root, "claude", notice)
                self.wait_pending()
                new_process = self.start_hook(permission)
                cards = self.wait_pending(2)
                new_permission = next(card for card in cards if card.get("kind") == "permission")
                self.decide(new_permission, "allow")
                self.assertEqual(self.output(new_process)["hookSpecificOutput"]["decision"]["behavior"], "allow")
                self.assertEqual(len(self.wait_pending()), 1)
                bridge.handle_hook(self.root, "claude", {"hook_event_name": "SessionEnd", "session_id": session})
                self.assertFalse(list((self.root / "requests").glob("*.json")))

    def test_malformed_retirement_metadata_does_not_break_normal_hook_fallback(self):
        self.heartbeat()
        path = bridge.session_path(self.root, "claude", "session-one")
        bad_records = ({"not": "an array"}, [None, [], {"eventName": []},
                       {"eventName": "Stop", "correlation": [], "observedAt": time.time()},
                       {"eventName": "Stop", "correlation": {"sessionId": "session-one"}, "observedAt": 10 ** 500}])
        for records in bad_records:
            bridge.write_json(path, {"retirements": records})
            process = self.start_hook(self.permission_event(), wait=0.15)
            self.wait_pending()
            self.assertIsNone(self.output(process))
            self.assertFalse(list((self.root / "requests").glob("*.json")))

    def test_codex_sync_question_notice_clears_by_tool_id_despite_changed_response_input(self):
        self.heartbeat()
        event = {"hook_event_name": "PreToolUse", "tool_name": "functions.request_user_input", "session_id": "question-session",
                 "turn_id": "question-turn", "tool_use_id": "question-call", "tool_input": {"questions": [{"question": "Choose?"}]}}
        bridge.handle_hook(self.root, "codex", event)
        self.wait_pending()
        bridge.handle_hook(self.root, "codex", {**event, "hook_event_name": "PostToolUse", "tool_input": {"questions": [], "answers": "source response"}})
        self.assertFalse(list((self.root / "requests").glob("*.json")))
        self.assertFalse(list((self.root / "decisions").glob("*.json")))

    def test_codex_async_question_acknowledgement_preserves_notice_and_expiry(self):
        self.heartbeat()
        for source in ("codex", "chatgpt-work"):
            for tool_name in ("request_user_input_async", "functions.request_user_input_async"):
                with self.subTest(source=source, tool_name=tool_name):
                    event = {"hook_event_name": "PreToolUse", "tool_name": tool_name,
                             "session_id": "async-question", "turn_id": "async-turn", "tool_use_id": "async-call",
                             "tool_input": {"questions": [{"question": "Choose?"}]}}
                    bridge.handle_hook(self.root, source, event)
                    request = self.wait_pending()[0]
                    path = self.root / "requests" / (request["id"] + ".json")
                    original = path.read_bytes()
                    self.assertFalse(request["canRespond"])
                    self.assertEqual(request["expiresAt"] - request["createdAt"], 120)
                    bridge.handle_hook(self.root, source, {**event, "hook_event_name": "PostToolUse",
                        "tool_name": "request_user_input_async", "tool_input": {}, "tool_response": {"accepted": True}})
                    self.assertEqual(path.read_bytes(), original, "Acknowledgement must retain the immutable notice")
                    self.assertFalse(list((self.root / "decisions").glob("*.json")))
                    bridge.handle_hook(self.root, source, {**event, "hook_event_name": "Stop"})
                    self.assertFalse(path.exists())

    def test_async_acknowledgement_before_notice_publication_does_not_suppress_it(self):
        self.heartbeat()
        for tool_name, expected in (("functions.request_user_input_async", 1), ("functions.request_user_input", 0)):
            with self.subTest(tool_name=tool_name):
                event = {"hook_event_name": "PreToolUse", "tool_name": tool_name,
                         "session_id": tool_name, "turn_id": "question-turn", "tool_use_id": "question-call",
                         "tool_input": {"questions": [{"question": "Choose?"}]}}
                bridge.handle_hook(self.root, "codex", {**event, "hook_event_name": "PostToolUse",
                    "tool_response": {"accepted": True}})
                bridge.handle_hook(self.root, "codex", event)
                self.assertEqual(len(list((self.root / "requests").glob("*.json"))), expected)
                bridge.handle_hook(self.root, "codex", {**event, "hook_event_name": "Stop"})

    def test_async_question_notices_keep_failure_and_scoped_lifecycle_cleanup(self):
        self.heartbeat()
        for event_name in ("PostToolUseFailure", "Stop", "Interrupt", "SessionEnd"):
            with self.subTest(event_name=event_name):
                event = {"hook_event_name": "PreToolUse", "tool_name": "functions.request_user_input_async",
                         "session_id": "async-" + event_name, "turn_id": "question-turn", "tool_use_id": "question-call",
                         "tool_input": {"questions": [{"question": "Choose?"}]}}
                other = {**event, "session_id": "other-" + event_name}
                bridge.handle_hook(self.root, "codex", event)
                bridge.handle_hook(self.root, "codex", other)
                bridge.handle_hook(self.root, "chatgpt-work", event)
                cards = self.wait_pending(3)
                bridge.handle_hook(self.root, "codex", {**event, "hook_event_name": event_name})
                remaining = self.wait_pending(2)
                expected = {card["id"] for card in cards
                            if card["source"] != "codex" or card["sessionId"] != event["session_id"]}
                self.assertEqual({card["id"] for card in remaining}, expected)
                self.assertFalse(list((self.root / "decisions").glob("*.json")))
                bridge.handle_hook(self.root, "codex", {**other, "hook_event_name": "SessionEnd"})
                bridge.handle_hook(self.root, "chatgpt-work", {**event, "hook_event_name": "SessionEnd"})

    def test_async_question_tool_permission_still_retires_after_tool_completion(self):
        self.heartbeat()
        event = {"hook_event_name": "PermissionRequest", "tool_name": "functions.request_user_input_async",
                 "session_id": "async-permission", "turn_id": "question-turn", "tool_use_id": "question-call",
                 "tool_input": {"questions": [{"question": "Choose?"}]}}
        process = self.start_hook(event, source="codex")
        request = self.wait_pending()[0]
        self.assertEqual(request["kind"], "permission")
        bridge.handle_hook(self.root, "codex", {**event, "hook_event_name": "PostToolUse",
            "tool_response": {"accepted": True}})
        self.assertIsNone(self.output(process), "Tool completion must not manufacture a permission decision")
        self.assertFalse(list((self.root / "requests").glob("*.json")))
        self.assertFalse(list((self.root / "decisions").glob("*.json")))

    def test_exact_tool_id_allows_omitted_optional_scope_in_either_event(self):
        self.heartbeat()
        scope = {"prompt_id": "prompt-one", "turn_id": "turn-one", "agent_id": "agent-one", "agent_type": "worker"}
        for omitted_in_request in (True, False):
            with self.subTest(omitted_in_request=omitted_in_request):
                call_id = "question-added-scope" if omitted_in_request else "question-omitted-scope"
                event = {**self.question_event(), "tool_use_id": call_id}
                if not omitted_in_request:
                    event.update(scope)
                process = self.start_hook(event)
                self.wait_pending()
                completed = {"hook_event_name": "PostToolUse", "session_id": event["session_id"],
                             "tool_use_id": call_id, "tool_name": "AskUserQuestion",
                             "tool_input": {"answers": {"Continue?": "Yes"}}}
                if omitted_in_request:
                    completed.update(scope)
                bridge.handle_hook(self.root, "claude", completed)
                self.assertIsNone(self.output(process), "A completed call must never inject a second answer")
                self.assertFalse(list((self.root / "requests").glob("*.json")))
                self.assertFalse(list((self.root / "decisions").glob("*.json")))

    def test_exact_tool_id_rejects_conflicting_known_scope(self):
        self.heartbeat()
        for field in ("prompt_id", "turn_id", "agent_id", "agent_type"):
            with self.subTest(conflicting_field=field):
                event = {**self.question_event(), "tool_use_id": "question-" + field, field: "original-scope"}
                process = self.start_hook(event, wait=0.3)
                card = self.wait_pending()[0]
                completed = {**event, "hook_event_name": "PostToolUse", field: "different-scope"}
                bridge.handle_hook(self.root, "claude", completed)
                self.assertTrue((self.root / "requests" / (card["id"] + ".json")).exists())
                self.assertIsNone(process.poll(), "Known scope conflicts must keep the original request waiting")
                self.assertIsNone(self.output(process))

    def test_shared_agent_id_is_authoritative_over_agent_type_labels(self):
        self.heartbeat()
        event = {**self.question_event(), "tool_use_id": "question-call", "agent_id": "same-agent", "agent_type": "first-label"}
        process = self.start_hook(event)
        self.wait_pending()
        bridge.handle_hook(self.root, "claude", {**event, "hook_event_name": "PostToolUse", "agent_type": "second-label"})
        self.assertIsNone(self.output(process))
        self.assertFalse(list((self.root / "requests").glob("*.json")))

    def test_exact_tool_completion_preserves_other_source_session_and_background_call(self):
        self.heartbeat()
        event = {**self.question_event(), "tool_use_id": "completed-call"}
        target = self.start_hook(event)
        other_events = [("vscode", event), ("claude", {**event, "session_id": "other-session"}),
                        ("claude", {**event, "tool_use_id": "active-background-call", "agent_id": "background-agent"})]
        others = [self.start_hook(other, source=source) for source, other in other_events]
        self.wait_pending(4)
        bridge.handle_hook(self.root, "claude", {**event, "hook_event_name": "PostToolUse", "prompt_id": "known-later",
                                                "background_tasks": [{"id": "still-running"}]})
        self.assertIsNone(self.output(target))
        self.wait_pending(3)
        for process in others:
            self.assertIsNone(process.poll())
        for source, other in other_events:
            bridge.handle_hook(self.root, source, {"hook_event_name": "SessionEnd", "session_id": other["session_id"]})
        for process in others:
            self.assertIsNone(self.output(process))

    def test_omitted_scope_does_not_widen_fingerprint_or_generic_notice_matching(self):
        self.heartbeat()
        event = self.permission_event()
        process = self.start_hook(event, wait=0.3)
        card = self.wait_pending()[0]
        bridge.handle_hook(self.root, "claude", {**event, "hook_event_name": "PostToolUse", "tool_use_id": "known-call",
                                                "prompt_id": "known-prompt"})
        self.assertTrue((self.root / "requests" / (card["id"] + ".json")).exists())
        self.assertIsNone(self.output(process))
        notice = {"hook_event_name": "Notification", "notification_type": "permission_prompt", "session_id": "notice-session",
                  "title": "Permission", "message": "Review in the original app"}
        bridge.handle_hook(self.root, "claude", notice)
        card = self.wait_pending()[0]
        bridge.handle_hook(self.root, "claude", {"hook_event_name": "Stop", "session_id": "notice-session", "prompt_id": "known-prompt"})
        self.assertTrue((self.root / "requests" / (card["id"] + ".json")).exists())

    def test_conflicting_tool_ids_never_fall_back_to_identical_input(self):
        self.heartbeat()
        event = {**self.question_event(), "tool_use_id": "pending-call"}
        process = self.start_hook(event, wait=0.3)
        card = self.wait_pending()[0]
        bridge.handle_hook(self.root, "claude", {**event, "hook_event_name": "PostToolUse", "tool_use_id": "different-call"})
        self.assertTrue((self.root / "requests" / (card["id"] + ".json")).exists())
        self.assertIsNone(self.output(process))

    def tracked_call(self, call_id="owned-call", session="session-one", command="example --literal", **scope):
        event = {"hook_event_name": "PreToolUse", "session_id": session, "prompt_id": "prompt-one", "tool_use_id": call_id,
                 "tool_name": "Bash", "tool_input": {"command": command}, **scope}
        bridge.track_tool(self.root, "claude", event)
        return event

    def native_decision(self, call, decision="accept", at=None, **overrides):
        event = {"session_id": call["session_id"], "tool_use_id": call["tool_use_id"], "decision": decision,
                 "source": "user_temporary" if decision == "accept" else "user_reject",
                 "decided_at": time.time() if at is None else at, **overrides}
        if "prompt_id" in call and "prompt_id" not in overrides:
            event["prompt_id"] = call["prompt_id"]
        bridge.handle_telemetry_decision(self.root, "claude", event)

    def notice_event(self, call):
        return {"hook_event_name": "Notification", "session_id": call["session_id"], "prompt_id": call.get("prompt_id", "prompt-one"),
                "notification_type": "permission_prompt", "title": "Permission", "message": "Review in the source"}

    def test_native_yes_retires_permission_while_its_tool_remains_active(self):
        self.heartbeat()
        call = self.tracked_call(agent_id="owned-agent", agent_type="worker")
        permission = {key: value for key, value in call.items() if key != "tool_use_id"}
        permission["hook_event_name"] = "PermissionRequest"
        process = self.start_hook(permission)
        card = self.wait_pending()[0]
        self.assertEqual(card["correlation"]["toolUseId"], call["tool_use_id"])
        self.native_decision(call)
        self.assertIsNone(self.output(process), "The native Yes must not produce a second approval from Pip")
        self.assertFalse(list((self.root / "decisions").glob("*.json")))
        state = bridge.session_document(self.root, "claude", call["session_id"])
        self.assertEqual(len(bridge.active_calls(state)), 1, "An approval must not pretend execution finished")
        self.assertEqual(bridge.retirement_records(state)[-1]["eventName"], "ToolDecision")
        self.assertEqual(state["status"], "working", "Accepted work must animate while the action executes")
        self.assertEqual(state["message"], "")

    def test_multiple_native_decisions_clear_only_their_matching_permission_cards(self):
        self.heartbeat()
        first = self.tracked_call("first-parallel-call", command="display first")
        second = self.tracked_call("second-parallel-call", command="display second")
        processes = []
        for call in (first, second):
            permission = {key: value for key, value in call.items() if key != "tool_use_id"}
            permission["hook_event_name"] = "PermissionRequest"
            processes.append(self.start_hook(permission, wait=5))
        cards = {card["correlation"]["toolUseId"]: card for card in self.wait_pending(2)}
        self.native_decision(first)
        self.assertIsNone(self.output(processes[0]))
        remaining = self.wait_pending()
        self.assertEqual([card["id"] for card in remaining], [cards[second["tool_use_id"]]["id"]])
        self.native_decision(second, "reject")
        self.assertIsNone(self.output(processes[1]))
        self.assertFalse(list((self.root / "requests").glob("*.json")))
        self.assertFalse(list((self.root / "decisions").glob("*.json")))
        self.assertEqual(len(bridge.active_calls(bridge.session_document(self.root, "claude", first["session_id"]))), 2)

    def test_native_decision_preserves_other_pending_attention_and_newer_stop_status(self):
        self.heartbeat()
        call = self.tracked_call()
        bridge.handle_hook(self.root, "claude", self.notice_event(call))
        other = {"id": "e" * 32, "source": "claude", "sessionId": call["session_id"],
                 "createdAt": time.time(), "expiresAt": time.time() + 120,
                 "correlation": {"sessionId": call["session_id"], "toolUseId": "other-call"}}
        path = self.root / "requests" / (other["id"] + ".json")
        bridge.write_json(path, other)
        self.native_decision(call)
        state = bridge.session_document(self.root, "claude", call["session_id"])
        self.assertEqual(state["status"], "attention")
        self.assertTrue(path.exists())
        path.unlink()
        # A delayed approval batch must not overwrite an already observed idle/offline state.
        for status in ("idle", "offline"):
            bridge.session_state(self.root, "claude", call, status, "newer lifecycle")
            self.native_decision(call)
            state = bridge.session_document(self.root, "claude", call["session_id"])
            self.assertEqual((state["status"], state["message"]), (status, "newer lifecycle"))

    def test_unique_notification_owner_recovers_subagent_scope_and_clears_on_later_decision(self):
        self.heartbeat()
        call = self.tracked_call(agent_id="subagent-owner", agent_type="worker")
        bridge.handle_hook(self.root, "claude", self.notice_event(call))
        card = self.wait_pending()[0]
        self.assertEqual(card["correlation"]["agentId"], "subagent-owner")
        self.assertEqual(card["correlation"]["toolUseId"], call["tool_use_id"])
        self.native_decision(call, "reject")
        self.assertFalse(list((self.root / "requests").glob("*.json")))
        self.assertFalse(list((self.root / "decisions").glob("*.json")))

    def test_earlier_batched_approval_does_not_clear_a_later_network_notice(self):
        self.heartbeat()
        call = self.tracked_call()
        accepted_at = time.time()
        bridge.handle_hook(self.root, "claude", self.notice_event(call))
        card = self.wait_pending()[0]
        self.assertLess(accepted_at, card["createdAt"])
        self.native_decision(call, at=accepted_at)
        self.assertTrue((self.root / "requests" / (card["id"] + ".json")).exists())
        # Duplicate delivery cannot convert receiver time into a new decision.
        self.native_decision(call, at=accepted_at)
        self.assertTrue((self.root / "requests" / (card["id"] + ".json")).exists())
        bridge.handle_hook(self.root, "claude", {**call, "hook_event_name": "PostToolUse"})
        self.assertFalse(list((self.root / "requests").glob("*.json")))

    def test_decision_history_suppresses_late_actionable_hook_but_not_later_notice(self):
        self.heartbeat()
        call = self.tracked_call()
        self.native_decision(call)
        permission = {key: value for key, value in call.items() if key != "tool_use_id"}
        permission["hook_event_name"] = "PermissionRequest"
        self.assertIsNone(self.output(self.start_hook(permission)))
        self.assertFalse(list((self.root / "requests").glob("*.json")))
        bridge.handle_hook(self.root, "claude", self.notice_event(call))
        self.assertEqual(self.wait_pending()[0]["correlation"]["toolUseId"], call["tool_use_id"])

    def test_parallel_agents_older_prompts_and_pending_cards_prevent_generic_binding(self):
        self.heartbeat()
        for other_scope in ({"agent_id": "another-agent"}, {"prompt_id": "older-prompt"}):
            with self.subTest(scope=other_scope):
                call = self.tracked_call()
                self.tracked_call("other-call", **other_scope)
                bridge.handle_hook(self.root, "claude", self.notice_event(call))
                card = self.wait_pending()[0]
                self.assertNotIn("toolUseId", card["correlation"])
                self.native_decision(call)
                self.assertTrue((self.root / "requests" / (card["id"] + ".json")).exists())
                bridge.handle_hook(self.root, "claude", {"hook_event_name": "SessionEnd", "session_id": call["session_id"]})
        call = self.tracked_call("single-call")
        # A card with unresolved owner is independent evidence of ambiguity.
        unknown = {"schemaVersion": 1, "id": "f" * 32, "source": "claude", "sessionId": call["session_id"],
                   "createdAt": time.time(), "expiresAt": time.time() + 120, "correlation": {"sessionId": call["session_id"]}}
        bridge.write_json(self.root / "requests" / (unknown["id"] + ".json"), unknown)
        bridge.handle_hook(self.root, "claude", self.notice_event(call))
        cards = self.wait_pending(2)
        self.assertTrue(all("toolUseId" not in card["correlation"] for card in cards))

    def test_background_launch_cannot_be_mistaken_for_a_foreground_permission(self):
        self.heartbeat()
        background = self.tracked_call("background-call", tool_input={"command": "background", "run_in_background": True})
        bridge.handle_hook(self.root, "claude", {**background, "hook_event_name": "PostToolUse", "tool_response": {"started": True}})
        main = self.tracked_call("foreground-call", command="foreground")
        bridge.handle_hook(self.root, "claude", self.notice_event(main))
        card = self.wait_pending()[0]
        self.assertNotIn("toolUseId", card["correlation"])
        self.native_decision(main)
        self.assertTrue((self.root / "requests" / (card["id"] + ".json")).exists())

    def test_identical_active_calls_cannot_be_assigned_by_hash_to_one_permission(self):
        self.heartbeat()
        first = self.tracked_call("first-call")
        self.tracked_call("second-call")
        permission = {key: value for key, value in first.items() if key != "tool_use_id"}
        permission["hook_event_name"] = "PermissionRequest"
        process = self.start_hook(permission, wait=0.4)
        card = self.wait_pending()[0]
        self.assertNotIn("toolUseId", card["correlation"])
        self.native_decision(first)
        self.assertTrue((self.root / "requests" / (card["id"] + ".json")).exists())
        bridge.handle_hook(self.root, "claude", {**first, "hook_event_name": "PostToolUse"})
        self.assertTrue((self.root / "requests" / (card["id"] + ".json")).exists())
        self.assertIsNone(self.output(process))

    def test_invalid_unrelated_or_stale_decisions_do_not_retire_bound_cards(self):
        self.heartbeat()
        call = self.tracked_call()
        bridge.handle_hook(self.root, "claude", self.notice_event(call))
        card = self.wait_pending()[0]
        for overrides in ({"session_id": "other-session"}, {"prompt_id": "other-prompt"}, {"tool_use_id": "unknown-call"},
                          {"tool_use_id": ""}, {"source": "user_abort"}, {"decided_at": time.time() + 30},
                          {"decided_at": 0}, {"decided_at": time.time() - 60}):
            self.native_decision(call, **overrides)
            self.assertTrue((self.root / "requests" / (card["id"] + ".json")).exists())
        bridge.handle_telemetry_decision(self.root, "codex", {"session_id": call["session_id"], "tool_use_id": call["tool_use_id"],
                                                           "decision": "accept", "source": "user_temporary", "decided_at": time.time()})
        self.assertTrue((self.root / "requests" / (card["id"] + ".json")).exists())

    def test_tool_ledger_preserves_lifecycle_records_and_contains_no_original_input(self):
        event = {"hook_event_name": "Stop", "session_id": "session-one", "prompt_id": "old-prompt"}
        bridge.handle_hook(self.root, "claude", event)
        call = self.tracked_call(command="PRIVATE-INPUT-MARKER", agent_id="owned-agent")
        state = bridge.session_document(self.root, "claude", call["session_id"])
        self.assertEqual(len(bridge.retirement_records(state)), 1)
        self.assertEqual(len(bridge.active_calls(state)), 1)
        self.assertNotIn("PRIVATE-INPUT-MARKER", json.dumps(state))
        self.assertNotIn("tool_input", json.dumps(state))
        bridge.handle_hook(self.root, "claude", {**call, "hook_event_name": "PostToolUse"})
        self.assertFalse(bridge.active_calls(bridge.session_document(self.root, "claude", call["session_id"])))

    def test_large_session_metadata_is_bounded_and_dropped_calls_stay_ambiguous(self):
        now = time.time()
        calls, retirements = [], []
        # Valid but atypically long identity values must not exceed IPC limits.
        long_identity = "\u754c" * (bridge.MAX_IDENTIFIER_BYTES // 3)
        for index in range(bridge.MAX_ACTIVE_CALLS):
            scope = {"sessionId": "session-one", "toolUseId": "call-" + str(index),
                     "promptId": long_identity, "turnId": long_identity, "agentId": long_identity,
                     "agentType": long_identity, "toolName": long_identity, "toolInputHash": "a" * 64}
            calls.append({"correlation": scope, "observedAt": now, "background": False})
            retirements.append({"eventName": "PostToolUse", "correlation": scope, "observedAt": now})
        bridge.session_state(self.root, "claude", {"session_id": "session-one"}, "working",
                             retirement=retirements[-32:], active_tools=calls)
        state = bridge.session_document(self.root, "claude", "session-one")
        self.assertLess(len(json.dumps(state).encode()), bridge.MAX_REQUEST)
        self.assertLessEqual(len(json.dumps(state["activeToolCalls"]).encode()), bridge.MAX_ACTIVE_METADATA)
        self.assertLessEqual(len(json.dumps(state["retirements"]).encode()), bridge.MAX_RETIREMENT_METADATA)
        self.assertTrue(state["activeToolOverflow"])
        self.assertLess(len(bridge.active_calls(state)), len(calls))
        # Even one surviving call cannot establish uniqueness after omitted owners.
        bridge.session_state(self.root, "claude", {"session_id": "session-one"}, "working", active_tools=calls[-1:])
        self.heartbeat()
        bridge.handle_hook(self.root, "claude", {"hook_event_name": "Notification", "session_id": "session-one",
                                                "notification_type": "permission_prompt", "message": "Review in source"})
        self.assertNotIn("toolUseId", self.wait_pending()[0]["correlation"])
        bridge.handle_hook(self.root, "claude", {"hook_event_name": "SessionEnd", "session_id": "session-one"})
        self.assertFalse(bridge.session_document(self.root, "claude", "session-one")["activeToolOverflow"])

    def test_oversized_or_invalid_identity_cannot_poison_the_tool_ledger(self):
        call = self.tracked_call()
        for identity in ("x" * (bridge.MAX_IDENTIFIER_BYTES + 1), "\ud800"):
            with self.subTest(identity_size=len(identity)):
                bad = {**call, "tool_use_id": "another-call", "agent_id": identity}
                completed = subprocess.run([sys.executable, str(bridge.PROJECT / "bridge.py"), "hook", "--source", "claude",
                                            "--runtime", str(self.root), "--track-tools"], input=json.dumps(bad),
                                           text=True, capture_output=True, timeout=2)
                self.assertEqual(completed.returncode, 0)
                self.assertEqual(completed.stdout, "")
                self.assertNotIn("Traceback", completed.stderr)
                state = bridge.session_document(self.root, "claude", call["session_id"])
                self.assertEqual(len(bridge.active_calls(state)), 1)
                self.assertTrue(state["activeToolOverflow"], "An omitted malformed owner must prevent uniqueness inference")

    def test_missing_tracked_call_identity_prevents_generic_notice_binding(self):
        self.heartbeat()
        call = self.tracked_call()
        incomplete = {**call, "tool_input": {"command": "another-call"}}
        incomplete.pop("tool_use_id")
        bridge.track_tool(self.root, "claude", incomplete)
        bridge.handle_hook(self.root, "claude", self.notice_event(call))
        card = self.wait_pending()[0]
        self.assertNotIn("toolUseId", card["correlation"])
        self.native_decision(call)
        self.assertTrue((self.root / "requests" / (card["id"] + ".json")).exists())

    def test_invalid_stored_call_marks_ambiguity_when_status_is_updated(self):
        call = self.tracked_call()
        state = bridge.session_document(self.root, "claude", call["session_id"])
        state["activeToolCalls"].append({"correlation": {"sessionId": "session-one", "toolUseId": "missing-owner",
                                                       "unexpectedScope": "hidden"},
                                         "observedAt": time.time(), "background": False})
        bridge.write_json(bridge.session_path(self.root, "claude", call["session_id"]), state)
        bridge.handle_hook(self.root, "claude", {"hook_event_name": "UserPromptSubmit", "session_id": call["session_id"]})
        state = bridge.session_document(self.root, "claude", call["session_id"])
        self.assertEqual(len(bridge.active_calls(state)), 1)
        self.assertTrue(state["activeToolOverflow"])

    def test_track_only_question_hook_returns_promptly_without_a_card_or_control(self):
        event = {**self.question_event(), "tool_use_id": "question-call"}
        started = time.monotonic()
        completed = subprocess.run([sys.executable, str(bridge.PROJECT / "bridge.py"), "hook", "--source", "claude",
                                    "--runtime", str(self.root), "--track-tools"], input=json.dumps(event), text=True,
                                   capture_output=True, timeout=2)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stdout, "")
        self.assertLess(time.monotonic() - started, 1)
        self.assertFalse(list((self.root / "requests").glob("*.json")))
        self.assertEqual(len(bridge.active_calls(bridge.session_document(self.root, "claude", event["session_id"]))), 1)

    def test_telemetry_cli_consumes_only_decision_metadata_and_returns_no_control(self):
        self.heartbeat()
        call = self.tracked_call("toolu_owned_one")
        bridge.handle_hook(self.root, "claude", self.notice_event(call))
        from test_telemetry import fixture
        document = fixture(at=time.time())
        completed = subprocess.run([sys.executable, str(bridge.PROJECT / "bridge.py"), "telemetry", "--runtime", str(self.root)],
                                   input=json.dumps(document), text=True, capture_output=True, timeout=2)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stdout, "")
        self.assertFalse(list((self.root / "requests").glob("*.json")))
        self.assertFalse(list((self.root / "decisions").glob("*.json")))
        invalid = subprocess.run([sys.executable, str(bridge.PROJECT / "bridge.py"), "telemetry", "--runtime", str(self.root)],
                                 input="{}", text=True, capture_output=True, timeout=2)
        self.assertNotEqual(invalid.returncode, 0)
        self.assertEqual(invalid.stdout, "")


if __name__ == "__main__":
    unittest.main()
