//
//  CommonKeys.swift
//  Wurstfinger
//
//  Shared key definitions reusable across all MessagEase languages.
//

import Foundation

/// Shared key definitions reusable across all MessagEase languages.
/// Utility keys and default punctuation/symbol bindings for the 3x3 grid.
enum CommonKeys {
    // MARK: - Utility Keys

    static let globe: KeyDefinition = {
        var bindings: [GestureType: KeyBinding] = [:]
        // Tap is intentionally inert: switching the input method lives on the
        // swipe-left gesture below. The empty `.none` slot keeps the key's
        // accessibility label without re-triggering the globe on a plain tap;
        // `accessibilityActivationGesture` routes a VoiceOver activation to
        // that swipe so the label stays true for gesture-free input.
        bindings[.tap] = KeyBinding(
            label: "", action: .none,
            category: .utility, returnAction: nil,
            accessibilityLabel: String(localized: "Switch keyboard")
        )
        bindings[.swipeLeft] = KeyBinding(
            label: "", action: .advanceToNextInputMode,
            category: .utility, returnAction: nil,
            accessibilityLabel: String(localized: "Switch keyboard")
        )
        bindings[.swipeDown] = KeyBinding(
            label: "", action: .dismissKeyboard,
            category: .utility, returnAction: nil,
            accessibilityLabel: String(localized: "Hide keyboard")
        )
        bindings[.swipeRight] = KeyBinding(
            label: "", action: .switchToNextLanguage,
            category: .utility, returnAction: nil,
            accessibilityLabel: String(localized: "Next language")
        )
        // The way back round the language ring: Flickboard's "previous letter
        // layer". Unlabelled like the other globe swipes (the next-language
        // swipe shows the language code, a second one would only clutter it).
        bindings[.swipeUp] = KeyBinding(
            label: "", action: .switchToPreviousLanguage,
            category: .utility, returnAction: nil,
            accessibilityLabel: String(localized: "Previous language")
        )
        return KeyDefinition(
            id: UtilitySlot.globe, bindings: bindings,
            swipeMode: .fourWayCross, slideType: .none,
            style: .utility, tapCycleActions: nil,
            accessibilityActivationGesture: .swipeLeft
        )
    }()

    static let delete = KeyDefinition.utility(
        UtilitySlot.delete, label: "⌫", action: .deleteBackward,
        swipeMode: .twoWayHorizontal, slideType: .delete,
        accessibilityLabel: String(localized: "Delete")
    )

    /// Home / End on the return key, after the Android MessagEase gestures
    /// (issue #77): a swipe toward the top-left corner jumps to the start of
    /// the line, toward the bottom-right corner to its end. The return swipe
    /// (out and back) of each goes the whole way, to the start or end of the
    /// document. The labels are empty because the key has no room for hints
    /// next to its glyph. The names exist for VoiceOver, which lists them as
    /// custom actions. The key's other swipes are `wordDeleteBindings`.
    static let lineJumpBindings: [GestureType: KeyBinding] = [
        .swipeUpLeft: KeyBinding(
            label: "", action: .lineStart, category: .utility,
            returnAction: .documentStart, accessibilityLabel: String(localized: "Line start")
        ),
        .swipeDownRight: KeyBinding(
            label: "", action: .lineEnd, category: .utility,
            returnAction: .documentEnd, accessibilityLabel: String(localized: "Line end")
        ),
    ]

    /// Word delete on the return key, left and right: Flickboard's delete-word
    /// on its delete key and long swipe. The delete key's own gestures are
    /// slides (one character per step), so the word-sized deletions live beside
    /// the other whole-unit movements, on the key next to it. Plain swipes, no
    /// return swipe: the delete is destructive and a rebound must not double it.
    static let wordDeleteBindings: [GestureType: KeyBinding] = [
        .swipeLeft: KeyBinding(
            label: "", action: .deleteWordBackward, category: .utility,
            returnAction: nil, accessibilityLabel: String(localized: "Delete word")
        ),
        .swipeRight: KeyBinding(
            label: "", action: .deleteWordForward, category: .utility,
            returnAction: nil, accessibilityLabel: String(localized: "Delete word ahead")
        ),
    ]

