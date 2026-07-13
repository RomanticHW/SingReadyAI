import XCTest
@testable import SingReadyAISharedKit

final class SongVersionIdentityTests: XCTestCase {
    func testUnmarkedTitlesAreCompatible() {
        let imported = SongVersionIdentity.parse(title: "后来", versionTags: [])
        let catalog = SongVersionIdentity.parse(title: "后来", versionTags: [])

        XCTAssertEqual(imported.normalizedBaseTitle, "后来")
        XCTAssertEqual(imported.kinds, [])
        XCTAssertFalse(imported.hasExplicitMarker)
        XCTAssertEqual(imported.compatibility(with: catalog), .compatible)
    }

    func testVersionSynonymsNormalizeToTheSameKinds() {
        let cases: [(tag: String, title: String, expectedKind: SongVersionKind)] = [
            ("Live", "后来 现场版", .live),
            ("Cover", "后来（翻唱版）", .cover),
            ("Remix", "后来 DJ版", .remix),
            ("伴奏", "后来（伴奏版）", .accompaniment),
            ("Edit", "后来 剪辑版", .edit)
        ]

        for testCase in cases {
            let tagged = SongVersionIdentity.parse(title: "后来", versionTags: [testCase.tag])
            let titled = SongVersionIdentity.parse(title: testCase.title, versionTags: [])

            XCTAssertEqual(tagged.normalizedBaseTitle, "后来", testCase.tag)
            XCTAssertEqual(titled.normalizedBaseTitle, "后来", testCase.title)
            XCTAssertEqual(tagged.kinds, [testCase.expectedKind], testCase.tag)
            XCTAssertEqual(titled.kinds, [testCase.expectedKind], testCase.title)
            XCTAssertTrue(tagged.hasExplicitMarker, testCase.tag)
            XCTAssertTrue(titled.hasExplicitMarker, testCase.title)
            XCTAssertEqual(tagged.compatibility(with: titled), .compatible, testCase.title)
        }
    }

    func testCompactEnglishVersionSuffixesRequireNoWhitespace() {
        let cases: [(title: String, expectedKind: SongVersionKind)] = [
            ("后来Live版", .live),
            ("后来Cover版", .cover),
            ("后来Remix版", .remix),
            ("后来DJ版", .remix),
            ("后来Edit版", .edit)
        ]

        for testCase in cases {
            let identity = SongVersionIdentity.parse(title: testCase.title, versionTags: [])

            XCTAssertEqual(identity.normalizedBaseTitle, "后来", testCase.title)
            XCTAssertEqual(identity.kinds, [testCase.expectedKind], testCase.title)
            XCTAssertTrue(identity.hasExplicitMarker, testCase.title)
        }
    }

    func testCompactEnglishSuffixDoesNotMatchInsideOrdinaryWords() {
        let titles = ["Alive版", "Discover版", "Premix版", "Credit版"]

        for title in titles {
            let identity = SongVersionIdentity.parse(title: title, versionTags: [])

            XCTAssertEqual(identity.normalizedBaseTitle, SongNormalizer.normalizeBaseTitle(title))
            XCTAssertTrue(identity.kinds.isEmpty, title)
            XCTAssertFalse(identity.hasExplicitMarker, title)
        }
    }

    func testParenthesizedOrdinaryWordsAreNotVersionMarkers() {
        let titles = ["Theme (Oliver)", "Song (Delivery)", "Work (Conversion)"]

        for title in titles {
            let identity = SongVersionIdentity.parse(title: title, versionTags: [])

            XCTAssertEqual(
                identity.normalizedBaseTitle,
                SongNormalizer.normalizeBaseTitle(title),
                title
            )
            XCTAssertTrue(identity.kinds.isEmpty, title)
            XCTAssertFalse(identity.hasExplicitMarker, title)
        }
    }

    func testSingleSidedVersionMarkerRequiresConfirmation() {
        let imported = SongVersionIdentity.parse(title: "后来 Live", versionTags: ["Live"])
        let catalog = SongVersionIdentity.parse(title: "后来", versionTags: [])

        XCTAssertEqual(imported.compatibility(with: catalog), .requiresConfirmation)
    }

