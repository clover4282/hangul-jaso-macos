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
        // 도구막대 클릭 시 팝업 없이 바로 실행
        if menuKind == .toolbarItemMenu {
            convertToNFC(nil)
            return NSMenu()
        }

        let menu = NSMenu(title: "")
        let convertItem = NSMenuItem(
            title: "한글 파일명 NFC 변환",
            action: #selector(convertToNFC(_:)),
            keyEquivalent: ""
        )
        convertItem.image = Self.flagImage(size: 16)
        menu.addItem(convertItem)

        return menu
    }

    // MARK: - Actions

    @objc func convertToNFC(_ sender: AnyObject?) {
        let items = FIFinderSyncController.default().selectedItemURLs()
        let target = FIFinderSyncController.default().targetedURL()

        if let items, !items.isEmpty {
            // 선택 항목을 App Group UserDefaults에 저장
            savePaths(items.map(\.path))
        } else if let target {
            savePaths([target.path])
        } else {
            // CloudStorage(File Provider): selectedItemURLs/targetedURL 모두 nil
            // → 메인 앱이 AppleScript로 Finder 선택 항목을 가져오도록 표시
            savePaths(["__FINDER_SELECTION__"])
        }

        // Darwin notification으로 메인 앱에 신호 전송 (샌드박스 제약 없음)
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName("com.clover4282.hanguljaso.finderConvert" as CFString), nil, nil, true)

        logger.notice("convert request sent via Darwin notification")
    }

    private static let suiteName = "9P8DG7976Y.com.clover4282.hanguljaso"
    private static let pendingKey = "pendingConvertPaths"

    private func savePaths(_ paths: [String]) {
        guard let defaults = UserDefaults(suiteName: Self.suiteName) else { return }
        // 기존 요청에 추가 (read-then-delete race 방지)
        var existing = defaults.stringArray(forKey: Self.pendingKey) ?? []
        existing.append(contentsOf: paths)
        defaults.set(existing, forKey: Self.pendingKey)
        defaults.synchronize()
    }
}
