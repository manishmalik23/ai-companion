import Foundation

/// Bundle-relative executables and user settings; a release bundle is never rewritten.
enum PipRuntime {
    struct Command {
        let executable: URL
        let arguments: [String]
    }

    static var support: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AgentCompanion")
    }

    static func helper(in bundle: Bundle = .main) -> URL? {
        let url = bundle.bundleURL.appendingPathComponent("Contents/Helpers/PipRuntime.app/Contents/MacOS/PipHelper").resolvingSymlinksInPath()
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static func infoPath(_ name: String, bundle: Bundle = .main) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: name) as? String, value.hasPrefix("/") else { return nil }
        return value
    }

    static func chat(runtime: URL, bundle: Bundle = .main) -> Command? {
        if let helper = helper(in: bundle) { return Command(executable: helper, arguments: ["chat"]) }
        let bridge = infoPath("CompanionBridgePath", bundle: bundle) ?? runtime.deletingLastPathComponent().appendingPathComponent("chat_bridge.py").path
        guard FileManager.default.fileExists(atPath: bridge) else { return nil }
        return Command(executable: URL(fileURLWithPath: infoPath("CompanionPythonPath", bundle: bundle) ?? "/usr/bin/python3"),
                       arguments: [bridge])
    }

    static func installed(bundle: Bundle = .main) -> Bool {
        let parent = bundle.bundleURL.deletingLastPathComponent().standardizedFileURL.path
        return parent == "/Applications" || parent == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
    }
}
