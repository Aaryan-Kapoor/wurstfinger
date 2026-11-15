//
//  GestureTraceTests.swift
//  WurstfingerTests
//
//  The opt-in gesture recorder: what a record holds (geometry, never text), how
//  gestures are labelled corrected or accepted, the capped store, the recorder's
//  batching on a manual clock, when the view model allows recording at all, and
//  the replay of an export through the gesture lab.
//

import CoreGraphics
import Foundation
import Testing
@testable import WurstfingerKit
@testable import WurstfingerScenarioKit

// MARK: - Helpers

private func record(
    slot: String = "topLeft", classified: GestureType = .swipeDown, isReturn: Bool = false
) -> GestureTraceRecord {
    GestureTraceRecord(
        meant: classified.rawValue, meantIsReturn: isReturn, label: .accepted,
        classified: classified.rawValue, classifiedIsReturn: isReturn,
        slot: slot, keyWidth: 80, keyHeight: 58,
        samples: [[0, 0, 0], [0, 0.3, 0.05], [0, 0.6, 0.1]], peakTime: 0.1, duration: 0.1
    )
}

private func temporaryStore() -> GestureTraceStore {
    GestureTraceStore(
        fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("trace-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("traces.jsonl")
    )
}

private func cleanUp(_ store: GestureTraceStore) {
    try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent())
}

// MARK: - Labelling

struct GestureTraceLabelerTests {
    private func run(_ steps: (inout GestureTraceLabeler) -> [GestureTraceRecord]) -> [GestureTraceRecord] {
        var labeler = GestureTraceLabeler()
        return steps(&labeler)
    }

    @Test func aGestureNothingContradictsIsAccepted() {
        let decided = run { labeler in
            _ = labeler.gesture(record(), endedAt: 10)
            return labeler.gesture(record(slot: "center", classified: .tap), endedAt: 11)
        }
        #expect(decided.map(\.label) == [.accepted])
    }

    @Test func aDeleteThenADifferentGestureOnTheSameKeyIsACorrection() {
        let decided = run { labeler in
            _ = labeler.gesture(record(classified: .swipeRight), endedAt: 10)
            labeler.delete(at: 10.8)
            return labeler.gesture(record(classified: .swipeDownRight), endedAt: 11.5)
        }
        #expect(decided.count == 1)
        #expect(decided[0].label == .corrected)
        #expect(decided[0].classified == "swipeRight", "what the recognizer said stays")
        #expect(decided[0].meant == "swipeDownRight", "what the retry was read as is the probable intent")
    }

    @Test func aRetryThatReadsTheSameIsNotACorrection() {
        let decided = run { labeler in
            _ = labeler.gesture(record(classified: .swipeRight), endedAt: 10)
            labeler.delete(at: 10.5)
            return labeler.gesture(record(classified: .swipeRight), endedAt: 11)
        }
        #expect(decided[0].label == .accepted)
    }

    @Test func aRetryOnAnotherKeyIsNotACorrection() {
        let decided = run { labeler in
            _ = labeler.gesture(record(slot: "topLeft"), endedAt: 10)
            labeler.delete(at: 10.5)
            return labeler.gesture(record(slot: "center", classified: .swipeUp), endedAt: 11)
        }
        #expect(decided[0].label == .accepted)
    }

    @Test func aDeleteTooLateOrARetryTooLateIsNotACorrection() {
        let lateDelete = run { labeler in
            _ = labeler.gesture(record(classified: .swipeRight), endedAt: 10)
            labeler.delete(at: 12.5)
            return labeler.gesture(record(classified: .swipeDownRight), endedAt: 13)
        }
        #expect(lateDelete[0].label == .accepted)
        let lateRetry = run { labeler in
            _ = labeler.gesture(record(classified: .swipeRight), endedAt: 10)
            labeler.delete(at: 10.5)
            return labeler.gesture(record(classified: .swipeDownRight), endedAt: 12.6)
        }
        #expect(lateRetry[0].label == .accepted)
    }

    @Test func aDeleteBeforeAnyGestureDoesNothing() {
        let decided = run { labeler in
            labeler.delete(at: 5)
            _ = labeler.gesture(record(classified: .swipeRight), endedAt: 10)
            return labeler.gesture(record(classified: .swipeUp), endedAt: 11)
        }
        #expect(decided[0].label == .accepted)
    }

