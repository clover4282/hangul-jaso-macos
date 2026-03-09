import SwiftUI

struct MainContentView: View {
    @Environment(HangulJasoViewModel.self) private var viewModel

    var body: some View {
        SettingsContainerView()
            .frame(minWidth: 600, minHeight: 450)
    }
}
