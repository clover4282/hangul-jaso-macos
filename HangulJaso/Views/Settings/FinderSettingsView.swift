import SwiftUI

struct FinderSettingsView: View {
    @Environment(HangulJasoViewModel.self) private var viewModel
    @State private var installResult: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Finder 연동")
                .font(.headline)

            Text("Finder 우클릭 메뉴에 Quick Action을 추가합니다")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Quick Action 설치") {
                    let result = viewModel.workflowInstaller.installAll()
                    if result.failed.isEmpty {
                        installResult = "✓ \(result.installed.count)개 Quick Action 설치 완료"
                    } else {
                        installResult = "일부 설치 실패: \(result.failed.joined(separator: ", "))"
                    }
                }
                .buttonStyle(.borderedProminent)

                Button("제거") {
                    viewModel.workflowInstaller.uninstallAll()
                    installResult = "Quick Action이 제거되었습니다"
                }
                .buttonStyle(.bordered)
            }

            if let result = installResult {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("설치되는 항목:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("• 한글 파일명 NFC 변환")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("• 한글 파일명 상태 확인")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
