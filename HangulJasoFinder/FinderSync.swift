import Cocoa
import FinderSync
import os.log

private let logger = Logger(subsystem: "com.clover4282.hanguljaso.finder", category: "FinderSync")

class FinderSyncExtension: FIFinderSync {

    override init() {
        super.init()

        // Monitor home directory so context menu appears everywhere
        let realHome: String
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            realHome = String(cString: dir)
        } else {
            realHome = "/Users/\(NSUserName())"
        }
        let homeURL = URL(fileURLWithPath: realHome, isDirectory: true)
        FIFinderSyncController.default().directoryURLs = [homeURL]

        logger.notice("FinderSync init OK — watching \(realHome, privacy: .public)")
    }

    // MARK: - Toolbar

    override var toolbarItemName: String { "한글 NFC 변환" }

    override var toolbarItemToolTip: String { "선택한 파일의 한글 파일명을 NFC로 변환" }

    override var toolbarItemImage: NSImage {
        Self.flagImage(size: 18)
    }

    /// 태극기 이모지로 아이콘 생성
    private static func flagImage(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let str = NSAttributedString(
                string: "\u{1F1F0}\u{1F1F7}",
                attributes: [.font: NSFont.systemFont(ofSize: size * 0.85)]
            )
            let strSize = str.size()
            let origin = NSPoint(x: (rect.width - strSize.width) / 2, y: (rect.height - strSize.height) / 2)
            str.draw(at: origin)
            return true
        }
    }

    // MARK: - Context Menu

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        // 컨텍스트 메뉴·툴바 클릭 모두 변환/검사 두 항목을 팝업으로 표시
        let menu = NSMenu(title: "")

        let convertItem = NSMenuItem(
            title: "한글 파일명 NFC 변환",
            action: #selector(convertToNFC(_:)),
            keyEquivalent: ""
        )
        convertItem.image = Self.flagImage(size: 16)
        menu.addItem(convertItem)

        let scanItem = NSMenuItem(
            title: "한글 NFD 검사",
            action: #selector(scanForNFD(_:)),
            keyEquivalent: ""
        )
        scanItem.image = Self.flagImage(size: 16)
        menu.addItem(scanItem)

        return menu
    }

    // MARK: - Actions

    @objc func convertToNFC(_ sender: AnyObject?) {
        sendRequest(key: Self.pendingConvertKey, notification: "com.clover4282.hanguljaso.finderConvert")
    }

    @objc func scanForNFD(_ sender: AnyObject?) {
        sendRequest(key: Self.pendingScanKey, notification: "com.clover4282.hanguljaso.finderScan")
    }

    /// 선택 항목 → 타깃 폴더 → Finder 열린 창 순으로 대상 경로를 잡아 App Group에 저장하고
    /// Darwin notification으로 메인 앱에 신호 전송 (샌드박스 제약 없음)
    private func sendRequest(key: String, notification: String) {
        let items = FIFinderSyncController.default().selectedItemURLs()
        let target = FIFinderSyncController.default().targetedURL()

        let paths: [String]
        if let items, !items.isEmpty {
            paths = items.map(\.path)
        } else if let target {
            paths = [target.path]
        } else {
            // CloudStorage(File Provider): selectedItemURLs/targetedURL 모두 nil
            // → 메인 앱이 AppleScript로 Finder 선택 항목을 가져오도록 표시
            paths = ["__FINDER_SELECTION__"]
        }
        savePaths(paths, key: key)

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName(notification as CFString), nil, nil, true)

        logger.notice("request sent: \(notification, privacy: .public)")
    }

    private static let suiteName = "9P8DG7976Y.com.clover4282.hanguljaso"
    private static let pendingConvertKey = "pendingConvertPaths"
    private static let pendingScanKey = "pendingScanPaths"

    private func savePaths(_ paths: [String], key: String) {
        guard let defaults = UserDefaults(suiteName: Self.suiteName) else { return }
        // 기존 요청에 추가 (read-then-delete race 방지)
        var existing = defaults.stringArray(forKey: key) ?? []
        existing.append(contentsOf: paths)
        defaults.set(existing, forKey: key)
        defaults.synchronize()
    }
}
