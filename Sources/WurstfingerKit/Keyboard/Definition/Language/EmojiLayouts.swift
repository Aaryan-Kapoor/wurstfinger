//
//  EmojiLayouts.swift
//  Wurstfinger
//
//  The emoji mode: the letter grid's nine keys become feelings.
//

import Foundation

/// The emoji mode, organised by feeling (docs/emoji-mode.md has the design and
/// the research behind the members).
///
/// **The map.** The nine grid keys are laid out like the circumplex model of
/// affect: the columns are valence (sour on the left, sweet on the right), the
/// rows are arousal (loud on top, quiet at the bottom):
///
/// ```
///   Anger      Surprise   Joy
///   Worry      Playful    Love
///   Sadness    Neutral    Approval
/// ```
///
/// **The key.** Each key reads the same way, so one rule serves all nine:
/// rows are *intensity* (a flick up is louder than the tap, a flick down is
/// quieter), columns are *kind* (left, another face; middle, the family's own
/// line; right, a hand, heart or symbol). The tap is the family's most
/// representative emoji. A return swipe (out and back) goes further in the
/// same direction: the second-level variant of that cell. A circle turns to
/// the second page, which holds nine more per family (and a second circle
/// turns back).
///
/// **The recent key.** The tenth key, bottom left, holds the nine emoji typed
/// last, in the same 3×3 shape. It is the one part of the mode that changes:
/// `recentKey(_:)` rebuilds it when the mode is entered.
///
/// **The shape of the data.** Every emoji is one grapheme cluster of Emoji 15.0
/// or earlier (iOS 17 draws them all); `EmojiLayoutTests` pins both.
enum EmojiLayouts {
    /// One feeling.
    struct Family: Sendable, Equatable {
        /// Stable identifier ("joy"); the localized name is `name`.
        let id: String
        /// The grid slot the family's key sits in.
        let slot: String
        /// The nine emoji of the first page in `gridGestures` order, separated
        /// by spaces: ↖ ↑ ↗ ← tap → ↙ ↓ ↘.
        let main: String
        /// The eight return-swipe emoji of the first page in `returnGestures`
        /// order: ↖ ↑ ↗ ← → ↙ ↓ ↘.
        let returns: String
        /// The nine emoji of the second page, in `gridGestures` order.
        let more: String

        /// The family's name for VoiceOver, in the user's language. Literal
        /// `String(localized:)` calls, one per name, so the catalog check can
        /// see every key.
        var name: String {
            switch id {
            case "anger": String(localized: "Anger")
            case "surprise": String(localized: "Surprise")
            case "joy": String(localized: "Joy")
            case "worry": String(localized: "Worry")
            case "playful": String(localized: "Playful")
            case "love": String(localized: "Love")
            case "sadness": String(localized: "Sadness")
            case "neutral": String(localized: "Neutral")
            case "approval": String(localized: "Approval")
            default: id
            }
        }
    }

    // MARK: - The map

