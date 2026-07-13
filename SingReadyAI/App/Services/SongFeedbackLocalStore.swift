import Foundation
import SingReadyAISharedKit

struct SongFeedbackLocalStore {
    enum LoadResult {
        case missing
        case loaded(SongFeedbackProfile)
    }

    private let key = "singready.songFeedbackProfile"

    func load() -> SongFeedbackProfile {
        switch loadWithStatus() {
        case .missing:
            return .empty
        case let .loaded(profile):
            return profile
        }
    }

    func loadWithStatus() -> LoadResult {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return .missing
        }
        // 已存在但无法解码的记录也视为独立存储已建立，避免旧工作流快照
        // 重新写回已经被用户取消或清除的历史反馈。
        let profile = (try? JSONDecoder().decode(SongFeedbackProfile.self, from: data)) ?? .empty
        return .loaded(profile)
    }

    func save(_ profile: SongFeedbackProfile) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    func clear() {
        // 空记录是不含用户反馈的 tombstone；它能阻止残留旧快照在下次启动时复活已清除反馈。
        save(.empty)
    }
}
