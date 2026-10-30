import AppKit

enum AppInstallError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// Install only the app bundle. Connections, chats and character data stay outside it.
enum AppInstallFiles {
    static let identifier = "dev.local.agent-companion"

    static func info(_ app: URL) throws -> [String: Any] {
        let file = app.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: file)
        guard data.count < 1_048_576,
              let value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              value["CFBundleIdentifier"] as? String == identifier else {
            throw AppInstallError.message("Another app occupies this location. Pip will not replace it.")
        }
        return value
    }

    static func destination(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            systemApplications: URL = URL(fileURLWithPath: "/Applications")) -> URL {
        let folder = FileManager.default.isWritableFile(atPath: systemApplications.path) ? systemApplications :
            home.appendingPathComponent("Applications")
        return folder.appendingPathComponent("Pip.app")
    }

    static func verifySignature(_ app: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", "--strict", app.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: deadline)
        process.waitUntilExit(); deadline.cancel()
        guard process.terminationStatus == 0 else {
            throw AppInstallError.message("Pip's copied files did not pass verification. Download Pip again.")
        }
    }

    static func trash(_ app: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: app, resultingItemURL: &result)
        guard let result else { throw AppInstallError.message("The previous Pip is in Trash; restore it there if needed.") }
        return result as URL
    }

    static func install(source: URL, destination: URL, replace: Bool,
                        validate: (URL) throws -> Void = verifySignature,
                        recoverableTrash: (URL) throws -> URL = trash) throws -> URL {
        let fm = FileManager.default, parent = destination.deletingLastPathComponent()
        guard source.standardizedFileURL != destination.standardizedFileURL else { return destination }
        _ = try info(source)
        let existing = fm.fileExists(atPath: destination.path)
        for location in [source, parent, destination] where fm.fileExists(atPath: location.path) {
            guard try location.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw AppInstallError.message("Pip will not install through a symbolic link. Choose a regular Applications folder.")
            }
        }
        if existing {
            _ = try info(destination)
            guard replace else { throw AppInstallError.message("Pip is already installed. Confirm replacement first.") }
        }
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let stage = parent.appendingPathComponent(".Pip-install-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        let copy = stage.appendingPathComponent("Pip.app")
        try fm.copyItem(at: source, to: copy)
        _ = try info(copy)
        try validate(copy)
        var previous: URL?
        if existing { previous = try recoverableTrash(destination) }
        do {
            // The stage shares the destination's volume, so publication is a rename.
            try fm.moveItem(at: copy, to: destination)
        } catch {
            if let previous, !fm.fileExists(atPath: destination.path) {
                do { try fm.moveItem(at: previous, to: destination) }
                catch { throw AppInstallError.message("Installation stopped. Restore your previous Pip from Trash.") }
            }
            throw error
        }
        return destination
    }
}

enum AppInstallation {
    private static func prompt(destination: URL) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Move Pip to Applications?"
        let folder = (destination.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        alert.informativeText = "Pip can copy itself into " + folder + " and reopen there. Then you can connect your coding agents. You can also drag Pip onto Applications in the installer window."
        alert.addButton(withTitle: "Move to Applications"); alert.addButton(withTitle: "Quit")
        return alert
    }

    /// A packaged app outside Applications offers installation before starting any runtime.
    static func handleLaunchIfNeeded() -> Bool {
        guard PipRuntime.helper() != nil, !PipRuntime.installed() else { return false }
        NSApp.activate(ignoringOtherApps: true)
        let source = Bundle.main.bundleURL, destination = AppInstallFiles.destination()
        guard prompt(destination: destination).runModal() == .alertFirstButtonReturn else {
            NSApp.terminate(nil); return true
        }
        do {
            let existing = FileManager.default.fileExists(atPath: destination.path)
            if existing {
                let current = try AppInstallFiles.info(destination)["CFBundleShortVersionString"] as? String ?? ""
                let replacement = NSAlert(); replacement.messageText = "Replace the installed Pip?"
                replacement.informativeText = "Pip " + current + " is already in Applications. The previous app will move to Trash. Your chats, connections and custom character stay in place."
                replacement.addButton(withTitle: "Replace"); replacement.addButton(withTitle: "Cancel")
                guard replacement.runModal() == .alertFirstButtonReturn else { NSApp.terminate(nil); return true }
            }
            let otherInstance = NSWorkspace.shared.runningApplications.contains {
                $0.bundleIdentifier == AppInstallFiles.identifier && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
            }
            guard !otherInstance else {
                throw AppInstallError.message("Quit the other Pip app after its current approvals finish, then reopen this installer.")
            }
            let installed = try AppInstallFiles.install(source: source, destination: destination, replace: existing)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.arguments = ["--agent-connections"]
            NSWorkspace.shared.openApplication(at: installed, configuration: configuration) { _, error in
                DispatchQueue.main.async {
                    if error != nil { showError("Pip is installed. Open it from Applications to continue.") }
                    NSApp.terminate(nil)
                }
            }
        } catch {
            showError(error.localizedDescription); NSApp.terminate(nil)
        }
        return true
    }

    private static func showError(_ text: String) {
        let alert = NSAlert(); alert.messageText = "Pip could not finish opening"
        alert.informativeText = text; alert.addButton(withTitle: "OK"); alert.runModal()
    }

}