    /// Every family, in grid order (rows of three, top to bottom). Edit with
    /// the scheme in the type's comment in mind: members of a cell must sit at
    /// its intensity and in its column.
    static let families: [Family] = [
        Family(
            id: "anger", slot: GridSlot.topLeft,
            main: "👿 😡 💢 😤 😠 👊 😾 😒 👎",
            returns: "👹 🤬 💥 👺 ✊ 😑 😮‍💨 🚫",
            more: "💀 ☠️ 🧨 🤛 😖 💣 🫵 🖕 🛑"
        ),
        Family(
            id: "surprise", slot: GridSlot.topCenter,
            main: "🫨 😲 ‼️ 😳 😮 👀 🫢 😯 ❓",
            returns: "🤯 😵 ⁉️ 🫣 🙉 🤭 😶‍🌫️ 🙀",
            more: "😦 💫 ❗ 🤐 😵‍💫 🔔 🌀 🪄 ❔"
        ),
        Family(
            id: "joy", slot: GridSlot.topRight,
            main: "😆 🤣 🔥 😁 😂 🎉 🙂 😊 ✨",
            returns: "🤩 🥳 🎊 😄 🌟 ☺️ 😇 ☀️",
            more: "😸 😹 🍾 😺 😀 🎂 🙃 🥂 🌸"
        ),
        Family(
            id: "worry", slot: GridSlot.midLeft,
            main: "😰 😱 🚨 😬 😨 💦 😅 😟 🤞",
            returns: "🥶 🥵 ⚠️ 🥴 👻 😓 🫠 🧿",
            more: "😧 😫 🆘 😣 😕 ⛈️ 🤢 🤒 💊"
        ),
        Family(
            id: "playful", slot: GridSlot.center,
            main: "😈 🤪 🤘 😎 😜 🙈 😏 😉 🤙",
            returns: "🤡 🤓 💃 😝 🙊 😋 😛 ✌️",
            more: "🤠 👽 🕺 😼 🤑 🎈 👾 🤫 🍀"
        ),
        Family(
            id: "love", slot: GridSlot.midRight,
            main: "😻 😘 💕 😚 😍 ❤️ 🥰 🤗 🫶",
            returns: "💋 ❤️‍🔥 💖 😙 💗 🥲 🥹 🤍",
            more: "😽 💘 💝 😗 💞 🌹 💜 💙 💚"
        ),
        Family(
            id: "sadness", slot: GridSlot.bottomLeft,
            main: "😞 😭 💔 🥺 😢 🥀 😥 😔 🌧️",
            returns: "😿 😩 🖤 ☹️ ☔ 🙁 😪 🫂",
            more: "🤧 💧 🪦 🤕 🍂 🕯️ 🌑 🌫️ 🌃"
        ),
        Family(
            id: "neutral", slot: GridSlot.bottomCenter,
            main: "🤨 🧐 💭 🙄 🤔 🤷 🥱 😐 💤",
            returns: "🫤 🧠 🔍 😶 🤦 😴 😷 🛌",
            more: "🥸 📚 💡 🤥 🧘 ⏳ 🪫 🕰️ 🔎"
        ),
        Family(
            id: "approval", slot: GridSlot.bottomRight,
            main: "🤝 👏 💯 😌 👍 ✅ 🙇 🙏 👌",
            returns: "💪 🙌 🏆 🫡 ✔️ 🤲 ☑️ 🆗",
            more: "🤟 👋 🎖️ 🙆 💁 🥇 🫱 🫰 🙋"
        ),
    ]

    /// The nine gestures of a key, in the order the data lists them: the rows
    /// of the key's own 3×3 map.
    static let gridGestures: [GestureType] = [
        .swipeUpLeft, .swipeUp, .swipeUpRight,
        .swipeLeft, .tap, .swipeRight,
        .swipeDownLeft, .swipeDown, .swipeDownRight,
    ]

    /// The eight swipes that have a return swipe, in the order of
    /// `Family.returns`.
    static let returnGestures: [GestureType] = gridGestures.filter { $0 != .tap }

    /// Whether `mode` is one of the emoji pages.
    static func isEmojiMode(_ mode: String) -> Bool {
        mode == ModeNames.emoji || mode == ModeNames.emojiMore
    }

    // MARK: - Modes

