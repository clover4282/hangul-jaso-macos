import Foundation

final class NFCService {

    func scan(urls: [URL]) -> [FileItem] {
        var items: [FileItem] = []
        let fm = FileManager.default

        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }

            if isDir.boolValue {
                // Recursive scan using FileManager.enumerator
                guard let enumerator = fm.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                var found: [FileItem] = []
                while let fileURL = enumerator.nextObject() as? URL {
                    let name = fileURL.lastPathComponent
                    let isSubDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                    found.append(FileItem(
                        url: fileURL,
                        originalName: name,
                        isDirectory: isSubDir
                    ))
                }
                // Sort by depth descending (deepest first for safe renaming)
                found.sort { $0.url.pathComponents.count > $1.url.pathComponents.count }
                items.append(contentsOf: found)

                // Also add the root directory itself
                let rootName = url.lastPathComponent
                items.append(FileItem(
                    url: url,
                    originalName: rootName,
                    isDirectory: true
                ))
            } else {
                let name = url.lastPathComponent
                items.append(FileItem(
                    url: url,
                    originalName: name,
                    isDirectory: false
                ))
            }
        }

        return items
    }

    func convert(item: FileItem) -> ConversionResult {
        guard item.isNFD else {
            return ConversionResult(fileItem: item, status: .skipped)
        }

        let newURL = item.parentURL.appendingPathComponent(item.normalizedName)
        let fm = FileManager.default

        // Check for name collision
        if fm.fileExists(atPath: newURL.path) {
            return ConversionResult(fileItem: item, status: .failed("같은 이름의 파일이 이미 존재합니다"))
        }

        do {
            try fm.moveItem(at: item.url, to: newURL)
            return ConversionResult(fileItem: item, status: .converted)
        } catch {
            return ConversionResult(fileItem: item, status: .failed(error.localizedDescription))
        }
    }

    func convertAll(items: [FileItem]) -> [ConversionResult] {
        // Items should already be sorted deepest-first
        items.map { convert(item: $0) }
    }

    func undo(record: ConversionRecord) -> Bool {
        let parentURL = URL(fileURLWithPath: record.path)
        let currentURL = parentURL.appendingPathComponent(record.convertedName)
        let originalURL = parentURL.appendingPathComponent(record.originalName)
        let fm = FileManager.default

        guard fm.fileExists(atPath: currentURL.path) else { return false }
        guard !fm.fileExists(atPath: originalURL.path) else { return false }

        do {
            try fm.moveItem(at: currentURL, to: originalURL)
            return true
        } catch {
            return false
        }
    }
}
