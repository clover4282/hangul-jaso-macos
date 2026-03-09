import AppKit
import UserNotifications
import os.log

private let logger = Logger(subsystem: "com.clover4282.hanguljaso", category: "AppDelegate")

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static let urlReceivedNotification = Notification.Name("HangulJasoURLReceived")

    /// Debouncer: pending rescan work items keyed by directory path
    private var pendingRescans: [String: DispatchWorkItem] = [:]
    private let debounceQueue = DispatchQueue(label: "com.clover4282.hanguljaso.debounce")

    /// Cooldown: recently converted directories (to prevent rename→FSEvents loop)
    private var recentlyConverted: Set<String> = []
    private let cooldownQueue = DispatchQueue(label: "com.clover4282.hanguljaso.cooldown")

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // Auto-install Quick Action workflows
        let installer = WorkflowInstaller()
        _ = installer.installAll()

        // Scan watched folders for NFD files and tag them
        scanAndShareNFDFiles()

        // Listen for rescan requests from ViewModel (FSEvents changes)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRescanDirectory(_:)),
            name: Notification.Name("HangulJasoRescanDirectory"),
            object: nil
        )

        // Listen for convert requests from Quick Actions
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleConvertRequest(_:)),
            name: Notification.Name("com.clover4282.hanguljaso.convertRequest"),
            object: nil
        )
    }

    @objc private func handleRescanDirectory(_ notification: Notification) {
        guard let dirPath = notification.object as? String else { return }
        let autoConvert = notification.userInfo?["autoConvert"] as? Bool ?? false

        // Skip if this directory was recently converted (cooldown)
        var inCooldown = false
        cooldownQueue.sync { inCooldown = recentlyConverted.contains(dirPath) }
        if inCooldown {
            NSLog("HangulJaso: skipping rescan (cooldown): %@", dirPath)
            return
        }

        // Debounce: cancel pending rescan for same directory, schedule new one in 2s
        debounceQueue.sync {
            pendingRescans[dirPath]?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                // FSEvents-triggered scan: non-recursive (only the changed directory)
                self.scanDirectory(dirPath, recursive: false)

                if autoConvert {
                    let converted = self.convertDirectoryContents(atPath: dirPath, recursive: false)
                    if converted > 0 {
                        NSLog("HangulJaso: auto-converted %d files in %@", converted, dirPath)
                        if UserDefaults.standard.bool(forKey: Constants.UserDefaultsKeys.notifyOnAutoConvert) {
                            self.sendNotification(
                                title: "한글 자소 정리",
                                body: "\(converted)개 파일을 NFC로 자동 변환했습니다"
                            )
                        }
                        // Re-scan to update tags after conversion
                        self.scanDirectory(dirPath, recursive: false)
                        // Start cooldown to prevent rename→FSEvents loop
                        self.cooldownQueue.sync { self.recentlyConverted.insert(dirPath) }
                        self.cooldownQueue.asyncAfter(deadline: .now() + 5.0) {
                            self.recentlyConverted.remove(dirPath)
                        }
                    }
                }

                self.debounceQueue.sync { self.pendingRescans.removeValue(forKey: dirPath) }
            }
            pendingRescans[dirPath] = workItem
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0, execute: workItem)
        }
    }

    @objc private func handleConvertRequest(_ notification: Notification) {
        guard let filePath = notification.object as? String else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            let url = URL(fileURLWithPath: filePath)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: filePath, isDirectory: &isDir)

            var totalConverted = 0

            if isDir.boolValue {
                // Recursively convert all NFD files inside the folder (bottom-up)
                totalConverted += self.convertDirectoryContents(atPath: filePath)
            }

            // Convert the item itself
            if self.convertSingleItem(url) {
                totalConverted += 1
            }

            // Notify extension of result
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("com.clover4282.hanguljaso.convertResult"),
                object: totalConverted > 0 ? "ok:\(totalConverted)" : "fail",
                userInfo: nil,
                deliverImmediately: true
            )

            // User notification
            if totalConverted > 0 {
                self.sendNotification(
                    title: "한글 자소 정리",
                    body: "\(totalConverted)개 파일을 NFC로 변환했습니다"
                )
            } else {
                self.sendNotification(
                    title: "한글 자소 정리",
                    body: "변환할 NFD 파일이 없습니다"
                )
            }
        }
    }

    /// Convert NFD entries inside a directory, optionally recursing into subdirectories (bottom-up)
    private func convertDirectoryContents(atPath dirPath: String, recursive: Bool = true) -> Int {
        guard let dir = opendir(dirPath) else { return 0 }
        defer { closedir(dir) }

        var converted = 0
        var subdirs: [String] = []

        while let entry = readdir(dir) {
            let nameLen = Int(entry.pointee.d_namlen)
            let rawName: String = withUnsafePointer(to: entry.pointee.d_name) { ptr in
                ptr.withMemoryRebound(to: UInt8.self, capacity: nameLen) { buf in
                    String(bytes: UnsafeBufferPointer(start: buf, count: nameLen), encoding: .utf8) ?? ""
                }
            }
            guard !rawName.isEmpty && rawName != "." && rawName != ".." else { continue }
            // Skip hidden folders and files during auto-conversion
            if Self.shouldSkipAutoConvert(rawName) { continue }

            let fullPath = dirPath + "/" + rawName
            let isDirectory = entry.pointee.d_type == DT_DIR

            if isDirectory {
                subdirs.append(fullPath)
            }
        }

        // Recurse into subdirectories first (depth-first), only if recursive mode
        if recursive {
            for subdir in subdirs {
                converted += convertDirectoryContents(atPath: subdir)
            }
        }

        // Now convert all NFD entries in this directory (re-read after subdirs are converted)
        guard let dir2 = opendir(dirPath) else { return converted }
        defer { closedir(dir2) }

        while let entry = readdir(dir2) {
            let nameLen = Int(entry.pointee.d_namlen)
            let rawName: String = withUnsafePointer(to: entry.pointee.d_name) { ptr in
                ptr.withMemoryRebound(to: UInt8.self, capacity: nameLen) { buf in
                    String(bytes: UnsafeBufferPointer(start: buf, count: nameLen), encoding: .utf8) ?? ""
                }
            }
            guard !rawName.isEmpty && rawName != "." && rawName != ".." else { continue }

            // Skip temp/lock files that may be in use
            if Self.shouldSkipAutoConvert(rawName) { continue }

            let nfc = rawName.precomposedStringWithCanonicalMapping
            guard !rawName.unicodeScalars.elementsEqual(nfc.unicodeScalars) else { continue }

            let nfdPath = dirPath + "/" + rawName
            let nfcPath = dirPath + "/" + nfc
            if Darwin.rename(nfdPath, nfcPath) == 0 {
                removeTag("NFD", from: URL(fileURLWithPath: nfcPath))
                converted += 1
            }
        }

        return converted
    }

    /// Check if a file/folder should be skipped during auto-conversion
    private static func shouldSkipAutoConvert(_ name: String) -> Bool {
        // Hidden files/folders (e.g. .git, .DS_Store)
        name.hasPrefix(".") ||
        // Office temp files (~$file.docx)
        name.hasPrefix("~$") ||
        // Lock/temp/swap files
        name.hasSuffix(".tmp") || name.hasSuffix(".lock") ||
        name.hasSuffix(".lck") || name.hasSuffix(".swp")
    }

    /// Convert a single item's name from NFD to NFC
    private func convertSingleItem(_ url: URL) -> Bool {
        let dirPath = url.deletingLastPathComponent().path
        guard let dir = opendir(dirPath) else { return false }
        defer { closedir(dir) }

        let nfcTarget = url.lastPathComponent

        while let entry = readdir(dir) {
            let nameLen = Int(entry.pointee.d_namlen)
            let rawName: String = withUnsafePointer(to: entry.pointee.d_name) { ptr in
                ptr.withMemoryRebound(to: UInt8.self, capacity: nameLen) { buf in
                    String(bytes: UnsafeBufferPointer(start: buf, count: nameLen), encoding: .utf8) ?? ""
                }
            }
            let nfc = rawName.precomposedStringWithCanonicalMapping
            guard nfc == nfcTarget,
                  !rawName.unicodeScalars.elementsEqual(nfc.unicodeScalars) else { continue }

            let nfdPath = dirPath + "/" + rawName
            let nfcPath = dirPath + "/" + nfc
            if Darwin.rename(nfdPath, nfcPath) == 0 {
                removeTag("NFD", from: URL(fileURLWithPath: nfcPath))
                return true
            }
            return false
        }
        return false
    }

    private func scanAndShareNFDFiles() {
        DispatchQueue.global(qos: .utility).async {
            let dirs = self.loadWatchedFolderPaths()
            NSLog("HangulJaso: scanning %d watched folders", dirs.count)
            for dir in dirs {
                self.scanDirectory(dir, isRoot: true)
            }
            NSLog("HangulJaso: scan complete")
        }
    }

    private func loadWatchedFolderPaths() -> [String] {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let fileURL = appSupport
            .appendingPathComponent("HangulJaso", isDirectory: true)
            .appendingPathComponent(Constants.Defaults.watchedFoldersFileName)
        guard let data = try? Data(contentsOf: fileURL),
              let folders = try? JSONDecoder().decode([WatchedFolder].self, from: data) else { return [] }
        return folders.filter(\.enabled).map(\.path)
    }

    /// Scans a directory for NFD filenames, tags them, and optionally recurses into subdirectories.
    /// Returns `true` if any NFD entry was found in this directory or its children.
    @discardableResult
    private func scanDirectory(_ dirPath: String, isRoot: Bool = false, recursive: Bool = true) -> Bool {
        guard let dir = opendir(dirPath) else { return false }
        defer { closedir(dir) }

        let tagName = "NFD"
        var subdirs: [String] = []
        var foundNFD = false

        while let entry = readdir(dir) {
            let nameLen = Int(entry.pointee.d_namlen)
            let rawName: String = withUnsafePointer(to: entry.pointee.d_name) { ptr in
                ptr.withMemoryRebound(to: UInt8.self, capacity: nameLen) { buf in
                    String(bytes: UnsafeBufferPointer(start: buf, count: nameLen), encoding: .utf8) ?? ""
                }
            }
            guard !rawName.isEmpty && rawName != "." && rawName != ".." else { continue }

            let isDirectory = entry.pointee.d_type == DT_DIR
            if isDirectory {
                subdirs.append(dirPath + "/" + rawName)
            }

            let nfc = rawName.precomposedStringWithCanonicalMapping
            let isNFD = !rawName.unicodeScalars.elementsEqual(nfc.unicodeScalars)

            let fileURL = URL(fileURLWithPath: dirPath).appendingPathComponent(nfc)
            if isNFD {
                NSLog("HangulJaso: NFD found: %@ -> tag %@", rawName, fileURL.path)
                addTag(tagName, to: fileURL)
                foundNFD = true
            } else {
                // Clean up stale NFD tag from previously converted files
                removeTag(tagName, from: fileURL)
            }
        }

        // Recurse into subdirectories (only if recursive mode)
        if recursive {
            for subdir in subdirs {
                if scanDirectory(subdir) {
                    foundNFD = true
                }
            }
        }

        // Tag or untag the folder itself based on whether it contains NFD entries
        let folderURL = URL(fileURLWithPath: dirPath)
        if !isRoot {
            if foundNFD {
                addTag(tagName, to: folderURL)
            } else {
                removeTag(tagName, from: folderURL)
            }
        }

        return foundNFD
    }

    private func addTag(_ tag: String, to url: URL) {
        let key = "com.apple.metadata:_kMDItemUserTags"
        let path = url.path
        var tags: [String] = []

        let size = getxattr(path, key, nil, 0, 0, 0)
        if size > 0 {
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { ptr in
                getxattr(path, key, ptr.baseAddress, size, 0, 0)
            }
            if read > 0, let existing = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] {
                tags = existing
            }
        }

        // Tag format: "Name\n7" (7 = orange color index)
        let tagEntry = "\(tag)\n7"
        if tags.contains(where: { $0 == tagEntry }) { return }
        tags.removeAll { $0.hasPrefix(tag) }
        tags.append(tagEntry)

        if let newData = try? PropertyListSerialization.data(fromPropertyList: tags, format: .binary, options: 0) {
            let result = newData.withUnsafeBytes { ptr -> Int32 in
                setxattr(path, key, ptr.baseAddress, newData.count, 0, 0)
            }
            if result != 0 {
                logger.error("addTag setxattr failed: \(path, privacy: .public) errno=\(errno, privacy: .public)")
            } else {
                logger.notice("addTag OK: \(path, privacy: .public)")
            }
        }

        // Clear FinderInfo color label to prevent Finder from re-creating color tags
        clearFinderInfoColor(at: path)
    }

    private func removeTag(_ tag: String, from url: URL) {
        let key = "com.apple.metadata:_kMDItemUserTags"
        let path = url.path

        let size = getxattr(path, key, nil, 0, 0, 0)
        guard size > 0 else { return }

        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { ptr in
            getxattr(path, key, ptr.baseAddress, size, 0, 0)
        }
        guard read > 0,
              var tags = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else { return }

        let before = tags.count
        tags.removeAll { $0.hasPrefix(tag) }
        guard tags.count < before else { return }

        if let newData = try? PropertyListSerialization.data(fromPropertyList: tags, format: .binary, options: 0) {
            newData.withUnsafeBytes { ptr in
                _ = setxattr(path, key, ptr.baseAddress, newData.count, 0, 0)
            }
        }

        // Also clear FinderInfo color label
        clearFinderInfoColor(at: path)
    }

    private func clearFinderInfoColor(at path: String) {
        let finderInfoKey = "com.apple.FinderInfo"
        var info = [UInt8](repeating: 0, count: 32)
        let size = getxattr(path, finderInfoKey, &info, 32, 0, 0)
        guard size == 32 else { return }

        // Color label is in bits 1-3 of byte 9 (Finder flags)
        let colorMask: UInt8 = 0x0E
        guard info[9] & colorMask != 0 else { return }
        info[9] &= ~colorMask

        if info.allSatisfy({ $0 == 0 }) {
            removexattr(path, finderInfoKey, 0)
        } else {
            _ = setxattr(path, finderInfoKey, &info, 32, 0, 0)
        }
    }

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme == "hangul-jaso" else { continue }
            NotificationCenter.default.post(
                name: Self.urlReceivedNotification,
                object: nil,
                userInfo: ["url": url]
            )
        }

        // Hide the main window that macOS auto-opens on URL activation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            for window in NSApp.windows where window.title == "한글 자소 정리" {
                window.orderOut(nil)
            }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
