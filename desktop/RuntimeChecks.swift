// A command-line check for the local mailbox; does not launch AppKit or run agent tools.
import Foundation
import Darwin

@main
struct RuntimeChecks {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("companion-native-check-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let store = try RuntimeStore(root: root)
        let encoder = JSONEncoder()
        let now = Date().timeIntervalSince1970
        var checks = 0

        func check(_ condition: Bool, _ message: String) {
            guard condition else { fatalError(message) }
            checks += 1
        }
        func privateWrite(_ data: Data, _ url: URL) throws {
            try data.write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        func request(_ id: String, detail: String = "{}", notice: Bool = false, expires: Double? = nil) -> PermissionRequest {
            PermissionRequest(schemaVersion: 1, id: id, source: "claude-code", sourceLabel: "Claude Code",
                sessionId: "test-session", toolName: "Bash", cwd: root.path, reason: "Test request",
                detailText: detail, isDemo: true, createdAt: now - 1, expiresAt: expires ?? now + 120,
                canRespond: notice ? false : nil, kind: nil, questions: nil)
        }
        func writeRequest(_ request: PermissionRequest) throws {
            try privateWrite(encoder.encode(request), root.appendingPathComponent("requests/" + request.id + ".json"))
        }
        func mustThrow(_ message: String, _ operation: () throws -> Void) {
            do { try operation(); fatalError(message) } catch { checks += 1 }
        }

        mustThrow("A second writer must not acquire the mailbox") { _ = try RuntimeStore(root: root) }
        let first = request(String(repeating: "a", count: 32))
        try writeRequest(first)
        let pending = try store.poll(now: now).0
        check(pending.count == 1, "A valid pending request must be visible")
        var heartbeatInfo = stat()
        check(lstat(root.appendingPathComponent("heartbeat.json").path, &heartbeatInfo) == 0 &&
              (heartbeatInfo.st_mode & 0o777) == 0o600, "Heartbeat must be owner-only")

        let fifo = root.appendingPathComponent("requests/" + String(repeating: "b", count: 32) + ".json")
        check(mkfifo(fifo.path, mode_t(0o600)) == 0, "Create the FIFO test fixture")
        let start = Date().timeIntervalSince1970
        check(try store.poll(now: now).0.count == 1, "A FIFO must be ignored")
        check(Date().timeIntervalSince1970 - start < 1, "A FIFO must not block the UI")

        let decisionURL = root.appendingPathComponent("decisions/" + first.id + ".json")
        try privateWrite(Data("{}".utf8), decisionURL)
        check(try store.poll(now: now).0.count == 1, "An invalid decision must not hide a request")
        let oversizedDecision = "{\"id\":\"" + first.id + "\",\"decision\":\"allow\",\"decidedAt\":" +
            String(now) + "}" + String(repeating: " ", count: 5000)
        try privateWrite(Data(oversizedDecision.utf8), decisionURL)
        check(try store.poll(now: now).0.count == 1, "An oversized decision must not hide a request the bridge still awaits")
        try fm.removeItem(at: decisionURL)
        try store.decide(pending[0], allow: true)
        check(try store.poll(now: Date().timeIntervalSince1970).0.isEmpty, "A valid decision must hide its request")
        var decisionInfo = stat()
        check(lstat(decisionURL.path, &decisionInfo) == 0 && (decisionInfo.st_mode & 0o777) == 0o600,
              "Decisions must be owner-only")
        mustThrow("A duplicate decision must not replace the existing one") { try store.decide(pending[0], allow: false) }

        let second = request(String(repeating: "c", count: 32))
        try writeRequest(second)
        let original = try store.poll(now: Date().timeIntervalSince1970).0[0]
        try writeRequest(request(second.id, detail: "changed input"))
        mustThrow("An unseen change must not be approved") { try store.decide(original, allow: true) }
        let refreshed = try store.poll(now: Date().timeIntervalSince1970).0[0]
        try store.decide(refreshed, allow: false)
        let deniedData = try Data(contentsOf: root.appendingPathComponent("decisions/" + second.id + ".json"))
        let denied = try JSONSerialization.jsonObject(with: deniedData) as! [String: Any]
        check(denied["decision"] as? String == "deny" && denied["id"] as? String == second.id,
              "Deny must produce a correlated deny response")
        let expired = request(String(repeating: "d", count: 32), expires: now - 0.1)
        try writeRequest(expired)
        check(try store.poll(now: Date().timeIntervalSince1970).0.isEmpty, "An expired request must not appear")

        let notification = request(String(repeating: "e", count: 32), notice: true)
        try writeRequest(notification)
        let notice = try store.poll(now: Date().timeIntervalSince1970).0.first { $0.request.id == notification.id }!
        mustThrow("An alert must never approve a tool") { try store.decide(notice, allow: true) }
        try store.dismissNotice(notice)
        check(!fm.fileExists(atPath: root.appendingPathComponent("requests/" + notification.id + ".json").path),
              "Dismiss must remove the notification")
        check(!fm.fileExists(atPath: root.appendingPathComponent("decisions/" + notification.id + ".json").path),
              "Dismiss must never create a permission decision")

        let questionText = "Should I continue?"
        let questions = [UserQuestion(question: questionText, header: "Next step",
            options: [QuestionOption(label: "Yes", description: nil), QuestionOption(label: "No", description: nil)], multiSelect: false)]
        func questionRequest(_ id: String, detail: String = "{}", expiry: Double? = nil, values: [UserQuestion]? = nil) -> PermissionRequest {
            PermissionRequest(schemaVersion: 1, id: id, source: "claude-code", sourceLabel: "Claude Code",
                sessionId: "question-session", toolName: "AskUserQuestion", cwd: root.path, reason: "Answer a question",
                detailText: detail, isDemo: true, createdAt: now - 1, expiresAt: expiry ?? now + 120,
                canRespond: true, kind: "question", questions: values ?? questions)
        }
        let question = questionRequest(String(repeating: "f", count: 32))
        try writeRequest(question)
        let questionSnapshot = try store.poll(now: Date().timeIntervalSince1970).0.first { $0.request.id == question.id }!
        mustThrow("Questions must never be approved as tools") { try store.decide(questionSnapshot, allow: true) }
        mustThrow("Every question needs a matching answer") { try store.answer(questionSnapshot, answers: [:]) }
        mustThrow("Unrelated answer keys must be rejected") { try store.answer(questionSnapshot, answers: ["Unseen question": "Yes"]) }
        mustThrow("Empty answers must be rejected") { try store.answer(questionSnapshot, answers: [questionText: "  "]) }
        mustThrow("Oversized free text must be rejected") { try store.answer(questionSnapshot, answers: [questionText: String(repeating: "x", count: 2001)]) }
        let questionDecision = root.appendingPathComponent("decisions/" + question.id + ".json")
        try privateWrite(Data("{\"id\":\"\(question.id)\",\"decision\":\"allow\",\"decidedAt\":\(now)}".utf8), questionDecision)
        check(try store.poll(now: Date().timeIntervalSince1970).0.contains { $0.request.id == question.id },
              "A permission decision must not hide an unanswered question")
        try privateWrite(Data("{\"id\":\"\(question.id)\",\"decision\":\"answer\",\"answers\":{},\"decidedAt\":\(now)}".utf8), questionDecision)
        check(try store.poll(now: Date().timeIntervalSince1970).0.contains { $0.request.id == question.id },
              "Malformed answer decisions must not hide questions")
        try fm.removeItem(at: questionDecision)
        try writeRequest(questionRequest(question.id, detail: "changed question input"))
        mustThrow("An unseen question change must not receive an answer") { try store.answer(questionSnapshot, answers: [questionText: "Yes"]) }
        let freshQuestion = try store.poll(now: Date().timeIntervalSince1970).0.first { $0.request.id == question.id }!
        try store.answer(freshQuestion, answers: [questionText: "Yes"])
        let answerJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: questionDecision)) as! [String: Any]
        check(answerJSON["decision"] as? String == "answer" && (answerJSON["answers"] as? [String: String])?[questionText] == "Yes",
              "Question responses must preserve the exact question-to-answer mapping")
        check(!((try store.poll(now: Date().timeIntervalSince1970)).0.contains { $0.request.id == question.id }),
              "A complete answer must hide its question")
        let fallback = questionRequest(String(repeating: "1", count: 32))
        try writeRequest(fallback)
        let fallbackSnapshot = try store.poll(now: Date().timeIntervalSince1970).0.first { $0.request.id == fallback.id }!
        try store.answer(fallbackSnapshot, answers: nil)
        let fallbackJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("decisions/" + fallback.id + ".json"))) as! [String: Any]
        check(fallbackJSON["decision"] as? String == "defer" && fallbackJSON["answers"] == nil,
              "Answer in Claude must emit defer without inventing answers")
        let expiredQuestion = questionRequest(String(repeating: "2", count: 32), expiry: now - 0.1)
        try writeRequest(expiredQuestion)
        mustThrow("Expired questions must not be answered") {
            try store.answer(RequestSnapshot(request: expiredQuestion, bytes: encoder.encode(expiredQuestion)), answers: [questionText: "Yes"])
        }
        let duplicateQuestions = questionRequest(String(repeating: "3", count: 32), values: questions + questions)
        check(!duplicateQuestions.isValid(now: now), "Repeated question keys must be rejected")

        let publicRoot = root.appendingPathComponent("public-folder")
        try fm.createDirectory(at: publicRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        mustThrow("An existing public folder must not be changed or used") { _ = try RuntimeStore(root: publicRoot) }
        let attributes = try fm.attributesOfItem(atPath: publicRoot.path)
        check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o755, "Public folder permissions must remain unchanged")
        store.stopHeartbeat()
        print("Native mailbox checks passed: \(checks)")
    }
}
