import json
from pathlib import Path
import sys
import tempfile
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import bridge


class CodexActivityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = bridge.runtime_directory(self.temp.name)
        bridge.write_json(self.root / 'heartbeat.json', {'updatedAt': time.time(), 'codexActivity': True})

    def emit(self, name, **extra):
        event = {'hook_event_name': name, 'session_id': 'session', 'turn_id': 'turn', **extra}
        bridge.handle_hook(self.root, 'chatgpt-work', event)
        return [json.loads(path.read_text()) for path in (self.root / 'activities').glob('*.json')]

    def test_official_payload_only_and_hashed_identity(self):
        items = self.emit('UserPromptSubmit', prompt='private prompt', transcript_path='/private/history')
        self.assertEqual(items[0]['phase'], 'thinking')
        self.assertEqual(len(items[0]['session']), 64)
        items = self.emit('Stop', last_assistant_message=' Hello! ')
        done = next(item for item in items if item['phase'] == 'completed')
        self.assertEqual(done['reply'], 'Hello!')
        encoded = json.dumps(items)
        self.assertNotIn('private prompt', encoded)
        self.assertNotIn('/private/history', encoded)
        self.assertEqual(items[0]['turn'], done['turn'])
        state = bridge.session_document(self.root, 'chatgpt-work', 'session')
        self.assertTrue(state['activityReceipts']['Stop']['hasReplyText'])
        self.assertTrue(state['activityReceipts']['Stop']['replyIsShort'])
        self.assertNotIn('Hello!', json.dumps(state))

    def test_long_missing_and_nontext_replies_are_not_truncated(self):
        for reply in ('x' * 241, None, {'text': 'no'}):
            items = self.emit('Stop', last_assistant_message=reply)
            self.assertTrue(all(item['reply'] is None for item in items))

    def test_no_subagents_missing_identity_or_unrelated_events(self):
        self.assertEqual(self.emit('UserPromptSubmit', agent_id='child'), [])
        self.assertEqual(self.emit('Stop', turn_id=None), [])
        self.assertEqual(self.emit('UserPromptSubmit', session_id=None), [])
        self.assertEqual(self.emit('PreCompact'), [])

    def test_tool_activity_is_working_without_tool_content(self):
        items = self.emit('PostToolUse', tool_name='Bash', tool_input={'command': 'private command'}, tool_response='private result')
        self.assertEqual(items[0]['phase'], 'working')
        self.assertIsNone(items[0]['reply'])
        self.assertNotIn('private', json.dumps(items))

    def test_opt_in_and_live_heartbeat_required(self):
        for heartbeat in ({'updatedAt': time.time()}, {'updatedAt': time.time(), 'codexActivity': False},
                          {'updatedAt': time.time() - 20, 'codexActivity': True}):
            bridge.write_json(self.root / 'heartbeat.json', heartbeat)
            self.assertEqual(self.emit('UserPromptSubmit'), [])

    def test_expired_events_and_queue_budget(self):
        old = self.root / 'activities' / ('a' * 32 + '.json')
        bridge.write_json(old, {'createdAt': time.time() - 11, 'reply': 'old'})
        self.emit('UserPromptSubmit')
        self.assertFalse(old.exists())
        for index in range(70):
            self.emit('UserPromptSubmit', turn_id=str(index))
        self.assertLessEqual(len(list((self.root / 'activities').glob('*.json'))), 64)

    def test_session_end_without_turn_and_permission_output_unchanged(self):
        items = self.emit('SessionEnd', turn_id=None)
        self.assertEqual(items[0]['phase'], 'reset')
        self.assertIsNone(items[0]['turn'])
        result = bridge.handle_hook(self.root, 'chatgpt-work', {
            'hook_event_name': 'Stop', 'session_id': 's', 'turn_id': 't', 'last_assistant_message': 'ok'})
        self.assertIsNone(result)


if __name__ == '__main__':
    unittest.main()