    @Test func anIntermediateGestureCancelsTheCorrection() {
        // delete, then a gesture elsewhere, then a retry: the delete belonged
        // to the elsewhere gesture's predecessor only.
        let decided = run { labeler in
            var out: [GestureTraceRecord] = []
            _ = labeler.gesture(record(classified: .swipeRight), endedAt: 10)
            labeler.delete(at: 10.4)
            out += labeler.gesture(record(slot: "center", classified: .tap), endedAt: 10.8)
            out += labeler.gesture(record(slot: "center", classified: .swipeUp), endedAt: 11.2)
            return out
        }
        #expect(decided.map(\.label) == [.accepted, .accepted])
    }

    @Test func aPendingGestureSettlesAsAcceptedOnceItsWindowHasPassed() {
        var labeler = GestureTraceLabeler()
        _ = labeler.gesture(record(), endedAt: 10)
        #expect(labeler.settle(at: 11).isEmpty)
        #expect(labeler.hasPending)
        #expect(labeler.settle(at: 12.5).map(\.label) == [.accepted])
        #expect(!labeler.hasPending)
    }

    @Test func forceSettlesAtOnce() {
        var labeler = GestureTraceLabeler()
        _ = labeler.gesture(record(), endedAt: 10)
        #expect(labeler.settle(at: 10, force: true).count == 1)
    }
}

// MARK: - The record

struct GestureTraceRecordTests {
    @Test func theJSONNamesNoCharacterNoTextNoLanguageNoClock() throws {
        let data = try JSONEncoder().encode(record())
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == [
            "version", "meant", "meantIsReturn", "label", "classified", "classifiedIsReturn",
            "slot", "keyWidth", "keyHeight", "samples", "peakTime", "duration",
        ])
        #expect(object["slot"] as? String == "topLeft")
    }

    @Test func translationsAreFromTheLandingInPoints() {
        let r = GestureTraceRecord(
            meant: "swipeRight", meantIsReturn: false, label: .accepted, classified: "swipeRight", classifiedIsReturn: false,
            slot: "center", keyWidth: 80, keyHeight: 50,
            samples: [[0.2, -0.1, 0], [0.4, -0.1, 0.05], [0.6, 0.1, 0.1]], peakTime: 0.1, duration: 0.1
        )
        let t = r.translations
        #expect(t.count == 3)
        #expect(t[0] == .zero)
        #expect(abs(t[1].x - 10) < 1e-9 && abs(t[1].y) < 1e-9)
        #expect(abs(t[2].x - 20) < 1e-9 && abs(t[2].y - 10) < 1e-9)
    }
}

// MARK: - The store

struct GestureTraceStoreTests {
    @Test func appendCountLoadAndClear() {
        let store = temporaryStore()
        defer { cleanUp(store) }
        #expect(store.count() == 0)
        #expect(store.append([record(), record(slot: "center")]) == 2)
        #expect(store.append([record(slot: "bottomRight")]) == 3)
        #expect(store.load().map(\.slot) == ["topLeft", "center", "bottomRight"])
        store.clear()
        #expect(store.count() == 0)
        #expect(store.load().isEmpty)
    }

    @Test func theStoreIsACappedRingBufferKeepingTheNewest() {
        let store = temporaryStore()
        defer { cleanUp(store) }
        let total = GestureTraceStore.capacity + GestureTraceStore.slack + 50
        let all = (0 ..< total).map { index -> GestureTraceRecord in
            var r = record()
            r.slot = "slot\(index)"
            return r
        }
        // In batches, like the recorder writes them.
        for start in stride(from: 0, to: total, by: 100) {
            store.append(Array(all[start ..< min(start + 100, total)]))
        }
        let loaded = store.load()
        #expect(store.count() <= GestureTraceStore.capacity)
        #expect(loaded.count <= GestureTraceStore.capacity)
        #expect(loaded.last?.slot == "slot\(total - 1)")
        #expect(loaded.first?.slot != "slot0")
    }

    @Test func aCorruptLineIsSkipped() throws {
        let store = temporaryStore()
        defer { cleanUp(store) }
        store.append([record(slot: "a1")])
        let handle = try FileHandle(forWritingTo: store.fileURL)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n".utf8))
        try handle.close()
        store.append([record(slot: "a2")])
        #expect(store.load().map(\.slot) == ["a1", "a2"])
    }

    @Test func theExportIsOneJSONArrayTheLabReads() throws {
        let store = temporaryStore()
        defer { cleanUp(store) }
        store.append([record(), record(slot: "center", classified: .tap)])
        let data = try #require(store.exportJSON())
        let traces = try GestureTrace.traces(fromExport: data)
        #expect(traces.count == 2)
        #expect(traces[1].record.slot == "center")
        #expect(traces[1].trace.meant == "tap")
    }

