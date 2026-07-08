import Foundation

public struct PreferenceProfiler: Sendable {
    public init() {}

    public func buildProfile(importedPlaylist: ImportedPlaylist, matches: [MatchResult]) -> PreferenceProfile {
        let matchedTracks = matches.compactMap(\.matchedTrack)
        let matchedCount = matchedTracks.count
        let totalCount = max(importedPlaylist.songs.count, 1)

        let topArtists = count(importedPlaylist.songs.compactMap(\.artist))
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(5)
            .map { (name: $0.key, count: $0.value) }

        let language = distribution(matchedTracks.map(\.language))
        let era = distribution(matchedTracks.map(\.era))
        let genre = distribution(matchedTracks.map(\.genre))
        let moods = distribution(matchedTracks.flatMap(\.moodTags))
        let scenes = distribution(matchedTracks.flatMap(\.sceneTags))
        let avgDifficulty = average(matchedTracks.map { Double($0.difficulty) })
        let avgSingAlong = average(matchedTracks.map(\.singAlongScore))
        let highRisk = average(matchedTracks.map(\.highNoteRisk))
        let matchRate = Double(matchedCount) / Double(totalCount)
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

        let favoriteArtist = topArtists.first?.name ?? "你常听的歌手"
        let topGenre = genre.max(by: { $0.value < $1.value })?.key ?? "流行"
        let topMood = moods.max(by: { $0.value < $1.value })?.key ?? "熟悉旋律"
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
        let summary = "你的歌单偏向\(topGenre)和\(topMood)，\(favoriteArtist)出现较多，适合\(bestScenario)。建议开场避免连续慢歌，用高传唱度歌曲热场。"

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
        var tags = [topGenre, topMood]
        tags.append(matchRate >= 0.75 ? "KTV 命中高" : "需要替代曲")
        tags.append(chorusFriendliness >= 0.78 ? "合唱友好" : "偏个人表达")
        tags.append(highRisk >= 0.65 ? "高音风险偏高" : "声线压力可控")
        tags.append(avgDifficulty >= 3.8 ? "适合挑战" : "适合稳唱")
        return Array(NSOrderedSet(array: tags).compactMap { $0 as? String }.prefix(8))
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
