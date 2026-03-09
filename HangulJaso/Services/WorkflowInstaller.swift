import Foundation

final class WorkflowInstaller {
    private let servicesDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Services")
    }()

    private let workflowNames = [
        "한글 파일명 NFC 변환"
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
        guard let resourceURL = Bundle.main.resourceURL else {
            NSLog("WorkflowInstaller: no resourceURL")
            return false
        }
        let sourceURL = resourceURL.appendingPathComponent("\(name).workflow")
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            NSLog("WorkflowInstaller: source not found at %@", sourceURL.path)
            // Try NFC-normalized path
            let nfcSource = resourceURL.appendingPathComponent("\(name.precomposedStringWithCanonicalMapping).workflow")
            if FileManager.default.fileExists(atPath: nfcSource.path) {
                return installFrom(source: nfcSource, name: name)
            }
            return false
        }
        return installFrom(source: sourceURL, name: name)
    }

    private func installFrom(source: URL, name: String) -> Bool {
        let destURL = servicesDir.appendingPathComponent("\(name).workflow")

        let fm = FileManager.default
        if fm.fileExists(atPath: destURL.path) {
            try? fm.removeItem(at: destURL)
        }

        do {
            try fm.copyItem(at: source, to: destURL)
            NSLog("WorkflowInstaller: installed %@", name)
            return true
        } catch {
            NSLog("WorkflowInstaller: failed to copy %@ - %@", name, error.localizedDescription)
            return false
        }
    }

    private func uninstall(name: String) {
        let destURL = servicesDir.appendingPathComponent("\(name).workflow")
        try? FileManager.default.removeItem(at: destURL)
    }
}
