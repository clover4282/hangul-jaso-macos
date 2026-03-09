import Foundation

struct FileItem: Identifiable {
    let id: UUID
    let url: URL
    let originalName: String
    let isDirectory: Bool

    init(id: UUID = UUID(), url: URL, originalName: String, isDirectory: Bool) {
        self.id = id
        self.url = url
        self.originalName = originalName
        self.isDirectory = isDirectory
    }

    var normalizedName: String { originalName.nfc }
    var isNFD: Bool { originalName.isNFD }
    var parentURL: URL { url.deletingLastPathComponent() }
}
