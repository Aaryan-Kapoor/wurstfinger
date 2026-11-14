//
//  HapticEngineLifecycleTests.swift
//  WurstfingerKitTests
//
//  When the Core Haptics engine may start, restart or be given up on —
//  against the pure lifecycle (this machine has no Taptic Engine) — and how
//  the player nudges a renderer that is wanted but not running.
//

import Foundation
import Testing
@testable import WurstfingerKit

private struct StartFailure: Error {}

struct HapticEngineLifecycleTests {
    private func running() -> HapticEngineLifecycle {
        var lifecycle = HapticEngineLifecycle()
        let prepare1 = lifecycle.prepare()
        #expect(prepare1)
        lifecycle.startBegan()
        lifecycle.startFinished(error: nil)
        #expect(lifecycle.state == .running)
        return lifecycle
    }

    @Test func aFailedStartIsNotForever() {
        var lifecycle = HapticEngineLifecycle()
        _ = lifecycle.prepare()
        lifecycle.startBegan()
        lifecycle.startFinished(error: StartFailure())
        // One failure (the process was being suspended, say) leaves the engine
        // idle and wanted, so the next touch may try again.
        #expect(lifecycle.state == .idle)
        #expect(lifecycle.isWanted)
        lifecycle.startBegan()
        lifecycle.startFinished(error: nil)
        #expect(lifecycle.state == .running)
        #expect(lifecycle.failedStarts == 0, "a success forgives the failures before it")
    }

    @Test func aPersistentFailureGivesUpInsteadOfLooping() {
        var lifecycle = HapticEngineLifecycle()
        _ = lifecycle.prepare()
        for _ in 0 ..< HapticEngineLifecycle.maxStartFailures {
            #expect(lifecycle.state == .idle)
            lifecycle.startBegan()
            lifecycle.startFinished(error: StartFailure())
        }
        #expect(lifecycle.state == .unavailable)
        // Gone for good: nothing wakes it.
        let prepare2 = lifecycle.prepare()
        #expect(!prepare2)
        let reset3 = lifecycle.reset()
        #expect(!reset3)
        lifecycle.startBegan()
        #expect(lifecycle.state == .unavailable)
    }

    @Test func aLateStartCompletionIsIgnoredOnceSuspended() {
        var lifecycle = HapticEngineLifecycle()
        _ = lifecycle.prepare()
        lifecycle.startBegan()
        let suspend4 = lifecycle.suspend()
        #expect(suspend4, "a start in flight is stopped too")
        lifecycle.startFinished(error: nil)
        #expect(lifecycle.state == .idle, "the completion of a start that was cancelled by suspend changes nothing")
    }

    @Test func aServerResetWhileSuspendedDoesNotRestartTheEngine() {
        var lifecycle = running()
        let suspend5 = lifecycle.suspend()
        #expect(suspend5)
        let reset6 = lifecycle.reset()
        #expect(!reset6, "off screen, the engine stays off")
        #expect(lifecycle.state == .idle)
        // Back on screen it is wanted again.
        let prepare7 = lifecycle.prepare()
        #expect(prepare7)
    }

    @Test func aServerResetOnScreenRestartsIt() {
        var lifecycle = running()
        let reset8 = lifecycle.reset()
        #expect(reset8)
        #expect(lifecycle.state == .idle)
    }

    @Test func aStopWhileSuspendedIsOurOwnAndIsNotRestarted() {
        var lifecycle = running()
        _ = lifecycle.suspend()
        let stopped9 = lifecycle.stopped(applicationWasSuspended: false)
        #expect(!stopped9)
        #expect(lifecycle.state == .idle)
    }

    @Test func aSystemStopOnScreenRestartsUnlessTheAppIsSuspended() {
        var lifecycle = running()
        let stopped10 = lifecycle.stopped(applicationWasSuspended: false)
        #expect(stopped10)
        #expect(lifecycle.state == .idle)

        var suspended = running()
        let stopped11 = suspended.stopped(applicationWasSuspended: true)
        #expect(!stopped11, "a restart now would only fail")
        #expect(suspended.state == .idle)
        #expect(suspended.isWanted, "but the next touch may start it")
    }

    @Test func aFailedPlayRestartsTheEngineItself() {
        // The stopped handler ignores an engine that is already idle, so
        // marking it idle without restarting would strand it until the next
        // appearance.
        var lifecycle = running()
        let playFailed12 = lifecycle.playFailed()
        #expect(playFailed12)
        #expect(lifecycle.state == .idle)
        let stopped13 = lifecycle.stopped(applicationWasSuspended: false)
        #expect(!stopped13, "the late stop notification finds it idle")
        let playFailed14 = lifecycle.playFailed()
        #expect(!playFailed14, "and a second failure while it restarts does not restart twice")
    }

    @Test func nothingStartsWhenNobodyAsked() {
        var lifecycle = HapticEngineLifecycle()
        let reset15 = lifecycle.reset()
        #expect(!reset15)
        let stopped16 = lifecycle.stopped(applicationWasSuspended: false)
        #expect(!stopped16)
        let playFailed17 = lifecycle.playFailed()
        #expect(!playFailed17)
        #expect(!lifecycle.isWanted)
    }
}

@MainActor
struct HapticResumeTests {
    private func makePlayer() -> (HapticFeedbackPlayer, RecordingHapticRenderer) {
        let settings = HapticSettings(defaults: InMemoryUserDefaults(), shouldPersist: false)
        let renderer = RecordingHapticRenderer()
        let player = HapticFeedbackPlayer(settings: settings, detailed: renderer, pulses: RecordingPulseRenderer())
        return (player, renderer)
    }

    @Test func aTouchNudgesAnEngineThatIsWantedButNotRunning() {
        let (player, renderer) = makePlayer()
        renderer.isReady = false
        player.prepareIfNeeded()
        player.tap()
        #expect(renderer.resumeCount >= 2)
    }

    @Test func aRunningEngineIsNotNudged() {
        let (player, renderer) = makePlayer()
        renderer.isReady = true
        player.prepareIfNeeded()
        player.tap()
        #expect(renderer.resumeCount == 0)
    }

    @Test func withDetailedHapticsOffTheEngineIsLeftAlone() {
        let settings = HapticSettings(defaults: InMemoryUserDefaults(), shouldPersist: false)
        settings.isDetailedEnabled = false
        let renderer = RecordingHapticRenderer()
        renderer.isReady = false
        let player = HapticFeedbackPlayer(settings: settings, detailed: renderer, pulses: RecordingPulseRenderer())
        player.tap()
        #expect(renderer.resumeCount == 0)
    }
}
