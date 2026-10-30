import Foundation
import Network
import Darwin

/// Authenticated, loopback-only transport for Claude's JSON approval events.
/// The receiver never logs request headers, bodies, or its authentication token.
struct ApprovalReceiverConfig: Decodable {
    let version: Int
    let host: String
    let port: Int
    let token: String

    static func load(path: String) throws -> Self {
        let bytes = try ApprovalReceiverFiles.readPrivate(path: path, limit: 4_096)
        let config = try JSONDecoder().decode(Self.self, from: bytes)
        guard config.version == 1, config.host == "127.0.0.1",
              (49_152...65_535).contains(config.port), config.token.utf8.count == 64,
              config.token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ApprovalReceiverError.invalidConfiguration
        }
        return config
    }
}

enum ApprovalReceiverError: Error {
    case invalidConfiguration
    case unsafeFile
    case unavailable
}

/// openat keeps every parent lookup anchored to a directory already checked.
/// O_NONBLOCK prevents a substituted FIFO from blocking before fstat rejects it.
enum ApprovalReceiverFiles {
    static func openDirectory(path: String) throws -> Int32 {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw ApprovalReceiverError.unsafeFile }
        let pieces = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !pieces.contains("."), !pieces.contains("..") else { throw ApprovalReceiverError.unsafeFile }
        var directory = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard directory >= 0 else { throw ApprovalReceiverError.unsafeFile }
        do {
            for piece in pieces {
                let next = String(piece).withCString {
                    openat(directory, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                }
                guard next >= 0 else { throw ApprovalReceiverError.unsafeFile }
                var info = stat()
                guard fstat(next, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
                      info.st_uid == 0 || info.st_uid == getuid() else {
                    close(next); throw ApprovalReceiverError.unsafeFile
                }
                close(directory); directory = next
            }
            return directory
        } catch { close(directory); throw error }
    }

    static func privateDirectory(path: String) throws -> Int32 {
        let fd = try openDirectory(path: path)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), (info.st_mode & 0o777) == 0o700 else {
            close(fd); throw ApprovalReceiverError.unsafeFile
        }
        return fd
    }

    static func readPrivate(path: String, limit: Int) throws -> Data {
        let url = URL(fileURLWithPath: path)
        guard path.hasPrefix("/"), !path.utf8.contains(0), !["", ".", ".."].contains(url.lastPathComponent) else {
            throw ApprovalReceiverError.unsafeFile
        }
        let parent = try privateDirectory(path: url.deletingLastPathComponent().path)
        defer { close(parent) }
        let fd = url.lastPathComponent.withCString { openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard fd >= 0 else { throw ApprovalReceiverError.unsafeFile }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), (info.st_mode & 0o777) == 0o600,
              info.st_size >= 0, info.st_size <= limit else { throw ApprovalReceiverError.unsafeFile }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(8_192, limit + 1))
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if count < 0 { if errno == EINTR { continue }; throw ApprovalReceiverError.unsafeFile }
            if count == 0 { return data }
            guard data.count + count <= limit else { throw ApprovalReceiverError.unsafeFile }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    static func executable(path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw ApprovalReceiverError.unsafeFile }
        // Homebrew's legitimate opt/bin links are resolved before validating the executable.
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ApprovalReceiverError.unsafeFile }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == 0 || info.st_uid == getuid(), (info.st_mode & 0o111) != 0,
              (info.st_mode & 0o022) == 0, access(url.path, X_OK) == 0 else {
            throw ApprovalReceiverError.unsafeFile
        }
        return url
    }

    static func writeHealth(directory: Int32, port: Int?, status: String) {
        var values: [String: Any] = ["status": status, "updatedAt": Date().timeIntervalSince1970]
        if let port { values["port"] = port }
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) else { return }
        let temporary = ".telemetry-health-" + UUID().uuidString
        let fd = temporary.withCString { openat(directory, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) }
        guard fd >= 0 else { return }
        defer { close(fd); temporary.withCString { _ = unlinkat(directory, $0, 0) } }
        guard fchmod(fd, 0o600) == 0 else { return }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
        guard written == data.count else { return }
        temporary.withCString { from in
            "telemetry-health.json".withCString { to in _ = renameat(directory, from, directory, to) }
        }
    }
}

