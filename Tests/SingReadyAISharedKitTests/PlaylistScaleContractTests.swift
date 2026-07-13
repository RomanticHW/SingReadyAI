import XCTest
@testable import SingReadyAISharedKit

final class PlaylistScaleContractTests: XCTestCase {
    func testAnalysisReportsMonotonicProgressInFixedBatches() async throws {
        let fixture = makeExactFixture(count: 45)
        let recorder = ProgressRecorder()

        let output = try await PlaylistAnalysisExecutor().analyze(
            playlist: fixture.playlist,
            catalog: fixture.catalog,
            progress: { completed, total in
                await recorder.append(completed: completed, total: total)
            }
        )

        let events = await recorder.snapshot()
        XCTAssertEqual(output.matches.count, 45)
        XCTAssertEqual(events.map(\.completed), [0, 20, 40, 45])
        XCTAssertEqual(events.map(\.total), [45, 45, 45, 45])
        XCTAssertEqual(events.first, ProgressEvent(completed: 0, total: 45))
        XCTAssertEqual(events.last, ProgressEvent(completed: 45, total: 45))
        for (previous, current) in zip(events, events.dropFirst()) {
            XCTAssertLessThan(previous.completed, current.completed)
        }
    }

    func testFiveHundredMixedSongsCompleteWithinFiveSeconds() async throws {
        let fixture = makeMixedFixture(count: 500)
        let clock = ContinuousClock()
        let start = clock.now

        let output = try await PlaylistAnalysisExecutor().analyze(
            playlist: fixture.playlist,
            catalog: fixture.catalog
        )

        let elapsed = start.duration(to: clock.now)
        assertMixedOutput(output, total: 500)
        print("PERF mixed-500 \(seconds(elapsed))s")
        XCTAssertLessThan(elapsed, .seconds(5))
    }

    func testThousandMixedSongsCompleteWithinEightSeconds() async throws {
        let fixture = makeMixedFixture(count: 1_000)
        let clock = ContinuousClock()
        let start = clock.now

        let output = try await PlaylistAnalysisExecutor().analyze(
            playlist: fixture.playlist,
            catalog: fixture.catalog
        )

        let elapsed = start.duration(to: clock.now)
        assertMixedOutput(output, total: 1_000)
        print("PERF mixed-1000 \(seconds(elapsed))s")
        XCTAssertLessThan(elapsed, .seconds(8))
    }

    func testThousandExactSongsCompleteWithinFiveSeconds() async throws {
        let fixture = makeExactFixture(count: 1_000)
        let clock = ContinuousClock()
        let start = clock.now

        let output = try await PlaylistAnalysisExecutor().analyze(
            playlist: fixture.playlist,
            catalog: fixture.catalog
        )

        let elapsed = start.duration(to: clock.now)
        XCTAssertEqual(output.matches.count, 1_000)
        XCTAssertTrue(output.matches.allSatisfy {
            if case .acceptedOriginalExact = $0.disposition {
                return true
            }
            return false
        })
        print("PERF exact-1000 \(seconds(elapsed))s")
        XCTAssertLessThan(elapsed, .seconds(5))
    }

    @MainActor
    func testThousandSongAnalysisKeepsMainActorHeartbeatBelowOneHundredMilliseconds() async throws {
        let fixture = makeMixedFixture(count: 1_000)
        let completion = AnalysisCompletionState()
        let clock = ContinuousClock()
        let heartbeatTask = Task { @MainActor in
            var previous = clock.now
            var longestInterval = Duration.zero

            while !(await completion.isFinished()) {
                await Task.yield()
                let now = clock.now
                longestInterval = max(longestInterval, previous.duration(to: now))
                previous = now
            }
            return longestInterval
        }

        let output = try await PlaylistAnalysisExecutor().analyze(
            playlist: fixture.playlist,
            catalog: fixture.catalog,
            progress: { completed, total in
                if completed == total {
                    await completion.finish()
                }
            }
        )
        let longestInterval = await heartbeatTask.value

        XCTAssertEqual(output.matches.count, 1_000)
        print("PERF main-heartbeat-max \(milliseconds(longestInterval))ms")
        XCTAssertLessThan(longestInterval, .milliseconds(100))
    }

    func testCancellationAfterCompletedBatchDoesNotReturnPartialOutput() async throws {
        let fixture = makeMixedFixture(count: 1_000)
        let recorder = ProgressRecorder()
        let reachedFirstBatch = expectation(description: "首批匹配完成")
        let releaseGate = AsyncReleaseGate()
        let analysisTask = Task {
            try await PlaylistAnalysisExecutor().analyze(
                playlist: fixture.playlist,
                catalog: fixture.catalog,
                progress: { completed, total in
                    await recorder.append(completed: completed, total: total)
                    if completed == 20 {
                        reachedFirstBatch.fulfill()
                        await releaseGate.wait()
                    }
                }
            )
        }

        await fulfillment(of: [reachedFirstBatch], timeout: 2)
        analysisTask.cancel()
        await releaseGate.open()

        do {
            _ = try await analysisTask.value
            XCTFail("取消后不得返回部分 PlaylistAnalysisOutput")
        } catch is CancellationError {
            // 预期路径。
        }

        let events = await recorder.snapshot()
        XCTAssertEqual(events.first, ProgressEvent(completed: 0, total: 1_000))
        XCTAssertEqual(events.last, ProgressEvent(completed: 20, total: 1_000))
    }