    func testConflictingVersionMarkersRequireConfirmation() {
        let live = SongVersionIdentity.parse(title: "后来 Live", versionTags: [])
        let cover = SongVersionIdentity.parse(title: "后来 翻唱版", versionTags: [])

        XCTAssertEqual(live.compatibility(with: cover), .requiresConfirmation)
    }

    func testUnknownVersionMarkerRequiresConfirmationEvenOnBothSides() {
        let imported = SongVersionIdentity.parse(title: "后来 特别版", versionTags: [])
        let catalog = SongVersionIdentity.parse(title: "后来", versionTags: ["特别版"])

        XCTAssertEqual(imported.normalizedBaseTitle, "后来")
        XCTAssertEqual(imported.kinds, [.unknown])
        XCTAssertTrue(imported.hasExplicitMarker)
        XCTAssertEqual(catalog.kinds, [.unknown])
        XCTAssertEqual(imported.compatibility(with: catalog), .requiresConfirmation)
    }

    func testMixedKnownAndUnknownMarkerSegmentRequiresConfirmation() throws {
        let mixed = SongVersionIdentity.parse(
            title: "后来 (Acoustic Live Version)",
            versionTags: []
        )
        let live = SongVersionIdentity.parse(title: "后来 Live", versionTags: [])

        XCTAssertEqual(mixed.normalizedBaseTitle, "后来")
        XCTAssertEqual(mixed.kinds, [.live, .unknown])
        XCTAssertEqual(mixed.compatibility(with: live), .requiresConfirmation)

        let song = try XCTUnwrap(
            PlainTextPlaylistParser().parseLine("刘若英 - 后来 (Acoustic Live Version)")
        )
        let imported = SongVersionIdentity.parse(
            title: song.title,
            versionTags: song.versionTags
        )
        XCTAssertEqual(imported.kinds, [.live, .unknown])
    }

    func testPossessiveTrailingVersionKeepsEveryBaseTitleWord() {
        let identity = SongVersionIdentity.parse(
            title: "All Too Well Taylor's Version",
            versionTags: []
        )

        XCTAssertEqual(identity.normalizedBaseTitle, "alltoowell")
        XCTAssertEqual(identity.kinds, [.unknown])
        XCTAssertTrue(identity.hasExplicitMarker)
    }

    func testUnparenthesizedMultiwordUnknownVersionStaysInTitle() {
        let unparenthesized = SongVersionIdentity.parse(
            title: "All Too Well Ten Minute Version",
            versionTags: []
        )
        let parenthesized = SongVersionIdentity.parse(
            title: "All Too Well (Ten Minute Version)",
            versionTags: []
        )

        XCTAssertEqual(
            unparenthesized.normalizedBaseTitle,
            "alltoowelltenminuteversion"
        )
        XCTAssertTrue(unparenthesized.kinds.isEmpty)
        XCTAssertFalse(unparenthesized.hasExplicitMarker)
        XCTAssertEqual(parenthesized.normalizedBaseTitle, "alltoowell")
        XCTAssertEqual(parenthesized.kinds, [.unknown])
        XCTAssertTrue(parenthesized.hasExplicitMarker)
    }

    func testVersionedAliasIsSearchEvidenceOnly() {
        let canonical = SongIdentityEvidence.canonicalTitle(
            identity: .parse(title: "后来", versionTags: [])
        )
        let alias = SongIdentityEvidence.alias(
            rawValue: "后来 现场版",
            identity: .parse(title: "后来 现场版", versionTags: [])
        )

        XCTAssertTrue(canonical.allowsAutomaticAcceptance)
        XCTAssertFalse(alias.allowsAutomaticAcceptance)
    }

    func testPlainTextParserUsesVersionIdentityExtractionRules() throws {
        let song = try XCTUnwrap(
            PlainTextPlaylistParser().parseLine("刘若英 - 后来 Edit 剪辑")
        )
        let identity = SongVersionIdentity.parse(
            title: song.title,
            versionTags: song.versionTags
        )

        XCTAssertEqual(song.title, "后来")
        XCTAssertEqual(identity.normalizedBaseTitle, "后来")
        XCTAssertEqual(identity.kinds, [.edit])
        XCTAssertTrue(identity.hasExplicitMarker)
    }
}
