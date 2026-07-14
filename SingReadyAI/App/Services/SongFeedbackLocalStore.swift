import Foundation
import SingReadyAISharedKit

struct SongFeedbackRecord: Codable, Equatable {
    var revision: UInt64
    var profile: SongFeedbackProfile
}

struct SongFeedbackLocalStore {
    enum StoreError: Error {
        case writeFailed
    }

    enum LoadResult {
        case missing
        case loaded(SongFeedbackRecord)
    }

    private let key: String
    private let defaults: UserDefaults

    init(
        defaults: UserDefaults = .standard,
        key: String = "singready.songFeedbackProfile"
    ) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> SongFeedbackProfile {
        switch loadWithStatus() {
        case .missing:
            return .empty
        case let .loaded(record):
            return record.profile
        }
    }

    func loadWithStatus() -> LoadResult {
        guard let data = defaults.data(forKey: key) else {
            return .missing
        }
        // 已存在但无法解码的记录也视为独立存储已建立，避免旧工作流快照
        // 重新写回已经被用户取消或清除的历史反馈。
        let decoder = JSONDecoder()
        if let record = try? decoder.decode(SongFeedbackRecord.self, from: data) {
            return .loaded(record)
        }
        let legacyProfile = (try? decoder.decode(SongFeedbackProfile.self, from: data)) ?? .empty
        return .loaded(SongFeedbackRecord(revision: 0, profile: legacyProfile))
    }

    func save(_ record: SongFeedbackRecord) throws {
        let data = try JSONEncoder().encode(record)
        defaults.set(data, forKey: key)
        guard defaults.data(forKey: key) == data else {
            throw StoreError.writeFailed
        }
    }

    func clear() {
        // 空记录是不含用户反馈的 tombstone；它能阻止残留旧快照在下次启动时复活已清除反馈。
        try? save(SongFeedbackRecord(revision: 0, profile: .empty))
    }
}
