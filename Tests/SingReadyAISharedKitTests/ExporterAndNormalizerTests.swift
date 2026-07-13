import XCTest
@testable import SingReadyAISharedKit

final class ExporterAndNormalizerTests: XCTestCase {
    func testLocalReferenceCopyAvoidsVenueAvailabilityClaims() throws {
        let catalog = try KTVCatalogRepository().loadTracks()
        let localTrack = try XCTUnwrap(catalog.first)
        let match = SongMatcher().match(
            song: ImportedSong(
                title: localTrack.title,
                artist: localTrack.artist,
                source: .plainText,
                confidence: 1
            ),
            catalog: catalog
        )
        var plan = try makePlan()
        let firstSectionIndex = try XCTUnwrap(plan.sections.indices.first)
        let firstItemIndex = try XCTUnwrap(plan.sections[firstSectionIndex].items.indices.first)
        let confidenceNote = "仅用于本地样例核对"
        plan.sections[firstSectionIndex].items[firstItemIndex].track = track(
            plan.sections[firstSectionIndex].items[firstItemIndex].track,
            confidenceNote: confidenceNote
        )

        let exportedText = PlaylistTextExporter().export(plan: plan)
        let userFacingCopy = [
            TrackCatalogSource.ktvCatalog.displayName,
            MatchStatus.exact.displayName,
            match.reason,
            exportedText
        ].joined(separator: "\n")

        XCTAssertEqual(TrackCatalogSource.ktvCatalog.displayName, "本地参考曲库")
        XCTAssertEqual(MatchStatus.exact.displayName, "参考命中")
        XCTAssertEqual(match.reason, "歌名和歌手在本地参考曲库中命中")
        XCTAssertTrue(exportedText.contains("本地参考曲库"))
        XCTAssertTrue(exportedText.contains("参考说明：\(confidenceNote)"))
        for forbiddenCopy in ["能点到", "大概率能点到", "直接唱", "KTV 曲库", "到店好找", "到店里留意"] {
            XCTAssertFalse(userFacingCopy.contains(forbiddenCopy), "仍包含不应承诺的文案：\(forbiddenCopy)")
        }
    }

    func testTextJSONAndPosterExportIncludeShareContext() throws {
        let plan = try makePlan()

        let text = PlaylistTextExporter().export(plan: plan)
        let json = try PlaylistJSONExporter().export(plan: plan)
        let poster = PosterRenderer().summary(for: plan)

        XCTAssertTrue(text.contains("今晚唱什么"))
        XCTAssertTrue(text.contains("为什么放这首"))
        XCTAssertTrue(text.contains("备选"))
        XCTAssertTrue(text.contains("常见音域参考：F3 到 G4"))
        XCTAssertFalse(text.contains("男声"))
        XCTAssertFalse(text.contains("女声"))
        XCTAssertFalse(text.contains("你歌单"))
        XCTAssertFalse(text.contains("你的声线"))
        XCTAssertFalse(text.contains("你的音域"))
        XCTAssertTrue(text.contains("朋友局先唱"))
        XCTAssertFalse(text.contains("出现较多"))
        XCTAssertFalse(text.contains("适合车载 K 歌"))
        XCTAssertTrue(json.contains("scoreBreakdown"))
        XCTAssertTrue(json.contains("voiceProfile"))
        XCTAssertTrue(json.contains("scenarioConfig"))
        XCTAssertTrue(json.contains("\"inputSource\" : \"example\""))
        XCTAssertTrue(json.contains("\"source\" : \"commonReference\""))
        XCTAssertEqual(poster.title, "今晚唱什么")
        XCTAssertTrue(poster.subtitle.contains("朋友局，120 分钟，常见音域参考"))
        XCTAssertFalse(poster.subtitle.contains("男声"))
        XCTAssertFalse(poster.subtitle.contains("女声"))
        XCTAssertGreaterThanOrEqual(poster.highlights.count, 5)
        XCTAssertLessThanOrEqual(poster.highlights.count, 10)
    }

