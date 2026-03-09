import SwiftUI

struct ConversionPreviewSheet: View {
    @Environment(HangulJasoViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text("변환 미리보기")
                .font(.headline)
                .padding()

            Text("\(viewModel.nfdCount)개 파일")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Divider()
                .padding(.vertical, 8)

            List(viewModel.nfdItems) { item in
                HStack {
                    VStack(alignment: .leading) {
                        Text(item.originalName)
                            .foregroundStyle(.red)
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down")
                                .font(.caption2)
                            Text(item.normalizedName)
                                .foregroundStyle(.green)
                        }
                        .font(.callout)
                    }

                    Spacer()

                    Image(systemName: item.isDirectory ? "folder" : "doc")
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 200)

            Divider()

            HStack {
                Button("취소") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("변환 실행") {
                    viewModel.convertAll()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 450, height: 400)
    }
}
