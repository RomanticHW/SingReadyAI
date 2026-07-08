import Foundation

public protocol KTVCatalogProviding: Sendable {
    func loadTracks() throws -> [KTVTrack]
}

public struct KTVCatalogRepository: KTVCatalogProviding {
    public init() {}

    public func loadTracks() throws -> [KTVTrack] {
        let data = try FixtureLoader.loadData(named: "fixtures_ktv_catalog", extension: "json")
        return try JSONDecoder().decode([KTVTrack].self, from: data)
    }

    public func trackMap() throws -> [String: KTVTrack] {
        try loadTracks().reduce(into: [:]) { $0[$1.id] = $1 }
    }
}
