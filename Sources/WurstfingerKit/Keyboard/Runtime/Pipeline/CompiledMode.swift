//
//  CompiledMode.swift
//  Wurstfinger
//
//  The gesture-resolution policy, compiled into flat lookup tables.
//

import Foundation

// MARK: - Why this exists
//
// Resolving a gesture used to walk the policy at run time. One keystroke (and,
// because the guide card resolves on every candidate change while a finger is
// still moving, every preview update) paid for:
//
//  - three existential witness calls (`GestureResolverChain` → `PrimaryResolver`
//    → `GhostKeyResolver`, plus `ReturnSwipeResolver` on a return swipe),
//  - up to three `String` hashes (`mode.key(for:)` once per resolver) and two
//    more for the circular fallback, each followed by a `bindings[gesture]`
//    lookup in a `[GestureType: KeyBinding]` dictionary,
//  - roughly ten retain/release pairs from copying `KeyDefinition`s (a struct
//    holding a dictionary and an array) and `KeyBinding`s (three strings and
//    two enums) out of those dictionaries,
//  - a `Locale` lookup and an `uppercased(with:)` on every circle.
//
// None of that depends on the touch: the answer is a pure function of
// (mode, key, gesture, isReturn), and a mode has a few hundred such inputs.
// `CompiledMode` evaluates that function once, ahead of time, by *running the
// resolvers themselves* over every input, and stores the result in an array.
// What is left per resolve is one `String` hash (key id → slot) and an array
// index. The resolvers (`PrimaryResolver`, `ReturnSwipeResolver`,
// `GhostKeyResolver`) stay in the tree as the specification the tables are
// compiled from, so the new behaviour equals the old one by construction and
// `CompiledModeTests` keeps proving it for every language.
//
// Memory. The binding table holds one `Int32` per
// (slot, isReturn, gesture): `slots × 2 × 12 × 4` bytes. A 40-key mode is
// 40 × 2 × 12 × 4 = 3,840 bytes (3.75 KiB). The binding pool is shared and
// deduplicated by equality, so the many identical bindings a mode repeats
// (the numeric mode's, the ghost fallbacks') are stored once. A circular table
// (two entries per slot) adds 40 × 2 × 24 bytes = 1,920 bytes. A language has
// four modes of about fourteen keys (today's languages), so its tables cost a
// few KiB in all: small beside the `KeyboardDefinition` they are derived from.

/// What a circular gesture on a key does, decided at compile time.
///
/// Exactly the three branches `handleCircular` used to evaluate per circle,
/// in the same order: the key's own binding for the direction, the uppercase
/// centre letter, then the opposite direction's binding.
enum CircularOutcome: Sendable, Equatable {
    /// An explicit binding (this direction's, or the opposite direction's as a
    /// fallback): an index into the mode's binding pool, dispatched *with* the
    /// binding so its category still drives auto-shift, haptics and the like.
    case binding(Int32)
    /// The key's tap letter, already uppercased with `keyboardUppercased(with:)`
    /// for the definition's locale (so `ß` stays a single `ẞ`). Dispatched as a
    /// bare `.commitText` action with no binding, as the old path did.
    case commitUppercase(String)
    /// Nothing to do: the key declares no circular binding and no letter.
    case none
}

extension GestureType {
    /// Number of gestures; the stride of a compiled table's gesture axis.
    ///
    /// A stored constant rather than `allCases.count`: `allCases` is a computed
    /// array, and this is read on the touch path.
    static let count = allCases.count

    /// Whether this is one of the two circular gestures, which resolve through
    /// `CompiledMode.circular(slot:clockwise:)` rather than the binding table.
    @inline(__always)
    var isCircular: Bool {
        self == .circularClockwise || self == .circularCounterclockwise
    }

    /// This gesture's position in `allCases`: a stable, dense array index.
    ///
    /// An explicit switch instead of `allCases.firstIndex(of:)` (a linear scan
    /// and an array allocation). The order is pinned to `allCases` by a test, so
    /// adding a case without extending this switch fails loudly rather than
    /// silently mis-indexing the tables. Raw values are untouched.
    @inline(__always)
    var index: Int {
        switch self {
        case .tap: 0
        case .swipeUp: 1
        case .swipeDown: 2
        case .swipeLeft: 3
        case .swipeRight: 4
        case .swipeUpLeft: 5
        case .swipeUpRight: 6
        case .swipeDownLeft: 7
        case .swipeDownRight: 8
        case .circularClockwise: 9
        case .circularCounterclockwise: 10
        case .longPress: 11
        }
    }
}