    static let `return` = KeyDefinition.utility(
        UtilitySlot.return, label: "↵", action: .newline,
        swipeMode: .eightWay,
        swipes: lineJumpBindings.merging(wordDeleteBindings) { first, _ in first },
        accessibilityLabel: String(localized: "New line")
    )

    /// Cut-all, bound to both circle directions below.
    ///
    /// Circling one key is easier to aim than circling a letter, and the key
    /// already owns the clipboard, so the gesture reads as "cut, but for
    /// everything". The direction is deliberately not distinguished: a thumb
    /// circle rarely comes out the way it was intended, and mapping the two
    /// directions to different clipboard actions would make a slip destructive.
    private static let cutAll = KeyBinding(
        label: "", action: .cutAll, category: .utility,
        returnAction: nil, accessibilityLabel: String(localized: "Cut all")
    )

    /// Clipboard bindings shared between the symbols key and numeric back-to-main key.
    static let clipboardBindings: [GestureType: KeyBinding] = [
        .swipeUp: KeyBinding(
            label: "", action: .copy, category: .utility,
            returnAction: nil, accessibilityLabel: String(localized: "Copy")
        ),
        .swipeUpRight: KeyBinding(
            label: "", action: .cut, category: .utility,
            returnAction: nil, accessibilityLabel: String(localized: "Cut")
        ),
        .swipeDown: KeyBinding(
            label: "", action: .paste, category: .utility,
            returnAction: nil, accessibilityLabel: String(localized: "Paste")
        ),
        .circularClockwise: cutAll,
        .circularCounterclockwise: cutAll,
    ]

    // EMOJI MODE: the gesture that enters it, on the key that stands for "123",
    // so it works from the letters and from the shifted and caps-lock modes
    // (generated from this one). Down-right is one of the key's two free
    // gestures; the other, right, would put the hint on top of the "123" label,
    // and the bottom-right corner is empty. The hint is drawn, so the way in is
    // discoverable.
    static let emojiEntry = KeyBinding(
        label: "\u{1F600}", action: .switchMode(ModeNames.emoji), category: .modifier,
        returnAction: nil, accessibilityLabel: String(localized: "Emoji")
    )

    /// Switches to the numeric mode. The label is the glyph sequence "123",
    /// which VoiceOver reads as the *number* one hundred twenty-three, so the
    /// tap carries a semantic name — as every neighbouring utility key does.
    /// Its counterpart is `NumericLayouts.backToMain`, named "Letters".
    static let symbols = symbols(withTerminalModes: false)

    /// The numeric-mode key, optionally with the gestures that enter the
    /// one-shot Ctrl and Alt modes (`KeyboardMode.generateTerminalModifier`)
    /// and the one that mirrors the keyboard.
    ///
    /// Flickboard puts its Ctrl and Alt toggles on the space bar; here the space
    /// bar's swipes are slides, so they sit on this key beside the clipboard
    /// gestures: up-left for Ctrl, left for Alt, down-left to mirror the
    /// keyboard (Flickboard's "toggle handedness"). Only layouts that have the
    /// two modes get the first two — a `switchMode` to a mode the definition
    /// does not have fails validation.
    static func symbols(withTerminalModes: Bool) -> KeyDefinition {
        var swipes = clipboardBindings
        swipes[.swipeDownRight] = emojiEntry // EMOJI MODE hook
        swipes[.swipeDownLeft] = KeyBinding(
            label: "", action: .toggleUtilityColumnSide, category: .utility,
            returnAction: nil, accessibilityLabel: String(localized: "Mirror keyboard")
        )
        if withTerminalModes {
            swipes[.swipeUpLeft] = KeyBinding(
                label: "", action: .switchMode(ModeNames.control), category: .modifier,
                returnAction: nil, accessibilityLabel: String(localized: "Ctrl")
            )
            swipes[.swipeLeft] = KeyBinding(
                label: "", action: .switchMode(ModeNames.alt), category: .modifier,
                returnAction: nil, accessibilityLabel: String(localized: "Alt")
            )
        }
        return KeyDefinition.utility(
            UtilitySlot.symbols, label: "123", action: .switchMode(ModeNames.numeric),
            swipeMode: .eightWay,
            swipes: swipes,
            accessibilityLabel: String(localized: "Numbers")
        )
    }

