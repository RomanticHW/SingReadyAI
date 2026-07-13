import Foundation

public struct PreferenceProfiler: Sendable {
    public init() {}

    public func buildProfile(importedPlaylist: ImportedPlaylist, matches: [MatchResult]) -> PreferenceProfile {
        let matchedTracks = matches.compactMap(\.acceptedTrack)
        let originalMatchCount = matches.filter(\.hasOriginalReferenceMatch).count
        let totalCount = max(importedPlaylist.songs.count, 1)

        let matchesByImportedSongID = Dictionary(
            matches.map { ($0.importedSong.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let profileArtists = importedPlaylist.songs.compactMap { song in
            song.artist?.nilIfBlank
                ?? matchesByImportedSongID[song.id]?.acceptedTrack?.artist.nilIfBlank
        }
        let topArtists = count(profileArtists)
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(5)
            .map { (name: $0.key, count: $0.value) }

        guard !matchedTracks.isEmpty else {
            return PreferenceProfile(
                topArtists: topArtists,
                languageDistribution: [:],
                eraDistribution: [:],
                genreDistribution: [:],
                moodTags: [:],
                sceneAffinity: [:],
                ktvMatchRate: 0,
                averageDifficulty: 0,
                averageSingAlongScore: 0,
                highNoteRisk: 0,
                chorusFriendliness: 0,
                scenarioFitScores: [:],
                profileTags: [],
                summary: "还没有可用的本地参考匹配，先逐首核对待确认和未命中歌曲。"
            )
        }

        let language = distribution(matchedTracks.map(\.language))
        let era = distribution(matchedTracks.map(\.era))
        let genre = distribution(matchedTracks.map(\.genre))
        let moods = distribution(matchedTracks.flatMap(\.moodTags))
        let scenes = distribution(matchedTracks.flatMap(\.sceneTags))
        let avgDifficulty = average(matchedTracks.map { Double($0.difficulty) })
        let avgSingAlong = average(matchedTracks.map(\.singAlongScore))
        let highRisk = average(matchedTracks.map(\.highNoteRisk))
        let matchRate = Double(originalMatchCount) / Double(totalCount)
        let chorusFriendliness = average(matchedTracks.map { track in
            max(track.singAlongScore, track.duetFriendly ? 0.82 : 0)
        })
        let scenarioFitScores = KTVScenario.allCases.reduce(into: [String: Double]()) { result, scenario in
            let values = matchedTracks.map { track -> Double in
                var score = track.sceneTags.contains(scenario.rawValue) ? 0.78 : 0.34
                if scenario.isGroupScenario, track.singAlongScore >= 0.82 { score += 0.12 }
                if scenario == .carKTV, track.rapDensity <= 0.2, track.difficulty <= 3 { score += 0.10 }
                if scenario == .birthday, track.moodTags.contains(where: { ["温暖", "甜蜜", "合唱", "喜庆"].contains($0) }) { score += 0.10 }
                if scenario == .soloPractice, track.difficulty >= 3 { score += 0.08 }
                return min(1, score)
            }
            result[scenario.rawValue] = average(values)
        }

        let favoriteArtist = topArtists.first?.name
        let topGenre = genre.max(by: { $0.value < $1.value })?.key ?? "流行"
        let topMood = moods.max(by: { $0.value < $1.value })?.key ?? "熟悉旋律"
        let displayGenre = userFacingTag(topGenre)
        let displayMood = moodSummaryPhrase(topMood)
        let bestScenario = scenarioFitScores
            .compactMap { key, value in KTVScenario(rawValue: key).map { ($0.displayName, value) } }
            .max { $0.1 < $1.1 }?.0 ?? "朋友局"
        let profileTags = buildTags(
            topGenre: topGenre,
            topMood: topMood,
            matchRate: matchRate,
            chorusFriendliness: chorusFriendliness,
            highRisk: highRisk,
            avgDifficulty: avgDifficulty
        )
        let artistSentence = favoriteArtist.map { "\($0)也经常出现。" } ?? ""
        let summary = "你平时听的\(genreSummaryPhrase(displayGenre))偏多，\(displayMood)也不少。\(artistSentence)如果今晚是\(bestScenario)，先用大家熟的歌把气氛带起来。"

        return PreferenceProfile(
            topArtists: topArtists,
            languageDistribution: language,
            eraDistribution: era,
            genreDistribution: genre,
            moodTags: moods,
            sceneAffinity: scenes,
            ktvMatchRate: matchRate,
            averageDifficulty: avgDifficulty,
            averageSingAlongScore: avgSingAlong,
            highNoteRisk: highRisk,
            chorusFriendliness: chorusFriendliness,
            scenarioFitScores: scenarioFitScores,
            profileTags: profileTags,
            summary: summary
        )
    }

    private func buildTags(
        topGenre: String,
        topMood: String,
        matchRate: Double,
        chorusFriendliness: Double,
        highRisk: Double,
        avgDifficulty: Double
    ) -> [String] {
        var tags = [userFacingTag(topGenre), userFacingTag(topMood)]
        tags.append(matchRate >= 0.75 ? "常见 K 歌参考较多" : "本地参考较少")
        tags.append(chorusFriendliness >= 0.78 ? "适合合唱" : "适合独唱")
        tags.append(highRisk >= 0.65 ? "高音要留意" : "唱起来不吃力")
        tags.append(avgDifficulty >= 3.8 ? "适合挑战" : "稳一点")
        return Array(NSOrderedSet(array: tags).compactMap { $0 as? String }.prefix(8))
    }

    private func userFacingTag(_ value: String) -> String {
        switch value {
        case "旋律熟": return "熟悉旋律"
        case "高光": return "想唱"
        default: return value
        }
    }

    private func moodSummaryPhrase(_ value: String) -> String {
        switch value {
        case "旋律熟": return "大家熟的歌"
        case "合唱": return "适合合唱的歌"
        default: return "\(userFacingTag(value))的歌"
        }
    }

    private func genreSummaryPhrase(_ value: String) -> String {
        switch value {
        case "流行":
            return "流行歌"
        default:
            return "\(value)歌"
        }
    }

    private func count(_ values: [String]) -> [String: Int] {
        values.reduce(into: [:]) { result, value in
            result[value, default: 0] += 1
        }
    }

    private func distribution(_ values: [String]) -> [String: Double] {
        guard !values.isEmpty else { return [:] }
        let counts = count(values)
        return counts.mapValues { Double($0) / Double(values.count) }
    }

    private func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}