/// A single HTTP request per TCP connection, with no chunking or pipelining.
struct ApprovalHTTPParser {
    static let headerLimit = 16 * 1_024
    static let bodyLimit = 512 * 1_024
    enum Result { case incomplete, body(Data), reject(Int) }
    private let expectedToken: [UInt8]
    private var buffer = Data()
    private var bodyOffset: Int?
    private var bodyLength: Int?
    private var finished = false

    init(token: String) { expectedToken = Array(token.utf8) }

    mutating func feed(_ bytes: Data) -> Result {
        guard !finished else { return .reject(400) }
        guard buffer.count + bytes.count <= Self.headerLimit + Self.bodyLimit else { return reject(413) }
        buffer.append(bytes)
        if bodyOffset == nil {
            guard let delimiter = buffer.range(of: Data([13, 10, 13, 10])) else {
                return buffer.count >= Self.headerLimit ? reject(413) : .incomplete
            }
            let offset = delimiter.upperBound
            guard offset <= Self.headerLimit else { return reject(413) }
            let headerBytes = buffer.prefix(delimiter.lowerBound)
            guard headerBytes.allSatisfy({ $0 == 9 || $0 == 10 || $0 == 13 || (32...126).contains($0) }),
                  let header = String(data: headerBytes, encoding: .ascii) else { return reject(400) }
            let lines = header.components(separatedBy: "\r\n")
            guard lines.first == "POST /v1/logs HTTP/1.1" else { return reject(400) }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { return reject(400) }
                let name = String(line[..<colon]).lowercased()
                let allowed = "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyz"
                guard name.utf8.allSatisfy({ allowed.utf8.contains($0) }), headers[name] == nil else { return reject(400) }
                let value = String(line[line.index(after: colon)...])
                guard value.utf8.allSatisfy({ $0 == 9 || (32...126).contains($0) }) else { return reject(400) }
                headers[name] = value.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            }
            guard headers["transfer-encoding"] == nil, headers["content-encoding"] == nil,
                  headers["expect"] == nil, let lengthText = headers["content-length"],
                  !lengthText.isEmpty, lengthText.utf8.allSatisfy({ (48...57).contains($0) }) else { return reject(400) }
            guard let length = Int(lengthText), length <= Self.bodyLimit else { return reject(413) }
            let contentType = headers["content-type"]?.lowercased()
            guard contentType == "application/json" || contentType == "application/json; charset=utf-8" else { return reject(400) }
            guard authenticates(headers["x-pip-token"] ?? "") else { return reject(401) }
            bodyOffset = offset; bodyLength = length
        }
        guard let offset = bodyOffset, let length = bodyLength else { return reject(400) }
        guard buffer.count <= offset + length else { return reject(400) }
        guard buffer.count == offset + length else { return .incomplete }
        finished = true
        return .body(Data(buffer[offset...]))
    }

    private func authenticates(_ value: String) -> Bool {
        let supplied = Array(value.utf8)
        guard supplied.count == expectedToken.count else { return false }
        var difference: UInt8 = 0
        for index in expectedToken.indices { difference |= supplied[index] ^ expectedToken[index] }
        return difference == 0
    }

    private mutating func reject(_ code: Int) -> Result { finished = true; return .reject(code) }
}

/// An explicitly bound IPv4 loopback socket avoids NWListener endpoint-binding
/// differences across macOS versions. Never bind a wildcard interface.
enum ApprovalReceiverSocket {
    static func makeListener(port: UInt16) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ApprovalReceiverError.unavailable }
        do {
            var yes: Int32 = 1
            guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                throw ApprovalReceiverError.unavailable
            }
            try configure(fd)
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, Darwin.listen(fd, 8) == 0 else { throw ApprovalReceiverError.unavailable }
            return fd
        } catch { Darwin.close(fd); throw error }
    }

    static func configure(_ fd: Int32) throws {
        var yes: Int32 = 1
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw ApprovalReceiverError.unavailable
        }
    }
}

