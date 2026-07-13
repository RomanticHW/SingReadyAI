import Foundation

public struct StartTipsContent: Equatable, Sendable {
    public let heroTitle: String
    public let heroSubtitle: String
    public let tags: [String]
    public let openingTitle: String
    public let openingLines: [String]
    public let fallbackTitle: String
    public let fallbackLines: [String]
    public let sharingTitle: String
    public let sharingLines: [String]

    public init(
        heroTitle: String,
        heroSubtitle: String,
        tags: [String],
        openingTitle: String,
        openingLines: [String],
        fallbackTitle: String,
        fallbackLines: [String],
        sharingTitle: String,
        sharingLines: [String]
    ) {
        self.heroTitle = heroTitle
        self.heroSubtitle = heroSubtitle
        self.tags = tags
        self.openingTitle = openingTitle
        self.openingLines = openingLines
        self.fallbackTitle = fallbackTitle
        self.fallbackLines = fallbackLines
        self.sharingTitle = sharingTitle
        self.sharingLines = sharingLines
    }

    public var allVisibleCopy: [String] {
        [heroTitle, heroSubtitle] + tags + [openingTitle] + openingLines
            + [fallbackTitle] + fallbackLines + [sharingTitle] + sharingLines
    }
}

public struct StartTipsContentPolicy: Sendable {
    private let selectionPolicy: StartTipsSelectionPolicy

    public init(selectionPolicy: StartTipsSelectionPolicy = StartTipsSelectionPolicy()) {
        self.selectionPolicy = selectionPolicy
    }

    public func content(for plan: SongPlan) -> StartTipsContent {
        content(for: plan.scenario, selection: selectionPolicy.selection(for: plan))
    }

    public func content(for scenario: KTVScenario) -> StartTipsContent {
        content(
            for: scenario,
            selection: StartTipsSelection(opening: nil, chorus: nil, closing: nil, easyFallback: nil)
        )
    }

    private func content(for scenario: KTVScenario, selection: StartTipsSelection) -> StartTipsContent {
        StartTipsContent(
            heroTitle: heroTitle(for: scenario),
            heroSubtitle: heroSubtitle(for: scenario),
            tags: tags(for: scenario),
            openingTitle: openingTitle(for: scenario),
            openingLines: openingLines(for: scenario, selection: selection),
            fallbackTitle: fallbackTitle(for: scenario),
            fallbackLines: fallbackLines(for: scenario, selection: selection),
            sharingTitle: sharingTitle(for: scenario),
            sharingLines: sharingLines(for: scenario)
        )
    }

    private func heroTitle(for scenario: KTVScenario) -> String {
        switch scenario {
        case .friends: return "今晚怎么开场"
        case .birthday: return "生日局怎么开场"
        case .teamBuilding: return "团建局怎么开场"
        case .carKTV: return "路上怎么安全开唱"
        case .couples: return "两个人怎么开场"
        case .soloPractice: return "今晚怎么练"
        }
    }

    private func openingTitle(for scenario: KTVScenario) -> String {
        switch scenario {
        case .friends: return "按这份歌单开场"
        case .birthday: return "先陪寿星开唱"
        case .teamBuilding: return "先让同事们开口"
        case .carKTV: return "安全开始"
        case .couples: return "两个人这样开唱"
        case .soloPractice: return "按这份歌单练"
        }
    }

    private func fallbackTitle(for scenario: KTVScenario) -> String {
        switch scenario {
        case .friends: return "现场怎么换"
        case .birthday: return "寿星想换歌时"
        case .teamBuilding: return "同事没接上时"
        case .carKTV: return "路上需要调整时"
        case .couples: return "两个人怎么换"
        case .soloPractice: return "状态不对怎么换"
        }
    }

