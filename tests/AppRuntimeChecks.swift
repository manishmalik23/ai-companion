import Foundation
import Darwin

@main struct AppRuntimeChecks {
    static func main() throws {
        let root = URL(fileURLWithPath: "/private/tmp/pip-runtime-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Pip.app")
        let contents = app.appendingPathComponent("Contents")
        let helper = contents.appendingPathComponent("Helpers/PipRuntime.app/Contents/MacOS/PipHelper")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "dev.pip.fixture", "CFBundleExecutable": "Pip"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        func check(_ condition: Bool, _ label: String) {
            if !condition {
                FileHandle.standardError.write(Data(("Runtime resolution failed: " + label + "\n").utf8))
                exit(1)
            }
        }
        guard let bundle = Bundle(url: app) else { throw NSError(domain: "Missing fixture bundle", code: 1) }
        let runtime = root.appendingPathComponent("runtime")
        check(PipRuntime.helper(in: bundle) == nil, "missing helper")
        check(PipRuntime.chat(runtime: runtime, bundle: bundle) == nil, "missing chat")
        try Data("fixture".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let expected = helper.resolvingSymlinksInPath().path
        check(PipRuntime.helper(in: bundle)?.path == expected, "bundle-relative helper")
        let command = PipRuntime.chat(runtime: runtime, bundle: bundle)!
        check(command.executable.path == expected && command.arguments == ["chat"], "bundled chat command")
        check(!PipRuntime.installed(bundle: bundle), "staging is not Applications")
        check(PipRuntime.support.path.hasSuffix("/Library/Application Support/AgentCompanion"), "private user support path")
        print("Passed 6 bundled runtime resolution checks; no external Python fallback for a packaged app.")
    }
}
