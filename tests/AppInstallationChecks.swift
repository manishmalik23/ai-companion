import AppKit

@main struct AppInstallationChecks {
    static func main() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp/pip-install-check-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        var checks = 0
        func check(_ value: Bool, _ description: String) {
            guard value else { fatalError(description) }; checks += 1
        }
        func fixture(_ name: String, version: String, id: String = AppInstallFiles.identifier) throws -> URL {
            let app = root.appendingPathComponent(name)
            let contents = app.appendingPathComponent("Contents")
            try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id, "CFBundleShortVersionString": version],
                                               format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
            try Data(version.utf8).write(to: contents.appendingPathComponent("MacOS/Pip"))
            return app
        }
        let source = try fixture("Download/Pip.app", version: "new")
        let target = root.appendingPathComponent("Applications/Pip.app")
        let state = root.appendingPathComponent("chat-history.json")
        try Data("keep my data".utf8).write(to: state)
        var validated = false
        _ = try AppInstallFiles.install(source: source, destination: target, replace: false, validate: { copy in
            check(!fm.fileExists(atPath: target.path), "Validate before publishing")
            check(try AppInstallFiles.info(copy)["CFBundleShortVersionString"] as? String == "new", "Validate the new copy")
            validated = true
        })
        check(validated && fm.fileExists(atPath: source.path), "The source app stays on the disk image")
        check(try AppInstallFiles.info(target)["CFBundleShortVersionString"] as? String == "new", "Publish installed app")
        check(try String(contentsOf: state, encoding: .utf8) == "keep my data", "Unrelated user data stays intact")
        do {
            _ = try AppInstallFiles.install(source: source, destination: target, replace: false, validate: { _ in })
            fatalError("Replacement must be confirmed")
        } catch { checks += 1 }
        var trashed = false
        do {
            _ = try AppInstallFiles.install(source: source, destination: target, replace: true,
                                           validate: { _ in throw AppInstallError.message("Invalid signature fixture") },
                                           recoverableTrash: { _ in trashed = true; return root })
            fatalError("An invalid signature must stop installation")
        } catch { checks += 1 }
        check(!trashed && fm.fileExists(atPath: target.path), "Failed validation preserves the old app")
        let foreign = try fixture("Foreign/Pip.app", version: "other", id: "dev.other.app")
        do {
            _ = try AppInstallFiles.install(source: source, destination: foreign, replace: true, validate: { _ in })
            fatalError("An unrelated app must not be replaced")
        } catch { checks += 1 }
        check(try String(contentsOf: foreign.appendingPathComponent("Contents/MacOS/Pip"), encoding: .utf8) == "other", "Foreign app remains intact")
        let trash = root.appendingPathComponent("previous-in-trash.app")
        _ = try AppInstallFiles.install(source: source, destination: target, replace: true, validate: { _ in },
                                       recoverableTrash: { old in try fm.moveItem(at: old, to: trash); return trash })
        check(fm.fileExists(atPath: target.path) && fm.fileExists(atPath: trash.path), "Previous app is recoverable")
        let rollback = root.appendingPathComponent("rollback.app")
        do {
            _ = try AppInstallFiles.install(source: source, destination: target, replace: true, validate: { _ in }, recoverableTrash: { old in
                try fm.moveItem(at: old, to: rollback)
                let stages = try fm.contentsOfDirectory(at: target.deletingLastPathComponent(), includingPropertiesForKeys: nil)
                for stage in stages where stage.lastPathComponent.hasPrefix(".Pip-install-") {
                    try fm.removeItem(at: stage.appendingPathComponent("Pip.app"))
                }
                return rollback
            })
            fatalError("A failed publication must report failure")
        } catch { checks += 1 }
        check(fm.fileExists(atPath: target.path) && !fm.fileExists(atPath: rollback.path), "Restore old app after failed publication")
        let stages = try fm.contentsOfDirectory(at: target.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        check(!stages.contains { $0.lastPathComponent.hasPrefix(".Pip-install-") }, "Clean up only private staging folders")
        let link = root.appendingPathComponent("LinkedApplications")
        try fm.createSymbolicLink(at: link, withDestinationURL: target.deletingLastPathComponent())
        do {
            _ = try AppInstallFiles.install(source: source, destination: link.appendingPathComponent("Pip.app"), replace: true, validate: { _ in })
            fatalError("A symbolic installation target must not be followed")
        } catch { checks += 1 }
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--real-app" {
            let app = URL(fileURLWithPath: CommandLine.arguments[2])
            let copied = root.appendingPathComponent("FreshApplications/Pip.app")
            _ = try AppInstallFiles.install(source: app, destination: copied, replace: false)
            let bundle = Bundle(url: copied)!
            guard let helper = PipRuntime.helper(in: bundle) else { fatalError("The copied bundled helper is missing") }
            let process = Process(); process.executableURL = helper; process.arguments = ["--version"]
            let pipe = Pipe(); process.standardOutput = pipe
            try process.run(); let output = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            check(process.terminationStatus == 0, "Copied app's frozen helper starts")
            let value = try JSONSerialization.jsonObject(with: output) as! [String: Any]
            check(value["bundled"] as? Bool == true, "Copied app uses its bundled Python")
            print("Real app copy and signature verified in a disposable Applications folder.")
        }
        print("Passed \(checks) app installation checks. No real app, settings, or Trash modified.")
    }
}
