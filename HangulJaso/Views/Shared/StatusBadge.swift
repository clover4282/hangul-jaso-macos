import SwiftUI

struct StatusBadge: View {
    let isNFD: Bool

    var body: some View {
        Circle()
            .fill(isNFD ? Color.red : Color.green)
            .frame(width: 8, height: 8)
            .help(isNFD ? "NFD (분해형)" : "NFC (조합형)")
    }
}