    func testPosterKeepsProvisionalCandidatesVisiblyPendingVerification() throws {
        let sourcePlan = try makePlan()
        let verifiedItems = Array(sourcePlan.sections.flatMap(\.items).prefix(2))
        let referenceTrack = try XCTUnwrap(verifiedItems.first?.track)
        let provisionalTrack = track(
            referenceTrack,
            id: "external:poster-candidate",
            title: "公开候选曲",
            artist: "候选歌手",
            catalogSource: .externalSimilar,
            externalCandidateMetadata: ExternalCandidateMetadata(
                relation: .similarTrack,
                relevance: 0.82,
                reasons: ["Apple 公开相似曲目"],
                provider: .iTunes
            )
        )
        let provisionalItem = SongPlanItem(
            track: provisionalTrack,
            score: 0.82,
            reasons: [],
            riskWarnings: [],
            alternatives: []
        )
        let plan = SongPlan(
            title: "不足十首的候选计划",
            scenario: sourcePlan.scenario,
            inputSource: sourcePlan.inputSource,
            scenarioConfig: sourcePlan.scenarioConfig,
            voiceProfile: sourcePlan.voiceProfile,
            sections: [
                SongPlanSection(
                    role: .warmup,
                    title: "已核对参考",
                    goal: "先唱熟悉歌曲",
                    items: verifiedItems
                ),
                SongPlanSection(
                    role: .externalVerification,
                    title: "待核对候选",
                    goal: "来自公开搜索，点歌前请核对",
                    items: [provisionalItem]
                )
            ]
        )

        let poster = PosterRenderer().summary(for: plan)
        let provisionalHighlight = try XCTUnwrap(
            poster.highlights.first { $0.contains("公开候选曲") }
        )
        let provisionalSection = try XCTUnwrap(
            poster.sections.first { $0.title == "待核对候选" }
        )

        XCTAssertEqual(poster.highlights.count, 3)
        XCTAssertEqual(poster.sections.map(\.title), ["已核对参考", "待核对候选"])
        XCTAssertEqual(
            provisionalSection.disclosure,
            "公开搜索候选，KTV 收录与现场数据待核对"
        )
        XCTAssertTrue(provisionalSection.highlights.allSatisfy(\.isPendingVerification))
        XCTAssertTrue(provisionalHighlight.contains("待核对"))
        XCTAssertTrue(
            poster.highlights
                .filter { !$0.contains("公开候选曲") }
                .allSatisfy { !$0.contains("待核对") }
        )
    }

    func testFallbackTextExporterDefensivelyOmitsPersonalizedClaimsAndKeyAdvice() throws {
        var plan = try makePlan()
        plan.preferenceSummary = "你平时听的流行歌偏多"
        let firstSection = try XCTUnwrap(plan.sections.indices.first)
        let firstItem = try XCTUnwrap(plan.sections[firstSection].items.indices.first)
        plan.sections[firstSection].items[firstItem].reasons = [
            "你歌单里本来就有这位歌手",
            "你导入的歌单中出现过该歌手",
            "这首的音域更贴你的声线",
            "副歌好接，适合朋友局合唱"
        ]
        plan.sections[firstSection].items[firstItem].singingAdvice = SingingAdjustmentAdvice(
            level: .lowerKey,
            title: "建议降 2 个半音",
            detail: "按你的音域降调",
            semitoneShift: -2
        )

        let text = PlaylistTextExporter().export(plan: plan)
        let json = try PlaylistJSONExporter().export(plan: plan)
        let poster = PosterRenderer().summary(for: plan)

        XCTAssertFalse(text.contains("你平时听"))
        XCTAssertFalse(text.contains("你歌单"))
        XCTAssertFalse(text.contains("你导入的歌单中出现过该歌手"))
        XCTAssertFalse(text.contains("你的声线"))
        XCTAssertFalse(text.contains("你的音域"))
        XCTAssertFalse(text.contains("建议降 2 个半音"))
        XCTAssertTrue(text.contains("副歌好接"))
        XCTAssertFalse(json.contains("你平时听"))
        XCTAssertFalse(json.contains("你歌单"))
        XCTAssertFalse(json.contains("你导入的歌单中出现过该歌手"))
        XCTAssertFalse(json.contains("你的声线"))
        XCTAssertFalse(json.contains("你的音域"))
        XCTAssertFalse(json.contains("建议降 2 个半音"))
        XCTAssertEqual(poster.subtitle, "朋友局，120 分钟，常见音域参考")
    }

