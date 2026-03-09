import Foundation
import os.log

private let logger = Logger(subsystem: "com.clover4282.hanguljaso", category: "LaunchAgent")

/// Manages a LaunchAgent plist for auto-start and KeepAlive (auto-restart on crash).
enum LaunchAgentService {
    private static let label = "com.clover4282.hanguljaso"
    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// Install the LaunchAgent plist and load it.
    static func install() {
        let appPath = "/Applications/HangulJaso.app"

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["\(appPath)/Contents/MacOS/HangulJaso"],
            "KeepAlive": ["SuccessfulExit": false],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
        ]

        do {
            let dir = plistURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)

            // Load the agent
            let result = Process()
            result.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            result.arguments = ["load", "-w", plistURL.path]
            try result.run()
            result.waitUntilExit()

            logger.notice("LaunchAgent installed: \(plistURL.path, privacy: .public)")
        } catch {
            logger.error("LaunchAgent install failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Unload and remove the LaunchAgent plist.
    static func uninstall() {
        // Unload first
        if FileManager.default.fileExists(atPath: plistURL.path) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["unload", "-w", plistURL.path]
            try? process.run()
            process.waitUntilExit()

            try? FileManager.default.removeItem(at: plistURL)
            logger.notice("LaunchAgent uninstalled")
        }
    }

    /// Check if the LaunchAgent is currently installed.
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }
}