    @Test func theSharedStoreIsAScratchDirectoryUnderTests() {
        #expect(GestureTraceStore.shared.fileURL.path.contains("wurstfinger-gesture-traces-"))
    }
}

// MARK: - The recorder

@MainActor
struct GestureTraceRecorderTests {
    private func makeRecorder(store: GestureTraceStore?, timers: ManualTimerSource, inline: Bool = true) -> GestureTraceRecorder {
        GestureTraceRecorder(store: store, timers: timers, writesInline: inline)
    }

    private func gesture(
        _ recorder: GestureTraceRecorder, id: PointerID = 1, slot: String = "topLeft", offset: CGPoint = .zero,
        to end: CGPoint, start: TimeInterval, classified: GestureType = .swipeRight
    ) {
        recorder.began(id, keyId: slot, keySize: CGSize(width: 80, height: 50), offset: offset, time: start)
        recorder.moved(id, translation: CGPoint(x: end.x / 2, y: end.y / 2), time: start + 0.03)
        recorder.ended(id, translation: end, time: start + 0.06, classification: GestureClassification(gesture: classified, isReturn: false))
    }

    @Test func aRecordHoldsTheGeometryInKeyHeightsFromTheKeysCentre() throws {
        let store = temporaryStore()
        defer { cleanUp(store) }
        let clock = ManualTimerSource(now: 100)
        let recorder = makeRecorder(store: store, timers: clock)
        gesture(recorder, offset: CGPoint(x: -10, y: 5), to: CGPoint(x: 30, y: 0), start: 100)
        recorder.flush(force: true)

        let r = try #require(store.load().first)
        #expect(r.slot == "topLeft")
        #expect(r.keyWidth == 80 && r.keyHeight == 50)
        #expect(r.samples.count == 3)
        // The landing: (-10, 5) points from the centre, in key heights.
        #expect(abs(r.samples[0][0] - (-0.2)) < 1e-9 && abs(r.samples[0][1] - 0.1) < 1e-9)
        // The lift: 30 points further along x.
        #expect(abs(r.samples[2][0] - 0.4) < 1e-9)
        #expect(abs(r.samples[2][2] - 0.06) < 1e-9, "seconds since touch-down")
        #expect(r.classified == "swipeRight" && r.label == .accepted)
        #expect(abs(r.peakTime - 0.06) < 1e-9)
    }

    @Test func recordsAreWrittenInOneBatchOnTheTimerNeverPerGesture() {
        let store = temporaryStore()
        defer { cleanUp(store) }
        let clock = ManualTimerSource(now: 100)
        let recorder = makeRecorder(store: store, timers: clock)
        for i in 0 ..< 4 {
            gesture(recorder, to: CGPoint(x: 30, y: 0), start: 100 + Double(i) * 0.4)
        }
        // The fifth lands just before the batch is due.
        clock.advance(to: 104.4)
        gesture(recorder, to: CGPoint(x: 30, y: 0), start: 104.5)
        #expect(store.count() == 0, "nothing is written while typing")
        #expect(clock.pendingCount == 1, "one flush timer, however many gestures")

        clock.advance(to: 100 + GestureTraceRecorder.flushDelay + 0.1)
        // Four are decided; the fifth still waits for a possible correction.
        #expect(store.count() == 4)
        // The pending one is looked at again and settles once its window passed.
        clock.advance(by: GestureTraceRecorder.flushDelay + GestureTraceLabeler.window)
        #expect(store.count() == 5)
        #expect(clock.pendingCount == 0)
    }

    @Test func aDeleteThenADifferentGestureOnTheSameKeyIsStoredAsCorrected() {
        let store = temporaryStore()
        defer { cleanUp(store) }
        let clock = ManualTimerSource(now: 100)
        let recorder = makeRecorder(store: store, timers: clock)
        gesture(recorder, to: CGPoint(x: 30, y: 0), start: 100, classified: .swipeRight)
        clock.advance(to: 100.7)
        recorder.noteDelete()
        gesture(recorder, to: CGPoint(x: 25, y: 20), start: 101, classified: .swipeDownRight)
        recorder.stop()

        let stored = store.load()
        #expect(stored.map(\.label) == [.corrected, .accepted])
        #expect(stored[0].classified == "swipeRight" && stored[0].meant == "swipeDownRight")
    }

