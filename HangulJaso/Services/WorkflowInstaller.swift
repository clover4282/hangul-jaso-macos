import Foundation

final class WorkflowInstaller {
    private let servicesDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Services")
    }()

    private let workflowNames = [
        "한글 파일명 NFC 변환",
        "한글 파일명 상태 확인"
    ]

    var installedWorkflows: [String] {
        workflowNames.filter { isInstalled(name: $0) }
    }

    func isInstalled(name: String) -> Bool {
        let dest = servicesDir.appendingPathComponent("\(name).workflow")
        return FileManager.default.fileExists(atPath: dest.path)
    }

    func installAll() -> (installed: [String], failed: [String]) {
        var installed: [String] = []
        var failed: [String] = []

        try? FileManager.default.createDirectory(at: servicesDir, withIntermediateDirectories: true)

        for name in workflowNames {
            if install(name: name) {
                installed.append(name)
            } else {
                failed.append(name)
            }
        }
        return (installed, failed)
    }

    func uninstallAll() {
        for name in workflowNames {
            uninstall(name: name)
        }
    }

    private func install(name: String) -> Bool {
        guard let resourceURL = Bundle.main.resourceURL else { return false }
        let sourceURL = resourceURL.appendingPathComponent("\(name).workflow")
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return false }
        let destURL = servicesDir.appendingPathComponent("\(name).workflow")

        let fm = FileManager.default
        if fm.fileExists(atPath: destURL.path) {
            try? fm.removeItem(at: destURL)
        }

        do {
            try fm.copyItem(at: sourceURL, to: destURL)
            return true
        } catch {
            return false
        }
    }

    private func uninstall(name: String) {
        let destURL = servicesDir.appendingPathComponent("\(name).workflow")
        try? FileManager.default.removeItem(at: destURL)
    }
}
