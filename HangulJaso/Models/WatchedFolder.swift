import Foundation

struct WatchedFolder: Codable, Identifiable {
    let id: UUID
    let path: String
    var enabled: Bool

    init(
        id: UUID = UUID(),
        path: String,
        enabled: Bool = true
    ) {
        self.id = id
        self.path = path
        self.enabled = enabled
    }

    var url: URL { URL(fileURLWithPath: path) }
    var displayName: String { url.lastPathComponent }
}
