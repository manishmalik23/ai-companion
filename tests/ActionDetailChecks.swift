import Foundation

@main struct ActionDetailChecks {
    static func main() throws {
        var checks = 0
        func request(_ tool: String, _ input: String, reason: String = "Review") throws -> PermissionRequest {
            let document: [String: Any] = ["schemaVersion": 1, "id": String(repeating: "a", count: 32),
                "source": "claude", "sourceLabel": "Claude Code", "sessionId": "test", "toolName": tool,
                "cwd": "/tmp", "reason": reason, "detailText": input, "isDemo": true,
                "createdAt": 1, "expiresAt": 2]
            return try JSONDecoder().decode(PermissionRequest.self, from: JSONSerialization.data(withJSONObject: document))
        }
        func check(_ tool: String, _ input: String, _ expected: String) throws {
            let request = try request(tool, input)
            precondition(request.actionDetail == expected, "Unexpected detail: \(request.actionDetail)")
            precondition(request.detailText == input, "Full input must remain available")
            checks += 1
        }
        func verify(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }
        func object(_ text: String) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        }
        func display(_ request: PermissionRequest) -> String {
            request.toolInputForDisplay(excludingDisplayedReason: request.reason)
        }
        try check("Read", #"{"file_path":"/tmp/bridge.py","offset":843,"limit":60}"#, "Read(/tmp/bridge.py · lines 843–902)")
        try check("Read", #"{"file_path":"/tmp/file","offset":4}"#, "Read(/tmp/file · from line 4)")
        try check("Read", #"{"file_path":"/tmp/file"}"#, "Read(/tmp/file)")
        try check("Read", #"{"file_path":"/tmp/file","offset":true,"limit":5}"#, "Read(/tmp/file)")
        try check("Read", "{\"file_path\":\"/tmp/file\",\"offset\":\(Int.max),\"limit\":2}", "Read(/tmp/file · from line \(Int.max))")
        try check("Edit", #"{"file_path":"/tmp/a.swift","old_string":"before","new_string":"after"}"#, "Edit(/tmp/a.swift)")
        try check("Write", #"{"file_path":"/tmp/new.txt","content":"hello"}"#, "Write(/tmp/new.txt)")
        try check("Bash", #"{"command":"echo $VALUE"}"#, "Bash(echo $VALUE)")
        try check("exec_command", #"{"cmd":"git status"}"#, "exec_command(git status)")
        try check("Read", "not JSON", "Read")
        try check("OtherTool", #"{"command":"do not infer"}"#, "OtherTool")

        let input = #"{"description":" Review \n","justification":"Review","reason":"Review","message":"Review","command":"Review","file_path":"/tmp/Review","nested":{"description":"Review","reason":"Review"},"other":"Review"}"#
        let duplicate = try request("Bash", input, reason: " \nReview\t")
        let displayed = try object(display(duplicate))
        verify(["description", "justification", "reason", "message"].allSatisfy { displayed[$0] == nil },
               "Only matching top-level explanation metadata should be omitted after edge whitespace trimming")
        let original = try object(input)
        verify(["command", "file_path", "nested", "other"].allSatisfy {
            NSDictionary(dictionary: ["value": displayed[$0]!]).isEqual(to: ["value": original[$0]!])
        }, "Commands, paths, nested explanations and other input values must remain available")

        let differentInput = #"{"description":"Review","justification":"Different explanation","reason":"review","message":{"reason":"Review"},"content":"Review"}"#
        let different = try object(display(request("Write", differentInput)))
        verify(different["description"] == nil && different["justification"] as? String == "Different explanation" &&
               different["reason"] as? String == "review" && different["content"] as? String == "Review" &&
               (different["message"] as? [String: String])?["reason"] == "Review",
               "Nonmatching, differently cased and non-string metadata must be retained without recursive scrubbing")

        for unchanged in ["not JSON: Review", "{broken", #"["Review",{"description":"Review"}]"#,
                          #"{"description":"Different","reason":"review","nested":{"description":"Review"}}"#] {
            verify(try display(request("Read", unchanged)) == unchanged,
                   "Non-object, malformed and nonmatching inputs must retain their exact original display text")
        }
        let blankReasonInput = #"{"description":" ","command":"echo hello"}"#
        verify(try display(request("Bash", blankReasonInput, reason: " \n")) == blankReasonInput,
               "An absent explanation must not remove empty metadata")
        let fallback = try request("Bash", #"{"description":"Claude Code wants to use Bash.","command":"echo hello"}"#, reason: "")
        let fallbackDisplay = try object(fallback.toolInputForDisplay(excludingDisplayedReason: "Claude Code wants to use Bash."))
        verify(fallbackDisplay["description"] == nil && fallbackDisplay["command"] as? String == "echo hello",
               "Filtering uses the explanation actually displayed, including a supplied fallback")

        let prefix = #"{"description":"Review","payload":""#
        let suffix = #""}"#
        let payloadCount = 512 * 1024 - prefix.utf8.count - suffix.utf8.count
        let boundary = prefix + String(repeating: "x", count: payloadCount) + suffix
        let boundaryDisplay = try object(display(request("Read", boundary)))
        verify(boundary.utf8.count == 512 * 1024 && boundaryDisplay["description"] == nil &&
               (boundaryDisplay["payload"] as? String)?.utf8.count == payloadCount,
               "The bounded parser accepts exactly 512 KiB and retains the remaining payload")
        let oversized = prefix + String(repeating: "x", count: payloadCount + 1) + suffix
        verify(try display(request("Read", oversized)) == oversized,
               "Inputs above 512 KiB must bypass display parsing and remain unchanged")

        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let originalBytes = try encoder.encode(duplicate)
        let snapshot = RequestSnapshot(request: duplicate, bytes: originalBytes)
        _ = display(snapshot.request)
        let afterDisplayBytes = try encoder.encode(snapshot.request)
        verify(snapshot.request.detailText == input && snapshot.bytes == originalBytes &&
               afterDisplayBytes == originalBytes,
               "Display filtering must not mutate original input, encoded request or decision snapshot bytes")
        print("\(checks) action detail and display checks passed")
    }
}
