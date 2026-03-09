import Foundation

struct ConversionResult: Identifiable {
    enum Status {
        case converted
        case skipped
        case failed(String)
    }

    let id: UUID
    let fileItem: FileItem
    let status: Status
    let timestamp: Date

    init(id: UUID = UUID(), fileItem: FileItem, status: Status, timestamp: Date = Date()) {
        self.id = id
        self.fileItem = fileItem
        self.status = status
        self.timestamp = timestamp
    }
}
