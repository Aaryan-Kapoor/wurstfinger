//
//  KeyboardHealthLog.swift
//  Wurstfinger
//
//  Release-safe lifecycle and memory telemetry for the keyboard extension.
//

import Foundation
import os

/// Records keyboard-extension lifecycle events together with the process's
/// memory footprint into a file in the shared app group — in Release builds
/// too, where `Logger` output is only reachable with a Mac.
///
/// Keyboard extensions run under a tight (~48–66 MB) memory budget and are
/// spawned into memory- and time-critical host contexts (SpringBoard hosts
/// the home-screen search field). When iOS declines to spawn the extension or
/// jetsams it, the user silently gets the system keyboard and no crash report
/// is written. This log answers two questions on-device after such an
/// incident: did the extension process run at that moment at all, and how
/// close to the memory budget was it? The host app renders the log in the
/// expert settings (`KeyboardHealthView`).
///
/// The log is persisted as a file rather than in `SharedDefaults`: every
/// defaults write fires the in-process `didChangeNotification`, which would
/// trigger a redundant settings reload on each keyboard appearance.
///
/// **Concurrency model.** An `actor` whose executor is one shared utility-QoS
/// serial `DispatchQueue`, so every file touch happens on that queue and can
/// never contend with the main thread. Callers are never made to `await` it:
/// `record` captures the footprint synchronously at the call site (so the
/// measurement is attributed to the right lifecycle point) and `yield`s the
/// finished entry into an `AsyncStream` (`bufferingNewest(256)`, so a runaway
/// producer can only ever cost the oldest queued entries, never memory). One
/// long-lived task drains the stream and appends in order, onto each entry's
/// log. That single FIFO is also what orders everything else: `entries()` and
/// `clear()` first `await` a barrier marker that rides the same stream, so
/// "reads observe every previously recorded entry" holds exactly as it did when
/// the queue was drained with `sync` — across log instances too, since the
/// stream, like the queue before it, is process-wide.
///
/// The suspension path uses `recordAndFlush` instead: there the write must
/// land before the process is frozen, and latency does not matter. It is the
/// one deliberately blocking call in the keyboard (never on the typing path):
/// a suspended process may never get CPU time again, so an async hop that
/// "will run soon" is not an option there. `recordDeferred` covers the one
/// case neither serves — a figure that is only correct some time *after* the
/// call site — and is allowed to go missing: the caller can cancel it (it
/// returns the `Task` handle), and a sample that arrives long after its
/// deadline is discarded rather than logged (see there). A host-app clear
/// racing an extension write can lose one side — acceptable for diagnostics,
/// and the file stays bounded by `maxEntries` either way.
actor KeyboardHealthLog {
    struct Entry: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        /// Wall-clock time of the event, for correlating with incidents where
        /// the system keyboard appeared instead of Wurstfinger.
        let date: Date
        /// Lifecycle point, e.g. "viewDidLoad.start" or "didReceiveMemoryWarning".
        let label: String
        /// Physical footprint — the figure iOS compares against the jetsam limit.
        let usedMB: Double
        /// Memory still grantable before jetsam, per `os_proc_available_memory`.
        /// Zero outside the extension process, where the API is unsupported.
        let availableMB: Double
    }

    /// Bounds the log file (~50 KB). A cold start records four entries, and a
    /// cleanly closed open→close cycle up to four — `viewWillAppear`,
    /// `viewDidAppear`, the suspension entry that closes it, and the deferred
    /// `postShedSettled` sample that follows it (see
    /// `KeyboardViewController.shedMemoryBeforeSuspension`) — so this holds
    /// roughly seventy cycles: still days of typical usage.
    ///
    /// "Cleanly closed" is not guaranteed. When the host app is killed
    /// outright while the keyboard is on screen, iOS calls nothing back: no
    /// closing entry is written and no shedding runs, so the log jumps from
    /// `viewDidAppear` straight to the next launch's `viewDidLoad.start`. That
    /// gap is a legible signature, not a defect of the log — it is the one
    /// path on which the extension idles at its full pre-shed weight until the
    /// system reaps it. No callback exists to close the cycle at the source.
    static let defaultMaxEntries = 300

    static let fileName = "keyboard-health-log.json"

    /// Label of the tombstone entry `clear()` leaves behind — see there for
    /// why a cleared log is not simply an empty one. Consumers key off this
    /// constant rather than the literal: `KeyboardHealthView` folds the
    /// tombstone away while it is the only entry, and keeps it out of the
    /// summary figures.
    static let clearedLabel = "logCleared"

    /// Shared instance persisting into the app group container. The
    /// `containerURL(...)` lookup is out-of-process IPC; it is deferred into a
    /// provider closure so it runs lazily on the log's queue on first file
    /// access, never synchronously on the main thread during the latency-
    /// critical extension spawn.
    static let shared = KeyboardHealthLog(fileURLProvider: {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: SharedDefaults.suiteName)?
            .appendingPathComponent(fileName)
    })

    // MARK: - Execution

    /// Serializes all file access across instances, and is every instance's
    /// actor executor. Utility QoS: a diagnostics write must never compete
    /// with the touch path for CPU.
    fileprivate static let ioQueue = DispatchSerialQueue(
        label: "de.akator.wurstfinger.keyboard-health-log",
        qos: .utility
    )

    /// Runs the actor on the shared utility queue instead of the cooperative
    /// pool, so file I/O keeps its own thread and QoS, and the synchronous
    /// `recordAndFlush` can wait for it with a plain `sync` barrier.
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        Self.ioQueue.asUnownedSerialExecutor()
    }

    // MARK: - Stream

    /// What travels through the stream. One FIFO carries entries and markers
    /// alike, which is what makes "a reader sees everything recorded before
    /// it" a property of the queue order rather than of timing.
    fileprivate enum Command: Sendable {
        /// An entry, with the log whose file it belongs to.
        case append(KeyboardHealthLog, Entry)
        /// Resumed once everything queued before it has been written.
        case barrier(CheckedContinuation<Void, Never>)
        /// Completed once everything queued before it has been written.
        case flushed(FlushTicket)
    }

    /// The completion flag a synchronous caller polls (`recordAndFlush`).
    fileprivate final class FlushTicket: Sendable {
        private let done = OSAllocatedUnfairLock(initialState: false)

        var isDone: Bool {
            done.withLock { $0 }
        }

        func complete() {
            done.withLock { $0 = true }
        }
    }

    /// Entries queued but not yet written. Bounded: a producer outrunning the
    /// disk loses the *oldest* queued entries rather than growing memory
    /// inside a ~48 MB budget.
    private static let streamCapacity = 256

    /// The one stream every instance feeds, and the single task draining it.
    ///
    /// Process-wide rather than per instance because the previous design had
    /// one process-wide serial queue ("serializes all file access across
    /// instances"): a read through *any* log instance observes every entry
    /// recorded through *any other* before it. Per-instance streams would have
    /// silently dropped that ordering between two instances over one file.
    /// There is a single log in production (`shared`); the guarantee is what
    /// keeps tests and tools that open the same file twice honest.
    ///
    /// The drain task is itself bound to the log queue (see `LogDrainer`), so
    /// consecutive entries are written back to back on one thread with no hop
    /// per entry; it only suspends when the stream runs dry.
    private static let commands: AsyncStream<Command>.Continuation = {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Command.self, bufferingPolicy: .bufferingNewest(streamCapacity)
        )
        Task(priority: .utility) {
            await LogDrainer().drain(stream)
        }
        return continuation
    }()

    private let fileURLProvider: @Sendable () -> URL?
    private let maxEntries: Int

    /// Approximate encoded size of one entry, used to size the compaction
    /// threshold. Only needs to be within an order of magnitude.
    private static let approxBytesPerEntry = 160

    /// Compaction fires once the file grows past this many bytes, i.e. roughly
    /// once every `maxEntries` appends — keeping the append hot path O(1)
    /// amortized while bounding the file to ~`2 * maxEntries` entries on disk.
    private var trimThresholdBytes: Int {
        2 * maxEntries * Self.approxBytesPerEntry
    }

    #if DEBUG
        private static let logger = Logger(subsystem: "de.akator.wurstfinger", category: "memory")
    #endif

    init(fileURL: URL?, maxEntries: Int = KeyboardHealthLog.defaultMaxEntries) {
        self.init(fileURLProvider: { fileURL }, maxEntries: maxEntries)
    }

    init(fileURLProvider: @escaping @Sendable () -> URL?, maxEntries: Int = KeyboardHealthLog.defaultMaxEntries) {
        self.fileURLProvider = fileURLProvider
        self.maxEntries = maxEntries
    }

    /// Appends one drained entry to this log's file. The only writer; runs on
    /// the log's queue.
    fileprivate func write(_ entry: Entry) {
        appendEntry(entry)
    }

    /// Queues a command, and releases a waiter whose marker the bounded
    /// buffer evicted (or that arrived after termination), so no reader can be
    /// left hanging by the capacity policy.
    private nonisolated static func enqueue(_ command: Command) {
        switch commands.yield(command) {
        case .enqueued:
            break
        case let .dropped(evicted):
            release(evicted)
        case .terminated:
            release(command)
        @unknown default:
            release(command)
        }
    }

    private nonisolated static func release(_ command: Command) {
        switch command {
        case let .barrier(waiter): waiter.resume()
        case let .flushed(ticket): ticket.complete()
        case .append: break
        }
    }

    /// Suspends until every entry queued before this call has been written.
    private nonisolated func settle() async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            Self.enqueue(.barrier(waiter))
        }
    }

    // MARK: - Recording

    /// Records the current footprint under the given lifecycle label.
    /// Returns immediately: the entry is built here, at the call site, and
    /// handed to the log's own queue through the stream.
    nonisolated func record(_ label: String) {
        Self.enqueue(.append(self, makeEntry(label)))
    }

    /// Longest `recordAndFlush` waits for its entry to reach the disk before
    /// giving up. Only a pathological stall (a hung container lookup) comes
    /// near it; the bound keeps such a stall from freezing suspension.
    private static let flushTimeout: DispatchTimeInterval = .seconds(2)

    /// Records like `record(_:)`, but returns only once the entry is on disk.
    /// For the suspension path: a suspended process may never get CPU time
    /// again — a resume-jetsam kills it on wake before queued writes run —
    /// and the post-shedding footprint entry is exactly what those incidents
    /// need. Entries queued earlier are written first (same FIFO). Not for
    /// the launch path or the typing path, where nothing may block.
    ///
    /// The wait is a `sync` barrier on the log's queue rather than an `await`,
    /// because the caller is synchronous UIKit teardown. It re-polls until the
    /// drain task has reported the entry written, rather than trusting one
    /// barrier: the drain task may not even have been scheduled onto the queue
    /// yet when the first barrier runs (a freshly created log), and an empty
    /// barrier then returns before the entry exists.
    nonisolated func recordAndFlush(_ label: String) {
        dispatchPrecondition(condition: .notOnQueue(Self.ioQueue))
        let ticket = FlushTicket()
        Self.enqueue(.append(self, makeEntry(label)))
        Self.enqueue(.flushed(ticket))
        let giveUp = DispatchTime.now() + Self.flushTimeout
        while !ticket.isDone, DispatchTime.now() < giveUp {
            Self.ioQueue.sync {}
        }
    }

    /// Records an entry whose footprint is sampled `delay` seconds from now,
    /// on a strictly best-effort basis, and hands back the pending task so the
    /// caller can void it once the premise it was queued under stops holding.
    ///
    /// The inverse of the other two: they sample at the call site precisely so
    /// the figure belongs to that lifecycle point, while this one deliberately
    /// samples *late*, for the case where the interesting number only becomes
    /// true after something the call site cannot wait for has settled (the
    /// kernel reclaiming a torn-down view graph takes another 1–2 s). Queued,
    /// never awaited, so it cannot delay the caller.
    ///
    /// Nothing is promised, and the two ways the entry can go missing are both
    /// deliberate. A process that dies before the timer fires loses it — hence
    /// callers must treat this as a refinement of an already-recorded
    /// guaranteed entry, never as the record itself. A process that is merely
    /// *frozen* does not lose it: the sleep ends as soon as the process is
    /// scheduled again — possibly minutes later and inside the next host
    /// cycle, since the extension process is reused. That sample would
    /// describe the resumed process while carrying the label of the earlier
    /// one, so a sample that reaches the log's queue more than its own delay
    /// late writes nothing. (The lateness is judged on the queue, not when the
    /// timer fires: a queue that was busy is as late as a process that was
    /// frozen.)
    ///
    /// The clock is `ContinuousClock`, which — unlike the mach-time clock the
    /// previous `DispatchQueue.asyncAfter` implementation compared against —
    /// keeps counting while the *device* sleeps, so a sample delayed across a
    /// sleep window is recognised as late instead of slipping through.
    /// Cancelling the returned task before it fires writes nothing.
    @discardableResult
    nonisolated func recordDeferred(_ label: String, after delay: TimeInterval) -> Task<Void, Never> {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(delay))
        // Overdue by more than the wait itself: no process that kept running
        // is that far behind, so whatever the sample would read now belongs to
        // a different situation than the label names.
        let discardAfter = deadline.advanced(by: .seconds(delay))
        return Task(priority: .utility) {
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return // cancelled: the premise no longer holds
            }
            await self.recordIfPunctual(label, discardAfter: discardAfter)
        }
    }

    /// Runs on the log's queue, so `ContinuousClock.now` here is the time the
    /// queue actually got to the sample.
    private func recordIfPunctual(_ label: String, discardAfter: ContinuousClock.Instant) {
        guard !Task.isCancelled, ContinuousClock.now < discardAfter else { return }
        // Through the stream, not straight to disk, so it stays behind
        // anything already queued (the flushed suspension entry it pairs with).
        Self.enqueue(.append(self, makeEntry(label)))
    }

    /// Captures the footprint synchronously at the call site, so the
    /// measurement is attributed to the right lifecycle point no matter when
    /// the entry is persisted.
    private nonisolated func makeEntry(_ label: String) -> Entry {
        let entry = Entry(
            id: UUID(),
            date: Date(),
            label: label,
            usedMB: Double(Self.physFootprintBytes()) / Self.bytesPerMB,
            availableMB: Double(os_proc_available_memory()) / Self.bytesPerMB
        )
        #if DEBUG
            let used = String(format: "%.1f", entry.usedMB)
            let available = String(format: "%.1f", entry.availableMB)
            let message = "[\(label)] used: \(used) MB, available: \(available) MB"
            Self.logger.log("\(message, privacy: .public)")
        #endif
        return entry
    }

    /// The tombstone `clear()` leaves behind: the clear's own timestamp, no
    /// footprint. Deliberately not `makeEntry`, which would sample the host
    /// app's memory here — a figure that belongs to no keyboard cycle and
    /// would still be compared against the extension's budget by every
    /// consumer of this log.
    private func makeClearedEntry() -> Entry {
        Entry(id: UUID(), date: Date(), label: Self.clearedLabel, usedMB: 0, availableMB: 0)
    }

    /// All recorded entries, oldest first, capped at `maxEntries`. Empty when
    /// the file is missing or unreadable (corruption is silently discarded —
    /// this is diagnostics, it must never take the keyboard down).
    ///
    /// Waits for every entry recorded before the call to reach the file, so a
    /// read always observes what the caller just recorded. Async because the
    /// work runs on the log's queue; only the host app's settings screen reads.
    ///
    /// The `suffix(maxEntries)` cap keeps the read bound even when the on-disk
    /// file has grown past `maxEntries` between physical compactions.
    func entries() async -> [Entry] {
        await settle()
        guard let fileURL = fileURLProvider() else { return [] }
        return Array(readEntries(fileURL).suffix(maxEntries))
    }

    /// Removes all recorded entries and stamps a tombstone in their place, so
    /// that an entry arriving afterwards reads as the first event *after* the
    /// clear instead of as a clear that did not take.
    ///
    /// The tombstone is not bookkeeping for its own sake. `clear()` is invoked
    /// from the **host app**, while the deferred `postShedSettled` sample is
    /// queued in the **extension process** two seconds before it writes (see
    /// `KeyboardViewController.shedMemoryBeforeSuspension`). Clearing the log
    /// shortly after a dismissal therefore reliably grows one entry in the
    /// file that was just emptied, and no cancellation can prevent it: the
    /// pending task lives in another process, and the log has no channel
    /// to reach across. Marking where the clear happened is the honest fix;
    /// cancelling in-process would only look like one.
    ///
    /// The tombstone deliberately carries no memory figures. It is stamped by
    /// the host app, whose footprint says nothing about the extension's jetsam
    /// budget, and a host-sized number in that column would skew the peak.
    /// `KeyboardHealthView` folds it away while it is the only entry, so a
    /// cleared log still reads as empty.
    func clear() async {
        await settle()
        guard let fileURL = fileURLProvider() else { return }
        try? FileManager.default.removeItem(at: fileURL)
        appendEntry(makeClearedEntry())
    }

    // MARK: - Private

    /// Appends a single entry to the newline-delimited JSON (JSONL) file with
    /// a `seekToEnd` + `write` — O(1), no full-file read on the hot path.
    /// Runs on the log's queue (the actor's executor).
    private func appendEntry(_ entry: Entry) {
        guard let fileURL = fileURLProvider(),
              let encoded = try? JSONEncoder().encode(entry) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            let end = (try? handle.seekToEnd()) ?? 0
            var payload = Data()
            // Separate the new line from a prior line or legacy array bytes.
            if end > 0 { payload.append(0x0A) }
            payload.append(encoded)
            try? handle.write(contentsOf: payload)
        } else if !FileManager.default.fileExists(atPath: fileURL.path) {
            // First write only. A handle can also fail on an *existing* file
            // (an unwritable container while the device is locked), and
            // overwriting then would discard exactly the history a
            // resume-jetsam investigation needs — drop the entry instead.
            try? encoded.write(to: fileURL, options: .atomic)
        }
        compactIfNeeded(fileURL)
    }

    /// Physically rewrites the file to the last `maxEntries` entries once it
    /// grows past `trimThresholdBytes`. Gated on a cheap `stat` (no content
    /// read), so a full read+rewrite happens only ~once per `maxEntries`
    /// appends — O(1) amortized per event. Runs on the log's queue.
    private func compactIfNeeded(_ fileURL: URL) {
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? Int ?? 0
        // A file the process cannot read is history, not garbage: rewriting it
        // from an empty decode would replace the log with nothing.
        guard size > trimThresholdBytes, let data = try? Data(contentsOf: fileURL) else { return }
        write(Array(decodeEntries(from: data).suffix(maxEntries)), to: fileURL)
    }

    /// Raw JSONL read; runs on the log's queue.
    private func readEntries(_ fileURL: URL) -> [Entry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return decodeEntries(from: data)
    }

    /// `split(separator:)` omits empty subsequences, so leading/double newlines
    /// and undecodable legacy segments are tolerated (corruption-discard
    /// contract preserved).
    private func decodeEntries(from data: Data) -> [Entry] {
        let decoder = JSONDecoder()
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(Entry.self, from: Data($0)) }
    }

    /// Atomically rewrites the whole file as newline-delimited JSON. Only used
    /// by compaction — never on the append hot path.
    private func write(_ entries: [Entry], to fileURL: URL) {
        let encoder = JSONEncoder()
        var data = Data()
        for entry in entries {
            guard let line = try? encoder.encode(entry) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static let bytesPerMB = 1024.0 * 1024.0

    /// The process's current physical memory footprint in bytes — the figure
    /// iOS compares against the jetsam limit. Returns 0 if the kernel query
    /// fails.
    private static func physFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}

/// The stream's consumer: an actor on the same queue as every
/// `KeyboardHealthLog`, so the drain loop and the writes it performs share one
/// thread of execution.
///
/// Draining from a plain task would cost a thread hop per entry (pool thread ->
/// log queue and back), which under load stretches a burst of appends from
/// milliseconds to seconds. Running the loop on the queue itself lets the
/// buffered entries go out back to back; `assumeIsolated` is sound because both
/// actors' executor *is* that queue, which the runtime verifies.
private actor LogDrainer {
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        KeyboardHealthLog.ioQueue.asUnownedSerialExecutor()
    }

    /// A synchronous function, because `assumeIsolated` is unavailable from
    /// async contexts. Runs while the drain loop holds the queue, so the
    /// assumption always holds.
    private nonisolated static func write(_ entry: KeyboardHealthLog.Entry, to log: KeyboardHealthLog) {
        log.assumeIsolated { $0.write(entry) }
    }

    func drain(_ stream: AsyncStream<KeyboardHealthLog.Command>) async {
        for await command in stream {
            switch command {
            case let .append(log, entry):
                Self.write(entry, to: log)
            case let .barrier(waiter):
                waiter.resume()
            case let .flushed(ticket):
                ticket.complete()
            }
        }
    }
}
