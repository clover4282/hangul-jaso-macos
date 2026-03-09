import Cocoa
import FinderSync
import os.log

private let logger = Logger(subsystem: "com.clover4282.hanguljaso.finder", category: "FinderSync")

class FinderSyncExtension: FIFinderSync {

    override init() {
        super.init()

        // Monitor user directories
        let realHome: String
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            realHome = String(cString: dir)
        } else {
            realHome = "/Users/\(NSUserName())"
        }
        let homeURL = URL(fileURLWithPath: realHome, isDirectory: true)
        FIFinderSyncController.default().directoryURLs = [
            homeURL.appendingPathComponent("Downloads", isDirectory: true),
            homeURL.appendingPathComponent("Desktop", isDirectory: true),
            homeURL.appendingPathComponent("Documents", isDirectory: true)
        ]

        logger.notice("FinderSync init OK")
    }

    // MARK: - Context Menu

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "")

        let convertItem = NSMenuItem(
            title: "한글 파일명 NFC 변환",
            action: #selector(convertToNFC(_:)),
            keyEquivalent: ""
        )
        convertItem.image = NSImage(systemSymbolName: "textformat.abc", accessibilityDescription: nil)
        menu.addItem(convertItem)

        let checkItem = NSMenuItem(
            title: "한글 파일명 상태 확인",
            action: #selector(checkStatus(_:)),
            keyEquivalent: ""
        )
        checkItem.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        menu.addItem(checkItem)

        return menu
    }

    // MARK: - Actions

    @objc func convertToNFC(_ sender: AnyObject?) {
        guard let items = FIFinderSyncController.default().selectedItemURLs(), !items.isEmpty else { return }

        var converted = 0
        var failed = 0

        for itemURL in items {
            if convertItemToNFC(itemURL) { converted += 1 } else { failed += 1 }
        }

        logger.notice("convert: \(converted, privacy: .public) ok, \(failed, privacy: .public) skip")

        let notification = NSUserNotification()
        notification.title = "한글 파일명 NFC 변환"
        if converted > 0 {
            notification.informativeText = "\(converted)개 파일 변환 완료" + (failed > 0 ? " (\(failed)개 건너뜀)" : "")
        } else {
            notification.informativeText = "변환할 NFD 파일이 없습니다"
        }
        NSUserNotificationCenter.default.deliver(notification)
    }

    @objc func checkStatus(_ sender: AnyObject?) {
        guard let items = FIFinderSyncController.default().selectedItemURLs(), !items.isEmpty else { return }

        var nfdFiles: [String] = []
        var nfcCount = 0

        for itemURL in items {
            if let actualName = getActualFilename(at: itemURL.path) {
                let nfc = actualName.precomposedStringWithCanonicalMapping
                if !actualName.unicodeScalars.elementsEqual(nfc.unicodeScalars) {
                    nfdFiles.append(actualName)
                } else {
                    nfcCount += 1
                }
            }
        }

        let notification = NSUserNotification()
        notification.title = "한글 파일명 상태 확인"
        if nfdFiles.isEmpty {
            notification.informativeText = "선택한 \(nfcCount)개 파일 모두 NFC (정상)"
        } else {
            notification.informativeText = "NFD 파일 \(nfdFiles.count)개: \(nfdFiles.prefix(3).joined(separator: ", "))" + (nfdFiles.count > 3 ? " 외 \(nfdFiles.count - 3)개" : "")
        }
        NSUserNotificationCenter.default.deliver(notification)
    }

    // MARK: - Helpers

    private func getActualFilename(at path: String) -> String? {
        var attrList = attrlist()
        attrList.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrList.commonattr = attrgroup_t(ATTR_CMN_NAME)

        let bufferSize = 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 4)
        defer { buffer.deallocate() }

        guard getattrlist(path, &attrList, buffer, bufferSize, 0) == 0 else { return nil }

        let attrRefPtr = buffer.advanced(by: MemoryLayout<UInt32>.size)
        let attrRef = attrRefPtr.assumingMemoryBound(to: attrreference_t.self).pointee
        let namePtr = attrRefPtr.advanced(by: Int(attrRef.attr_dataoffset))
        return String(cString: namePtr.assumingMemoryBound(to: CChar.self))
    }

    private func convertItemToNFC(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        guard exists else { return false }

        let isNFD: Bool
        if let actualName = getActualFilename(at: url.path) {
            let nfc = actualName.precomposedStringWithCanonicalMapping
            isNFD = !actualName.unicodeScalars.elementsEqual(nfc.unicodeScalars)
        } else {
            isNFD = false
        }

        // For directories, always send request (to convert contents recursively)
        // For files, only send if the name is NFD
        guard isDir.boolValue || isNFD else { return false }

        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.clover4282.hanguljaso.convertRequest"),
            object: url.path,
            userInfo: nil,
            deliverImmediately: true
        )
        logger.notice("convert request sent: \(url.lastPathComponent, privacy: .public) isDir=\(isDir.boolValue, privacy: .public)")
        return true
    }

    private func removeTag(_ tag: String, from url: URL) {
        let key = "com.apple.metadata:_kMDItemUserTags"
        let path = url.path

        // Read existing tags via xattr
        let size = getxattr(path, key, nil, 0, 0, 0)
        guard size > 0 else { return }

        var data = Data(count: size)
        let readSize = data.withUnsafeMutableBytes { ptr in
            getxattr(path, key, ptr.baseAddress, size, 0, 0)
        }
        guard readSize > 0 else { return }

        // Parse plist
        guard var tags = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else { return }
        let before = tags.count
        tags.removeAll { $0.hasPrefix(tag) }
        guard tags.count < before else { return }

        // Write back
        if let newData = try? PropertyListSerialization.data(fromPropertyList: tags, format: .binary, options: 0) {
            newData.withUnsafeBytes { ptr in
                _ = setxattr(path, key, ptr.baseAddress, newData.count, 0, 0)
            }
        }
    }
}
