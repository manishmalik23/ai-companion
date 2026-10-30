import Foundation
import Darwin

@main struct ApprovalReceiverChecks {
    static func main() throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message); checks += 1
        }
        let temporary = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("pip-receiver-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let probe = try ApprovalReceiverSocket.makeListener(port: 0)
        var address = sockaddr_in(), size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let gotAddress = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(probe, $0, &size) }
        }
        check(gotAddress == 0 && address.sin_addr.s_addr == inet_addr("127.0.0.1"), "Must bind explicitly to IPv4 loopback")
        let port = UInt16(bigEndian: address.sin_port)
        Darwin.close(probe)
        let runtime = temporary.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let config = temporary.appendingPathComponent("config.json"), bridge = temporary.appendingPathComponent("bridge.py")
        let token = String(repeating: "a", count: 64)
        try JSONSerialization.data(withJSONObject: ["version": 1, "host": "127.0.0.1", "port": Int(port), "token": token]).write(to: config)
        try Data("import sys\nsys.stdin.buffer.read()\n".utf8).write(to: bridge)
        for file in [config, bridge] { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        let bundled = CommandLine.arguments[1] == "--helper"
        let receiver = try bundled ? ApprovalReceiver(configPath: config.path, helperPath: CommandLine.arguments[2], runtime: runtime.path) :
            ApprovalReceiver(configPath: config.path, pythonPath: CommandLine.arguments[1], bridgePath: bridge.path, runtime: runtime.path)
        receiver.start()
        defer { receiver.stop() }
        func status() -> String? {
            guard let bytes = try? Data(contentsOf: runtime.appendingPathComponent("telemetry-health.json")),
                  let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return nil }
            return value["status"] as? String
        }
        let deadline = Date().addingTimeInterval(3)
        while status() != "listening" && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        check(status() == "listening", "Real receiver must start")
        func request(_ raw: String) throws -> String {
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw ApprovalReceiverError.unavailable }
            defer { Darwin.close(fd) }
            var timeout = timeval(tv_sec: 8, tv_usec: 0)
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            var target = sockaddr_in()
            target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); target.sin_family = sa_family_t(AF_INET)
            target.sin_port = port.bigEndian; target.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &target) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard connected == 0 else { throw ApprovalReceiverError.unavailable }
            let bytes = Array(raw.utf8)
            let sent = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!, $0.count, 0) }
            guard sent == bytes.count else { throw ApprovalReceiverError.unavailable }
            var output = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress!, $0.count, 0) }
                if count <= 0 { break }
                output.append(contentsOf: buffer.prefix(count))
            }
            return String(decoding: output, as: UTF8.self)
        }
        let headers = "POST /v1/logs HTTP/1.1\r\nContent-Type: application/json\r\nX-Pip-Token: \(token)\r\n"
        let body = bundled ? "{\"resourceLogs\":[]}" : "{}"
        let valid = try request(headers + "Content-Length: \(body.utf8.count)\r\n\r\n" + body)
        check(valid.hasPrefix("HTTP/1.1 200 "), "Authenticated request must succeed")
        let unauthenticated = try request("POST /v1/logs HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}")
        check(unauthenticated.hasPrefix("HTTP/1.1 401 "), "Unauthenticated request must fail")
        let duplicate = try request(headers + "Content-Length: 2\r\nContent-Length: 2\r\n\r\n{}")
        check(duplicate.hasPrefix("HTTP/1.1 400 "), "Duplicate framing must fail")
        let chunked = try request(headers + "Transfer-Encoding: chunked\r\nContent-Length: 2\r\n\r\n{}")
        check(chunked.hasPrefix("HTTP/1.1 400 "), "Chunked framing must fail")
        let oversized = try request(headers + "Content-Length: 999999\r\n\r\n")
        check(oversized.hasPrefix("HTTP/1.1 413 "), "Oversized body must fail")
        let partial = try request(headers + "Content-Length: 2\r\n\r\n{")
        check(partial.hasPrefix("HTTP/1.1 503 "), "Partial body must hit the bounded request deadline")
        print("Passed \(checks) real loopback receiver checks. Disposable runtime and stub bridge only.")
    }
}
