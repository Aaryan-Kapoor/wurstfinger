//
//  GestureTraceRecord.swift
//  Wurstfinger
//
//  What the opt-in gesture recorder stores about one gesture: its shape and
//  timing, and how the recognizer read it. Never what it typed.
//

import Foundation

/// One recorded gesture.
///
/// **Geometry only.** The samples are the finger's path relative to the *centre
/// of the key* in key heights, with the seconds since touch-down: where on a
/// key a thumb lands and how it moves is exactly what tuning the recognizer
/// needs, and it says nothing about the text. The record names the key's slot
/// (`topLeft`, not a letter), the recognizer's verdict and, for a corrected
/// gesture, the verdict that replaced it. It holds no character, no text from
/// the field, no language, and no wall-clock time. (Slot and gesture together
/// do identify a character to anyone who knows the layout — which is why
/// nothing is recorded in sensitive, URL, email or code fields, why the file
/// stays on the device, and why exporting it is the user's own act.)
///
/// The JSON this encodes is what `GestureTrace` in the lab reads: `meant`
/// is the label to replay against.
struct GestureTraceRecord: Codable, Sendable, Equatable {
    static let currentVersion = 1

    enum Label: String, Codable, Sendable {
        /// Nothing contradicted it: the user went on typing.
        case accepted
        /// The user deleted it and made another gesture on the same key: the
        /// recognizer probably read it wrong, and `meant` is what the second
        /// gesture was read as.
        case corrected
    }

    var version = GestureTraceRecord.currentVersion
    /// The gesture to replay against: the recognizer's own verdict for an
    /// accepted gesture, the follow-up's verdict for a corrected one.
    var meant: String
    var meantIsReturn: Bool
    var label: Label
    /// The recognizer's verdict on this gesture as it happened.
    var classified: String
    var classifiedIsReturn: Bool
    /// The key's slot id (`GridSlot`), not its character.
    var slot: String
    /// The key's size in points.
    var keyWidth: Double
    var keyHeight: Double
    /// `[x, y, t]` per sample: x and y in key heights from the key's centre,
    /// t in seconds since touch-down. The first sample is where the finger landed.
    var samples: [[Double]]
    /// Seconds to the farthest point from the landing, and to the lift.
    var peakTime: Double
    var duration: Double

    /// The path as the classifier takes it: translations from the landing, in
    /// points, in the order they were recorded.
    var translations: [CGPoint] {
        guard let first = samples.first, first.count >= 2 else { return [] }
        return samples.compactMap { sample in
            guard sample.count >= 2 else { return nil }
            return CGPoint(x: (sample[0] - first[0]) * keyHeight, y: (sample[1] - first[1]) * keyHeight)
        }
    }
}

// MARK: - Labelling

/// Decides which recorded gestures were corrected.
///
/// A gesture is **corrected** when the user deletes within two seconds of it and
/// then, within two seconds of the delete, makes a gesture on the *same key* the
/// recognizer reads differently: they undid it and tried again, so the second
/// reading is the probable intent. Everything else — including a retry that reads
/// the same, and a retry on another key — is accepted. A pure value type driven
/// by the recorder, so the rule is testable without touching anything.
struct GestureTraceLabeler {
    /// How long a delete may follow a gesture, and a retry follow the delete.
    static let window: TimeInterval = 2

    private var pending: GestureTraceRecord?
    private var pendingEnd: TimeInterval = 0
    private var deleteTime: TimeInterval?

    /// A gesture finished at `time`. Returns the records now decided: the
    /// previous gesture, as accepted or corrected.
    mutating func gesture(_ record: GestureTraceRecord, endedAt time: TimeInterval) -> [GestureTraceRecord] {
        var decided: [GestureTraceRecord] = []
        if var previous = pending {
            if let deleted = deleteTime,
               deleted >= pendingEnd, deleted - pendingEnd <= Self.window, time - deleted <= Self.window,
               previous.slot == record.slot,
               previous.classified != record.classified || previous.classifiedIsReturn != record.classifiedIsReturn {
                previous.label = .corrected
                previous.meant = record.classified
                previous.meantIsReturn = record.classifiedIsReturn
            }
            decided.append(previous)
        }
        pending = record
        pendingEnd = time
        deleteTime = nil
        return decided
    }

    /// Whether a gesture is still waiting to be decided.
    var hasPending: Bool { pending != nil }

