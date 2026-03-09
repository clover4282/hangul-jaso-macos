import SwiftUI

struct HistoryListView: View {
    @Environment(HangulJasoViewModel.self) private var viewModel: HangulJasoViewModel

    private var history: [ConversionRecord] { viewModel.history }

    var body: some View {
        VStack(spacing: 0) {
            if history.isEmpty {
                ContentUnavailableView {
                    Label("이력 없음", systemImage: "clock")
                } description: {
                    Text("변환 이력이 여기에 표시됩니다")
                }
            } else {
                List {
                    ForEach(history) { record in
                        HistoryRowView(record: record, onUndo: {
                            viewModel.undoRecord(record)
                        })
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))

                Divider()

                HStack {
                    Text("\(history.count)개 이력")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("이력 지우기") {
                        viewModel.clearHistory()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding()
            }
        }
    }
}

private struct HistoryRowView: View {
    let record: ConversionRecord
    let onUndo: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(record.originalName)
                        .strikethrough(record.undone)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                    Text(record.convertedName)
                        .foregroundStyle(record.undone ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.green))
                }
                .font(.callout)

                HStack {
                    Text(record.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    Text("·")
                    Text(record.timestamp, style: .relative)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if !record.undone {
                Button("실행취소", action: onUndo)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Text("취소됨")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