    /// Space bar. The `zeroDigit` parameterizes the hold-for-digit output so
    /// each layout can emit its own native zero (e.g. Arabic ٠); it defaults to
    /// ASCII "0". `GridKeyboardFactory` and `NumericLayouts` pass the layout's
    /// first numeric digit.
    static func spacebar(zeroDigit: String = "0") -> KeyDefinition {
        KeyDefinition(
            id: UtilitySlot.space,
            bindings: [
                .tap: KeyBinding(
                    label: "␣", action: .space, category: .utility,
                    returnAction: nil, accessibilityLabel: String(localized: "Space")
                ),
                // The hold-for-digit feature pairs 0 with the space bar (no
                // letter-mode slot maps to 0 otherwise). Long presses
                // only occur with the opt-in setting enabled, so this is inert by
                // default; .longPress has no hint alignment, so nothing renders.
                .longPress: KeyBinding(
                    label: zeroDigit, action: .commitText(zeroDigit),
                    category: .digit, returnAction: nil, accessibilityLabel: nil
                ),
                // Word completions: a swipe down takes the first one (it does
                // nothing without any). The only vertical swipe the bar has
                // besides the label toggle on up; unlabelled, the bar has no
                // room for a hint. Named for VoiceOver's custom actions.
                .swipeDown: KeyBinding(
                    label: "", action: .acceptCompletion, category: .utility,
                    returnAction: nil, accessibilityLabel: String(localized: "Accept suggestion")
                ),
            ],
            // Vertical only, for the down-swipe above: the resolvers drop a
            // swipe a key's mode does not allow, and the engine runs the
            // bar's slides and up-swipe off `slideType`, not this.
            swipeMode: .twoWayVertical,
            slideType: .moveCursor,
            style: .spacebar,
            tapCycleActions: nil
        )
    }

    /// All utility keys as dictionary, mergeable with language keys.
    static let allUtilityKeys: [String: KeyDefinition] = [
        UtilitySlot.globe: globe,
        UtilitySlot.delete: delete,
        UtilitySlot.return: `return`,
        UtilitySlot.symbols: symbols,
        UtilitySlot.space: spacebar(),
    ]

    // MARK: - Default Slot Bindings