    /// The user deleted at `time`.
    mutating func delete(at time: TimeInterval) {
        guard pending != nil else { return }
        deleteTime = time
    }

    /// The pending gesture as accepted, once nothing can correct it any more
    /// (`time` is past its window), or unconditionally with `force`.
    mutating func settle(at time: TimeInterval, force: Bool = false) -> [GestureTraceRecord] {
        guard let previous = pending else { return [] }
        let reference = deleteTime ?? pendingEnd
        guard force || time - reference > Self.window else { return [] }
        pending = nil
        deleteTime = nil
        return [previous]
    }
}

// MARK: - Store

/// The recorded traces, in a file in the app group container: JSON lines, one
/// record each, newest last, capped at `capacity`.
///
/// Appending is a write at the end of the file; the file is rewritten (oldest
/// dropped) only when it has outgrown the cap by `slack`, so a burst of typing
/// never rewrites it. Plain value, no state: every call goes to the file, so the
/// recorder can run it off the main actor and the app can read it directly.
struct GestureTraceStore: Sendable {
    /// Most traces kept: the last 2000.
    static let capacity = 2000
    /// How far past `capacity` the file may grow before it is trimmed.
    static let slack = 200

    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// The production store: the app group container's `GestureTraces/traces.jsonl`
    /// (the shared container is why recording needs Full Access); the app's
    /// Application Support directory where the app group is unavailable; a
    /// throwaway temporary directory under the unit-test runner and the UI tests'
    /// isolated launch, so neither can reach the user's real traces.
    static var shared: GestureTraceStore { sharedStore }

    private static let sharedStore: GestureTraceStore = {
        let fileManager = FileManager.default
        if UnitTestHost.isActive || ProcessInfo.processInfo.arguments.contains(SharedDefaults.isolatedStoreArgument) {
            let process = ProcessInfo.processInfo.processIdentifier
            return GestureTraceStore(
                fileURL: fileManager.temporaryDirectory
                    .appendingPathComponent("wurstfinger-gesture-traces-\(process)", isDirectory: true)
                    .appendingPathComponent("traces.jsonl")
            )
        }
        let base = fileManager.containerURL(forSecurityApplicationGroupIdentifier: SharedDefaults.suiteName)
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return GestureTraceStore(
            fileURL: base.appendingPathComponent("GestureTraces", isDirectory: true).appendingPathComponent("traces.jsonl")
        )
    }()

    private static let newline = Data([0x0A])

    /// Adds `records` and trims to the cap. Returns how many traces the file
    /// holds afterwards (0 if it could not be written).
    @discardableResult
    func append(_ records: [GestureTraceRecord]) -> Int {
        guard !records.isEmpty else { return count() }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        var data = Data()
        for record in records {
            guard let line = try? encoder.encode(record) else { continue }
            data.append(line)
            data.append(Self.newline)
        }
        guard !data.isEmpty else { return count() }
        if fileManager.fileExists(atPath: fileURL.path) {
            guard let handle = try? FileHandle(forWritingTo: fileURL) else { return 0 }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
        if lineCount() > Self.capacity + Self.slack { trim() }
        return count()
    }

    /// How many traces the store holds (at most `capacity`), without decoding
    /// them: one per line.
    func count() -> Int {
        min(lineCount(), Self.capacity)
    }

    private func lineCount() -> Int {
        guard let data = try? Data(contentsOf: fileURL) else { return 0 }
        var lines = 0
        for byte in data where byte == 0x0A { lines += 1 }
        return lines
    }

    /// The newest `capacity` traces, oldest first. A line that does not decode
    /// is skipped.
    func load() -> [GestureTraceRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        let all = data.split(separator: 0x0A).compactMap { try? decoder.decode(GestureTraceRecord.self, from: Data($0)) }
        return Array(all.suffix(Self.capacity))
    }

    /// The file's traces as one JSON array — what the app exports, and what the
    /// gesture lab's `GestureTrace` reads.
    func exportJSON() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(load())
    }

    /// Deletes every trace.
    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Rewrites the file keeping the newest `capacity` traces.
    private func trim() {
        let kept = load()
        let encoder = JSONEncoder()
        var data = Data()
        for record in kept {
            guard let line = try? encoder.encode(record) else { continue }
            data.append(line)
            data.append(Self.newline)
        }
        try? data.write(to: fileURL, options: .atomic)
    }
}
