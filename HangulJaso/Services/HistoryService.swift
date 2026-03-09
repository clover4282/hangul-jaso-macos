import Foundation

final class HistoryService {

    private let fileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("HangulJaso", isDirectory: true)
        return appDir.appendingPathComponent(Constants.Defaults.historyFileName)
    }()

    private let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = .prettyPrinted
        return enc
    }()

    private let decoder: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }()

    // MARK: - Private helpers

    private func ensureDirectoryExists() {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func load() -> [ConversionRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? decoder.decode([ConversionRecord].self, from: data)) ?? []
    }

    private func save(_ records: [ConversionRecord]) {
        ensureDirectoryExists()
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Public API

    func addEntry(_ entry: ConversionRecord) {
        var records = load()
        records.insert(entry, at: 0)
        if records.count > Constants.Defaults.maxHistoryEntries {
            records = Array(records.prefix(Constants.Defaults.maxHistoryEntries))
        }
        save(records)
    }

    func addEntries(_ entries: [ConversionRecord]) {
        guard !entries.isEmpty else { return }
        var records = load()
        records.insert(contentsOf: entries, at: 0)
        if records.count > Constants.Defaults.maxHistoryEntries {
            records = Array(records.prefix(Constants.Defaults.maxHistoryEntries))
        }
        save(records)
    }

    func getHistory() -> [ConversionRecord] {
        load()
    }

    func markUndone(id: UUID) {
        var records = load()
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index] = ConversionRecord(
            id: records[index].id,
            timestamp: records[index].timestamp,
            originalName: records[index].originalName,
            convertedName: records[index].convertedName,
            path: records[index].path,
            undone: true
        )
        save(records)
    }

    func clearHistory() {
        save([])
    }
}