    /// Both pages, for a layout whose "back to letters" key is labelled
    /// `backToAlphaLabel` (the same label the numeric mode uses), with the
    /// recent key carrying `recents` and the hands and people in `tone` (the
    /// recent key is not toned: it holds what was typed, in the tone it was
    /// typed in).
    static func modes(
        backToAlphaLabel: String = NumericLayouts.defaultBackToAlphaLabel,
        recents: EmojiRecents = EmojiRecents(),
        tone: EmojiSkinTone = .none
    ) -> [String: KeyboardMode] {
        let firstPageKeys = tone == .none ? Self.firstPageKeys : pageKeys(second: false, tone: tone)
        let secondPageKeys = tone == .none ? Self.secondPageKeys : pageKeys(second: true, tone: tone)
        func page(_ name: String, keys familyKeys: [String: KeyDefinition], label: String) -> KeyboardMode {
            var keys = familyKeys
            keys[GridSlot.recent] = recentKey(recents, onSecondPage: name == ModeNames.emojiMore)
            keys[UtilitySlot.symbols] = lettersKey(label: label)
            keys[UtilitySlot.globe] = CommonKeys.globe
            keys[UtilitySlot.delete] = CommonKeys.delete
            keys[UtilitySlot.return] = CommonKeys.return
            keys[UtilitySlot.space] = CommonKeys.spacebar()
            return KeyboardMode(name: name, keys: keys, arrangements: arrangements, autoTransitions: [:])
        }
        return [
            ModeNames.emoji: page(ModeNames.emoji, keys: firstPageKeys, label: backToAlphaLabel),
            ModeNames.emojiMore: page(ModeNames.emojiMore, keys: secondPageKeys, label: backToAlphaLabel + "\u{00B2}"),
        ]
    }

    // MARK: - Sharing between layouts

    /// The default pages (no recents typed, no tone) of a layout whose back key
    /// is labelled `backToAlphaLabel`, built once per label for the process.
    ///
    /// The pages of two layouts differ only by that label, yet every definition
    /// used to build its own copy (about 43 KB of heap each, almost half of a
    /// definition). A `KeyboardMode` is a value over copy-on-write storage, so
    /// handing every definition the same value shares the keys, and a later
    /// `applying(_:tone:to:)` builds new pages for the one definition that
    /// enters the mode without touching the shared ones.
    static func sharedModes(backToAlphaLabel: String) -> [String: KeyboardMode] {
        sharedPages.value(for: backToAlphaLabel) { modes(backToAlphaLabel: backToAlphaLabel) }
    }

    private static let sharedPages = LockedCache<String, [String: KeyboardMode]>()

    /// A shared page's compiled tables, with the same sharing: the tables of a
    /// default page do not depend on the language (every emoji key binds every
    /// gesture itself, and the utility keys that fall back to the numeric mode
    /// find the same bindings there in every language), only on the label of
    /// its back key, so they are compiled once per label.
    ///
    /// Thread-safe, because the prewarm compiles definitions concurrently, and
    /// touched only when a definition is compiled, never on the typing path,
    /// where a lookup is the array index it always was. A page that is not the
    /// default one (recents typed, a tone chosen, a custom definition) is
    /// compiled for itself, and `CompiledModeTests` holds every shared table to
    /// what compiling that language's page alone gives.
    static func compiled(
        _ mode: KeyboardMode, fallbackMode: KeyboardMode?, shiftedMode: KeyboardMode?, locale: Locale
    ) -> CompiledMode {
        let label = mode.keys[UtilitySlot.symbols]?.bindings[.tap]?.label ?? ""
        let entry = sharedTables.value(for: "\(mode.name)|\(label)") {
            SharedTables(
                source: mode,
                compiled: CompiledMode(mode: mode, fallbackMode: fallbackMode, shiftedMode: shiftedMode, locale: locale)
            )
        }
        if entry.source == mode { return entry.compiled }
        return CompiledMode(mode: mode, fallbackMode: fallbackMode, shiftedMode: shiftedMode, locale: locale)
    }

    private struct SharedTables: Sendable {
        let source: KeyboardMode
        let compiled: CompiledMode
    }

    private static let sharedTables = LockedCache<String, SharedTables>()

    /// `definition` with the emoji pages rebuilt around `recents` and `tone`.
    /// Everything else in the definition is shared with it, not copied.
    static func applying(
        _ recents: EmojiRecents, tone: EmojiSkinTone = .none, to definition: KeyboardDefinition
    ) -> KeyboardDefinition {
        var updated = definition
        let pages = modes(backToAlphaLabel: definition.numericBackToAlphaLabel, recents: recents, tone: tone)
        for (name, mode) in pages {
            updated = updated.replacingMode(name, with: mode)
        }
        return updated
    }

