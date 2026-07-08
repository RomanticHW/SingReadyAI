import Foundation

public struct AppGroupStore: Sendable {
    public static let defaultAppGroupID = "group.com.example.SingReadyAI"

    private let appGroupIdentifier: String
    private let fallbackDirectory: URL?

    public init(
        appGroupIdentifier: String = AppGroupStore.defaultAppGroupID,
        fallbackDirectory: URL? = nil
    ) {
        self.appGroupIdentifier = appGroupIdentifier
        self.fallbackDirectory = fallbackDirectory
    }

    public func savePendingImport(_ payload: PendingImportPayload) throws {
        var payloads = try loadPendingImports()
        payloads.insert(payload, at: 0)
        payloads = Array(payloads.prefix(20))
        try write(payloads)
    }

    public func loadPendingImports() throws -> [PendingImportPayload] {
        let url = try storeFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([PendingImportPayload].self, from: data)
    }

    public func clearPendingImports() throws {
        try write([])
    }

    public func removePendingImport(id: UUID) throws {
        let remaining = try loadPendingImports().filter { $0.id != id }
        try write(remaining)
    }

    public func storeDirectoryURL() throws -> URL {
        if let appGroupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            return appGroupURL
        }
        if let fallbackDirectory {
            return fallbackDirectory
        }
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent("SingReadyAI", isDirectory: true)
    }

    public func isUsingFallbackStore() -> Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) == nil
    }

    private func storeFileURL() throws -> URL {
        let directory = try storeDirectoryURL()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory.appendingPathComponent("pending_imports.json")
    }

    private func write(_ payloads: [PendingImportPayload]) throws {
        let url = try storeFileURL()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payloads)
        try data.write(to: url, options: [.atomic])
    }
}

public struct LocalJSONStore<Value: Codable>: Sendable {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load(default defaultValue: Value) throws -> Value {
        guard FileManager.default.fileExists(atPath: url.path) else { return defaultValue }
        return try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
    }

    public func save(_ value: Value) throws {
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: [.atomic])
    }
}
