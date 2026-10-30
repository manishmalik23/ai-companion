from copy import deepcopy
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import telemetry


NOW = datetime(2026, 10, 9, tzinfo=timezone.utc).timestamp()
EVENT_TIME = NOW - 0.25


def attribute(key, value):
    return {"key": key, "value": {"stringValue": value}}


def nanoseconds(at):
    return int(Decimal(str(at)) * 1_000_000_000)


def fixture(decision="accept", source="user_temporary", at=EVENT_TIME):
    return {"resourceLogs": [{
        "resource": {"attributes": [attribute("service.name", "claude-code"),
                                       attribute("service.version", "2.1.292")]},
        "scopeLogs": [{"scope": {"name": "com.anthropic.claude_code.events", "version": "2.1.292"},
                       "logRecords": [{
                           "timeUnixNano": str(nanoseconds(at)),
                           "observedTimeUnixNano": str(nanoseconds(NOW)),
                           "body": {"stringValue": "claude_code.tool_decision"},
                           "attributes": [attribute("event.name", "tool_decision"),
                                          attribute("event.timestamp", datetime.fromtimestamp(at, timezone.utc).isoformat()),
                                          attribute("session.id", "session-one"), attribute("prompt.id", "prompt-one"),
                                          attribute("tool_use_id", "toolu_owned_one"), attribute("decision", decision),
                                          attribute("source", source), attribute("tool_name", "Bash")],
                       }]}],
    }]}


def record(document):
    return document["resourceLogs"][0]["scopeLogs"][0]["logRecords"][0]


def replace_attribute(document, key, value):
    attributes = record(document)["attributes"]
    attributes[:] = [entry for entry in attributes if entry["key"] != key]
    attributes.append(attribute(key, value))