/// One `KeyboardMode`'s gesture policy, flattened into arrays.
///
/// Built once per (definition, numpad style) and cached by `KeyboardRegistry`;
/// immutable afterwards, so it is a plain `Sendable` value that the main-actor
/// touch path reads without any synchronisation.
struct CompiledMode: Sendable {
    /// The keys, in sorted-id order: `keys[slot]`. A slot id is the key id, so
    /// `slots[keys[i].id] == i`.
    let keys: [KeyDefinition]

    /// Key id → slot. The one hash left on the resolve path.
    let slots: [String: Int]

    /// The binding pool, deduplicated by equality. `table` and the circular
    /// outcomes index into it.
    let bindings: [KeyBinding]

    /// Binding index per (slot, isReturn, gesture), or -1 for "nothing
    /// resolves". Indexed `(slot * 2 + (isReturn ? 1 : 0)) * GestureType.count
    /// + gesture.index`. The circular gestures' columns are unused (-1): they
    /// resolve through `circularTable`, which has its own, different rules.
    let table: [Int32]

    /// Circular outcome per (slot, direction): `slot * 2 + (clockwise ? 0 : 1)`.
    let circularTable: [CircularOutcome]

    /// Compiles `mode`.
    ///
    /// - Parameters:
    ///   - mode: The mode to flatten.
    ///   - fallbackMode: The definition's numeric mode, the ghost keys'
    ///     fallback (`nil` when the definition has none).
    ///   - locale: The definition's locale, for the circular uppercase letter.
    ///
    /// The resolver chains are assembled exactly as the view model used to
    /// assemble them at load time: primary, then ghost fallback; and for return
    /// swipes the return-swipe resolver in front of those.
    init(mode: KeyboardMode, fallbackMode: KeyboardMode?, locale: Locale) {
        var base: [GestureResolver] = [PrimaryResolver()]
        if let fallbackMode {
            base.append(GhostKeyResolver(fallbackMode: fallbackMode))
        }
        let chains = [
            GestureResolverChain(resolvers: base),
            GestureResolverChain(resolvers: [ReturnSwipeResolver()] + base),
        ]

        let ids = mode.keys.keys.sorted()
        let gestureCount = GestureType.count
        var table = [Int32](repeating: -1, count: ids.count * 2 * gestureCount)
        var circularTable = [CircularOutcome](repeating: .none, count: ids.count * 2)
        var pool = BindingPool()
        var keys: [KeyDefinition] = []
        var slots: [String: Int] = [:]
        keys.reserveCapacity(ids.count)
        slots.reserveCapacity(ids.count)

        for (slot, id) in ids.enumerated() {
            guard let key = mode.keys[id] else { continue }
            keys.append(key)
            slots[id] = slot

            for (returnIndex, chain) in chains.enumerated() {
                let row = (slot * 2 + returnIndex) * gestureCount
                for gesture in GestureType.allCases where !gesture.isCircular {
                    if let binding = chain.resolve(keyId: id, gesture: gesture, in: mode) {
                        table[row + gesture.index] = pool.index(of: binding)
                    }
                }
            }

            circularTable[slot * 2] = Self.circularOutcome(
                for: key, gesture: .circularClockwise, locale: locale, pool: &pool
            )
            circularTable[slot * 2 + 1] = Self.circularOutcome(
                for: key, gesture: .circularCounterclockwise, locale: locale, pool: &pool
            )
        }

        self.keys = keys
        self.slots = slots
        self.bindings = pool.bindings
        self.table = table
        self.circularTable = circularTable
    }

