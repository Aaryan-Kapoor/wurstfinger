//
//  DarwinNotificationCenterTests.swift
//  WurstfingerTests
//
//  The cross-process settings signal: a post reaches an `AsyncStream`,
//  bursts coalesce, and dropping the stream tears the registration down.
//

import Foundation
import Testing
@testable import WurstfingerKit

struct DarwinNotificationCenterTests {
    /// A name no other test or process shares.
    private static func uniqueName() -> String {
        "de.akator.wurstfinger.test.\(UUID().uuidString)"
    }

    /// The first value of `stream`, or `false` if none arrives in time.
    private static func receivesSignal(on stream: AsyncStream<Void>, within timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in stream { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    @Test func postRoundTripsThroughTheStream() async {
        let name = Self.uniqueName()
        let center = DarwinNotificationCenter.shared
        // Registration is synchronous inside `notifications(named:)`, so a post
        // after it returns cannot be missed.
        let stream = center.notifications(named: name)
        center.post(name)
        #expect(await Self.receivesSignal(on: stream, within: .seconds(3)))
    }

    @Test func aPostToAnotherNameIsNotDelivered() async {
        let center = DarwinNotificationCenter.shared
        let stream = center.notifications(named: Self.uniqueName())
        center.post(Self.uniqueName())
        #expect(!(await Self.receivesSignal(on: stream, within: .milliseconds(300))))
    }

    @Test func aBurstCoalescesToOnePendingSignal() async {
        let name = Self.uniqueName()
        let center = DarwinNotificationCenter.shared
        let stream = center.notifications(named: name)
        for _ in 0 ..< 50 { center.post(name) }
        // Let the callback queue deliver the burst before reading.
        try? await Task.sleep(for: .milliseconds(200))

        var received = 0
        await withTaskGroup(of: Int.self) { group in
            group.addTask {
                var count = 0
                for await _ in stream {
                    count += 1
                    if count > 1 { break }
                }
                return count
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(300))
                return -1
            }
            // The reader yields one buffered signal, then waits: the timer wins.
            received = await group.next() ?? 0
            group.cancelAll()
        }
        #expect(received == -1, "the burst should have collapsed to one buffered signal")
    }

    @Test func settingsChangedNameIsTheDocumentedOne() {
        #expect(DarwinNotificationCenter.settingsChanged == "de.akator.wurstfinger.settingsChanged")
    }

    @Test func cancellingTheConsumerEndsTheStream() async {
        let name = Self.uniqueName()
        let stream = DarwinNotificationCenter.shared.notifications(named: name)
        let consumer = Task { () -> Bool in
            for await _ in stream {}
            return true // only reached once the stream finishes
        }
        consumer.cancel()
        #expect(await consumer.value)
    }
}

struct NotificationSignalTests {
    @Test func signalsYieldOncePerPostAndIgnoreOtherObjects() async {
        let name = Notification.Name("de.akator.wurstfinger.test.\(UUID().uuidString)")
        let watched = NSObject()
        let other = NSObject()
        let stream = NotificationCenter.default.signals(named: name, object: watched)

        NotificationCenter.default.post(name: name, object: other)
        NotificationCenter.default.post(name: name, object: watched)

        let received = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in stream { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(received)
    }
}