class TelemetryParserTests(unittest.TestCase):
    def parse(self, document):
        return telemetry.parse_tool_decisions(document, now=NOW)

    def test_official_shape_returns_only_permission_metadata(self):
        self.assertEqual(self.parse(fixture()), [{"session_id": "session-one", "prompt_id": "prompt-one",
                                                 "tool_use_id": "toolu_owned_one", "decision": "accept",
                                                 "source": "user_temporary", "decided_at": EVENT_TIME}])

    def test_every_supported_decision_source_combination(self):
        for decision, sources in telemetry.DECISION_SOURCES.items():
            for source in sources:
                with self.subTest(decision=decision, source=source):
                    result = self.parse(fixture(decision, source))
                    self.assertEqual(result[0]["decision"], decision)
                    self.assertEqual(result[0]["source"], source)

    def test_incompatible_and_unknown_decision_sources_reject(self):
        for decision, source in (("accept", "user_abort"), ("accept", "user_reject"),
                                 ("reject", "user_temporary"), ("reject", "user_permanent"),
                                 ("allow", "user_temporary"), ("accept", "classifier")):
            with self.subTest(decision=decision, source=source):
                self.assertEqual(self.parse(fixture(decision, source)), [])

    def test_optional_prompt_can_be_absent_but_not_invalid(self):
        document = fixture()
        record(document)["attributes"] = [entry for entry in record(document)["attributes"] if entry["key"] != "prompt.id"]
        self.assertNotIn("prompt_id", self.parse(document)[0])
        for value in ("", "unknown prompt", "\n", "x" * 513):
            replace_attribute(document, "prompt.id", value)
            self.assertEqual(self.parse(document), [])

    def test_missing_empty_oversized_and_control_character_identities_reject(self):
        for key in ("session.id", "tool_use_id"):
            for value in (None, "", " identity", "contains space", "tab\tidentity", "bad\x00id", "bad\ud800id", "x" * 513, "é" * 257):
                with self.subTest(key=key, value=value):
                    document = fixture()
                    attributes = record(document)["attributes"]
                    attributes[:] = [entry for entry in attributes if entry["key"] != key]
                    if value is not None:
                        attributes.append(attribute(key, value))
                    self.assertEqual(self.parse(document), [])

    def test_non_string_identity_and_conflicting_anyvalue_types_reject(self):
        for value in ({"intValue": "7"}, {"stringValue": "session-one", "intValue": "7"},
                      {"stringValue": 7}, {}, {"stringValue": True}):
            document = fixture()
            attributes = record(document)["attributes"]
            next(entry for entry in attributes if entry["key"] == "session.id")["value"] = value
            self.assertEqual(self.parse(document), [])

    def test_duplicate_attributes_reject_even_identical_or_unused(self):
        for key, value in (("session.id", "session-one"), ("session.id", "other-session"), ("tool_name", "Bash")):
            document = fixture()
            record(document)["attributes"].append(attribute(key, value))
            self.assertEqual(self.parse(document), [])

    def test_resource_scope_and_body_cannot_impersonate_claude_event(self):
        mutations = [
            lambda d: d["resourceLogs"][0]["resource"]["attributes"].clear(),
            lambda d: d["resourceLogs"][0]["resource"]["attributes"][0]["value"].update(stringValue="other-service"),
            lambda d: d["resourceLogs"][0]["scopeLogs"][0]["scope"].update(name="other.scope"),
            lambda d: record(d).update(body={"stringValue": "claude_code.tool_result"}),
            lambda d: record(d).update(body={"stringValue": "claude_code.tool_decision", "intValue": "1"}),
            lambda d: replace_attribute(d, "event.name", "tool_result"),
        ]
        for mutate in mutations:
            document = fixture()
            mutate(document)
            self.assertEqual(self.parse(document), [])

    def test_resource_duplicate_and_conflicting_types_reject(self):
        for value in ({"stringValue": "claude-code", "intValue": "1"}, {"intValue": "1"}):
            document = fixture()
            document["resourceLogs"][0]["resource"]["attributes"][0]["value"] = value
            self.assertEqual(self.parse(document), [])
        document = fixture()
        document["resourceLogs"][0]["resource"]["attributes"].append(attribute("service.name", "claude-code"))
        self.assertEqual(self.parse(document), [])

    def test_prebatched_records_keep_original_time_and_ignore_arrival(self):
        document = fixture(at=NOW - 86_400)
        record(document)["observedTimeUnixNano"] = str(nanoseconds(NOW + 3600))
        self.assertEqual(self.parse(document)[0]["decided_at"], NOW - 86_400)

    def test_integer_nanoseconds_and_iso_fallback_are_supported(self):
        document = fixture()
        record(document)["timeUnixNano"] = nanoseconds(EVENT_TIME)
        self.assertEqual(self.parse(document)[0]["decided_at"], EVENT_TIME)
        for absent in (None, 0, "0"):
            document = fixture()
            if absent is None:
                record(document).pop("timeUnixNano")
            else:
                record(document)["timeUnixNano"] = absent
            self.assertEqual(self.parse(document)[0]["decided_at"], EVENT_TIME)

    def test_nanosecond_fraction_in_iso_fallback_is_not_truncated(self):
        document = fixture()
        record(document).pop("timeUnixNano")
        replace_attribute(document, "event.timestamp", "2026-10-01T00:00:00.123456789Z")
        expected = datetime(2026, 10, 1, tzinfo=timezone.utc).timestamp() + 0.123456789
        self.assertEqual(self.parse(document)[0]["decided_at"], expected)

    def test_malformed_nanoseconds_cannot_fall_back_to_other_time(self):
        for value in (True, -1, "-1", "NaN", "1e18", "1790000000.0", 1.5, "9" * 21, telemetry.MAX_UINT64 + 1):
            document = fixture()
            record(document)["timeUnixNano"] = value
            self.assertEqual(self.parse(document), [])

    def test_missing_time_and_observed_time_only_reject(self):
        document = fixture()
        record(document).pop("timeUnixNano")
        record(document)["attributes"] = [entry for entry in record(document)["attributes"] if entry["key"] != "event.timestamp"]
        self.assertEqual(self.parse(document), [])

    def test_future_time_rejects_beyond_clock_skew(self):
        self.assertEqual(self.parse(fixture(at=NOW + telemetry.CLOCK_SKEW_SECONDS + 1)), [])
        self.assertEqual(len(self.parse(fixture(at=NOW + telemetry.CLOCK_SKEW_SECONDS))), 1)

    def test_malformed_or_disagreeing_iso_timestamps_reject(self):
        for value in ("not-a-time", "2026-10-01T00:00:00", "2026-99-01T00:00:00Z", "1970-01-01T00:00:00Z",
                      "2026-10-01T00:00:00+05:99", "2026-10-01T00:00:00+24:00"):
            document = fixture()
            replace_attribute(document, "event.timestamp", value)
            self.assertEqual(self.parse(document), [])

    def test_iso_offset_and_millisecond_record_sampling_difference(self):
        document = fixture()
        record(document).pop("timeUnixNano")
        replace_attribute(document, "event.timestamp", "2026-10-01T05:30:00.25+05:30")
        expected = datetime(2026, 10, 1, tzinfo=timezone.utc).timestamp() + 0.25
        self.assertEqual(self.parse(document)[0]["decided_at"], expected)
        document = fixture()
        record(document)["timeUnixNano"] = str(nanoseconds(EVENT_TIME + 0.01))
        self.assertAlmostEqual(self.parse(document)[0]["decided_at"], EVENT_TIME + 0.01, places=6)

    def test_ignored_content_account_and_mcp_names_never_leave_parser(self):
        document = fixture()
        record(document)["attributes"] += [attribute("user.email", "fixture@example.invalid"),
                                             attribute("user.account_uuid", "private-account"),
                                             attribute("prompt", "private question"),
                                             attribute("tool_parameters", "private command")]
        replace_attribute(document, "tool_name", "mcp_tool")
        result = self.parse(document)[0]
        self.assertEqual(set(result), {"session_id", "prompt_id", "tool_use_id", "decision", "source", "decided_at"})
        self.assertNotIn("private", repr(result))

    def test_valid_neighbor_survives_malformed_and_unrelated_records(self):
        document = fixture()
        valid = deepcopy(record(document))
        invalid = deepcopy(valid)
        invalid["body"] = {"stringValue": "claude_code.user_prompt"}
        document["resourceLogs"][0]["scopeLogs"][0]["logRecords"] = [None, invalid, valid]
        self.assertEqual(len(self.parse(document)), 1)

    def test_traversal_and_text_bounds_reject(self):
        document = fixture()
        record(document)["attributes"] += [attribute("unused", "x" * (telemetry.MAX_VALUE_BYTES + 1))]
        self.assertEqual(self.parse(document), [])
        document = fixture()
        record(document)["attributes"] = [attribute(str(i), "x") for i in range(telemetry.MAX_ATTRIBUTES + 1)]
        self.assertEqual(self.parse(document), [])
        document = fixture()
        document["resourceLogs"] *= telemetry.MAX_RESOURCE_LOGS + 1
        self.assertEqual(self.parse(document), [])
        document = fixture()
        document["resourceLogs"][0]["scopeLogs"] *= telemetry.MAX_SCOPE_LOGS + 1
        self.assertEqual(self.parse(document), [])
        document = fixture()
        document["resourceLogs"][0]["scopeLogs"][0]["logRecords"] *= telemetry.MAX_LOG_RECORDS + 1
        self.assertEqual(self.parse(document), [])

    def test_malformed_envelopes_and_nonfinite_now_fail_closed(self):
        for document in (None, [], {}, {"resourceLogs": {}}, {"resourceLogs": [None, {}]}):
            self.assertEqual(self.parse(document), [])
        for now in (True, "today", float("nan"), float("inf"), -1, 10 ** 1000):
            self.assertEqual(telemetry.parse_tool_decisions(fixture(), now=now), [])


if __name__ == "__main__":
    unittest.main()
