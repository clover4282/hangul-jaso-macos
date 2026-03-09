import AppKit
import UserNotifications
import os.log

private let logger = Logger(subsystem: "com.clover4282.hanguljaso", category: "AppDelegate")

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static let urlReceivedNotification = Notification.Name("HangulJasoURLReceived")
    private let fileMonitor = FileMonitorService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // Scan common directories for NFD files and share with Finder extension
        scanAndShareNFDFiles()

        // Start watching directories for file changes
        startFileMonitoring()

        // Listen for distributed notification from extension requesting a scan
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleScanRequest(_:)),
            name: Notification.Name("com.clover4282.hanguljaso.scanRequest"),
            object: nil
        )

        // Listen for convert requests from extension
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleConvertRequest(_:)),
            name: Notification.Name("com.clover4282.hanguljaso.convertRequest"),
            object: nil
        )
    }

    private func startFileMonitoring() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dirs = ["Downloads", "Desktop", "Documents"].map { home + "/" + $0 }

        fileMonitor.setChangeHandler { [weak self] changedPaths in
            guard let self else { return }
            DispatchQueue.global(qos: .utility).async {
                for changedPath in changedPaths {
                    self.handleFileChange(changedPath)
                }
            }
        }

        for dir in dirs {
            fileMonitor.startWatching(path: dir)
        }
    }

    private func handleFileChange(_ path: String) {
        let url = URL(fileURLWithPath: path)
        let dirPath = url.deletingLastPathComponent().path
        let nfcName = url.lastPathComponent

        guard let dir = opendir(dirPath) else { return }
        defer { closedir(dir) }

        var foundNFD = false

        while let entry = readdir(dir) {
            let nameLen = Int(entry.pointee.d_namlen)
            let rawName: String = withUnsafePointer(to: entry.pointee.d_name) { ptr in
                ptr.withMemoryRebound(to: UInt8.self, capacity: nameLen) { buf in
                    String(bytes: UnsafeBufferPointer(start: buf, count: nameLen), encoding: .utf8) ?? ""
                }
            }
            guard !rawName.isEmpty && rawName != "." && rawName != ".." else { continue }
            let nfc = rawName.precomposedStringWithCanonicalMapping
            guard nfc == nfcName else { continue }

            if !rawName.unicodeScalars.elementsEqual(nfc.unicodeScalars) {
                // File is NFD — add tag
                addTag("NFD", to: url)
                foundNFD = true
            } else {
                // File is NFC — remove tag if present
                removeTag("NFD", from: url)
            }
            break
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
        }
    }

    /// Recursively convert all NFD entries inside a directory (bottom-up)
    private func convertDirectoryContents(atPath dirPath: String) -> Int {
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

            let fullPath = dirPath + "/" + rawName
            let isDirectory = entry.pointee.d_type == DT_DIR

            if isDirectory {
                subdirs.append(fullPath)
            }
        }

        // Recurse into subdirectories first (depth-first)
        for subdir in subdirs {
            converted += convertDirectoryContents(atPath: subdir)
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

    @objc private func handleScanRequest(_ notification: Notification) {
        if let dirPath = notification.object as? String {
            scanDirectory(dirPath)
        } else {
            scanAndShareNFDFiles()
        }
        // Notify extension that scan is complete
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.clover4282.hanguljaso.scanComplete"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    private func scanAndShareNFDFiles() {
        DispatchQueue.global(qos: .utility).async {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            NSLog("HangulJaso: scanning home=%@", home)
            let dirs = ["Downloads", "Desktop", "Documents"].map { home + "/" + $0 }
            for dir in dirs {
                self.scanDirectory(dir)
            }
            NSLog("HangulJaso: scan complete")
        }
    }

    private func scanDirectory(_ dirPath: String) {
        guard let dir = opendir(dirPath) else { return }
        defer { closedir(dir) }

        let tagName = "NFD"

        while let entry = readdir(dir) {
            let nameLen = Int(entry.pointee.d_namlen)
            let rawName: String = withUnsafePointer(to: entry.pointee.d_name) { ptr in
                ptr.withMemoryRebound(to: UInt8.self, capacity: nameLen) { buf in
                    String(bytes: UnsafeBufferPointer(start: buf, count: nameLen), encoding: .utf8) ?? ""
                }
            }
            guard !rawName.isEmpty && rawName != "." && rawName != ".." else { continue }
            let nfc = rawName.precomposedStringWithCanonicalMapping
            let isNFD = !rawName.unicodeScalars.elementsEqual(nfc.unicodeScalars)

            if isNFD {
                let fileURL = URL(fileURLWithPath: dirPath).appendingPathComponent(nfc)
                NSLog("HangulJaso: NFD found: %@ -> tag %@", rawName, fileURL.path)
                addTag(tagName, to: fileURL)
            }
        }
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
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
