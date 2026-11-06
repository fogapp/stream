import AVFoundation
import XCTest
@testable import StreamTV

/// What the Apple TV tells Stream about a play (docs/APPLETV_STALLS.md ›
/// R0): the clocks and the log are pure, so they're tested without a
/// player; the keys match MediaController::EVENT_DETAIL.
final class TelemetryTests: XCTestCase {
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private func json<T: Encodable>(_ value: T) throws -> String {
        try XCTUnwrap(String(data: encoder.encode(value), encoding: .utf8))
    }

    func testStartupIsCountedFromThePressLikeTheWebs() throws {
        let pressed = Date(timeIntervalSince1970: 1_000)
        let clock = StartupClock(requestedAt: pressed, answeredAt: pressed.addingTimeInterval(0.09))
        let detail = clock.detail(firstFrameAt: pressed.addingTimeInterval(0.64))
        XCTAssertEqual(detail, EventDetail(ms: 640, sessionMs: 90, frameMs: 640))
        XCTAssertEqual(try json(PlaybackEvents(events: [.init(kind: "startup", position: 0, detail: detail)])),
                       #"{"events":[{"detail":{"frame_ms":640,"ms":640,"session_ms":90},"kind":"startup","position":0}]}"#)
    }

    func testAStallLastsFromWaitingToPlayingAndSaysWhy() {
        var clock = StallClock()
        let began = Date(timeIntervalSince1970: 2_000)
        XCTAssertNil(clock.resumed(at: began), "nothing to resume from")
        clock.waiting(at: began, reason: "minimizeStalls")
        clock.waiting(at: began.addingTimeInterval(1), reason: "evaluatingBufferingRate")
        XCTAssertEqual(clock.resumed(at: began.addingTimeInterval(2.26)), EventDetail(seconds: 2.3, via: "minimizeStalls"),
                       "the first wait's reason and start count")
        XCTAssertNil(clock.resumed(at: began.addingTimeInterval(3)), "reported once")
    }

    func testRecoveriesAreCountedByWhatTheyWere() {
        var log = RecoveryLog()
        XCTAssertTrue(log.isEmpty)
        log.add("HTTP 424", position: 12, cause: "transcoder gave up")
        log.add("playbackStalled", position: 13)
        log.add("HTTP 424", position: 20, cause: "later words are not kept")
        let events = log.drain()
        XCTAssertEqual(events, [
            .init(kind: "recovery", position: 12, detail: EventDetail(message: "HTTP 424", cause: "transcoder gave up", count: 2)),
            .init(kind: "recovery", position: 13, detail: EventDetail(message: "playbackStalled", count: 1)),
        ])
        XCTAssertTrue(log.isEmpty, "drained")
    }

    func testTheSummaryAddsUpTheAccessLogAndLeavesOutWhatWasntMeasured() throws {
        var totals = AccessTotals()
        totals.add(stalls: 1, droppedFrames: -1, watchedSeconds: 600, bitrate: 4_200_000, startupSeconds: 1.82)
        totals.add(stalls: 2, droppedFrames: 7, watchedSeconds: 688.4, bitrate: 3_900_000, startupSeconds: -1)
        XCTAssertEqual(totals.detail, EventDetail(ms: 1820, stalls: 3, droppedFrames: 7, watchedSeconds: 1288, bitrate: 3_900_000))
        XCTAssertEqual(try json(totals.detail), #"{"bitrate":3900000,"dropped_frames":7,"ms":1820,"stalls":3,"watched_seconds":1288}"#)
        XCTAssertNil(AccessTotals.of(nil))
    }

    func testAVPlayersWaitingReasonsReadShort() {
        XCTAssertEqual(PlayerTelemetry.shortReason("AVPlayerWaitingToMinimizeStallsReason"), "toMinimizeStalls")
        XCTAssertEqual(PlayerTelemetry.shortReason("AVPlayerWaitingWhileEvaluatingBufferingRateReason"), "whileEvaluatingBufferingRate")
        XCTAssertEqual(PlayerTelemetry.shortReason("Other"), "other")
    }
}

final class BufferingTests: XCTestCase {
    func testAPlayerOnScreenBuffersAMinuteAndOneTunedAheadTenSeconds() throws {
        let url = try XCTUnwrap(URL(string: "https://stream.example/media/s/token/hls/index.m3u8"))
        XCTAssertEqual(Buffering.item(url: url, standby: false).preferredForwardBufferDuration, 60)
        XCTAssertEqual(Buffering.item(url: url, standby: true).preferredForwardBufferDuration, 10)
        XCTAssertLessThan(Buffering.watching * 1000, Double(180_000), "inside the transcoder's lead (Supervisor::AHEAD_PAUSE_MS)")
    }

    @MainActor func testAPlayerChangingRoleChangesItsBuffer() throws {
        let url = try XCTUnwrap(URL(string: "https://stream.example/media/s/token/hls/index.m3u8"))
        let player = AVPlayer(playerItem: Buffering.item(url: url, standby: true))
        Buffering.set(player, standby: false)
        XCTAssertEqual(player.currentItem?.preferredForwardBufferDuration, 60)
        Buffering.set(player, standby: true)
        XCTAssertEqual(player.currentItem?.preferredForwardBufferDuration, 10)
    }
}

final class SubtitleWaitTests: XCTestCase {
    func testAsksAgainOnlyWhileStreamSaysTheTrackIsComing() {
        XCTAssertEqual(SubtitleWait.delay(status: 503, retryAfter: "10"), 10)
        XCTAssertEqual(SubtitleWait.delay(status: 503, retryAfter: "120"), 30, "never more than half a minute")
        XCTAssertEqual(SubtitleWait.delay(status: 503, retryAfter: nil), 10)
        XCTAssertNil(SubtitleWait.delay(status: 200, retryAfter: nil))
        XCTAssertNil(SubtitleWait.delay(status: 422, retryAfter: "10"), "why there isn't one is the answer")
    }
}
