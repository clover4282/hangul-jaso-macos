import SwiftUI

struct StatsSummaryView: View {
    @Environment(HangulJasoViewModel.self) private var viewModel

    var body: some View {
        HStack(spacing: 16) {
            StatItem(label: "전체", count: viewModel.totalCount, color: .primary)
            Divider().frame(height: 16)
            StatItem(label: "NFD", count: viewModel.nfdCount, color: .red)
            Divider().frame(height: 16)
            StatItem(label: "NFC", count: viewModel.nfcCount, color: .green)
        }
        .font(.callout)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

private struct StatItem: View {
    let label: String
    let count: Int
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(.secondary)
            Text("\(count)")
                .fontWeight(.semibold)
                .foregroundStyle(color)
        }
    }
}