    /// The three branches of the old `handleCircular`, in order. Circles read
    /// the key's own bindings directly (no swipe-mode filter, no ghost fallback,
    /// no return variant), which is why they do not go through the chains.
    private static func circularOutcome(
        for key: KeyDefinition,
        gesture: GestureType,
        locale: Locale,
        pool: inout BindingPool
    ) -> CircularOutcome {
        // 1. Explicit binding for this direction.
        if let binding = key.bindings[gesture] {
            return .binding(pool.index(of: binding))
        }
        // 2. Uppercase of the centre character (letter keys). keyboardUppercased
        //    (not plain uppercased) keeps ß → ẞ a single character, matching the
        //    shifted-mode generation in the definition layer.
        if let tap = key.bindings[.tap],
           case let .commitText(text) = tap.action,
           text.first?.isLetter == true {
            return .commitUppercase(text.keyboardUppercased(with: locale))
        }
        // 3. The opposite direction's binding.
        let opposite: GestureType = gesture == .circularClockwise
            ? .circularCounterclockwise : .circularClockwise
        if let binding = key.bindings[opposite] {
            return .binding(pool.index(of: binding))
        }
        return .none
    }

    // MARK: - Lookup

    /// The slot of the key with `keyId` (a key id *is* its slot id), or `nil`
    /// when the mode has no such key.
    @inline(__always)
    func slot(for keyId: String) -> Int? {
        slots[keyId]
    }

    /// The key at `slot`.
    @inline(__always)
    func key(at slot: Int) -> KeyDefinition {
        keys[slot]
    }

    /// The binding `gesture` fires on the key at `slot`, or `nil` when nothing
    /// resolves. Equal to running the old resolver chain, because the table was
    /// filled by running it.
    ///
    /// `gesture` must not be circular (see `circular(slot:clockwise:)`); a slot
    /// must come from `slot(for:)` of this same mode.
    @inline(__always)
    func binding(slot: Int, gesture: GestureType, isReturn: Bool) -> KeyBinding? {
        assert(!gesture.isCircular, "circular gestures resolve through circular(slot:clockwise:)")
        let entry = table[(slot * 2 + (isReturn ? 1 : 0)) * GestureType.count + gesture.index]
        return entry < 0 ? nil : bindings[Int(entry)]
    }

    /// What a circle in the given direction does on the key at `slot`.
    @inline(__always)
    func circular(slot: Int, clockwise: Bool) -> CircularOutcome {
        circularTable[slot * 2 + (clockwise ? 0 : 1)]
    }

    /// The pooled binding a `CircularOutcome.binding` index refers to.
    @inline(__always)
    func binding(at index: Int32) -> KeyBinding {
        bindings[Int(index)]
    }
}

/// Interns bindings by equality while a mode is being compiled.
///
/// `KeyBinding` is `Equatable` but not `Hashable` (its `KeyAction` is not, and
/// the Codable schema is not ours to change), so buckets are keyed by label and
/// compared by `==` within a bucket: a mode holds hundreds of bindings but only
/// a handful share a label, so this stays linear where a flat scan would not.
private struct BindingPool {
    private(set) var bindings: [KeyBinding] = []
    private var buckets: [String: [Int32]] = [:]

    mutating func index(of binding: KeyBinding) -> Int32 {
        if let found = buckets[binding.label]?.first(where: { bindings[Int($0)] == binding }) {
            return found
        }
        let created = Int32(bindings.count)
        bindings.append(binding)
        buckets[binding.label, default: []].append(created)
        return created
    }
}

/// Every mode of one `KeyboardDefinition`, compiled.
struct CompiledDefinition: Sendable {
    let modes: [String: CompiledMode]

    /// Compiles every mode of `definition`.
    ///
    /// The ghost fallback is the definition's numeric mode and the uppercase
    /// letter uses the definition's locale: the same two inputs
    /// `rebuildResolverChain` and `tryCircularUppercase` used to read per call.
    /// Compiling the numeric mode against itself as its own fallback is
    /// harmless (a ghost lookup there finds the primary's answer again), and is
    /// what the old chain did too.
    init(_ definition: KeyboardDefinition) {
        let fallback = definition.mode(ModeNames.numeric)
        let locale = definition.locale
        modes = definition.modes.mapValues {
            CompiledMode(mode: $0, fallbackMode: fallback, locale: locale)
        }
    }

    /// The compiled mode named `name`, or `nil` when the definition has none.
    @inline(__always)
    func mode(_ name: String) -> CompiledMode? {
        modes[name]
    }
}
