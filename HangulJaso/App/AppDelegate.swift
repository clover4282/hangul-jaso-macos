import AppKit
import UserNotifications
import os.log

private let logger = Logger(subsystem: "com.clover4282.hanguljaso", category: "AppDelegate")

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static let urlReceivedNotification = Notification.Name("HangulJasoURLReceived")

    /// Debouncer: pending rescan work items keyed by directory path
    private var pendingRescans: [String: DispatchWorkItem] = [:]
    private let debounceQueue = DispatchQueue(label: "com.clover4282.hanguljaso.debounce")

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

        // Listen for scan requests from Quick Actions (URL scheme → ViewModel → DistributedNotification)
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleScanRequest(_:)),
            name: Notification.Name("com.clover4282.hanguljaso.scanRequest"),
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

        // Listen for scan requests from FinderSync extension (Darwin notification + App Group)
        CFNotificationCenterAddObserver(darwinCenter, Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async {
                    delegate.handleFinderSyncScan()
                }
            },
            "com.clover4282.hanguljaso.finderScan" as CFString, nil, .deliverImmediately
        )

        // Periodic full scan every 1 hour (개선 2)
        periodicScanTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.scanAndShareNFDFiles()
        }
    }

    @objc private func handleRescanDirectory(_ notification: Notification) {
        guard let dirPath = notification.object as? String else { return }

        // Debounce: cancel pending rescan for same directory, schedule new one in 2s
        debounceQueue.sync {
            pendingRescans[dirPath]?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                // FSEvents-triggered scan: non-recursive (only the changed directory)
                // NFD 파일에 태그만 부착 — 변환(rename)은 수동(Finder 우클릭/툴바)으로만 수행
                let found = self.scanDirectory(dirPath, recursive: false)

                // scanDirectory는 폴더 자체 태그를 부모에게 맡기므로, 이 폴더 자체 태그를 직접 갱신
                self.reevaluateOwnTag(path: dirPath, contentFound: found)

                self.debounceQueue.sync { self.pendingRescans.removeValue(forKey: dirPath) }
            }
            pendingRescans[dirPath] = workItem
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0, execute: workItem)
        }
    }

    @objc private func handleFullScanDirectory(_ notification: Notification) {
        guard let dirPath = notification.object as? String else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            NSLog("HangulJaso: full scan requested for %@", dirPath)
            self.scanDirectory(dirPath)
        }
    }

    /// FinderSync에서 Darwin notification + App Group UserDefaults로 전달된 변환 요청 처리 (메인 스레드에서 호출)
    private func handleFinderSyncConvert() {
        NSLog("HangulJaso: handleFinderSyncConvert called")
        guard let filePaths = resolvePendingPaths(key: Constants.SharedDefaults.pendingConvertPathsKey) else { return }
        processConvert(filePaths: filePaths)
    }

    /// FinderSync에서 Darwin notification + App Group UserDefaults로 전달된 검사 요청 처리 (메인 스레드에서 호출)
    private func handleFinderSyncScan() {
        NSLog("HangulJaso: handleFinderSyncScan called")
        guard let filePaths = resolvePendingPaths(key: Constants.SharedDefaults.pendingScanPathsKey) else { return }
        processScan(filePaths: filePaths)
    }

    /// App Group에서 pending 경로를 읽고, __FINDER_SELECTION__이면 AppleScript로 Finder 선택 항목을 해석
    /// 반환: 해석된 경로 배열 (없거나 오류면 nil — 알림은 내부에서 처리)
    private func resolvePendingPaths(key: String) -> [String]? {
        guard let defaults = UserDefaults(suiteName: Constants.SharedDefaults.suiteName) else { return nil }
        // 다른 프로세스에서 쓴 값을 확실히 읽기 위해 동기화
        defaults.synchronize()
        guard let pending = defaults.stringArray(forKey: key), !pending.isEmpty else { return nil }
        defaults.removeObject(forKey: key)
        defaults.synchronize()

        // __FINDER_SELECTION__: File Provider 폴더에서 AppleScript로 선택 항목 가져오기
        guard pending == ["__FINDER_SELECTION__"] else { return pending }

        // AppleScript는 메인 스레드에서 실행 (NSAppleScript 스레드 안전성)
        // TCC 다이얼로그 표시를 위해 일시적으로 regular 앱으로 전환
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let (paths, errorMsg) = finderSelectionViaAppleScript()

        NSApp.setActivationPolicy(.accessory)

        if paths.isEmpty {
            sendNotification(title: "한글 자소 정리", body: errorMsg ?? "선택된 파일이 없습니다", fallbackToAlert: true)
            return nil
        }
        return paths
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
        guard let raw = notification.object as? String else { return }
        // 여러 경로는 개행으로 join되어 전달됨 (ViewModel.handleURL)
        let filePaths = raw.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard !filePaths.isEmpty else { return }
        processConvert(filePaths: filePaths)
    }

    @objc private func handleScanRequest(_ notification: Notification) {
        guard let raw = notification.object as? String else { return }
        let filePaths = raw.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard !filePaths.isEmpty else { return }
        processScan(filePaths: filePaths)
    }

    /// 여러 경로를 한 번에 변환하고 요약 알림 1개만 표시
    private func processConvert(filePaths: [String]) {
        DispatchQueue.global(qos: .userInitiated).async {
            var totalConverted = 0
            var notFound = 0
            for path in filePaths {
                if let converted = self.convertPath(path) {
                    totalConverted += converted
                } else {
                    notFound += 1
                }
            }

            // 변환이 있었으면 영향받은 감시 루트를 재귀 재스캔하여
            // 변환된 파일의 상위 폴더 태그까지 정확히 갱신 (하위에 NFD 없으면 태그 해제)
            if totalConverted > 0 {
                let roots = self.loadWatchedFolders().map(\.path)
                var affectedRoots = Set<String>()
                for path in filePaths {
                    let clean = path.hasSuffix("/") ? String(path.dropLast()) : path
                    for root in roots where clean == root || clean.hasPrefix(root + "/") {
                        affectedRoots.insert(root)
                    }
                }
                for root in affectedRoots {
                    self.scanDirectory(root)
                }
            }

            let body: String
            if totalConverted > 0 {
                body = "\(totalConverted)개 파일을 NFC로 변환했습니다"
            } else if notFound == filePaths.count {
                body = "경로를 찾을 수 없습니다"
            } else {
                body = "변환할 NFD 파일이 없습니다"
            }
            self.sendNotification(title: "한글 자소 정리", body: body, fallbackToAlert: true)
        }
    }

    /// 단일 경로(파일/폴더)를 변환. 반환: 변환된 파일 개수, 경로가 없으면 nil (알림 없음)
    private func convertPath(_ filePath: String) -> Int? {
        NSLog("HangulJaso: convertPath called for: %@", filePath)
        // 경로 끝의 / 제거 (AppleScript 디렉토리 경로 대응)
        let cleanPath = filePath.hasSuffix("/") ? String(filePath.dropLast()) : filePath
        let url = URL(fileURLWithPath: cleanPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cleanPath, isDirectory: &isDir) else {
            return nil
        }

        var totalConverted = 0
        if isDir.boolValue {
            totalConverted += convertDirectoryContents(atPath: cleanPath)
            // 변환 후 재스캔: 폴더 태그 + 잘못된 파일 태그 정리
            scanDirectory(cleanPath)
        }
        // 파일 또는 폴더 이름 자체가 NFD인 경우 변환
        if convertSingleItem(url) { totalConverted += 1 }
        return totalConverted
    }

    /// 여러 경로를 검사해 NFD에 태그를 부착/정리하고 요약 알림 1개만 표시 (변환 없음)
    private func processScan(filePaths: [String]) {
        DispatchQueue.global(qos: .userInitiated).async {
            var foundAny = false
            var scanned = 0
            for path in filePaths {
                if let found = self.scanPath(path) {
                    scanned += 1
                    if found { foundAny = true }
                }
            }

            let body: String
            if scanned == 0 {
                body = "경로를 찾을 수 없습니다"
            } else if foundAny {
                body = "NFD 파일을 발견해 태그로 표시했습니다"
            } else {
                body = "NFD 파일이 없습니다"
            }
            self.sendNotification(title: "한글 자소 정리", body: body, fallbackToAlert: true)
        }
    }

    /// 단일 경로 검사. 반환: NFD 발견 여부, 경로가 없으면 nil
    private func scanPath(_ filePath: String) -> Bool? {
        let cleanPath = filePath.hasSuffix("/") ? String(filePath.dropLast()) : filePath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cleanPath, isDirectory: &isDir) else { return nil }
        guard isDir.boolValue else { return scanSingleFile(cleanPath) }

        let found = scanDirectory(cleanPath)
        // scanDirectory는 자식만 처리하므로 스캔한 폴더 자신의 태그를 재평가한다.
        reevaluateOwnTag(path: cleanPath, contentFound: found)
        return found
    }

    /// 스캔/재스캔한 폴더 **자신**의 NFD 태그를 재평가한다.
    /// scanDirectory는 폴더 자체 태그를 부모에게 맡기므로, 직속 스캔 대상은 여기서 직접 갱신한다.
    /// 감시 루트(Downloads 등)는 자체 태깅하지 않되, 과거에 잘못 붙은 stale 태그는 정리한다.
    private func reevaluateOwnTag(path: String, contentFound: Bool) {
        let url = URL(fileURLWithPath: path)
        // watched_folders.json 경로가 NFD로 저장돼 있어도 Swift String ==는 정규화 동등성으로 매칭됨
        let isWatchedRoot = loadWatchedFolders().contains { $0.path == path }
        if !isWatchedRoot && (contentFound || isOnDiskNameNFD(path)) {
            addTag("NFD", to: url)
        } else if hasTag("NFD", at: url) {
            removeTag("NFD", from: url)
        }
    }

    /// 디스크 상의 실제 이름이 NFD인지 판정한다.
    /// URL.path/NSString은 macOS에서 경로를 NFD로 분해하므로 이름 정규화 판정에 쓸 수 없다 →
    /// 부모 디렉토리를 readdir해 원본 바이트로 확인한다. (열기 실패 시 false)
    private func isOnDiskNameNFD(_ path: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        let targetNFC = (path as NSString).lastPathComponent.precomposedStringWithCanonicalMapping
        guard let dir = opendir(parent) else { return false }
        defer { closedir(dir) }
        while let entry = readdir(dir) {
            let nameLen = Int(entry.pointee.d_namlen)
            let rawName: String = withUnsafePointer(to: entry.pointee.d_name) { ptr in
                ptr.withMemoryRebound(to: UInt8.self, capacity: nameLen) { buf in
                    String(bytes: UnsafeBufferPointer(start: buf, count: nameLen), encoding: .utf8) ?? ""
                }
            }
            let nfc = rawName.precomposedStringWithCanonicalMapping
            if nfc == targetNFC {
                return !rawName.unicodeScalars.elementsEqual(nfc.unicodeScalars)
            }
        }
        return false
    }

    /// 단일 파일 이름이 NFD인지 검사해 태그 부착/정리. 반환: NFD 여부
    private func scanSingleFile(_ filePath: String) -> Bool {
        let url = URL(fileURLWithPath: filePath)
        let dirPath = url.deletingLastPathComponent().path
        let nfcTarget = url.lastPathComponent
        if Self.shouldSkip(nfcTarget) { return false }
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
            let nfc = rawName.precomposedStringWithCanonicalMapping
            guard nfc == nfcTarget else { continue }

            let fileURL = URL(fileURLWithPath: dirPath).appendingPathComponent(nfc)
            if !rawName.unicodeScalars.elementsEqual(nfc.unicodeScalars) {
                addTag(tagName, to: fileURL)
                return true
            } else {
                if hasTag(tagName, at: fileURL) { removeTag(tagName, from: fileURL) }
                return false
            }
        }
        return false
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
            if Self.shouldSkip(rawName) { continue }

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

    /// 숨김·임시 파일은 NFD 검사/변환에서 제외 (~$ Office 잠금파일, dotfile, .tmp/.lock/.lck/.swp)
    private static func shouldSkip(_ name: String) -> Bool {
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
        if Self.shouldSkip(nfcTarget) { return false }
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
            for folder in folders {
                // NFD 파일에 태그만 부착 — 변환(rename)은 수동으로만 수행
                self.scanDirectory(folder.path)
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
    /// 디렉토리를 스캔해 NFD 항목에 태그를 부착/정리한다.
    /// 폴더 자체 태그는 결정하지 않고 **부모가** (자식 이름 NFD ‖ 자식 내용 NFD)로 결정한다 —
    /// "이름만 NFD인 폴더"를 부모가 붙였다가 자식 재귀가 떼는 깜빡임을 막기 위함.
    /// 반환: 이 디렉토리(직속 파일 + 하위 폴더 포함)에 NFD가 있는지 여부.
    @discardableResult
    private func scanDirectory(_ dirPath: String, recursive: Bool = true) -> Bool {
        guard let dir = opendir(dirPath) else { return false }
        defer { closedir(dir) }

        let tagName = "NFD"
        // 하위 폴더: (경로, 폴더 이름이 NFD인지)
        var subdirs: [(path: String, nameIsNFD: Bool)] = []
        var foundNFD = false

        while let entry = readdir(dir) {
            let nameLen = Int(entry.pointee.d_namlen)
            let rawName: String = withUnsafePointer(to: entry.pointee.d_name) { ptr in
                ptr.withMemoryRebound(to: UInt8.self, capacity: nameLen) { buf in
                    String(bytes: UnsafeBufferPointer(start: buf, count: nameLen), encoding: .utf8) ?? ""
                }
            }
            guard !rawName.isEmpty && rawName != "." && rawName != ".." else { continue }

            // 숨김·임시 파일은 검사 제외. 과거에 잘못 붙은 태그가 있으면 정리(디렉토리는 건드리지 않음)
            if Self.shouldSkip(rawName) {
                if entry.pointee.d_type != DT_DIR {
                    let u = URL(fileURLWithPath: dirPath).appendingPathComponent(rawName)
                    if hasTag(tagName, at: u) { removeTag(tagName, from: u) }
                }
                continue
            }

            let nfc = rawName.precomposedStringWithCanonicalMapping
            let isNFD = !rawName.unicodeScalars.elementsEqual(nfc.unicodeScalars)
            let isDirectory = entry.pointee.d_type == DT_DIR

            if isDirectory {
                // 폴더 태그는 재귀 이후 (이름 NFD ‖ 내용 NFD)로 일괄 결정
                subdirs.append((dirPath + "/" + rawName, isNFD))
                if isNFD { foundNFD = true }
            } else if isNFD {
                // NFD 파일: 이름 기준 태그 부여
                let fileURL = URL(fileURLWithPath: dirPath).appendingPathComponent(nfc)
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

        // 하위 폴더 태그 결정: 폴더 이름이 NFD이거나, (재귀 시) 내용에 NFD가 있으면 태그
        for sub in subdirs {
            let contentHasNFD = recursive
                ? scanDirectory(sub.path)
                : hasTag(tagName, at: URL(fileURLWithPath: sub.path)) // 비재귀: 기존 태그를 내용 프록시로 유지
            let subURL = URL(fileURLWithPath: sub.path)
            if sub.nameIsNFD || contentHasNFD {
                addTag(tagName, to: subURL)
                foundNFD = true
            } else if hasTag(tagName, at: subURL) {
                removeTag(tagName, from: subURL)
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

        if tags.isEmpty {
            // 마지막 태그면 빈 배열 []을 남기지 않고 속성을 완전히 삭제 (CloudStorage에서 잔여 속성 방지)
            removexattr(path, key, 0)
        } else if let newData = try? PropertyListSerialization.data(fromPropertyList: tags, format: .binary, options: 0) {
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

    private func sendNotification(title: String, body: String, fallbackToAlert: Bool = false) {
        logger.notice("sendNotification: \(title, privacy: .public) - \(body, privacy: .public)")

        // 수동 변환: 알림 요약/권한 상태와 무관하게 즉각 피드백
        if fallbackToAlert {
            showAlert(title: title, body: body)
        }

        // 시스템 알림도 전송 (알림 센터 기록용)
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = fallbackToAlert ? nil : .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request) { error in
            if let error {
                logger.error("notification add failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func showAlert(title: String, body: String) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = body
            alert.alertStyle = .informational
            let button = alert.addButton(withTitle: "확인 (1)")

            // 매초 카운트다운 표시 후 자동 닫기
            var remaining = 1
            let timer = Timer(timeInterval: 1.0, repeats: true) { timer in
                remaining -= 1
                if remaining <= 0 {
                    timer.invalidate()
                    alert.window.close()
                    NSApp.stopModal(withCode: .alertFirstButtonReturn)
                } else {
                    button.title = "확인 (\(remaining))"
                }
            }
            RunLoop.current.add(timer, forMode: .modalPanel)

            alert.runModal()
            timer.invalidate()
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