final class ApprovalReceiver {
    private let config: ApprovalReceiverConfig
    private let runtime: String
    private let python: URL
    private let bridgeArguments: [String]
    private let queue = DispatchQueue(label: "Pip.approval-receiver", qos: .utility)
    private let writerQueue = DispatchQueue(label: "Pip.approval-receiver.stdin", qos: .utility, attributes: .concurrent)
    private let healthDirectory: Int32
    private var listener: DispatchSourceRead?
    private var requests: [UUID: ApprovalConnection] = [:]
    private var stopping = false

    init(configPath: String, pythonPath: String, bridgePath: String, runtime: String) throws {
        config = try ApprovalReceiverConfig.load(path: configPath)
        python = try ApprovalReceiverFiles.executable(path: pythonPath)
        _ = try ApprovalReceiverFiles.readPrivate(path: bridgePath, limit: 2 * 1_024 * 1_024)
        bridgeArguments = [bridgePath, "telemetry"]; self.runtime = runtime
        healthDirectory = try ApprovalReceiverFiles.privateDirectory(path: runtime)
    }

    init(configPath: String, helperPath: String, runtime: String) throws {
        config = try ApprovalReceiverConfig.load(path: configPath)
        python = try ApprovalReceiverFiles.executable(path: helperPath)
        bridgeArguments = ["telemetry"]; self.runtime = runtime
        healthDirectory = try ApprovalReceiverFiles.privateDirectory(path: runtime)
    }

    deinit { close(healthDirectory) }

    static func configured(runtime: String, bundle: Bundle = .main) -> ApprovalReceiver? {
        if let helper = PipRuntime.helper(in: bundle) {
            let config = PipRuntime.support.appendingPathComponent(".telemetry.json").path
            guard FileManager.default.fileExists(atPath: config) else { return nil }
            return try? ApprovalReceiver(configPath: config, helperPath: helper.path, runtime: runtime)
        }
        guard let config = bundle.object(forInfoDictionaryKey: "CompanionTelemetryConfigPath") as? String else { return nil }
        do {
            guard let python = bundle.object(forInfoDictionaryKey: "CompanionPythonPath") as? String,
                  let bridge = bundle.object(forInfoDictionaryKey: "CompanionHookBridgePath") as? String else {
                throw ApprovalReceiverError.invalidConfiguration
            }
            return try ApprovalReceiver(configPath: config, pythonPath: python, bridgePath: bridge, runtime: runtime)
        } catch {
            if let fd = try? ApprovalReceiverFiles.privateDirectory(path: runtime) {
                ApprovalReceiverFiles.writeHealth(directory: fd, port: nil, status: "invalid-configuration")
                close(fd)
            }
            return nil
        }
    }

    func start() {
        queue.async { [self] in
            guard listener == nil, !stopping else { return }
            do {
                let fd = try ApprovalReceiverSocket.makeListener(port: UInt16(config.port))
                let listener = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                listener.setCancelHandler { Darwin.close(fd) }
                listener.setEventHandler { [weak self] in self?.accept(listener: fd) }
                self.listener = listener
                listener.resume()
                health("listening")
            } catch { health("listener-failed") }
        }
    }

    func stop() {
        queue.sync {
            guard !stopping else { return }
            stopping = true; listener?.cancel(); listener = nil
            let active = Array(requests.values)
            for request in active { request.cancel() }
            requests.removeAll(); health("stopped")
        }
    }

    private func health(_ state: String) {
        ApprovalReceiverFiles.writeHealth(directory: healthDirectory, port: config.port, status: state)
    }

    private func accept(listener fd: Int32) {
        guard !stopping else { return }
        for _ in 0..<16 {
            var address = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(fd, $0, &length) }
            }
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            guard requests.count < 8, length == MemoryLayout<sockaddr_in>.size,
                  address.sin_family == sa_family_t(AF_INET), address.sin_addr.s_addr == inet_addr("127.0.0.1") else {
                Darwin.close(client); continue
            }
            do { try ApprovalReceiverSocket.configure(client) }
            catch { Darwin.close(client); continue }
            let id = UUID()
            let request = ApprovalConnection(socket: client, token: config.token, queue: queue,
                                         writerQueue: writerQueue, python: python, bridgeArguments: bridgeArguments, runtime: runtime) { [weak self] in
                self?.requests.removeValue(forKey: id)
            }
            requests[id] = request; request.start()
        }
    }

    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint, case .ipv4(let address) = host else { return false }
        return address == .loopback
    }
}