    @Test func aCancelledTouchLeavesNothing() {
        let store = temporaryStore()
        defer { cleanUp(store) }
        let clock = ManualTimerSource(now: 100)
        let recorder = makeRecorder(store: store, timers: clock)
        recorder.began(1, keyId: "a", keySize: CGSize(width: 80, height: 50), offset: .zero, time: 100)
        recorder.moved(1, translation: CGPoint(x: 5, y: 0), time: 100.02)
        recorder.cancelled(1)
        recorder.ended(1, translation: .zero, time: 100.1, classification: GestureClassification(gesture: .tap, isReturn: false))
        recorder.stop()
        #expect(store.count() == 0)
    }

    @Test func twoFingersAreRecordedApart() {
        let store = temporaryStore()
        defer { cleanUp(store) }
        let clock = ManualTimerSource(now: 100)
        let recorder = makeRecorder(store: store, timers: clock)
        recorder.began(1, keyId: "left", keySize: CGSize(width: 80, height: 50), offset: .zero, time: 100)
        recorder.began(2, keyId: "right", keySize: CGSize(width: 80, height: 50), offset: .zero, time: 100.01)
        recorder.ended(2, translation: CGPoint(x: 0, y: -30), time: 100.05, classification: GestureClassification(gesture: .swipeUp, isReturn: false))
        recorder.ended(1, translation: CGPoint(x: 30, y: 0), time: 100.07, classification: GestureClassification(gesture: .swipeRight, isReturn: false))
        recorder.stop()
        #expect(Set(store.load().map(\.slot)) == ["left", "right"])
    }

    @Test func aRecorderWithoutAStoreKeepsNothing() {
        let clock = ManualTimerSource(now: 100)
        let recorder = makeRecorder(store: nil, timers: clock)
        gesture(recorder, to: CGPoint(x: 30, y: 0), start: 100)
        recorder.stop()
        #expect(clock.pendingCount == 0)
    }

    @Test func theBackgroundWriteLandsAndNeverOverlaps() async throws {
        let store = temporaryStore()
        defer { cleanUp(store) }
        let clock = ManualTimerSource(now: 100)
        let recorder = makeRecorder(store: store, timers: clock, inline: false)
        for i in 0 ..< 3 { gesture(recorder, to: CGPoint(x: 30, y: 0), start: 100 + Double(i) * 0.3) }
        recorder.stop()
        // The write is a background task; poll with a generous deadline.
        let end = ContinuousClock().now.advanced(by: .seconds(20))
        while store.count() < 3, ContinuousClock().now < end {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.count() == 3)
    }
}

// MARK: - When the view model may record

@MainActor
@Suite(.serialized)
struct GestureTraceGatingTests {
    private func makeModel(
        recording: Bool = true, fullAccess: Bool = true, traits: FieldTraits = .standard
    ) -> KeyboardViewModel {
        let defaults = InMemoryUserDefaults()
        defaults.set(recording, forKey: SettingsKey.gestureTraceRecording.rawValue)
        defaults.set(fullAccess, forKey: SettingsKey.keyboardFullAccess.rawValue)
        let model = KeyboardViewModel(
            userDefaults: defaults, shouldPersistSettings: false, timers: ManualTimerSource(now: 0),
            gestureTraceStore: temporaryStore()
        )
        model.fieldTraits = traits
        return model
    }

    @Test func offByDefault() {
        let model = KeyboardViewModel(userDefaults: InMemoryUserDefaults(), shouldPersistSettings: false)
        #expect(!model.mayRecordGestureTraces)
        #expect(model.traceRecorder == nil)
        #expect(model.touchEngine.traceSink == nil)
    }

    @Test func recordsWhenOnWithFullAccessInAnOrdinaryField() {
        let model = makeModel()
        #expect(model.mayRecordGestureTraces)
        #expect(model.traceRecorder != nil)
        #expect(model.touchEngine.traceSink === model.traceRecorder)
    }

    @Test func needsFullAccess() {
        let model = makeModel(fullAccess: false)
        #expect(!model.mayRecordGestureTraces)
        #expect(model.touchEngine.traceSink == nil)
    }

    @Test func neverInASensitiveField() {
        var traits = FieldTraits.standard
        traits.isSensitive = true
        let model = makeModel(traits: traits)
        #expect(!model.mayRecordGestureTraces)
        #expect(model.touchEngine.traceSink == nil)
    }