    // MARK: - Keys

    /// The recent key's gestures after the tap, in the order of recency:
    /// clockwise from up, so the second-newest is a flick up and the oldest
    /// of the nine is up-left.
    static let recentGestures: [GestureType] = [
        .swipeUp, .swipeUpRight, .swipeRight, .swipeDownRight,
        .swipeDown, .swipeDownLeft, .swipeLeft, .swipeUpLeft,
    ]

    /// The recent key: `recents.items[0]` on the tap, the rest around it. A
    /// circle on it turns the page like on every other key of the mode.
    static func recentKey(_ recents: EmojiRecents, onSecondPage: Bool = false) -> KeyDefinition {
        let items = recents.items
        var cells = Array(repeating: "", count: gridGestures.count)
        for (position, gesture) in gridGestures.enumerated() {
            if gesture == .tap {
                cells[position] = items.first ?? ""
            } else if let rank = recentGestures.firstIndex(of: gesture), rank + 1 < items.count {
                cells[position] = items[rank + 1]
            }
        }
        return key(
            id: GridSlot.recent, name: String(localized: "Recent emoji"),
            cells: cells, returns: [], pageSwitch: onSecondPage ? toFirstPage : toSecondPage
        )
    }

    /// The default-tone keys, built once for the process.
    private static let firstPageKeys = pageKeys(second: false, tone: .none)
    private static let secondPageKeys = pageKeys(second: true, tone: .none)

    /// The nine family keys of a page, the hands and people in `tone`.
    private static func pageKeys(second: Bool, tone: EmojiSkinTone) -> [String: KeyDefinition] {
        func toned(_ cells: String) -> [String] {
            cells.split(separator: " ").map { tone.applying(to: String($0)) }
        }
        var keys: [String: KeyDefinition] = [:]
        for family in families {
            keys[family.slot] = key(
                id: family.slot, name: family.name,
                cells: toned(second ? family.more : family.main),
                returns: second ? [] : toned(family.returns),
                pageSwitch: second ? toFirstPage : toSecondPage
            )
        }
        return keys
    }

    /// A circle turns the page, in either direction (as everywhere else, a
    /// thumb circle rarely comes out the way it was meant).
    private static let toSecondPage = KeyBinding(
        label: "\u{2461}", action: .switchMode(ModeNames.emojiMore), category: .modifier,
        returnAction: nil, accessibilityLabel: String(localized: "More emoji")
    )
    private static let toFirstPage = KeyBinding(
        label: "\u{2460}", action: .switchMode(ModeNames.emoji), category: .modifier,
        returnAction: nil, accessibilityLabel: String(localized: "Main emoji")
    )

    /// One emoji key: `cells` in `gridGestures` order, `returns` in
    /// `returnGestures` order (or none).
    ///
    /// - Every binding commits one emoji and names itself by it: VoiceOver
    ///   reads an emoji in the user's language, so the generated custom
    ///   actions ("😂, swipe up") are localized for free, and a hand-written
    ///   English name would only get in the way. The key itself is named by
    ///   its family and its tap ("Joy, 😂"), the one thing the glyph does not
    ///   say.
    /// - A hold types what the tap types. The key has no digit or capital for
    ///   the long press to reach, and an unbound hold would fall through to the
    ///   numeric mode's ghost key and type a digit.
    private static func key(
        id: String, name: String, cells: [String], returns: [String], pageSwitch: KeyBinding
    ) -> KeyDefinition {
        precondition(cells.count == gridGestures.count, "\(id): a key has nine emoji")
        precondition(returns.isEmpty || returns.count == returnGestures.count, "\(id): eight return emoji or none")
        var bindings: [GestureType: KeyBinding] = [:]
        for (gesture, emoji) in zip(gridGestures, cells) where !emoji.isEmpty {
            let returnAction: KeyAction? = returnGestures.firstIndex(of: gesture)
                .flatMap { $0 < returns.count ? .commitText(returns[$0]) : nil }
            bindings[gesture] = KeyBinding(
                label: emoji, action: .commitText(emoji), category: .emoji,
                returnAction: returnAction, accessibilityLabel: nil
            )
        }
        let tapEmoji = cells[gridGestures.firstIndex(of: .tap) ?? 4]
        bindings[.tap] = KeyBinding(
            label: tapEmoji, action: .commitText(tapEmoji), category: .emoji,
            returnAction: nil, accessibilityLabel: "\(name), \(tapEmoji)"
        )
        bindings[.longPress] = KeyBinding(
            label: tapEmoji, action: .commitText(tapEmoji), category: .emoji,
            returnAction: nil, accessibilityLabel: nil
        )
        bindings[.circularClockwise] = pageSwitch
        bindings[.circularCounterclockwise] = pageSwitch
        return KeyDefinition(
            id: id, bindings: bindings, swipeMode: .eightWay,
            slideType: .none, style: .primary, tapCycleActions: nil
        )
    }

