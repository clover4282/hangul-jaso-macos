import Foundation
import SwiftUI
import ServiceManagement
import UserNotifications

// MARK: - AppTab

enum AppTab: String, CaseIterable {
    case files, history, settings

    var icon: String {
        switch self {
        case .files:    return "doc.on.doc"
        case .history:  return "clock"
        case .settings: return "gear"
        }
    }

    var title: String {
        switch self {
        case .files:    return "파일"
        case .history:  return "이력"
        case .settings: return "설정"
        }
    }
}

// MARK: - HangulJasoViewModel

@Observable
@MainActor
final class HangulJasoViewModel {

    // MARK: - State

    var fileItems: [FileItem] = []
    var history: [ConversionRecord] = []
    var watchedFolders: [WatchedFolder] = []
    var isScanning = false
    var currentTab: AppTab = .files
    var showPreviewSheet = false
    var lastConversionResults: [ConversionResult] = []

    // MARK: - Computed

    var totalCount: Int { fileItems.count }
    var nfdCount: Int { fileItems.filter(\.isNFD).count }
    var nfcCount: Int { fileItems.count - nfdCount }
    var nfdItems: [FileItem] { fileItems.filter(\.isNFD) }
    var hasNFDFiles: Bool { nfdCount > 0 }

    // MARK: - Services

    private let nfcService = NFCService()
    private let historyService = HistoryService()
    private let monitorService = FileMonitorService()
    let workflowInstaller = WorkflowInstaller()

    @ObservationIgnored private var urlObserver: Any?

    // MARK: - Init

    init() {
        UserDefaults.standard.register(defaults: Constants.Defaults.registeredSettings)
        history = historyService.getHistory()
        loadWatchedFolders()
        setupURLHandler()
        setupMonitoring()
    }

    // MARK: - File Actions

    func addFiles(urls: [URL]) {
        isScanning = true
        let newItems = nfcService.scan(urls: urls)
        let existingPaths = Set(fileItems.map(\.url.path))
        let unique = newItems.filter { !existingPaths.contains($0.url.path) }
        fileItems.append(contentsOf: unique)
        isScanning = false
    }

    func clearFiles() {
        fileItems.removeAll()
    }

    func convertAll() {
        let itemsToConvert = nfdItems
        guard !itemsToConvert.isEmpty else { return }

        let results = nfcService.convertAll(items: itemsToConvert)
        lastConversionResults = results

        let records = results.compactMap { result -> ConversionRecord? in
            guard case .converted = result.status else { return nil }
            return ConversionRecord(
                originalName: result.fileItem.originalName,
                convertedName: result.fileItem.normalizedName,
                path: result.fileItem.parentURL.path
            )
        }
        if !records.isEmpty {
            historyService.addEntries(records)
            history = historyService.getHistory()
        }

        // Refresh by re-scanning the unique parent directories of all current items
        let parentURLs = Array(Set(fileItems.map(\.parentURL)))
        fileItems.removeAll()
        addFiles(urls: parentURLs)

        sendConversionNotification(converted: records.count, total: itemsToConvert.count)
    }

    func undoRecord(_ record: ConversionRecord) {
        guard nfcService.undo(record: record) else { return }
        historyService.markUndone(id: record.id)
        history = historyService.getHistory()
    }

    func clearHistory() {
        historyService.clearHistory()
        history = []
    }

    // MARK: - Watched Folders

    func addWatchedFolder(url: URL) {
        let folder = WatchedFolder(path: url.path)
        watchedFolders.append(folder)
        saveWatchedFolders()
        if folder.enabled {
            monitorService.startWatching(path: folder.path)
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
            try? SMAppService.mainApp.register()
        } else {
            try? SMAppService.mainApp.unregister()
        }
    }

    // MARK: - Open File Panel

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "추가"
        panel.message = "변환할 파일이나 폴더를 선택하세요"

        if panel.runModal() == .OK {
            addFiles(urls: panel.urls)
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
        let paths = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "paths" })?
            .value?
            .split(separator: ",")
            .map { URL(fileURLWithPath: String($0)) } ?? []

        guard !paths.isEmpty else { return }

        switch host {
        case "convert":
            addFiles(urls: paths)
            convertAll()
        case "check":
            addFiles(urls: paths)
        default:
            break
        }
    }

    private func setupMonitoring() {
        monitorService.setChangeHandler { [weak self] changedPaths in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let urls = changedPaths.map { URL(fileURLWithPath: $0) }
                let items = self.nfcService.scan(urls: urls)
                let nfdItems = items.filter(\.isNFD)

                guard !nfdItems.isEmpty else { return }

                let autoConvertPaths = Set(self.watchedFolders.filter(\.autoConvert).map(\.path))
                let shouldAutoConvert = nfdItems.contains { item in
                    autoConvertPaths.contains { item.url.path.hasPrefix($0) }
                }

                if shouldAutoConvert {
                    let results = self.nfcService.convertAll(items: nfdItems)
                    let records = results.compactMap { result -> ConversionRecord? in
                        guard case .converted = result.status else { return nil }
                        return ConversionRecord(
                            originalName: result.fileItem.originalName,
                            convertedName: result.fileItem.normalizedName,
                            path: result.fileItem.parentURL.path
                        )
                    }
                    if !records.isEmpty {
                        self.historyService.addEntries(records)
                        self.history = self.historyService.getHistory()
                        self.sendConversionNotification(converted: records.count, total: nfdItems.count)
                    }
                } else if UserDefaults.standard.bool(forKey: Constants.UserDefaultsKeys.notifyOnAutoConvert) {
                    self.sendDetectionNotification(count: nfdItems.count)
                }
            }
        }

        for folder in watchedFolders where folder.enabled {
            monitorService.startWatching(path: folder.path)
        }
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