    private func assertMixedOutput(
        _ output: PlaylistAnalysisOutput,
        total: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let partitionSize = total / 4
        XCTAssertEqual(output.matches.count, total, file: file, line: line)
        XCTAssertEqual(
            output.matches.filter { match in
                if case .acceptedOriginalExact = match.disposition { return true }
                return false
            }.count,
            partitionSize,
            file: file,
            line: line
        )
        XCTAssertEqual(
            output.matches.filter { match in
                if case .identityConfirmationRequired = match.disposition { return true }
                return false
            }.count,
            partitionSize,
            file: file,
            line: line
        )
        XCTAssertEqual(
            output.matches.filter { match in
                if case .alternativeSuggested = match.disposition { return true }
                return false
            }.count,
            partitionSize,
            file: file,
            line: line
        )
        XCTAssertEqual(
            output.matches.filter(\.isUnmatched).count,
            partitionSize,
            file: file,
            line: line
        )
        XCTAssertEqual(output.preferenceProfile.ktvMatchRate, 0.25, accuracy: 0.000_1)
    }

    private func makeMixedFixture(count: Int) -> ScaleFixture {
        precondition(count.isMultiple(of: 4))
        let partitionSize = count / 4
        var catalog: [KTVTrack] = []
        var songs: [ImportedSong] = []
        catalog.reserveCapacity(partitionSize * 2)
        songs.reserveCapacity(count)

        for index in 0..<partitionSize {
            let token = String(format: "%04d", index)
            let exactTrack = makeTrack(
                id: "exact-\(token)",
                title: "精确曲\(token)",
                artist: "歌手\(token)"
            )
            let alternativeTrack = makeTrack(
                id: "alternative-\(token)",
                title: "甲乙丙丁\(token)",
                artist: "替代歌手\(token)"
            )
            catalog.append(exactTrack)
            catalog.append(alternativeTrack)

            songs.append(
                ImportedSong(
                    title: exactTrack.title,
                    artist: exactTrack.artist,
                    source: .plainText,
                    confidence: 1
                )
            )
            songs.append(
                ImportedSong(
                    title: exactTrack.title,
                    source: .plainText,
                    confidence: 1
                )
            )
            songs.append(
                ImportedSong(
                    title: "戊己庚辛\(token)",
                    artist: alternativeTrack.artist,
                    source: .plainText,
                    confidence: 0.8
                )
            )
            songs.append(
                ImportedSong(
                    title: "完全未收录陌生标题\(token)",
                    artist: "无关演唱者\(token)",
                    source: .plainText,
                    confidence: 0.4
                )
            )
        }

        return ScaleFixture(
            catalog: catalog,
            playlist: ImportedPlaylist(
                source: .plainText,
                title: "混合规模合同",
                songs: songs,
                parseConfidence: 1
            )
        )
    }

    private func makeExactFixture(count: Int) -> ScaleFixture {
        var catalog: [KTVTrack] = []
        var songs: [ImportedSong] = []
        catalog.reserveCapacity(count)
        songs.reserveCapacity(count)

        for index in 0..<count {
            let token = String(format: "%04d", index)
            let track = makeTrack(
                id: "exact-only-\(token)",
                title: "唯一精确歌曲\(token)",
                artist: "唯一歌手\(token)"
            )
            catalog.append(track)
            songs.append(
                ImportedSong(
                    title: track.title,
                    artist: track.artist,
                    source: .plainText,
                    confidence: 1
                )
            )
        }

        return ScaleFixture(
            catalog: catalog,
            playlist: ImportedPlaylist(
                source: .plainText,
                title: "精确规模合同",
                songs: songs,
                parseConfidence: 1
            )
        )
    }

    private func makeTrack(id: String, title: String, artist: String) -> KTVTrack {
        KTVTrack(
            id: id,
            title: title,
            artist: artist,
            language: "Mandarin",
            era: "2020s",
            genre: "华语流行",
            moodTags: ["熟悉"],
            sceneTags: ["friends"],
            difficulty: 2,
            vocalRangeLowMidi: 48,
            vocalRangeHighMidi: 67,
            energy: 0.6,
            singAlongScore: 0.7,
            ktvAvailability: 0.8,
            duetFriendly: false,
            rapDensity: 0,
            highNoteRisk: 0.3,
            aliases: [],
            similarSongIds: []
        )
    }

    private func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private func milliseconds(_ duration: Duration) -> Double {
        seconds(duration) * 1_000
    }
}

private struct ScaleFixture {
    let catalog: [KTVTrack]
    let playlist: ImportedPlaylist
}

private struct ProgressEvent: Equatable, Sendable {
    let completed: Int
    let total: Int
}

private actor ProgressRecorder {
    private var events: [ProgressEvent] = []

    func append(completed: Int, total: Int) {
        events.append(ProgressEvent(completed: completed, total: total))
    }

    func snapshot() -> [ProgressEvent] {
        events
    }
}

private actor AnalysisCompletionState {
    private var finished = false

    func finish() {
        finished = true
    }

    func isFinished() -> Bool {
        finished
    }
}

private actor AsyncReleaseGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pendingContinuations = continuations
        continuations.removeAll()
        for continuation in pendingContinuations {
            continuation.resume()
        }
    }
}
