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

    /// Periodic full scan timer
    private var periodicScanTimer: Timer?

    /// In-flight scan guard (개선 5: 중복 실행 방지)
    private var isScanning = false

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

        // Listen for full scan requests (folder added in settings)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFullScanDirectory(_:)),
            name: Notification.Name("HangulJasoFullScanDirectory"),
            object: nil
        )

        // Listen for convert requests from Quick Actions (URL scheme → ViewModel → DistributedNotification)
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleConvertRequest(_:)),
            name: Notification.Name("com.clover4282.hanguljaso.convertRequest"),
            object: nil
        )

        // Listen for convert requests from FinderSync extension (Darwin notification + App Group)
        let darwinCenter = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(darwinCenter, Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async {
                    delegate.handleFinderSyncConvert()
                }
            },
            "com.clover4282.hanguljaso.finderConvert" as CFString, nil, .deliverImmediately
        )

        // Periodic full scan every 1 hour (개선 2)
        periodicScanTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.scanAndShareNFDFiles()
        }
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
                        // 변환 후 재스캔: 폴더 태그 갱신 (rename 없으므로 FSEvents 루프 안전)
                        self.scanDirectory(dirPath, recursive: false)
                        // 상위 폴더 태그 정리 (감시 루트까지)
                        self.cleanParentFolderTags(from: dirPath)

                        NSLog("HangulJaso: auto-converted %d files in %@", converted, dirPath)
                        if UserDefaults.standard.bool(forKey: Constants.UserDefaultsKeys.notifyOnAutoConvert) {
                            self.sendNotification(
                                title: "한글 자소 정리",
                                body: "\(converted)개 파일을 NFC로 자동 변환했습니다"
                            )
                        }
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

    @objc private func handleFullScanDirectory(_ notification: Notification) {
        guard let dirPath = notification.object as? String else { return }
        let autoConvert = notification.userInfo?["autoConvert"] as? Bool ?? false

        DispatchQueue.global(qos: .userInitiated).async {
            NSLog("HangulJaso: full scan requested for %@", dirPath)
            self.scanDirectory(dirPath, isRoot: true)

            if autoConvert {
                let converted = self.convertDirectoryContents(atPath: dirPath)
                if converted > 0 {
                    // 변환 후 재스캔: 전체 트리 폴더 태그 갱신
                    self.scanDirectory(dirPath, isRoot: true)
                    if UserDefaults.standard.bool(forKey: Constants.UserDefaultsKeys.notifyOnAutoConvert) {
                        self.sendNotification(
                            title: "한글 자소 정리",
                            body: "\(converted)개 파일을 NFC로 자동 변환했습니다"
                        )
                    }
                }
            }
        }
    }

    /// FinderSync에서 Darwin notification + App Group UserDefaults로 전달된 변환 요청 처리 (메인 스레드에서 호출)
    private func handleFinderSyncConvert() {
        guard let defaults = UserDefaults(suiteName: Constants.SharedDefaults.suiteName) else { return }
        // 다른 프로세스에서 쓴 값을 확실히 읽기 위해 동기화
        defaults.synchronize()
        guard let pending = defaults.stringArray(forKey: Constants.SharedDefaults.pendingConvertPathsKey),
              !pending.isEmpty else { return }
        defaults.removeObject(forKey: Constants.SharedDefaults.pendingConvertPathsKey)
        defaults.synchronize()

        // __FINDER_SELECTION__: File Provider 폴더에서 AppleScript로 선택 항목 가져오기
        var filePaths = pending
        if filePaths == ["__FINDER_SELECTION__"] {
            // AppleScript는 메인 스레드에서 실행 (NSAppleScript 스레드 안전성)
            // TCC 다이얼로그 표시를 위해 일시적으로 regular 앱으로 전환
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)

            let (paths, errorMsg) = finderSelectionViaAppleScript()

            NSApp.setActivationPolicy(.accessory)

            if paths.isEmpty {
                sendNotification(title: "한글 자소 정리", body: errorMsg ?? "선택된 파일이 없습니다")
                return
            }
            filePaths = paths
        }

        for filePath in filePaths {
            processConvert(filePath: filePath)
        }
    }

    /// AppleScript로 Finder 선택 항목의 POSIX 경로를 가져옴 (메인 스레드에서 호출)
    /// 반환: (경로 배열, 에러 메시지 또는 nil)
    private func finderSelectionViaAppleScript() -> ([String], String?) {
        let source = """
            tell application "Finder"
                set sel to selection
                if (count of sel) = 0 then
                    return POSIX path of (target of front Finder window as alias)
                end if
                set paths to ""
                repeat with f in sel
                    set paths to paths & POSIX path of (f as alias) & linefeed
                end repeat
                return text 1 thru -2 of paths
            end tell
            """

        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        let result = script?.executeAndReturnError(&error)

        if let error {
            let errorNum = error[NSAppleScript.errorNumber] as? Int ?? 0
            let errorMsg = error[NSAppleScript.errorMessage] as? String ?? "알 수 없는 오류"
            NSLog("HangulJaso: AppleScript error %d: %@", errorNum, errorMsg)
            if errorNum == -1743 {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                return ([], "Finder 자동화 권한이 필요합니다. 설정에서 허용해 주세요.")
            }
            return ([], "AppleScript 오류: \(errorMsg)")
        }

        guard let output = result?.stringValue, !output.isEmpty else {
            return ([], nil)
        }
        return (output.components(separatedBy: "\n"), nil)
    }

    @objc private func handleConvertRequest(_ notification: Notification) {
        guard let filePath = notification.object as? String else { return }
        processConvert(filePath: filePath)
    }

    private func processConvert(filePath: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            // 경로 끝의 / 제거 (AppleScript 디렉토리 경로 대응)
            let cleanPath = filePath.hasSuffix("/") ? String(filePath.dropLast()) : filePath
            let url = URL(fileURLWithPath: cleanPath)
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: cleanPath, isDirectory: &isDir)

            guard exists else {
                self.sendNotification(title: "한글 자소 정리", body: "경로를 찾을 수 없습니다")
                return
            }

            var totalConverted = 0

            if isDir.boolValue {
                totalConverted += self.convertDirectoryContents(atPath: cleanPath)
                // 변환 후 재스캔: 폴더 태그 + 잘못된 파일 태그 정리
                self.scanDirectory(cleanPath, isRoot: true)
            }
            // 파일 또는 폴더 이름 자체가 NFD인 경우 변환
            if self.convertSingleItem(url) { totalConverted += 1 }

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
    /// 개선 3: opendir 1회로 통합 — 단일 루프에서 하위 디렉토리 목록 + NFD 파일 목록을 동시에 수집,
    ///         하위 디렉토리 재귀 처리 후 수집된 NFD 항목 변환 (bottom-up 순서 유지).
    private func convertDirectoryContents(atPath dirPath: String, recursive: Bool = true) -> Int {
        guard let dir = opendir(dirPath) else { return 0 }
        defer { closedir(dir) }

        var converted = 0
        var subdirs: [String] = []
        // NFD 파일/디렉토리: (rawName, nfcName) 쌍으로 수집
        var nfdEntries: [(raw: String, nfc: String)] = []

        while let entry = readdir(dir) {
            let nameLen = Int(entry.pointee.d_namlen)
            let rawName: String = withUnsafePointer(to: entry.pointee.d_name) { ptr in
                ptr.withMemoryRebound(to: UInt8.self, capacity: nameLen) { buf in
                    String(bytes: UnsafeBufferPointer(start: buf, count: nameLen), encoding: .utf8) ?? ""
                }
            }
            guard !rawName.isEmpty && rawName != "." && rawName != ".." else { continue }
            if Self.shouldSkipAutoConvert(rawName) { continue }

            let fullPath = dirPath + "/" + rawName
            let isDirectory = entry.pointee.d_type == DT_DIR

            if isDirectory && recursive {
                subdirs.append(fullPath)
            }

            let nfc = rawName.precomposedStringWithCanonicalMapping
            if !rawName.unicodeScalars.elementsEqual(nfc.unicodeScalars) {
                nfdEntries.append((raw: rawName, nfc: nfc))
            }
        }

        // 하위 디렉토리 먼저 재귀 처리 (depth-first, bottom-up)
        for subdir in subdirs {
            converted += convertDirectoryContents(atPath: subdir)
        }

        // 수집된 NFD 항목 변환 (현재 디렉토리)
        for entry in nfdEntries {
            let nfdPath = dirPath + "/" + entry.raw
            let nfcPath = dirPath + "/" + entry.nfc
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
        let nfcTarget = url.lastPathComponent
        guard let dir = opendir(dirPath) else { return false }
        defer { closedir(dir) }

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
        // 개선 5: 중복 실행 방지
        guard !isScanning else {
            NSLog("HangulJaso: scan already in progress, skipping")
            return
        }
        isScanning = true
        DispatchQueue.global(qos: .utility).async {
            defer { self.isScanning = false }
            let folders = self.loadWatchedFolders()
            NSLog("HangulJaso: scanning %d watched folders", folders.count)
            var totalConverted = 0
            for folder in folders {
                self.scanDirectory(folder.path, isRoot: true)
                if folder.autoConvert {
                    let converted = self.convertDirectoryContents(atPath: folder.path)
                    if converted > 0 {
                        totalConverted += converted
                        // 변환 후 재스캔: 전체 트리 폴더 태그 갱신
                        self.scanDirectory(folder.path, isRoot: true)
                    }
                }
            }
            if totalConverted > 0 {
                NSLog("HangulJaso: startup auto-converted %d files", totalConverted)
                if UserDefaults.standard.bool(forKey: Constants.UserDefaultsKeys.notifyOnAutoConvert) {
                    self.sendNotification(
                        title: "한글 자소 정리",
                        body: "\(totalConverted)개 파일을 NFC로 자동 변환했습니다"
                    )
                }
            }
            NSLog("HangulJaso: scan complete")
        }
    }

    private func loadWatchedFolders() -> [WatchedFolder] {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let fileURL = appSupport
            .appendingPathComponent("HangulJaso", isDirectory: true)
            .appendingPathComponent(Constants.Defaults.watchedFoldersFileName)
        guard let data = try? Data(contentsOf: fileURL),
              let folders = try? JSONDecoder().decode([WatchedFolder].self, from: data) else { return [] }
        return folders.filter(\.enabled)
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

            // 개선 1: NFD 파일에만 태그 부여, NFC 파일은 잘못된 태그만 정리
            if isNFD {
                let fileURL = URL(fileURLWithPath: dirPath).appendingPathComponent(nfc)
                NSLog("HangulJaso: NFD found: %@ -> tag %@", rawName, fileURL.path)
                addTag(tagName, to: fileURL)
                foundNFD = true
            } else {
                // NFC 파일에 잘못된 NFD 태그가 남아있으면 정리
                let fileURL = URL(fileURLWithPath: dirPath).appendingPathComponent(rawName)
                if hasTag(tagName, at: fileURL) {
                    removeTag(tagName, from: fileURL)
                }
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

    /// 부모 폴더 체인을 감시 루트까지 올라가며 NFD 태그 정리
    private func cleanParentFolderTags(from dirPath: String) {
        let watchedRoots = Set(loadWatchedFolders().map(\.path))
        let tagName = "NFD"
        var current = dirPath
        while true {
            let parent = (current as NSString).deletingLastPathComponent
            guard parent != current else { break }
            // 감시 루트 자체는 정리하지 않음 (isRoot 폴더는 scanDirectory에서 태그 안 붙임)
            if watchedRoots.contains(parent) { break }
            let parentURL = URL(fileURLWithPath: parent)
            guard hasTag(tagName, at: parentURL) else { break }
            if directoryStillHasNFD(parent) { break }
            removeTag(tagName, from: parentURL)
            current = parent
        }
    }

    /// 디렉토리에 NFD 항목이 아직 남아있는지 확인 (직접 자식 이름 + 하위 폴더 NFD 태그)
    private func directoryStillHasNFD(_ dirPath: String) -> Bool {
        guard let dir = opendir(dirPath) else { return false }
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

            // 직접 자식 이름이 NFD인지 확인
            let nfc = rawName.precomposedStringWithCanonicalMapping
            if !rawName.unicodeScalars.elementsEqual(nfc.unicodeScalars) {
                return true
            }

            // 하위 폴더가 NFD 태그를 갖고 있는지 확인 (깊은 NFD의 프록시)
            if entry.pointee.d_type == DT_DIR {
                let subURL = URL(fileURLWithPath: dirPath).appendingPathComponent(rawName)
                if hasTag(tagName, at: subURL) {
                    return true
                }
            }
        }
        return false
    }

    /// xattr에서 특정 태그 존재 여부를 빠르게 확인
    private func hasTag(_ tag: String, at url: URL) -> Bool {
        let key = "com.apple.metadata:_kMDItemUserTags"
        let path = url.path
        let size = getxattr(path, key, nil, 0, 0, 0)
        guard size > 0 else { return false }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { ptr in
            getxattr(path, key, ptr.baseAddress, size, 0, 0)
        }
        guard read > 0,
              let tags = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else {
            return false
        }
        return tags.contains { $0.hasPrefix(tag) }
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
