import Foundation

// Thin persistence helper for Codable state we want to inspect / back up
// outside UserDefaults. Files live under the sandboxed
// `Application Support/TSOClient/` directory; the directory is created
// on first write. Reads return nil for any error (missing file, parse
// error, etc.); writes log on failure but never throw.
protocol JSONFileStoring {
    func load<T: Decodable>(_ type: T.Type, from filename: String) -> T?
    func save<T: Encodable>(_ value: T, to filename: String)
}

struct JSONFileStore: JSONFileStoring {
    let appSubdirectory: String
    let logger: Logger

    init(appSubdirectory: String = "TSOClient",
         logger: Logger = ConsoleLogger()) {
        self.appSubdirectory = appSubdirectory
        self.logger = logger
    }

    func load<T: Decodable>(_ type: T.Type, from filename: String) -> T? {
        guard let url = fileURL(filename, createDirectory: false) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            logger.log("[JSONFileStore] decode failed for \(filename): \(error)")
            return nil
        }
    }

    func save<T: Encodable>(_ value: T, to filename: String) {
        guard let url = fileURL(filename, createDirectory: true) else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(value)
            try data.write(to: url, options: [.atomic])
        } catch {
            logger.log("[JSONFileStore] write failed for \(filename): \(error)")
        }
    }

    private func fileURL(_ filename: String, createDirectory: Bool) -> URL? {
        do {
            let appSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: createDirectory
            )
            let dir = appSupport.appendingPathComponent(appSubdirectory, isDirectory: true)
            if createDirectory {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            return dir.appendingPathComponent(filename, isDirectory: false)
        } catch {
            logger.log("[JSONFileStore] cannot resolve path for \(filename): \(error)")
            return nil
        }
    }
}