    /// Shared punctuation, symbol, compose, and action bindings for each grid slot.
    /// The factory merges these with language-specific center characters.
    /// Each KeyBinding includes both the primary action and an optional return-swipe action.
    ///
    /// **Which of these carry an `accessibilityLabel`, and why so few.** A label
    /// puts a binding in the first, curated tier of VoiceOver custom actions
    /// (`KeyDefinition.accessibilityActions`), ahead of the generated
    /// "character, gesture" entries every typed character gets. It is for
    /// bindings whose glyph does not say what they do, or that a user needs
    /// first and often — the ones unreachable without gestures *and* without a
    /// workaround:
    ///
    /// - `,` `.` `?` — sentence punctuation. Auto-capitalization and the
    ///   double-space shortcut can stand in for a period; nothing stands in for
    ///   comma and question mark, and a keyboard that cannot end a question is
    ///   not usable without gestures.
    /// - `⇧` / `⇩` — deliberate capitalization. Auto-capitalization only produces
    ///   sentence-initial capitals, so names and acronyms need the modifier. Both
    ///   directions are named so that caps lock is not a one-way door: `⇧` in the
    ///   caps-lock mode is a no-op, and `⇩` is the only way back.
    ///
    /// Letter bindings stay unnamed on purpose: their glyph is their name, and
    /// the generated tier offers each of them after the curated entries.
    /// Names state the *function*, not the glyph, so
    /// `GridKeyboardFactory` hands them down when a layout substitutes its own
    /// script's mark (Arabic `،`, Japanese `。`).
    static let defaultSlotBindings: [String: [GestureType: KeyBinding]] = [
        // MARK: topLeft

        GridSlot.topLeft: [
            .swipeUpLeft: KeyBinding(
                label: "\u{1F152}", action: .cycleAccents, category: .compose,
                returnAction: .cycleAccents, accessibilityLabel: nil
            ),
            .swipeRight: KeyBinding(
                label: "-", action: .commitText("-"), category: nil,
                returnAction: .commitText("÷"), accessibilityLabel: nil
            ),
            .swipeDownLeft: KeyBinding(
                label: "$", action: .compose(trigger: "$"), category: .compose,
                returnAction: .commitText("¥"), accessibilityLabel: nil
            ),
            // Flickboard's ellipsis key and its bullet (shifted); the ellipsis is
            // also the return swipe of the period, the bullet has no other home.
            .swipeDown: KeyBinding(
                label: "…", action: .commitText("…"), category: nil,
                returnAction: .commitText("•"), accessibilityLabel: nil
            ),
            // Breve as a dead key (ă ĕ ğ ĭ ŏ ŭ …); its return swipe is the
            // low-9 quotation mark that completes the quote family on the
            // bottom-center key (“ ” „ and now ‚).
            .swipeUpRight: KeyBinding(
                label: "˘", action: .compose(trigger: "˘"), category: .compose,
                returnAction: .commitText("‚"), accessibilityLabel: nil
            ),
        ],

        // MARK: topCenter

        GridSlot.topCenter: [
            .swipeUpLeft: KeyBinding(
                label: "`", action: .compose(trigger: "ˋ"), category: .compose,
                returnAction: .commitText("\u{2018}"), accessibilityLabel: nil
            ),
            .swipeUp: KeyBinding(
                label: "^", action: .compose(trigger: "^"), category: .compose,
                returnAction: .compose(trigger: "ˇ"), accessibilityLabel: nil
            ),
            .swipeUpRight: KeyBinding(
                label: "´", action: .compose(trigger: "´"), category: .compose,
                returnAction: .commitText("\u{2019}"), accessibilityLabel: nil
            ),
            .swipeRight: KeyBinding(
                label: "!", action: .commitText("!"), category: nil,
                returnAction: .commitText("¡"), accessibilityLabel: nil
            ),
            .swipeDownRight: KeyBinding(
                label: "\\", action: .commitText("\\"), category: nil,
                returnAction: .commitText("—"), accessibilityLabel: nil
            ),
            .swipeDownLeft: KeyBinding(
                label: "/", action: .commitText("/"), category: nil,
                returnAction: .commitText("–"), accessibilityLabel: nil
            ),
            .swipeLeft: KeyBinding(
                label: "+", action: .commitText("+"), category: nil,
                returnAction: .commitText("×"), accessibilityLabel: nil
            ),
        ],

        // MARK: topRight

        GridSlot.topRight: [
            .swipeUpRight: KeyBinding(
                label: "", action: .commitText("\n"), category: nil,
                returnAction: .commitText("\n"), accessibilityLabel: nil
            ),
            .swipeDownRight: KeyBinding(
                label: "€", action: .commitText("€"), category: nil,
                returnAction: .commitText("£"), accessibilityLabel: nil
            ),
            .swipeDown: KeyBinding(
                label: "=", action: .commitText("="), category: nil,
                returnAction: .commitText("±"), accessibilityLabel: nil
            ),
            .swipeLeft: KeyBinding(
                label: "?", action: .commitText("?"), category: nil,
                returnAction: .commitText("¿"),
                accessibilityLabel: String(localized: "Question mark")
            ),
            // Up one line, keeping the column: Flickboard's line-jump on the
            // same key and direction (its down twin is on the bottomRight key).
            // The arrow is the hint and hides with the extra symbols, so the
            // layout can still be practised from memory. Unnamed for VoiceOver
            // like every letter-grid binding outside the policy set (see the
            // note above): the screen reader's own text navigation covers it.
            .swipeUp: KeyBinding(
                label: "↑", action: .lineUp, category: .symbol,
                returnAction: nil, accessibilityLabel: nil
            ),
        ],

        // MARK: midLeft

        GridSlot.midLeft: [
            .swipeUpLeft: KeyBinding(
                label: "{", action: .commitText("{"), category: nil,
                returnAction: .commitText("}"), accessibilityLabel: nil
            ),
            .swipeUpRight: KeyBinding(
                label: "%", action: .commitText("%"), category: nil,
                returnAction: .commitText("‰"), accessibilityLabel: nil
            ),
            .swipeDownRight: KeyBinding(
                label: "_", action: .commitText("_"), category: nil,
                returnAction: .commitText("¬"), accessibilityLabel: nil
            ),
            .swipeDownLeft: KeyBinding(
                label: "[", action: .commitText("["), category: nil,
                returnAction: .commitText("]"), accessibilityLabel: nil
            ),
            .swipeLeft: KeyBinding(
                label: "(", action: .commitText("("), category: nil,
                returnAction: .commitText(")"), accessibilityLabel: nil
            ),
            // Ogonek as a dead key (ą ę į ų), macron on its return swipe
            // (ā ē ī ō ū): Flickboard's bottom-of-the-key pair.
            .swipeDown: KeyBinding(
                label: "˛", action: .compose(trigger: "˛"), category: .compose,
                returnAction: .compose(trigger: "¯"), accessibilityLabel: nil
            ),
        ],

        // MARK: center — no defaults (all 8 directions are language-specific)

        // MARK: midRight

        GridSlot.midRight: [
            .swipeUpLeft: KeyBinding(
                label: "|", action: .commitText("|"), category: nil,
                returnAction: .commitText("¶"), accessibilityLabel: nil
            ),
            // `KeyboardMode.replacingShiftUpBinding` repoints this to caps lock
            // in the shifted mode and to a no-op in caps lock itself, which
            // matches how a single shift key behaves everywhere else — and it
            // decides the name per mode, because the caps-lock no-op must not
            // become a rotor action. The return swipe (`capitalizeWord`) cannot
            // be named separately: a binding carries one label, and a custom
            // action always dispatches `isReturn: false`.
            .swipeUp: KeyBinding(
                label: "⇧", action: .switchMode(ModeNames.shifted), category: .modifier,
                returnAction: .capitalizeWord(uppercased: true),
                accessibilityLabel: String(localized: "Shift")
            ),
            .swipeUpRight: KeyBinding(
                label: "}", action: .commitText("}"), category: nil,
                returnAction: .commitText("{"), accessibilityLabel: nil
            ),
            .swipeRight: KeyBinding(
                label: ")", action: .commitText(")"), category: nil,
                returnAction: .commitText("("), accessibilityLabel: nil
            ),
            // Present in the shifted and caps-lock modes; main keeps it only as
            // an unlabelled carrier for the return swipe (see
            // `GridKeyboardFactory`). Named because it is the only way out of
            // caps lock, where the ⇧ above switches to the mode it is already
            // in. Its return swipe steps the word before the cursor down a case
            // (UPPER → Title → lower), the counterpart of the ⇧ return swipe.
            .swipeDown: KeyBinding(
                label: "⇩", action: .switchMode(ModeNames.main), category: .modifier,
                returnAction: .cycleWordCase(ascending: false),
                accessibilityLabel: String(localized: "Lowercase")
            ),
            .swipeDownRight: KeyBinding(
                label: "]", action: .commitText("]"), category: nil,
                returnAction: .commitText("["), accessibilityLabel: nil
            ),
            .swipeDownLeft: KeyBinding(
                label: "@", action: .commitText("@"), category: nil,
                returnAction: .commitText("ª"), accessibilityLabel: nil
            ),
        ],

        // MARK: bottomLeft

        GridSlot.bottomLeft: [
            .swipeUpLeft: KeyBinding(
                label: "~", action: .compose(trigger: "~"), category: .compose,
                returnAction: .commitText("˜"), accessibilityLabel: nil
            ),
            .swipeUp: KeyBinding(
                label: "¨", action: .compose(trigger: "¨"), category: .compose,
                returnAction: .compose(trigger: "˝"), accessibilityLabel: nil
            ),
            .swipeRight: KeyBinding(
                label: "*", action: .commitText("*"), category: nil,
                returnAction: .commitText("†"), accessibilityLabel: nil
            ),
            .swipeDownRight: KeyBinding(
                label: "⇥", action: .commitText("\t"), category: nil,
                returnAction: .commitText("\t"), accessibilityLabel: nil
            ),
            .swipeLeft: KeyBinding(
                label: "<", action: .commitText("<"), category: nil,
                returnAction: .commitText("‹"), accessibilityLabel: nil
            ),
            // Caron as a dead key on its own (the ^ key's return swipe types it
            // too), guillemets on the return swipes: Flickboard's « sits here.
            .swipeDownLeft: KeyBinding(
                label: "ˇ", action: .compose(trigger: "ˇ"), category: .compose,
                returnAction: .commitText("«"), accessibilityLabel: nil
            ),
            // Cedilla as a dead key (ş ţ ģ ķ), closing guillemet on the return
            // swipe.
            .swipeDown: KeyBinding(
                label: "¸", action: .compose(trigger: "¸"), category: .compose,
                returnAction: .commitText("»"), accessibilityLabel: nil
            ),
        ],

        // MARK: bottomCenter

        GridSlot.bottomCenter: [
            .swipeUpLeft: KeyBinding(
                label: "\"", action: .commitText("\""), category: nil,
                returnAction: .commitText("\u{201C}"), accessibilityLabel: nil
            ),
            .swipeUpRight: KeyBinding(
                label: "'", action: .commitText("'"), category: nil,
                returnAction: .commitText("\u{201D}"), accessibilityLabel: nil
            ),
            .swipeDownRight: KeyBinding(
                label: ":", action: .commitText(":"), category: nil,
                returnAction: .commitText("„"), accessibilityLabel: nil
            ),
            .swipeDown: KeyBinding(
                label: ".", action: .commitText("."), category: nil,
                returnAction: .commitText("…"),
                accessibilityLabel: String(localized: "Period")
            ),
            .swipeDownLeft: KeyBinding(
                label: ",", action: .commitText(","), category: nil,
                returnAction: .commitText(","),
                accessibilityLabel: String(localized: "Comma")
            ),
        ],

        // MARK: bottomRight

        GridSlot.bottomRight: [
            .swipeUp: KeyBinding(
                label: "&", action: .commitText("&"), category: nil,
                returnAction: .commitText("§"), accessibilityLabel: nil
            ),
            .swipeUpRight: KeyBinding(
                label: "°", action: .compose(trigger: "°"), category: .compose,
                returnAction: .commitText("º"), accessibilityLabel: nil
            ),
            .swipeRight: KeyBinding(
                label: ">", action: .commitText(">"), category: nil,
                returnAction: .commitText("›"), accessibilityLabel: nil
            ),
            .swipeDownRight: KeyBinding(
                label: "", action: .commitText(" "), category: nil,
                returnAction: .commitText(" "), accessibilityLabel: nil
            ),
            .swipeDownLeft: KeyBinding(
                label: ";", action: .commitText(";"), category: nil,
                returnAction: .commitText(";"), accessibilityLabel: nil
            ),
            .swipeLeft: KeyBinding(
                label: "#", action: .commitText("#"), category: nil,
                returnAction: .commitText("£"), accessibilityLabel: nil
            ),
            // Down one line, keeping the column (see the topRight key).
            .swipeDown: KeyBinding(
                label: "↓", action: .lineDown, category: .symbol,
                returnAction: nil, accessibilityLabel: nil
            ),
        ],
    ]

    /// The slot bindings a layout starts from when it keeps no shared
    /// punctuation on its letter keys: the shift affordance on the midRight
    /// key (⇧ up, ⇩ down), which the shifted modes and the caps-lock exit
    /// depend on, and the named period on the bottomCenter key's down swipe,
    /// which a layout that carries no other sentence punctuation still needs
    /// to be usable without gestures (see the naming policy above).
    /// Everything else a key carries is the layout's own.
    static let essentialSlotBindings: [String: [GestureType: KeyBinding]] = {
        let shift: Set<GestureType> = [.swipeUp, .swipeDown]
        let midRight = (defaultSlotBindings[GridSlot.midRight] ?? [:]).filter { shift.contains($0.key) }
        var essential = [GridSlot.midRight: midRight]
        if let period = defaultSlotBindings[GridSlot.bottomCenter]?[.swipeDown] {
            essential[GridSlot.bottomCenter] = [.swipeDown: period]
        }
        return essential
    }()
}
