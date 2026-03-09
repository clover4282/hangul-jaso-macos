import SwiftUI

struct FileRowView: View {
    let item: FileItem

    var body: some View {
        HStack(spacing: 8) {
            StatusBadge(isNFD: item.isNFD)

            Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                .foregroundStyle(item.isDirectory ? .blue : .secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.originalName)
                    .fontWeight(item.isNFD ? .medium : .regular)

                if item.isNFD {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                        Text(item.normalizedName)
                            .foregroundStyle(.green)
                    }
                    .font(.caption)
                }
            }

            Spacer()

            Text(item.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
    }
}
