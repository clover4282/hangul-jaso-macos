import SwiftUI

struct SettingsContainerView: View {
    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "v\(version) (\(build))"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                GeneralSettingsView()
                Divider()
                MonitorSettingsView()
                Divider()
                FinderSettingsView()
                Divider()
                Text("한글 자소 정리 \(appVersion)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
            .padding()
        }
    }
}
