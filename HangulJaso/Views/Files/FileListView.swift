import SwiftUI

struct FileListView: View {
    @Environment(HangulJasoViewModel.self) private var viewModel

    var body: some View {
        VStack(spacing: 0) {
            DropZoneView()
                .padding()

            if viewModel.totalCount > 0 {
                StatsSummaryView()

                Divider()

                List(viewModel.fileItems) { item in
                    FileRowView(item: item)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))

                Divider()

                HStack {
                    Button("지우기") {
                        viewModel.clearFiles()
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button("미리보기") {
                        viewModel.showPreviewSheet = true
                    }
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.hasNFDFiles)

                    Button("전체 변환") {
                        viewModel.convertAll()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.hasNFDFiles)
                }
                .padding()
            }
        }
        .sheet(isPresented: Binding(
            get: { viewModel.showPreviewSheet },
            set: { viewModel.showPreviewSheet = $0 }
        )) {
            ConversionPreviewSheet()
        }
    }
}
