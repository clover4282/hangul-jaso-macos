import SwiftUI

struct MainContentView: View {
    @Environment(HangulJasoViewModel.self) private var viewModel

    var body: some View {
        @Bindable var vm = viewModel

        TabView(selection: $vm.currentTab) {
            FileListView()
                .tabItem {
                    Label(AppTab.files.title, systemImage: AppTab.files.icon)
                }
                .tag(AppTab.files)

            HistoryListView()
                .tabItem {
                    Label(AppTab.history.title, systemImage: AppTab.history.icon)
                }
                .tag(AppTab.history)

            SettingsContainerView()
                .tabItem {
                    Label(AppTab.settings.title, systemImage: AppTab.settings.icon)
                }
                .tag(AppTab.settings)
        }
        .frame(minWidth: 600, minHeight: 450)
    }
}
