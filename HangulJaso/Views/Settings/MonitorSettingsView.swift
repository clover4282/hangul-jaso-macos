import SwiftUI

struct MonitorSettingsView: View {
    @Environment(HangulJasoViewModel.self) private var viewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("폴더 감시")
                    .font(.headline)

                Spacer()

                Button {
                    selectFolder()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if viewModel.watchedFolders.isEmpty {
                Text("감시할 폴더를 추가하세요")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                ForEach(viewModel.watchedFolders) { folder in
                    HStack {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.blue)

                        VStack(alignment: .leading) {
                            Text(folder.displayName)
                                .font(.callout)
                            Text(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Toggle("자동 변환", isOn: Binding(
                            get: { folder.autoConvert },
                            set: { _ in viewModel.toggleAutoConvert(folder) }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.small)

                        Button {
                            viewModel.removeWatchedFolder(folder)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "추가"
        panel.message = "감시할 폴더를 선택하세요"

        if panel.runModal() == .OK, let url = panel.url {
            viewModel.addWatchedFolder(url: url)
        }
    }
}