    @Test func notWhereTheHostTurnsSuggestionsOff() {
        // URL, email, number, username and autocorrection-off fields.
        var traits = FieldTraits.standard
        traits.suppressesCompletions = true
        let model = makeModel(traits: traits)
        #expect(!model.mayRecordGestureTraces)
        #expect(model.touchEngine.traceSink == nil)
    }

    @Test func enteringASensitiveFieldStopsRecordingAndWritesWhatWaits() async throws {
        let store = temporaryStore()
        defer { cleanUp(store) }
        let defaults = InMemoryUserDefaults()
        defaults.set(true, forKey: SettingsKey.gestureTraceRecording.rawValue)
        defaults.set(true, forKey: SettingsKey.keyboardFullAccess.rawValue)
        let model = KeyboardViewModel(
            userDefaults: defaults, shouldPersistSettings: false, timers: ManualTimerSource(now: 0), gestureTraceStore: store
        )
        let recorder = try #require(model.traceRecorder)
        recorder.began(1, keyId: "a", keySize: CGSize(width: 80, height: 50), offset: .zero, time: 1)
        recorder.ended(1, translation: CGPoint(x: 30, y: 0), time: 1.05, classification: GestureClassification(gesture: .swipeRight, isReturn: false))

        var traits = FieldTraits.standard
        traits.isSensitive = true
        model.fieldTraits = traits

        #expect(model.traceRecorder == nil)
        #expect(model.touchEngine.traceSink == nil)
        // What was recorded in the ordinary field is written when recording
        // stops (on a background task: poll with a generous deadline).
        let end = ContinuousClock().now.advanced(by: .seconds(20))
        while store.count() < 1, ContinuousClock().now < end {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.count() == 1)
    }

    @Test func turningTheSettingOffOnReloadStopsRecording() {
        let model = makeModel()
        #expect(model.traceRecorder != nil)
        model.sharedDefaults.set(false, forKey: SettingsKey.gestureTraceRecording.rawValue)
        model.reloadSettings()
        #expect(model.traceRecorder == nil)
        #expect(model.touchEngine.traceSink == nil)
    }
}

// MARK: - Through the touch engine

@MainActor
@Suite(.serialized)
struct GestureTraceEngineTests {
    /// Waits (generously; a passing run returns at once) for the background
    /// write to leave `count` traces in the shared store.
    private func waitForTraces(_ count: Int) async throws {
        let end = ContinuousClock().now.advanced(by: .seconds(20))
        while GestureTraceStore.shared.count() < count, ContinuousClock().now < end {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A scenario on a manual clock with recording on; its view model writes to
    /// the shared store, a scratch directory under the test runner.
    private func makeScenario(timers: ManualTimerSource) -> (KeyboardScenario, KeyboardViewModel) {
        let scenario = KeyboardScenario(
            language: "en_US", autoCapitalize: false,
            settings: [.gestureTraceRecording: true, .keyboardFullAccess: true],
            timers: timers
        )
        return (scenario, scenario.viewModel)
    }

    @Test func aFlickThroughTheEngineIsRecordedWithItsSlotAndNoCharacter() async throws {
        let timers = ManualTimerSource(now: 1000)
        let (scenario, viewModel) = makeScenario(timers: timers)
        let recorder = try #require(viewModel.traceRecorder)
        // The scenario's view model writes to the shared (per-process, temporary) store.
        GestureTraceStore.shared.clear()
        defer { GestureTraceStore.shared.clear() }

        let outcome = scenario.swipe(GridSlot.topLeft, .swipeDown)
        #expect(outcome.gesture == .swipeDown)
        recorder.stop()
        try await waitForTraces(1)

        let stored = GestureTraceStore.shared.load()
        let r = try #require(stored.last)
        #expect(r.slot == GridSlot.topLeft)
        #expect(r.classified == "swipeDown")
        #expect(r.samples.count >= 3)
        // The line holds the record's fields and nothing of what was typed.
        let line = try #require(String(contentsOf: GestureTraceStore.shared.fileURL, encoding: .utf8)
            .split(separator: "\n").last)
        let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(object.keys.count == 12)
        #expect(!scenario.text.isEmpty && !line.contains(scenario.text))
    }

    @Test func aSlideOnTheDeleteKeyIsNotRecorded() throws {
        let timers = ManualTimerSource(now: 1000)
        let (scenario, viewModel) = makeScenario(timers: timers)
        let recorder = try #require(viewModel.traceRecorder)
        GestureTraceStore.shared.clear()
        defer { GestureTraceStore.shared.clear() }
        scenario.drag(UtilitySlot.delete, by: CGSize(width: -60, height: 0))
        recorder.stop()
        #expect(GestureTraceStore.shared.count() == 0)
    }

    @Test func recordingOffLeavesTheEngineUntouched() {
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: false)
        #expect(scenario.viewModel.traceRecorder == nil)
        #expect(scenario.viewModel.touchEngine.traceSink == nil)
        scenario.swipe(GridSlot.topLeft, .swipeDown)
    }

