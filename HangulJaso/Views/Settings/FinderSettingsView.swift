import SwiftUI

struct FinderSettingsView: View {
    @Environment(HangulJasoViewModel.self) private var viewModel
    @State private var installResult: String?
    @State private var workflowStatus: [String: Bool] = [:]
    @State private var extensionEnabled = false

    private let workflowNames = [
        "한글 파일명 NFC 변환"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Finder 연동")
                .font(.headline)

            // MARK: - Finder Sync Extension 상태
            VStack(alignment: .leading, spacing: 8) {
                Text("Finder 확장 프로그램")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                StatusRow(
                    label: "컨텍스트 메뉴 & 도구막대",
                    isOK: extensionEnabled,
                    okText: "활성",
                    failText: "비활성"
                )

                if !extensionEnabled {
                    Text("시스템 설정 → 개인정보 보호 및 보안 → 확장 프로그램 → 추가된 확장 프로그램에서 HangulJaso의 Finder 확장을 활성화하세요.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))

            // MARK: - Quick Action 상태
            VStack(alignment: .leading, spacing: 8) {
                Text("Quick Action (빠른 동작)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ForEach(workflowNames, id: \.self) { name in
                    StatusRow(
                        label: name,
                        isOK: workflowStatus[name] ?? false,
                        okText: "설치됨",
                        failText: "미설치"
                    )
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))

            // MARK: - 액션
            HStack(spacing: 12) {
                Button("Quick Action 설치") {
                    let result = viewModel.workflowInstaller.installAll()
                    if result.failed.isEmpty {
                        installResult = "\(result.installed.count)개 Quick Action 설치 완료"
                    } else {
                        installResult = "일부 설치 실패: \(result.failed.joined(separator: ", "))"
                    }
                    refreshStatus()
                }
                .buttonStyle(.borderedProminent)

                Button("제거") {
                    viewModel.workflowInstaller.uninstallAll()
                    installResult = "Quick Action이 제거되었습니다"
                    refreshStatus()
                }
                .buttonStyle(.bordered)

                Spacer()
            }

            if let result = installResult {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // MARK: - 사용 방법
            VStack(alignment: .leading, spacing: 8) {
                Text("사용 방법")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    usageStep("cursorarrow.click.2", "Finder에서 파일/폴더를 우클릭 → \"한글 파일명 NFC 변환\" (Finder 확장)")
                    usageStep("macwindow", "Finder 보기 → 도구막대 사용자화 → \"한글 NFC 변환\"을 도구막대로 드래그")
                    usageStep("bolt.fill", "또는 우클릭 → 빠른 동작 → \"한글 파일명 NFC 변환\" (Quick Action)")
                }
                .font(.callout)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { refreshStatus() }
    }

    private func usageStep(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .frame(width: 16)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func refreshStatus() {
        for name in workflowNames {
            workflowStatus[name] = viewModel.workflowInstaller.isInstalled(name: name)
        }
        // Check Finder Sync Extension registration
        extensionEnabled = checkFinderSyncEnabled()
    }

    private func checkFinderSyncEnabled() -> Bool {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = ["-m", "-p", "com.apple.FinderSync"]
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output.contains("com.clover4282.hanguljaso.finder")
    }
}

private struct StatusRow: View {
    let label: String
    let isOK: Bool
    let okText: String
    let failText: String

    var body: some View {
        HStack {
            Image(systemName: isOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(isOK ? .green : .red)
                .font(.body)
            Text(label)
                .font(.callout)
            Spacer()
            Text(isOK ? okText : failText)
                .font(.caption)
                .foregroundStyle(isOK ? .green : .red)
        }
    }
}
