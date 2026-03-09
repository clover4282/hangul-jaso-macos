import SwiftUI

struct GeneralSettingsView: View {
    @Environment(HangulJasoViewModel.self) private var viewModel
    @AppStorage(Constants.UserDefaultsKeys.notifyOnAutoConvert) private var notifyOnAutoConvert = true
    @AppStorage(Constants.UserDefaultsKeys.startAtLogin) private var startAtLogin = false
    @AppStorage(Constants.UserDefaultsKeys.recursiveScan) private var recursiveScan = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("일반")
                .font(.headline)

            Toggle("로그인 시 자동 시작", isOn: $startAtLogin)
                .onChange(of: startAtLogin) { _, newValue in
                    viewModel.updateLoginItem(enabled: newValue)
                }

            Toggle("자동 변환 시 알림", isOn: $notifyOnAutoConvert)

            Toggle("하위 폴더 재귀 스캔", isOn: $recursiveScan)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