    /// The way back: a tap leaves for the letters, a swipe left goes to the
    /// numbers, and the clipboard gestures stay where they are on the other
    /// modes' version of this key.
    private static func lettersKey(label: String) -> KeyDefinition {
        var swipes = CommonKeys.clipboardBindings
        swipes[.swipeLeft] = KeyBinding(
            label: "", action: .switchMode(ModeNames.numeric), category: .modifier,
            returnAction: nil, accessibilityLabel: String(localized: "Numbers")
        )
        return KeyDefinition.utility(
            UtilitySlot.symbols, label: label, action: .switchMode(ModeNames.main),
            swipeMode: .eightWay, swipes: swipes,
            accessibilityLabel: String(localized: "Letters")
        )
    }

    // MARK: - Arrangements

    /// The letter grid and the utility column, with the recent key where the
    /// numeric mode keeps its zero.
    private static let arrangements: [ArrangementContext: GridArrangement] = {
        let portrait = GridArrangement(
            columns: 4,
            rows: [
                [.init(keyId: GridSlot.topLeft), .init(keyId: GridSlot.topCenter), .init(keyId: GridSlot.topRight), .init(keyId: UtilitySlot.globe)],
                [.init(keyId: GridSlot.midLeft), .init(keyId: GridSlot.center), .init(keyId: GridSlot.midRight), .init(keyId: UtilitySlot.symbols)],
                [.init(keyId: GridSlot.bottomLeft), .init(keyId: GridSlot.bottomCenter), .init(keyId: GridSlot.bottomRight), .init(keyId: UtilitySlot.delete)],
                [.init(keyId: GridSlot.recent), .init(keyId: UtilitySlot.space, widthMultiplier: 2), .init(keyId: UtilitySlot.return)],
            ]
        )
        let landscape = GridArrangement(
            columns: 5,
            rows: [
                [
                    .init(keyId: UtilitySlot.globe), .init(keyId: GridSlot.topLeft), .init(keyId: GridSlot.topCenter),
                    .init(keyId: GridSlot.topRight), .init(keyId: UtilitySlot.delete),
                ],
                [
                    .init(keyId: UtilitySlot.symbols), .init(keyId: GridSlot.midLeft), .init(keyId: GridSlot.center),
                    .init(keyId: GridSlot.midRight), .init(keyId: UtilitySlot.return, heightMultiplier: 2),
                ],
                [
                    .init(keyId: GridSlot.recent), .init(keyId: GridSlot.bottomLeft), .init(keyId: GridSlot.bottomCenter),
                    .init(keyId: GridSlot.bottomRight),
                ],
            ]
        )
        let leading = StandardArrangements.leadingUtilityKeys
        return [
            .portrait: portrait,
            .portraitUtilityLeft: portrait.movingToLeading(keyIds: leading),
            .landscape: landscape,
            .landscapeUtilityLeft: landscape.movingToLeading(keyIds: leading),
        ]
    }()
}
