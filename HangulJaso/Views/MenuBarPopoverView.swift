import SwiftUI

struct MenuBarPopoverView: View {
    @Environment(HangulJasoViewModel.self) private var viewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 12) {
            Text("한글 자소 정리")
                .font(.headline)

            DropZoneView()
                .frame(height: 100)

            if viewModel.totalCount > 0 {
                StatsSummaryView()

                HStack {
                    Button("전체 변환") {
                        viewModel.convertAll()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.hasNFDFiles)
                }
            }

            Divider()

            Button("메인 윈도우 열기") {
                openWindow(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .frame(width: 280)
    }
}
