import Foundation
import SwiftUI

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
            // 추가 즉시 전체 스캔 요청 (NFD 태그 부착)
            NotificationCenter.default.post(
                name: Notification.Name("HangulJasoFullScanDirectory"),
                object: folder.path
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
            postPathRequest(url: url, notification: "com.clover4282.hanguljaso.convertRequest")
        case "scan":
            postPathRequest(url: url, notification: "com.clover4282.hanguljaso.scanRequest")
        default:
            break
        }
    }

    /// URL의 p 쿼리에서 경로들을 추출해 개행으로 묶어 AppDelegate에 distributed notification 전달 → 요약 알림 1개
    /// (Swift URL이 NFD→NFC 자동 정규화하므로 저수준 readdir 변환/검사는 AppDelegate에 위임)
    private func postPathRequest(url: URL, notification: String) {
        let paths = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .filter { $0.name == "p" }
            .compactMap { $0.value }
            .map { URL(fileURLWithPath: $0) } ?? []
        guard !paths.isEmpty else { return }
        let joined = paths.map(\.path).joined(separator: "\n")
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(notification),
            object: joined,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    private func setupMonitoring() {
        monitorService.setChangeHandler { changedPaths in
            // Collect unique parent directories from changed paths
            let dirs = Set(changedPaths.map { path -> String in
                let url = URL(fileURLWithPath: path)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                    return path
                }
                return url.deletingLastPathComponent().path
            })

            for dir in dirs {
                NotificationCenter.default.post(
                    name: Notification.Name("HangulJasoRescanDirectory"),
                    object: dir
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
}
