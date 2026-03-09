import Foundation

struct ConversionRecord: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let originalName: String
    let convertedName: String
    let path: String
    var undone: Bool

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        originalName: String,
        convertedName: String,
        path: String,
        undone: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.originalName = originalName
        self.convertedName = convertedName
        self.path = path
        self.undone = undone
    }
}
