import Foundation

enum HelperInstaller {
    private static let appleScript = """
    on run argv
        do shell script "/bin/sh " & quoted form of (item 1 of argv) & " " & quoted form of (item 2 of argv) & " " & (item 3 of argv) with administrator privileges
    end run
    """

    /// Shows the macOS admin password prompt. Returns an error message, or nil on success.
    static func run(script: String) async -> String? {
        guard let path = Bundle.main.path(forResource: script, ofType: "sh"),
              let daemon = Bundle.main.path(forAuxiliaryExecutable: "coolantd") else {
            return "This copy of the app is missing its helper files."
        }
        return await Task.detached {
            let process = Process()
            let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", appleScript, path, daemon, String(getuid())]
            process.standardError = errors
            do { try process.run() } catch { return error.localizedDescription }
            process.waitUntilExit()
            guard process.terminationStatus != 0 else { return nil }
            let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return text.isEmpty ? "The installer failed." : text
        }.value
    }
}

enum LaunchAtLogin {
    private static let label = "com.arterialist.coolant"

    private static var plist: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static func set(_ enabled: Bool) {
        guard enabled else {
            try? FileManager.default.removeItem(at: plist)
            return
        }
        guard let executable = Bundle.main.executablePath else { return }
        let contents: [String: Any] = ["Label": label, "ProgramArguments": [executable], "RunAtLoad": true, "ProcessType": "Interactive"]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: contents, format: .xml, options: 0) else { return }
        try? FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: plist, options: .atomic)
    }
}
