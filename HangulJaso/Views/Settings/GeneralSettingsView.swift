import SwiftUI

struct GeneralSettingsView: View {
    @Environment(HangulJasoViewModel.self) private var viewModel
    @AppStorage(Constants.UserDefaultsKeys.autoConvertOnDrop) private var autoConvertOnDrop = false
    @AppStorage(Constants.UserDefaultsKeys.showConversionPreview) private var showConversionPreview = true
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

            Toggle("드래그 시 자동 변환", isOn: $autoConvertOnDrop)

            Toggle("변환 전 미리보기 표시", isOn: $showConversionPreview)

            Toggle("자동 변환 시 알림", isOn: $notifyOnAutoConvert)

            Toggle("하위 폴더 재귀 스캔", isOn: $recursiveScan)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
