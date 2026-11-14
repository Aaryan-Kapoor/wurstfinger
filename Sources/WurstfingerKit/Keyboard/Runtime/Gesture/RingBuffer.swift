//
//  RingBuffer.swift
//  Wurstfinger
//
//  A fixed-size circular buffer for efficient O(1) appending.
//

import Foundation

/// A fixed-capacity circular buffer: appending past `capacity` overwrites the
/// oldest element.
///
/// Storage is a plain `ContiguousArray<T>` that is reserved to `capacity` once,
/// in `init`, and grows by `append` until it is full; from then on every
/// append overwrites a slot in place. There is no optional per slot (a
/// `[T?]` doubles the stride of a `CGPoint` and forces an unwrap on every
/// read), and after the first full touch — and across `removeAll`, which only
/// rewinds the indices — appending never allocates.
struct RingBuffer<T> {
    private var storage: ContiguousArray<T>
    private var writeIndex = 0

    /// Number of elements currently held, `0 ... capacity`.
    private(set) var count = 0

    let capacity: Int

    init(capacity: Int) {
        precondition(capacity > 0, "RingBuffer capacity must be greater than 0")
        self.capacity = capacity
        storage = []
        storage.reserveCapacity(capacity)
    }

    mutating func append(_ element: T) {
        if writeIndex < storage.count {
            storage[writeIndex] = element
        } else {
            // Still filling for the first time: `writeIndex == storage.count`.
            storage.append(element)
        }
        writeIndex = (writeIndex + 1) % capacity
        if count < capacity {
            count += 1
        }
    }

    mutating func removeAll() {
        writeIndex = 0
        count = 0
        // The stale elements stay in `storage` to be overwritten in place; the
        // buffer only ever holds value types here, so nothing leaks.
    }

    var isEmpty: Bool {
        count == 0
    }

    /// Index in `storage` of the oldest element.
    private var oldestIndex: Int {
        count < capacity ? 0 : writeIndex
    }

    /// Returns the elements in order, from oldest to newest.
    /// This is O(N) where N is the number of elements, and allocates the
    /// returned array; the input path uses `copyOrdered(into:)` instead.
    var elements: [T] {
        guard count > 0 else { return [] }
        var result = [T]()
        result.reserveCapacity(count)
        let start = oldestIndex
        for i in 0 ..< count {
            result.append(storage[(start + i) % capacity])
        }
        return result
    }

    /// Copies the elements, oldest to newest, into `buffer` and returns how
    /// many were written; `buffer.count` must be at least `count`.
    ///
    /// The ring can have wrapped, so its storage is not in path order, and a
    /// reader can't be handed a pointer into it without a copy. The
    /// classifier wants one contiguous, origin-anchored path, so the copy
    /// goes straight into caller-owned scratch (see `ClassificationScratch`)
    /// instead of into a fresh array the way `elements` does. The destination
    /// must be initialized memory: the elements are assigned, not initialised.
    func copyOrdered(into buffer: UnsafeMutableBufferPointer<T>) -> Int {
        precondition(buffer.count >= count, "RingBuffer.copyOrdered: destination too small")
        guard count > 0 else { return 0 }
        let start = oldestIndex
        for i in 0 ..< count {
            var index = start + i
            if index >= capacity { index -= capacity }
            buffer[i] = storage[index]
        }
        return count
    }
}

/// A ring buffer of `Sendable` elements is itself a plain value and may cross
/// isolation domains (the gesture sequence that owns one is a value type).
extension RingBuffer: Sendable where T: Sendable {}
