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
        guard let items = FIFinderSyncController.default().selectedItemURLs(), !items.isEmpty else { return }

        for itemURL in items {
            requestConversion(itemURL)
        }

        logger.notice("convert request sent for \(items.count, privacy: .public) items")
    }

    // MARK: - Helpers

    /// Send conversion request to main app via DistributedNotificationCenter
    private func requestConversion(_ url: URL) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.clover4282.hanguljaso.convertRequest"),
            object: url.path,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}