    @Test func aDeleteThroughTheViewModelLabelsTheGestureBeforeItCorrected() async throws {
        let timers = ManualTimerSource(now: 1000)
        let (scenario, viewModel) = makeScenario(timers: timers)
        let recorder = try #require(viewModel.traceRecorder)
        GestureTraceStore.shared.clear()
        defer { GestureTraceStore.shared.clear() }

        scenario.swipe(GridSlot.topLeft, .swipeRight)
        // The scenario's clock runs past each gesture; the recorder compares the
        // delete (on the view model's manual clock) with the lift (the engine's
        // touch clock), which the scenario started at 1000.
        timers.advance(to: 1000.5)
        viewModel.dispatchAction(.deleteBackward)
        scenario.swipe(GridSlot.topLeft, .swipeDownRight)
        recorder.stop()
        try await waitForTraces(2)

        let labels = GestureTraceStore.shared.load().map(\.label)
        #expect(labels == [.corrected, .accepted])
    }
}

// MARK: - Replay

struct GestureTraceReplayTests {
    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/gesture-traces.json")
    }

    private func fixture() throws -> [(record: GestureTraceRecord, trace: GestureTrace)] {
        try GestureTrace.traces(fromExport: Data(contentsOf: Self.fixtureURL))
    }

    @Test func theFixtureHoldsEveryClassAndSomeCorrections() throws {
        let traces = try fixture()
        let meant = Set(traces.map { "\($0.trace.meant)\($0.trace.isReturn ? "-return" : "")" })
        #expect(meant.count >= 19)
        #expect(traces.contains { $0.record.label == .corrected })
        #expect(traces.contains { $0.record.label == .accepted })
    }

    @Test func everyTraceReplaysToTheVerdictItWasRecordedWith() throws {
        // The key-height conversion loses nothing: the classifier reads the
        // replayed path exactly as it read the live one.
        for (record, trace) in try fixture() {
            let verdict = LabLabel(GestureLab.classify(trace.gesture))
            #expect(verdict.gesture.rawValue == record.classified, "\(record.slot) \(record.meant)")
            #expect(verdict.isReturn == record.classifiedIsReturn, "\(record.slot) \(record.meant)")
        }
    }

    @Test func theAcceptedTracesAreAPerfectMatrixAndTheCorrectedOnesShowWhereItErred() throws {
        let traces = try fixture()
        let accepted = GestureLab.matrix(replaying: traces.filter { $0.record.label == .accepted }.map(\.trace.gesture))
        #expect(accepted.overallAccuracy == 1)
        let corrected = GestureLab.matrix(replaying: traces.filter { $0.record.label == .corrected }.map(\.trace.gesture))
        #expect(corrected.overallAccuracy == 0, "a corrected trace is one the recognizer got wrong")
        #expect(!corrected.worstConfusions().isEmpty)
    }

    /// Writes the fixture from the lab: `GESTURE_LAB_FIXTURE=<path> swift test --filter writeTheFixture`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GESTURE_LAB_FIXTURE"] != nil))
    func writeTheFixture() throws {
        var records: [GestureTraceRecord] = []
        let clean = GestureLab(profile: .clean, seed: 0xF1)
        for label in LabLabel.all {
            for g in clean.gestures(label, count: 1) {
                records.append(GestureTraceRecord(g, classifiedAs: LabLabel(GestureLab.classify(g)), slot: "center"))
            }
        }
        // Three the recogniser misread (corrected), from the sloppiest profile.
        var corrections = 0
        for g in GestureLab(profile: .fastTyping, seed: 0xF2).gestures(LabLabel(gesture: .swipeRight), count: 600) where corrections < 3 {
            let verdict = LabLabel(GestureLab.classify(g))
            if verdict != g.label {
                records.append(GestureTraceRecord(g, classifiedAs: verdict, slot: "topLeft"))
                corrections += 1
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(records).write(to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["GESTURE_LAB_FIXTURE"] ?? ""))
    }
}
