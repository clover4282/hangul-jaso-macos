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