    private func heroSubtitle(for scenario: KTVScenario) -> String {
        switch scenario {
        case .friends: return "先唱哪首、朋友接不上时换哪首，现场直接看。"
        case .birthday: return "先唱哪首、寿星想换歌时怎么接，现场直接看。"
        case .teamBuilding: return "先唱哪首、同事暂时不接时换哪首，现场直接看。"
        case .carKTV: return "驾驶者专心开车，点歌、切歌和音量都交给乘客。"
        case .couples: return "两个人先唱哪首、谁来接下一首，现场直接看。"
        case .soloPractice: return "先练哪首、状态不对时换哪首，照着歌单练。"
        }
    }

    private func tags(for scenario: KTVScenario) -> [String] {
        switch scenario {
        case .friends: return ["朋友轮唱", "熟歌暖场", "群里认领"]
        case .birthday: return ["寿星优先", "祝福接唱", "朋友轮换"]
        case .teamBuilding: return ["同事轮唱", "全员参与", "轻松热场"]
        case .carKTV: return ["安全优先", "乘客点歌", "轻松跟唱"]
        case .couples: return ["两人轮唱", "对唱", "轻松切换"]
        case .soloPractice: return ["独自练唱", "按状态排序", "保护嗓子"]
        }
    }

    private func openingLines(for scenario: KTVScenario, selection: StartTipsSelection) -> [String] {
        switch scenario {
        case .friends:
            var lines = [opening(selection, fallback: "先用朋友们熟悉的歌暖场，别一上来就唱太难的。") {
                "今晚先唱《\($0.track.title)》，让朋友们先跟上。"
            }]
            lines.append(selection.chorus.map { "气氛起来后接《\($0.track.title)》，让大家一起唱。" }
                ?? "气氛起来后再安排大家能一起接的歌。")
            appendClosing(selection, to: &lines) { "最后留《\($0.track.title)》，朋友都在的时候再唱。" }
            return lines
        case .birthday:
            var lines = [opening(selection, fallback: "先用寿星熟悉的歌开场，让朋友们容易接上。") {
                "今晚先唱《\($0.track.title)》，让寿星和朋友们先跟上。"
            }]
            lines.append(selection.chorus.map { "祝福环节接《\($0.track.title)》，请朋友们陪寿星一起唱。" }
                ?? "中段给寿星留一首想唱的，再安排朋友们一起接。")
            appendClosing(selection, to: &lines) { "最后留《\($0.track.title)》给寿星和朋友们收尾。" }
            return lines
        case .teamBuilding:
            var lines = [opening(selection, fallback: "先用同事们熟悉、容易开口的歌热场。") {
                "今晚先唱《\($0.track.title)》，让同事们容易开口。"
            }]
            lines.append(selection.chorus.map { "气氛起来后接《\($0.track.title)》，让更多同事一起参与。" }
                ?? "同事之间轮着唱，别让一个人连续唱太久。")
            appendClosing(selection, to: &lines) { "最后留《\($0.track.title)》，人齐时一起收尾。" }
            return lines
        case .carKTV:
            var lines = [opening(selection, fallback: "由乘客先点一首轻松熟悉的歌，驾驶者专心开车。") {
                "由乘客先点《\($0.track.title)》，驾驶者专心开车。"
            }]
            lines.append(selection.chorus.map { "路上接《\($0.track.title)》，仍由乘客负责切歌和音量。" }
                ?? "歌与歌之间留点空档，避免音量和情绪影响驾驶注意力。")
            appendClosing(selection, to: &lines) { "到达前用《\($0.track.title)》轻松收尾。" }
            return lines
        case .couples:
            var lines = [opening(selection, fallback: "两个人先从熟悉的旋律开始，别一上来就唱太难的。") {
                "两个人先唱《\($0.track.title)》，从熟悉的旋律开始。"
            }]
            lines.append(selection.chorus.map { "气氛起来后接《\($0.track.title)》，一人主唱，另一位跟唱。" }
                ?? "一人主唱时，另一位可以接副歌或帮忙找下一首。")
            appendClosing(selection, to: &lines) { "最后留《\($0.track.title)》，两人一起收尾。" }
            return lines
        case .soloPractice:
            var lines = [opening(selection, fallback: "先从不费嗓的歌开始，自己慢慢找状态。") {
                "今晚先唱《\($0.track.title)》，自己先把声音活动开。"
            }]
            lines.append(selection.chorus.map { "状态起来后再唱《\($0.track.title)》，留意哪一段需要继续练。" }
                ?? "状态稳定后再练难一点的歌，不要连续冲高音。")
            appendClosing(selection, to: &lines) { "最后再唱《\($0.track.title)》，记下今天更顺的地方。" }
            return lines
        }
    }