private final class ApprovalConnection {
    private let socket: Int32
    private var reader: DispatchSourceRead?
    private var readerSuspended = false
    private let queue: DispatchQueue
    private let writerQueue: DispatchQueue
    private let python: URL
    private let bridgeArguments: [String]
    private let runtime: String
    private let onClose: () -> Void
    private var parser: ApprovalHTTPParser
    private var deadline: DispatchWorkItem?
    private var process: Process?
    private var input: FileHandle?
    private var responding = false
    private var closed = false

    init(socket: Int32, token: String, queue: DispatchQueue, writerQueue: DispatchQueue,
         python: URL, bridgeArguments: [String], runtime: String, onClose: @escaping () -> Void) {
        self.socket = socket; self.queue = queue; self.writerQueue = writerQueue
        self.python = python; self.bridgeArguments = bridgeArguments; self.runtime = runtime; self.onClose = onClose
        parser = ApprovalHTTPParser(token: token)
    }

    func start() {
        let deadline = DispatchWorkItem { [weak self] in self?.respond(503) }
        self.deadline = deadline; queue.asyncAfter(deadline: .now() + 5, execute: deadline)
        let reader = DispatchSource.makeReadSource(fileDescriptor: socket, queue: queue)
        let fd = socket
        reader.setCancelHandler { Darwin.close(fd) }
        reader.setEventHandler { [weak self] in self?.receive() }
        self.reader = reader; reader.resume()
    }

    private func receive() {
        guard !responding, !closed else { return }
        var buffer = [UInt8](repeating: 0, count: 8_192)
        for _ in 0..<16 {
            let count = buffer.withUnsafeMutableBytes { Darwin.recv(socket, $0.baseAddress!, $0.count, 0) }
            if count > 0 {
                switch parser.feed(Data(buffer.prefix(count))) {
                case .body(let body):
                    reader?.suspend(); readerSuspended = true
                    handle(body); return
                case .reject(let status): respond(status); return
                case .incomplete: break
                }
            } else if count == 0 {
                respond(400); return
            } else {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { close() }
                return
            }
        }
    }

    private func handle(_ body: Data) {
        let child = Process(), pipe = Pipe()
        child.executableURL = python; child.arguments = bridgeArguments + ["--runtime", runtime]
        child.standardInput = pipe
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        child.terminationHandler = { [weak self] terminated in
            guard let self else { return }
            self.queue.async { [weak self] in self?.respond(terminated.terminationStatus == 0 ? 200 : 400) }
        }
        process = child; input = pipe.fileHandleForWriting
        // Suppress SIGPIPE only on this pipe when a malformed batch exits early.
        guard fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { respond(503); return }
        do { try child.run() } catch { respond(503); return }
        try? pipe.fileHandleForReading.close()
        let writeHandle = pipe.fileHandleForWriting
        writerQueue.async {
            do { try writeHandle.write(contentsOf: body) } catch { }
            try? writeHandle.close()
        }
    }

    private func respond(_ status: Int) {
        guard !responding, !closed else { return }
        responding = true
        if status != 200 { terminateChild() }
        try? input?.close(); input = nil
        let phrase = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 413: "Payload Too Large", 503: "Service Unavailable"][status] ?? "Bad Request"
        let response = "HTTP/1.1 \(status) \(phrase)\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
        let bytes = Array(response.utf8)
        bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.send(socket, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                if count > 0 { offset += count }
                else if count < 0 && errno == EINTR { continue }
                else { break }
            }
        }
        close()
    }

    func cancel() { terminateChild(immediately: true); close() }

    private func terminateChild(immediately: Bool = false) {
        guard let process, process.isRunning else { return }
        process.terminate()
        if immediately {
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        } else {
            queue.asyncAfter(deadline: .now() + 0.2) {
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            }
        }
    }

    private func close() {
        guard !closed else { return }
        closed = true; deadline?.cancel(); deadline = nil
        terminateChild()
        try? input?.close(); input = nil
        if readerSuspended { reader?.resume(); readerSuspended = false }
        reader?.cancel(); reader = nil
        onClose()
    }
}
