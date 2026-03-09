import SwiftUI

struct SettingsContainerView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                GeneralSettingsView()
                Divider()
                MonitorSettingsView()
                Divider()
                FinderSettingsView()
            }
            .padding()
        }
    }
}