    func testFallbackExporterRejectsLegacyPossessiveVoiceReasonEvenWhenVoiceWasMeasured() throws {
        var plan = try makePlan()
        var voice = try XCTUnwrap(plan.voiceProfile)
        voice.source = .measured
        plan.voiceProfile = voice
        let firstSection = try XCTUnwrap(plan.sections.indices.first)
        let firstItem = try XCTUnwrap(plan.sections[firstSection].items.indices.first)
        plan.sections[firstSection].items[firstItem].reasons = ["这首的音域更贴你的声线"]

        let text = PlaylistTextExporter().export(plan: plan)
        let json = try PlaylistJSONExporter().export(plan: plan)

        XCTAssertFalse(text.contains("你的声线"))
        XCTAssertFalse(json.contains("你的声线"))
    }

    func testSongNormalizerCleansVersionsAndAvoidsShortSubstringOvermatch() {
        XCTAssertEqual(SongNormalizer.normalizeTitle("晴天 (Live 版)"), "晴天")
        XCTAssertEqual(SongNormalizer.normalizeTitle("晴天 现场版"), "晴天")
        XCTAssertEqual(SongNormalizer.normalizeTitle("成都 民谣版"), "成都")
        XCTAssertEqual(SongNormalizer.normalizeTitle("事故现场"), "事故现场")
        XCTAssertEqual(SongNormalizer.normalizeTitle("告白氣球"), "告白气球")
        XCTAssertGreaterThan(SongNormalizer.similarity("蓝莲花新版", "蓝莲花"), 0.7)
        XCTAssertLessThan(SongNormalizer.similarity("不存在的测试歌名", "存在"), 0.45)
    }

    func testLegacyCatalogDecodesMissingVersionTagsAsEmpty() throws {
        let catalog = try KTVCatalogRepository().loadTracks()

        XCTAssertFalse(catalog.isEmpty)
        XCTAssertTrue(catalog.allSatisfy(\.versionTags.isEmpty))
    }

    func testKTVTrackRoundTripsNonEmptyVersionTags() throws {
        let source = try XCTUnwrap(KTVCatalogRepository().loadTracks().first)
        let versioned = track(source, versionTags: ["Live", "Acoustic"])

        let restored = try JSONDecoder().decode(
            KTVTrack.self,
            from: JSONEncoder().encode(versioned)
        )

        XCTAssertEqual(restored, versioned)
        XCTAssertEqual(restored.versionTags, ["Live", "Acoustic"])
    }

    func testShareTextExporterKeepsGroupCopyConcise() throws {
        let plan = try makePlan()

        let text = PlaylistShareTextExporter().export(plan: plan)

        XCTAssertTrue(text.contains("今晚唱什么｜朋友局 120 分钟"))
        XCTAssertTrue(text.contains("开场热身"))
        XCTAssertTrue(text.contains("稻香 - 周杰伦"))
        XCTAssertFalse(text.contains("为什么放这首"))
        XCTAssertFalse(text.contains("搜歌："))
        XCTAssertFalse(text.contains("https://"))
        XCTAssertLessThan(text.count, 1_500)
    }

    func testDetailedTextFileExporterCreatesUTF8TxtWithFullExplanations() throws {
        var plan = try makePlan()
        plan.title = "朋友/局：今晚\n歌单"

        let payload = PlaylistTextFileExporter().export(plan: plan)

        XCTAssertTrue(payload.fileName.hasSuffix(".txt"))
        XCTAssertFalse(payload.fileName.contains("/"))
        XCTAssertFalse(payload.fileName.contains("\n"))
        XCTAssertTrue(payload.fileName.contains("详细歌单"))
        XCTAssertEqual(String(data: payload.data, encoding: .utf8), payload.contents)
        XCTAssertTrue(payload.contents.contains("为什么放这首"))
        XCTAssertTrue(payload.contents.contains("备选"))
        XCTAssertGreaterThan(payload.contents.count, PlaylistShareTextExporter().export(plan: plan).count)
    }

