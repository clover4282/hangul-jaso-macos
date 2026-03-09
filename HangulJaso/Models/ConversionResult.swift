import Foundation

struct ConversionResult {
    let fileItem: FileItem
    let status: Status

    enum Status {
        case converted
        case skipped
        case failed(String)
    }
}
