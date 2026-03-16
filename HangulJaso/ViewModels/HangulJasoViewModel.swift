import Foundation
import SwiftUI
import UserNotifications

// MARK: - HangulJasoViewModel

@Observable
@MainActor
final class HangulJasoViewModel {

    // MARK: - State

    var watchedFolders: [WatchedFolder] = []

    // MARK: - Services

    private let nfcService = NFCService()
    private let monitorService = FileMonitorService()
    let workflowInstaller = WorkflowInstaller()

    @ObservationIgnored private var urlObserver: Any?

    // MARK: - Init

    init() {
        UserDefaults.standard.register(defaults: Constants.Defaults.registeredSettings)
        loadWatchedFolders()
        if watchedFolders.isEmpty {
            addDefaultWatchedFolders()
        }
        setupURLHandler()
        setupMonitoring()
    }

    // MARK: - Watched Folders

    func addWatchedFolder(url: URL) {
        let folder = WatchedFolder(path: url.path)
        watchedFolders.append(folder)
        saveWatchedFolders()
        if folder.enabled {
            monitorService.startWatching(path: folder.path)
            // 추가 즉시 전체 스캔+변환 요청
            NotificationCenter.default.post(
                name: Notification.Name("HangulJasoFullScanDirectory"),
                object: folder.path,
                userInfo: ["autoConvert": folder.autoConvert]
            )
        }
    }

    func removeWatchedFolder(_ folder: WatchedFolder) {
        monitorService.stopWatching(path: folder.path)
        watchedFolders.removeAll { $0.id == folder.id }
        saveWatchedFolders()
    }

    func toggleWatchedFolder(_ folder: WatchedFolder) {
        guard let index = watchedFolders.firstIndex(where: { $0.id == folder.id }) else { return }
        watchedFolders[index].enabled.toggle()
        if watchedFolders[index].enabled {
            monitorService.startWatching(path: folder.path)
        } else {
            monitorService.stopWatching(path: folder.path)
        }
        saveWatchedFolders()
    }

    func toggleAutoConvert(_ folder: WatchedFolder) {
        guard let index = watchedFolders.firstIndex(where: { $0.id == folder.id }) else { return }
        watchedFolders[index].autoConvert.toggle()
        saveWatchedFolders()
    }

    // MARK: - Settings

    func updateLoginItem(enabled: Bool) {
        if enabled {
            LaunchAgentService.install()
        } else {
            LaunchAgentService.uninstall()
        }
    }

    // MARK: - Private

    private func setupURLHandler() {
        urlObserver = NotificationCenter.default.addObserver(
            forName: AppDelegate.urlReceivedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let url = notification.userInfo?["url"] as? URL else { return }
            Task { @MainActor [weak self] in
                self?.handleURL(url)
            }
        }
    }

    private func handleURL(_ url: URL) {
        guard let host = url.host else { return }

        switch host {
        case "convert":
            let paths = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .filter { $0.name == "p" }
                .compactMap { $0.value }
                .map { URL(fileURLWithPath: $0) } ?? []
            guard !paths.isEmpty else { return }
            // Delegate to AppDelegate's low-level readdir-based converter
            // (Swift URL auto-normalizes NFD→NFC, so nfcService can't detect NFD)
            for path in paths {
                DistributedNotificationCenter.default().postNotificationName(
                    Notification.Name("com.clover4282.hanguljaso.convertRequest"),
                    object: path.path,
                    userInfo: nil,
                    deliverImmediately: true
                )
            }
        default:
            break
        }
    }

    private func setupMonitoring() {
        monitorService.setChangeHandler { [weak self] changedPaths in
            guard let self else { return }
            // Collect unique parent directories from changed paths
            let dirs = Set(changedPaths.map { path -> String in
                let url = URL(fileURLWithPath: path)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                    return path
                }
                return url.deletingLastPathComponent().path
            })

            // Check autoConvert status for each directory
            let autoConvertDirs = Set(self.watchedFolders.filter(\.autoConvert).map(\.path))

            for dir in dirs {
                let shouldAutoConvert = autoConvertDirs.contains(where: { dir.hasPrefix($0) })
                NotificationCenter.default.post(
                    name: Notification.Name("HangulJasoRescanDirectory"),
                    object: dir,
                    userInfo: ["autoConvert": shouldAutoConvert]
                )
            }
        }

        for folder in watchedFolders where folder.enabled {
            monitorService.startWatching(path: folder.path)
        }
    }

    private func addDefaultWatchedFolders() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let defaults = ["Downloads", "Desktop", "Documents"]
        for name in defaults {
            let path = home + "/" + name
            guard FileManager.default.fileExists(atPath: path) else { continue }
            watchedFolders.append(WatchedFolder(path: path))
        }
        saveWatchedFolders()
    }

    private func loadWatchedFolders() {
        guard let data = try? Data(contentsOf: watchedFoldersFileURL) else { return }
        watchedFolders = (try? JSONDecoder().decode([WatchedFolder].self, from: data)) ?? []
    }

    private func saveWatchedFolders() {
        guard let data = try? JSONEncoder().encode(watchedFolders) else { return }
        try? data.write(to: watchedFoldersFileURL, options: .atomic)
    }

    private var watchedFoldersFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("HangulJaso", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent(Constants.Defaults.watchedFoldersFileName)
    }

    private func sendConversionNotification(converted: Int, total: Int) {
        let content = UNMutableNotificationContent()
        content.title = "한글 자소 정리"
        content.body = "\(total)개 중 \(converted)개 파일을 NFC로 변환했습니다"
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func sendDetectionNotification(count: Int) {
        let content = UNMutableNotificationContent()
        content.title = "한글 자소 정리"
        content.body = "NFD 파일 \(count)개가 감지되었습니다"
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