    private func fallbackLines(for scenario: KTVScenario, selection: StartTipsSelection) -> [String] {
        var lines: [String]
        switch scenario {
        case .friends: lines = ["朋友临时不想唱，就跳到下一首，不用让所有人等。"]
        case .birthday: lines = ["寿星临时想换歌，就先换到下一首，祝福环节稍后再接。"]
        case .teamBuilding: lines = ["有同事暂时不想唱，就换下一位，别让现场停下来。"]
        case .carKTV: lines = ["驾驶者不操作手机，由乘客点歌和切歌。"]
        case .couples: lines = ["一人暂时不想唱，就由另一位先接下一首。"]
        case .soloPractice: lines = ["这一首状态不对，就直接跳到下一首，不用硬撑。"]
        }
        if let easy = selection.easyFallback {
            switch scenario {
            case .soloPractice: lines.append("嗓子累了就换《\(easy.track.title)》，让自己先轻松一点。")
            case .couples: lines.append("其中一人嗓子累了就换《\(easy.track.title)》，另一位也能轻松接。")
            case .carKTV: lines.append("想放松时由乘客换到《\(easy.track.title)》，音量保持适中。")
            default: lines.append("有人嗓子累了就换《\(easy.track.title)》，先轻松一点。")
            }
        }
        switch scenario {
        case .soloPractice: lines.append("遇到还不熟的歌先做标记，下次再集中练。")
        case .couples: lines.append("两个人都不熟的歌直接换掉，不打断节奏。")
        case .carKTV: lines.append("需要调整时先由乘客处理；没有乘客就等安全停车后再操作。")
        default: lines.append("遇到不熟的歌直接换成备选，别打断现场气氛。")
        }
        return lines
    }

    private func sharingTitle(for scenario: KTVScenario) -> String {
        switch scenario {
        case .friends, .birthday, .teamBuilding: return "发到群里"
        case .carKTV: return "车上怎么配合"
        case .couples: return "发给另一位"
        case .soloPractice: return "给自己留一份"
        }
    }

    private func sharingLines(for scenario: KTVScenario) -> [String] {
        switch scenario {
        case .friends:
            return ["把歌单发到朋友群里，让大家先认领想唱的歌。", "开唱前确认第一位主唱，避免第一首没人接。"]
        case .birthday:
            return ["把歌单发到生日群里，请朋友们先认领祝福歌。", "提前问寿星最想唱哪首，把它留在中段。"]
        case .teamBuilding:
            return ["把歌单发到同事群里，让不同同事先认领歌曲。", "开唱前确认前两位主唱，减少等待。"]
        case .carKTV:
            return ["驾驶者不操作手机，由乘客点歌和切歌。", "没有乘客时，等安全停车后再调整歌单。"]
        case .couples:
            return ["把歌单发给另一位，两个人先各选一首最想唱的。", "提前说好谁先唱、谁接下一首，现场更顺。"]
        case .soloPractice:
            return ["把歌单保存给自己，练完后标记唱得顺和需要再练的歌。", "下次先复习今天卡住的部分，再增加新的挑战。"]
        }
    }

    private func opening(
        _ selection: StartTipsSelection,
        fallback: String,
        present: (SongPlanItem) -> String
    ) -> String {
        selection.opening.map(present) ?? fallback
    }

    private func appendClosing(
        _ selection: StartTipsSelection,
        to lines: inout [String],
        sentence: (SongPlanItem) -> String
    ) {
        guard let closing = selection.closing,
              closing.track.id != selection.opening?.track.id else { return }
        lines.append(sentence(closing))
    }
}
