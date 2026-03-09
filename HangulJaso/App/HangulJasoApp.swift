import SwiftUI

@main
struct HangulJasoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var viewModel = HangulJasoViewModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopoverView()
                .environment(viewModel)
        } label: {
            let image: NSImage = {
                guard let img = NSImage(named: "MenuBarIcon") else {
                    return NSImage(systemSymbolName: "textformat.abc", accessibilityDescription: nil)!
                }
                img.size = NSSize(width: 18, height: 18)
                return img
            }()
            Image(nsImage: image)
        }
        .menuBarExtraStyle(.window)

        Window("한글 자소 정리", id: "main") {
            MainContentView()
                .environment(viewModel)
                .frame(minWidth: 600, minHeight: 450)
        }
        .windowResizability(.contentMinSize)
    }
}