    func testTemporaryExportFileStoreClearRemovesMaterializedFileAndOwnedDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TemporaryExportFileStore(directory: directory)
        let payload = PlaylistTextFilePayload(
            fileName: "朋友局-详细歌单.txt",
            contents: "晴天 - 周杰伦"
        )

        let fileURL = try store.materialize(payload)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))

        try store.clear()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testTemporaryExportFileStoreRejectsPathsAndNonTextFileNamesWithoutWriting() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-boundary-\(UUID().uuidString)", isDirectory: true)
        let directory = root.appendingPathComponent("owned", isDirectory: true)
        let outsideURL = root.appendingPathComponent("outside.txt")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TemporaryExportFileStore(directory: directory)
        let invalidFileNames = [
            "../outside.txt",
            outsideURL.path,
            "nested/playlist.txt",
            "playlist.json"
        ]

        for fileName in invalidFileNames {
            XCTAssertThrowsError(
                try store.materialize(
                    PlaylistTextFilePayload(fileName: fileName, contents: "晴天 - 周杰伦")
                ),
                fileName
            ) { error in
                XCTAssertEqual(error as? TemporaryExportFileStoreError, .invalidFileName)
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: outsideURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testSongActionLinkBuilderOnlyPreservesApprovedHTTPSDestinations() throws {
        let baseTrack = try XCTUnwrap(try KTVCatalogRepository().loadTracks().first)
        let builder = SongActionLinkBuilder()
        let approvedURLs = [
            URL(string: "https://music.apple.com/cn/song/123")!,
            URL(string: "https://www.last.fm/music/Test/_/Song")!
        ]
        for approvedURL in approvedURLs {
            XCTAssertEqual(
                builder.url(for: track(baseTrack, externalURL: approvedURL)),
                approvedURL
            )
        }

        let unsafeURLs = [
            URL(string: "http://music.apple.com/cn/song/123")!,
            URL(string: "javascript:alert(1)")!,
            URL(string: "https://music.apple.com.evil.example/song/123")!,
            URL(string: "https://user:password@music.apple.com/cn/song/123")!
        ]
        for unsafeURL in unsafeURLs {
            let fallback = try XCTUnwrap(
                builder.url(for: track(baseTrack, externalURL: unsafeURL))
            )
            XCTAssertEqual(fallback.scheme, "https")
            XCTAssertEqual(fallback.host, "music.apple.com")
            XCTAssertEqual(fallback.path, "/cn/search")
        }
    }

    func testSongPlanItemDropsUnsafeLegacyActionURL() throws {
        let track = try XCTUnwrap(try KTVCatalogRepository().loadTracks().first)

        let item = SongPlanItem(
            track: track,
            score: 0.8,
            reasons: [],
            riskWarnings: [],
            alternatives: [],
            actionURL: URL(string: "javascript:alert(1)")
        )

        XCTAssertNil(item.actionURL)
    }

    private func makePlan() throws -> SongPlan {
        let catalog = try KTVCatalogRepository().loadTracks()
        let playlist = try ImportCoordinator().resolveDemoPlaylist()
        let matches = SongMatcher().match(playlist: playlist, catalog: catalog)
        let profile = PreferenceProfiler().buildProfile(importedPlaylist: playlist, matches: matches)
        return RecommendationEngine().generatePlan(
            matches: matches,
            preferenceProfile: profile,
            voiceProfile: .simulatedMiddle,
            scenario: ScenarioConfig(scenario: .friends, durationMinutes: 120),
            catalog: catalog,
            inputSource: .example
        )
    }

    private func track(_ track: KTVTrack, confidenceNote: String) -> KTVTrack {
        KTVTrack(
            id: track.id,
            title: track.title,
            artist: track.artist,
            language: track.language,
            era: track.era,
            genre: track.genre,
            moodTags: track.moodTags,
            sceneTags: track.sceneTags,
            difficulty: track.difficulty,
            vocalRangeLowMidi: track.vocalRangeLowMidi,
            vocalRangeHighMidi: track.vocalRangeHighMidi,
            energy: track.energy,
            singAlongScore: track.singAlongScore,
            ktvAvailability: track.ktvAvailability,
            duetFriendly: track.duetFriendly,
            rapDensity: track.rapDensity,
            highNoteRisk: track.highNoteRisk,
            aliases: track.aliases,
            similarSongIds: track.similarSongIds,
            externalURL: track.externalURL,
            catalogSource: track.catalogSource,
            confidenceNote: confidenceNote
        )
    }

    private func track(_ track: KTVTrack, versionTags: [String]) -> KTVTrack {
        KTVTrack(
            id: track.id,
            title: track.title,
            artist: track.artist,
            language: track.language,
            era: track.era,
            genre: track.genre,
            moodTags: track.moodTags,
            sceneTags: track.sceneTags,
            difficulty: track.difficulty,
            vocalRangeLowMidi: track.vocalRangeLowMidi,
            vocalRangeHighMidi: track.vocalRangeHighMidi,
            energy: track.energy,
            singAlongScore: track.singAlongScore,
            ktvAvailability: track.ktvAvailability,
            duetFriendly: track.duetFriendly,
            rapDensity: track.rapDensity,
            highNoteRisk: track.highNoteRisk,
            aliases: track.aliases,
            versionTags: versionTags,
            similarSongIds: track.similarSongIds,
            externalURL: track.externalURL,
            catalogSource: track.catalogSource,
            confidenceNote: track.confidenceNote,
            externalCandidateMetadata: track.externalCandidateMetadata
        )
    }

    private func track(_ track: KTVTrack, externalURL: URL?) -> KTVTrack {
        KTVTrack(
            id: track.id,
            title: track.title,
            artist: track.artist,
            language: track.language,
            era: track.era,
            genre: track.genre,
            moodTags: track.moodTags,
            sceneTags: track.sceneTags,
            difficulty: track.difficulty,
            vocalRangeLowMidi: track.vocalRangeLowMidi,
            vocalRangeHighMidi: track.vocalRangeHighMidi,
            energy: track.energy,
            singAlongScore: track.singAlongScore,
            ktvAvailability: track.ktvAvailability,
            duetFriendly: track.duetFriendly,
            rapDensity: track.rapDensity,
            highNoteRisk: track.highNoteRisk,
            aliases: track.aliases,
            similarSongIds: track.similarSongIds,
            externalURL: externalURL,
            catalogSource: track.catalogSource,
            confidenceNote: track.confidenceNote,
            externalCandidateMetadata: track.externalCandidateMetadata
        )
    }

    private func track(
        _ track: KTVTrack,
        id: String,
        title: String,
        artist: String,
        catalogSource: TrackCatalogSource,
        externalCandidateMetadata: ExternalCandidateMetadata?
    ) -> KTVTrack {
        KTVTrack(
            id: id,
            title: title,
            artist: artist,
            language: track.language,
            era: track.era,
            genre: track.genre,
            moodTags: track.moodTags,
            sceneTags: track.sceneTags,
            difficulty: track.difficulty,
            vocalRangeLowMidi: track.vocalRangeLowMidi,
            vocalRangeHighMidi: track.vocalRangeHighMidi,
            energy: track.energy,
            singAlongScore: track.singAlongScore,
            ktvAvailability: track.ktvAvailability,
            duetFriendly: track.duetFriendly,
            rapDensity: track.rapDensity,
            highNoteRisk: track.highNoteRisk,
            aliases: [],
            similarSongIds: [],
            catalogSource: catalogSource,
            confidenceNote: "来自公开搜索，KTV 收录与现场数据待核对",
            externalCandidateMetadata: externalCandidateMetadata
        )
    }
}
