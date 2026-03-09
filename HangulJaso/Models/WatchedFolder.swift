import Foundation

struct WatchedFolder: Codable, Identifiable {
    let id: UUID
    let path: String
    var enabled: Bool
    var autoConvert: Bool

    init(
        id: UUID = UUID(),
        path: String,
        enabled: Bool = true,
        autoConvert: Bool = false
    ) {
        self.id = id
        self.path = path
        self.enabled = enabled
        self.autoConvert = autoConvert
    }

    var url: URL { URL(fileURLWithPath: path) }
    var displayName: String { url.lastPathComponent }
}
