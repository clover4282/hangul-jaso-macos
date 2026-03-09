import SwiftUI

@main
struct HangulJasoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var viewModel = HangulJasoViewModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenuView()
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
        .menuBarExtraStyle(.menu)

        Window("한글 자소 정리", id: "main") {
            MainContentView()
                .environment(viewModel)
                .frame(minWidth: 600, minHeight: 450)
        }
        .windowResizability(.contentMinSize)
    }
}

private struct MenuBarMenuView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("설정 열기") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("종료") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
