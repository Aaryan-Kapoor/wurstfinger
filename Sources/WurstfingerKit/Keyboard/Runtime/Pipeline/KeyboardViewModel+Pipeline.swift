//
//  KeyboardViewModel+Pipeline.swift
//  Wurstfinger
//
//  Extension that handles the data-driven gesture pipeline:
//  definition loading, compiled gesture tables, pipeline assembly,
//  gesture dispatch, mode switching, and slide handling.
//

import Foundation

extension KeyboardViewModel {
    // MARK: - Data-Driven Loading & Pipeline

    /// Loads a keyboard definition by ID from the registry and sets up the
    /// compiled gesture tables and action pipeline.
    func loadDefinition(for id: String) {
        // Fall back to English if the requested language can't be resolved (e.g.
        // a stale stored id for a language removed in a later version) so the
        // keyboard always renders a layout instead of coming up blank.
        guard let base = KeyboardRegistry.load(id: id)
            ?? KeyboardRegistry.load(id: LanguageMetadata.english.id)
        else { return }
        let definition = applyNumpadType(to: base)
        currentDefinition = definition
        // Record the signature of what was actually loaded (the id may differ
        // from the requested one after the English fallback) so the controller
        // can skip redundant rebuilds on the next appearance.
        let numpadType = sharedDefaults.string(forKey: SettingsKey.numpadStyle.rawValue)
        loadedDefinitionSignature = Self.definitionSignature(
            languageId: definition.id,
            numpadType: numpadType
        )
        activeModeName = definition.defaultMode
        pipelineLocale = definition.locale
        // The gesture tables come from the registry's cache: a prewarmed
        // language (phone numpad) finds them ready, anything else compiles here
        // once and every later switch back is a hit.
        compiledDefinition = KeyboardRegistry.compiled(
            for: definition,
            signature: KeyboardRegistry.compiledSignature(
                languageId: definition.id, numpadType: numpadType
            )
        )
        rebuildPipeline()
        startPrewarmIfNeeded()
    }

    /// Signature of the inputs that determine a loaded definition (language +
    /// numpad type). Pure so the desync-free comparison between the
    /// controller's desired inputs and the view model's loaded state can be
    /// unit-tested without a UIKit lifecycle.
    static func definitionSignature(languageId: String, numpadType: String?) -> String {
        "\(languageId)|\(numpadType ?? "")"
    }

    /// Swaps the numeric mode to the classic (7-8-9) ordering when the user
    /// selected it. The registry caches the phone-style definition, so this
    /// always derives from the canonical phone layout and never mutates the cache.
    private func applyNumpadType(to definition: KeyboardDefinition) -> KeyboardDefinition {
        let raw = sharedDefaults.string(forKey: SettingsKey.numpadStyle.rawValue)
        let numpadType = raw.flatMap(NumpadType.init(rawValue:)) ?? .phone
        guard numpadType == .classic else { return definition }
        let classicNumeric = NumericLayouts.classic(
            digits: definition.numericDigits,
            backToAlphaLabel: definition.numericBackToAlphaLabel
        )
        return definition.replacingMode(ModeNames.numeric, with: classicNumeric)
    }

    /// Injects the text input target (typically a `DocumentProxyTarget`).
    func bindTextInputTarget(_ target: TextInputTarget) {
        textInputTarget = target
        rebuildPipeline()
    }

    /// Injects VC-specific action closures (globe key, dismiss).
    func bindViewControllerActions(
        advanceToNextInputMode: @escaping () -> Void,
        dismissKeyboard: @escaping () -> Void
    ) {
        onAdvanceToNextInputMode = advanceToNextInputMode
        onDismissKeyboard = dismissKeyboard
        rebuildPipeline()
    }

    /// Recompiles the gesture tables from `currentDefinition`, bypassing the
    /// registry cache.
    ///
    /// `loadDefinition` takes the cached tables instead; this is for a
    /// definition that was assigned to `currentDefinition` directly (a
    /// fixture, a custom layout) and so has no registry signature to cache
    /// under. The policy compiled in is the resolvers': standard is primary →
    /// ghost (numeric fallback), a return swipe is returnSwipe → primary →
    /// ghost.
    func rebuildResolverChain() {
        compiledDefinition = currentDefinition.map(CompiledDefinition.init)
    }

    /// Assembles the full action pipeline with all middlewares.
    func rebuildPipeline() {
        guard let definition = currentDefinition else {
            pipeline = nil
            return
        }
        var middlewares: [ActionMiddleware] = []

        // 1. Haptic feedback — confirmation ticks for state-changing actions
        //    only. The per-keystroke tap haptic fires once at touch-down in
        //    the view layer (`feedbackTap`) and slide steps trigger their own
        //    drag haptic, so text actions MUST stay silent here: a per-action
        //    haptic buzzed every key press and slide step a second time.
        middlewares.append(HapticMiddleware(trigger: { [weak self] action in
            self?.triggerHaptic(for: action)
        }))

        // 2. Compose + Cycle Accents — per-definition engine so language-specific
        // compose rule overrides are honored (rebuilt on every definition load).
        let composeEngine = definition.settings.composeRuleOverrides
            .map { ComposeEngine.withGlobalRules(overrides: $0) } ?? .shared
        middlewares.append(ComposeMiddleware(
            compose: { previous, trigger in
                composeEngine.compose(previous: previous, trigger: trigger)
            },
            cycleAccent: { character in
                composeEngine.cycleAccent(for: character)
            },
            previousCharacter: { [weak self] in
                self?.textInputTarget?.documentContextBeforeInput?.last.map(String.init) ?? ""
            },
            deletePreviousCharacter: { [weak self] in
                self?.textInputTarget?.deleteBackward()
            },
            selectedText: { [weak self] in self?.textInputTarget?.selectedText }
        ))

        // 3. Sequential composition — one shared middleware in two flavours:
        //
        //    3a. Vietnamese Telex: two-char digraph lookback plus single-char
        //        lookback. Always appended; inert (a single closure call) via
        //        `isActive` on non-Telex layouts.
        //    3b. Sequential combine (static rule table or the algorithmic
        //        Hangul automaton, resolved once by `settings.sequentialCombiner`
        //        in the definition layer). Only appended when the definition
        //        opts into a combiner, so the ~40 other layouts never allocate
        //        the middleware or evaluate its closures.
        let inputMethod = definition.settings.inputMethod
        middlewares.append(SequentialCompositionMiddleware(
            isActive: { inputMethod == .telex },
            documentContextBefore: { [weak self] in
                self?.textInputTarget?.documentContextBeforeInput
            },
            deleteBackward: { [weak self] in
                self?.textInputTarget?.deleteBackward()
            },
            selectedText: { [weak self] in self?.textInputTarget?.selectedText },
            composeDigraph: { prev2, prev1, trigger in
                ComposeEngine.composeTelexDigraph(prev2: prev2, prev1: prev1, trigger: trigger)
            },
            composeSingle: { previous, trigger in
                ComposeEngine.composeTelex(previous: previous, trigger: trigger)
            }
        ))

        if let combiner = definition.settings.sequentialCombiner {
            middlewares.append(SequentialCompositionMiddleware(
                isActive: { true },
                documentContextBefore: { [weak self] in
                    self?.textInputTarget?.documentContextBeforeInput
                },
                deleteBackward: { [weak self] in
                    self?.textInputTarget?.deleteBackward()
                },
                selectedText: { [weak self] in self?.textInputTarget?.selectedText },
                composeDigraph: nil,
                composeSingle: combiner
            ))
        }

        // 3c. Text replacement (issue #259). After composition, so a boundary
        //     produced by a dead key is already final, and before the text
        //     input types the boundary, so the phrase lands in front of it.
        //     Reads the table from the settings snapshot on use (the pipeline
        //     is not rebuilt when the shortcuts change) and is inert while
        //     the table is empty. Before double-space: the expansion ends in a
        //     word, never a space, so the two cannot both claim a keystroke.
        middlewares.append(TextReplacementMiddleware(
            table: { [weak self] in self?.typingBehavior.textReplacements ?? .empty },
            locale: { [weak self] in self?.pipelineLocale ?? Locale.current },
            documentContextBefore: { [weak self] in
                self?.textInputTarget?.documentContextBeforeInput
            },
            selectedText: { [weak self] in self?.textInputTarget?.selectedText },
            deleteBackward: { [weak self] in self?.textInputTarget?.deleteBackward() },
            insertText: { [weak self] text in self?.textInputTarget?.insertText(text) }
        ))

        // 4. Advanced text (delete-forward, capitalize, clipboard). The
        //    clipboard confirmation tick fires from the middleware's success
        //    paths (not upfront in the haptic middleware) so guarded no-ops
        //    stay silent.
        middlewares.append(AdvancedTextMiddleware(
            target: { [weak self] in self?.textInputTarget },
            locale: { [weak self] in self?.pipelineLocale ?? Locale.current },
            onClipboardSuccess: { [weak self] in self?.feel(.clipboardSuccess) },
            // Read on use, not captured at build time: the pipeline is only
            // rebuilt on definition or target changes, so a captured value
            // would keep the old setting until the next reload. Cut-all runs
            // once per deliberate circle, so the read is off the hot path.
            isCutAllEnabled: { [weak self] in
                self?.typingBehavior.cutAllEnabled ?? false
            },
            clipboard: clipboard
        ))

        // 4c. Double-space → sentence terminator (the iOS "." Shortcut). Runs
        //     right before the text-input middleware so it can rewrite the
        //     pending `.space`. The terminator comes from the definition, so
        //     Hindi and Japanese get their own marks. Inert unless enabled.
        middlewares.append(DoubleSpacePeriodMiddleware(
            isEnabled: { [weak self] in
                self?.typingBehavior.doubleSpacePeriodEnabled ?? false
            },
            documentContextBefore: { [weak self] in
                self?.textInputTarget?.documentContextBeforeInput
            },
            selectedText: { [weak self] in
                self?.textInputTarget?.selectedText
            },
            deleteBackward: { [weak self] in
                self?.textInputTarget?.deleteBackward()
            },
            sentenceTerminator: AutoCapitalization.sentenceTerminator(for: definition.locale)
        ))

        // 5. Basic text input (commitText, deleteBackward, space, newline, moveCursor)
        middlewares.append(TextInputMiddleware(
            target: { [weak self] in self?.textInputTarget }
        ))

        // 6. View controller actions (globe, dismiss)
        middlewares.append(ViewControllerActionMiddleware(
            onAdvanceToNextInputMode: { [weak self] in self?.onAdvanceToNextInputMode?() },
            onDismissKeyboard: { [weak self] in self?.onDismissKeyboard?() }
        ))

        // 7. Auto-capitalization
        middlewares.append(AutoCapitalizationMiddleware(
            evaluate: { [weak self] in self?.evaluateAutoCapitalization() },
            onCapitalize: { [weak self] in self?.engageAutoCapitalization() },
            onReleaseCapitalize: { [weak self] in
                // Mirror `refreshAutoCapitalization`: only an *auto-engaged*
                // shift may be released when the context stops calling for
                // capitalization. A manually tapped shift is one-shot and is
                // consumed exclusively by letters (via the shifted mode's
                // auto-transition) — never dropped by delete, symbols,
                // paste, or cut — matching iOS system shift behavior.
                guard let self, shiftEngagedByAutoCapitalization else { return }
                releaseAutoCapitalization()
            }
        ))

        // 8. Mode transitions (auto-transitions from key category)
        middlewares.append(ModeTransitionMiddleware(
            definition: definition,
            onModeChange: { [weak self] newMode in
                self?.switchToMode(newMode)
            }
        ))

        pipeline = ActionPipeline(middlewares: middlewares)
    }

    // MARK: - Auto-Capitalization

    /// Re-evaluates auto-capitalization outside the key-action pipeline.
    /// Called from `KeyboardViewController` when the host text changes
    /// (keyboard appearance, field switch, caret relocation) so the shift
    /// state matches the new context. Idempotent: `switchToMode` ignores
    /// same-mode switches, so overlapping calls (e.g. `viewWillAppear` and
    /// `textDidChange` both firing on appearance) are harmless.
    func refreshAutoCapitalization() {
        switch evaluateAutoCapitalization() {
        case .some(true):
            engageAutoCapitalization()
        case .some(false):
            // Outside the key pipeline only an *auto-engaged* shift may be
            // released — a manually tapped shift must survive textDidChange
            // firing for caret moves or field switches.
            if shiftEngagedByAutoCapitalization {
                releaseAutoCapitalization()
            }
        case .none:
            break
        }
    }

    /// Returns whether the next key should be capitalized, or `nil` when
    /// auto-capitalization is inactive — either the definition does not
    /// support it for this language or the user disabled it in settings.
    func evaluateAutoCapitalization() -> Bool? {
        guard currentDefinition?.settings.autoCapitalize == true,
              typingBehavior.autoCapitalizeEnabled
        else { return nil }
        let context = textInputTarget?.documentContextBeforeInput
        // Sentence-opening punctuation (Spanish ¿/¡) capitalizes the letter
        // that immediately follows it, matching iOS system keyboards.
        if let last = context?.last,
           AutoCapitalization.shouldCapitalizeImmediately(after: String(last)) {
            return true
        }
        return AutoCapitalization.shouldCapitalize(context: context)
    }

    /// Engages the shifted mode for the next key. Only fires from `main`:
    /// caps lock must survive sentence enders, and the numeric/symbol
    /// modes must not be hijacked into the letter modes.
    func engageAutoCapitalization() {
        guard activeModeName == ModeNames.main else { return }
        switchToMode(ModeNames.shifted)
        shiftEngagedByAutoCapitalization = activeModeName == ModeNames.shifted
    }

    /// Releases a pending auto-shift. Only fires from `shifted` so caps
    /// lock and non-letter modes are never demoted.
    func releaseAutoCapitalization() {
        guard activeModeName == ModeNames.shifted else { return }
        switchToMode(ModeNames.main)
    }

    // MARK: - Gesture Dispatch

    /// Central entry point for the data-driven gesture path.
    ///
    /// Returns whether the gesture resolved to a binding and was dispatched.
    /// The long-press path uses this to decide whether the touch is consumed:
    /// a key without a long-press binding (e.g. return, globe) must keep its
    /// normal tap on release instead of being swallowed by the failed hold.
    @discardableResult
    func handleGesture(_ gesture: GestureType, keyId: String, isReturn: Bool) -> Bool {
        // `dispatch` nests inside the `keystroke` interval opened at touch-down
        // (see `InputSignposts`); the keystroke ends here, once the pipeline has
        // delivered its text.
        InputSignposts.begin(InputSignposts.dispatch, InputSignposts.dispatchID)
        defer {
            InputSignposts.end(InputSignposts.dispatch, InputSignposts.dispatchID)
            endKeystrokeInterval()
        }
        return performGesture(gesture, keyId: keyId, isReturn: isReturn)
    }

    /// Entry point for a completed swipe-or-tap classification: resolves a
    /// long swipe first, and otherwise hands the gesture to `handleGesture`.
    ///
    /// A long swipe (issue #79) is a flick that travelled past the user's
    /// threshold in key sizes; it fires the global action configured for its
    /// direction and the key's own binding is not consulted at all — that is
    /// the point, it works the same on every key. The decision is a pure
    /// function of the classification and the `gestureTuning` snapshot, so it
    /// adds no store read and no suspension to the touch path.
    @discardableResult
    func handleClassification(_ classification: GestureClassification, keyId: String) -> Bool {
        guard let action = gestureTuning.longSwipe.action(for: classification) else {
            return handleGesture(classification.gesture, keyId: keyId, isReturn: classification.isReturn)
        }
        InputSignposts.begin(InputSignposts.dispatch, InputSignposts.dispatchID)
        defer {
            InputSignposts.end(InputSignposts.dispatch, InputSignposts.dispatchID)
            endKeystrokeInterval()
        }
        // A mode switch (shift on or off, Ctrl, Alt) is not a pipeline action:
        // it goes through the mode machinery, like a tap on a mode key.
        if case let .switchMode(targetMode) = action {
            handleSwitchMode(targetMode)
        } else {
            dispatchAction(action)
        }
        // Felt at the lift (`feelReleased`, a long-swipe commit), not here:
        // the release may be held back behind an earlier finger.
        return true
    }

    private func performGesture(_ gesture: GestureType, keyId: String, isReturn: Bool) -> Bool {
        guard let compiled = activeCompiledMode else { return false }

        // Circular gestures: always "handled", even on a key with nothing to
        // type, as before (a circle never falls through to the tap on release).
        if gesture.isCircular {
            if let slot = compiled.slot(for: keyId) {
                handleCircular(compiled.circular(slot: slot, clockwise: gesture == .circularClockwise), in: compiled)
            }
            return true
        }

        guard let slot = compiled.slot(for: keyId),
              let binding = compiled.binding(slot: slot, gesture: gesture, isReturn: isReturn)
        else { return false }

        // Mode and language switches bypass the pipeline, so their
        // confirmation tick fires here instead of in the haptic middleware —
        // but only when the switch actually changed something (same-mode
        // taps and single-language globe swipes are silent no-ops).
        if case let .switchMode(targetMode) = binding.action {
            let previousMode = activeModeName
            handleSwitchMode(targetMode)
            if activeModeName != previousMode {
                feel(.modeSwitch)
            }
            return true
        }
        if case .switchToNextLanguage = binding.action {
            let previousLanguage = currentDefinition?.id
            switchToNextLanguage()
            if currentDefinition?.id != previousLanguage {
                feel(.languageSwitch)
            }
            return true
        }
        if case .switchToPreviousLanguage = binding.action {
            let previousLanguage = currentDefinition?.id
            switchToPreviousLanguage()
            if currentDefinition?.id != previousLanguage {
                feedbackStateChange()
            }
            return true
        }
        if case .toggleUtilityColumnSide = binding.action {
            utilityColumnLeading.toggle()
            feedbackStateChange()
            return true
        }

        let context = ActionContext(
            action: binding.action,
            binding: binding,
            mode: activeModeName
        )
        pipeline?.process(context)
        return true
    }

    /// Performs a circular gesture's compiled outcome: an explicit binding
    /// (e.g. superscripts in numeric mode), the uppercase centre character, or
    /// the opposite direction's binding. The order was decided at compile time
    /// (`CompiledMode.circular(slot:clockwise:)`).
    private func handleCircular(_ outcome: CircularOutcome, in compiled: CompiledMode) {
        switch outcome {
        case let .binding(index):
            dispatchBinding(compiled.binding(at: index))
        case let .commitUppercase(text):
            dispatchAction(.commitText(text))
        case .none:
            break
        }
    }

    /// Handles `.switchMode` actions.
    func handleSwitchMode(_ targetMode: String) {
        switchToMode(targetMode)
    }

    /// Switches to a named mode, updating published state.
    func switchToMode(_ modeName: String) {
        guard modeName != activeModeName,
              let definition = currentDefinition,
              definition.mode(modeName) != nil
        else { return }
        activeModeName = modeName
        // Any mode change invalidates a pending auto-shift; the auto-cap
        // engage path re-sets the flag right after switching.
        shiftEngagedByAutoCapitalization = false
    }

    /// Resets the active mode to the definition's default. Called by the
    /// controller on appearance so a keyboard hidden on the numeric or
    /// shifted mode reopens on letters. No-op (and publish-free) when the
    /// default mode is already active.
    func resetToDefaultMode() {
        guard let definition = currentDefinition else { return }
        switchToMode(definition.defaultMode)
    }

    // MARK: - Slide Gesture Handling

    /// Handles slide events from keys with `slideType != .none`.
    func handleSlide(_ key: KeyDefinition, phase: SlidePhase) {
        switch key.slideType {
        case .moveCursor:
            handleSpaceSlide(phase: phase, key: key)
        case .delete:
            handleDeleteSlide(phase: phase, key: key)
        case .none:
            break
        }
    }

    /// Cursor-movement type for the space-bar drag. Taken from the settings
    /// snapshot per gesture (stable for the duration of a drag); defaults to
    /// `.continuous`.
    var cursorMovementType: CursorMovementType {
        typingBehavior.cursorMovement
    }

    func handleSpaceSlide(phase: SlidePhase, key: KeyDefinition) {
        switch phase {
        case .began:
            isSpaceDragging = true
            spaceDragResidual = 0
            spaceDragPeak = 0
            // Snapshot the type once so a mid-drag settings change can't switch
            // this gesture between discrete and continuous classification.
            spaceDragCursorType = cursorMovementType
            feelSlideBegan(.moveCursor, key: key)
        case let .changed(deltaX):
            guard isSpaceDragging, deltaX != 0 else { return }
            spaceDragResidual += deltaX
            if spaceDragCursorType == .discrete {
                // Track the peak; movement is deferred to `.ended` so the whole
                // swipe counts as a single discrete step.
                if abs(spaceDragResidual) > abs(spaceDragPeak) {
                    spaceDragPeak = spaceDragResidual
                }
            } else {
                stepContinuousCursor()
            }
        case .ended:
            if spaceDragCursorType == .discrete {
                finishDiscreteSpaceSlide()
            }
            isSpaceDragging = false
            spaceDragResidual = 0
            spaceDragPeak = 0
            feelSlideEnded()
            endKeystrokeInterval()
        case .cancelled:
            // System cancelled the touches mid-drag: discard the drag state
            // without committing a discrete move or a tap.
            isSpaceDragging = false
            spaceDragResidual = 0
            spaceDragPeak = 0
            feelSlideEnded()
        case .tap:
            handleGesture(.tap, keyId: key.id, isReturn: false)
        case let .swipeUp(isReturn):
            // Only reported when the horizontal slide never activated, so
            // this cannot interfere with cursor movement in either style.
            toggleLabelVisibility(grouped: isReturn)
        }
    }

    /// MessagEase space-bar label toggles. A plain up-swipe flips the
    /// extra-symbol labels; a return-up swipe (`grouped`) toggles letter and
    /// standard-symbol labels together: only when both are hidden does it
    /// show them again, otherwise it hides both.
    private func toggleLabelVisibility(grouped: Bool) {
        if grouped {
            let hidden = sharedDefaults.bool(forKey: SettingsKey.areLetterLabelsHidden.rawValue)
                && sharedDefaults.bool(forKey: SettingsKey.areStandardSymbolLabelsHidden.rawValue)
            setLabelFlag(!hidden, forKey: .areLetterLabelsHidden)
            setLabelFlag(!hidden, forKey: .areStandardSymbolLabelsHidden)
        } else {
            let hidden = sharedDefaults.bool(forKey: SettingsKey.areExtraSymbolLabelsHidden.rawValue)
            setLabelFlag(!hidden, forKey: .areExtraSymbolLabelsHidden)
        }
        // Confirmation, not a second tap impact: the touch-down already
        // fired the tap haptic, and the toggle is a state change like a
        // mode switch.
        feel(.modeSwitch)
    }

    /// Writes only a value the store does not already hold. Every write fires
    /// `UserDefaults.didChangeNotification` (a full settings reload) and
    /// invalidates the `@AppStorage` bindings the grid renders from, so
    /// re-asserting a flag that already has the wanted value costs a keyboard
    /// round-trip for nothing — which the grouped toggle would otherwise do
    /// whenever the two flags start out of sync.
    private func setLabelFlag(_ hidden: Bool, forKey key: SettingsKey) {
        guard sharedDefaults.bool(forKey: key.rawValue) != hidden else { return }
        sharedDefaults.set(hidden, forKey: key.rawValue)
    }

    /// Continuous (joystick) mode: emit one character move per `dragStep` of
    /// accumulated travel.
    ///
    /// The surrounding context is read once per drag update and then walked
    /// locally. `adjustTextPosition` reaches the host application
    /// asynchronously, so when a single update owes more than one step, the
    /// context read back for the second step can still describe the caret
    /// *before* the first move — measuring the same cluster twice and skipping
    /// a character or landing inside an emoji. Device-only: the mock target
    /// updates its context in place.
    private func stepContinuousCursor() {
        let step = KeyboardConstants.SpaceGestures.dragStep
        // A legitimate 120 Hz update owes one or two steps; the cap keeps a
        // corrupt residual (non-finite or absurd) from trapping the `Int`
        // conversion or emitting an unbounded burst. Whatever is left over
        // stays in the residual and is emitted by the following update.
        let raw = (spaceDragResidual / step).rounded(.towardZero)
        guard raw.isFinite, raw != 0 else { return }
        let steps = Int(min(max(raw, -Self.maxCursorStepsPerUpdate), Self.maxCursorStepsPerUpdate))
        let direction = steps < 0 ? -1 : 1
        let context = direction > 0
            ? textInputTarget?.documentContextAfterInput
            : textInputTarget?.documentContextBeforeInput
        for width in Self.clusterWidths(in: context ?? "", count: abs(steps), fromEnd: direction < 0) {
            dispatchAction(.moveCursor(offset: direction * width))
            feelSlideStep(.moveCursor, direction: direction)
        }
        spaceDragResidual -= CGFloat(steps) * step
    }

    /// Upper bound on cursor steps emitted from one drag update.
    private static let maxCursorStepsPerUpdate: CGFloat = 32

    /// UTF-16 widths of the first `count` grapheme clusters of `context`,
    /// ordered away from the caret (`fromEnd` walks the text behind the caret
    /// backwards). Steps beyond the known context fall back to one code unit
    /// each — the same fallback `singleGraphemeOffset` uses when the host
    /// exposes no context at all.
    static func clusterWidths(in context: String, count: Int, fromEnd: Bool) -> [Int] {
        guard count > 0 else { return [] }
        let clusters = fromEnd
            ? Array(context.suffix(count).reversed())
            : Array(context.prefix(count))
        return (0 ..< count).map { $0 < clusters.count ? clusters[$0].utf16.count : 1 }
    }

    /// UTF-16 offset that moves the cursor across exactly one grapheme cluster
    /// in `direction` (+1 forward, -1 backward).
    ///
    /// `adjustTextPosition(byCharacterOffset:)` moves by UTF-16 code units, so
    /// multi-unit clusters (emoji, surrogate pairs, ZWJ sequences) need their
    /// full UTF-16 width; otherwise the caret lands inside the cluster. Falls
    /// back to 1 when no document context is available.
    private func singleGraphemeOffset(direction: Int) -> Int {
        let cluster: Character? = direction > 0
            ? textInputTarget?.documentContextAfterInput?.first
            : textInputTarget?.documentContextBeforeInput?.last
        return direction * (cluster?.utf16.count ?? 1)
    }

    /// Discrete (MessagEase) mode: classify the completed swipe.
    /// A regular swipe moves one character; a return swipe (finger returns
    /// toward the origin) moves one whole word in the swipe's direction.
    private func finishDiscreteSpaceSlide() {
        let peak = spaceDragPeak
        let finalX = spaceDragResidual
        // Ignore taps / tiny jitters that never travelled a full step.
        guard abs(peak) >= KeyboardConstants.SpaceGestures.dragStep else { return }

        let direction = peak < 0 ? -1 : 1
        let ratio = abs(finalX) / abs(peak)
        if ratio < KeyboardConstants.SpaceGestures.returnSwipeThreshold {
            moveCursorByWord(direction: direction)
        } else {
            dispatchAction(.moveCursor(offset: singleGraphemeOffset(direction: direction)))
        }
        feelSlideStep(.moveCursor, direction: direction)
    }

    /// Moves the cursor by one word in `direction` (+1 forward, -1 backward)
    /// by computing the UTF-16 offset to the nearest word boundary from the
    /// surrounding document context.
    private func moveCursorByWord(direction: Int) {
        let offset: Int = direction > 0
            ? Self.forwardWordOffset(in: textInputTarget?.documentContextAfterInput ?? "")
            : -Self.backwardWordOffset(in: textInputTarget?.documentContextBeforeInput ?? "")
        guard offset != 0 else { return }
        dispatchAction(.moveCursor(offset: offset))
    }

    /// UTF-16 code units from the cursor to the end of the next word: skip
    /// leading whitespace, then the word itself. Iterates graphemes but sums
    /// their UTF-16 widths, matching `adjustTextPosition`'s unit.
    static func forwardWordOffset(in text: String) -> Int {
        var count = 0
        var seenWord = false
        for char in text {
            if char.isWhitespace {
                if seenWord {
                    break
                }
            } else {
                seenWord = true
            }
            count += char.utf16.count
        }
        return count
    }

    /// UTF-16 code units from the cursor back to the start of the previous
    /// word: skip trailing whitespace, then the word itself. Iterates graphemes
    /// but sums their UTF-16 widths, matching `adjustTextPosition`'s unit.
    static func backwardWordOffset(in text: String) -> Int {
        var count = 0
        var seenWord = false
        for char in text.reversed() {
            if char.isWhitespace {
                if seenWord {
                    break
                }
            } else {
                seenWord = true
            }
            count += char.utf16.count
        }
        return count
    }

    func handleDeleteSlide(phase: SlidePhase, key: KeyDefinition) {
        switch phase {
        case .began:
            isDeleteDragging = true
            deleteDragResidual = 0
            feelSlideBegan(.delete, key: key)
        case let .changed(deltaX):
            guard isDeleteDragging, deltaX != 0 else { return }
            deleteDragResidual += deltaX
            let step = KeyboardConstants.DeleteGestures.dragStep
            while deleteDragResidual <= -step {
                dispatchAction(.deleteBackward)
                feelSlideStep(.delete, direction: -1)
                deleteDragResidual += step
            }
            while deleteDragResidual >= step {
                dispatchAction(.deleteForward)
                feelSlideStep(.delete, direction: 1)
                deleteDragResidual -= step
            }
        case .ended, .cancelled:
            isDeleteDragging = false
            deleteDragResidual = 0
            feelSlideEnded()
        case .tap:
            handleGesture(.tap, keyId: key.id, isReturn: false)
        case .swipeUp:
            // The delete key has no vertical gestures; label toggles are a
            // space-bar feature. `SlideGestureConfiguration.delete` never
            // classifies one, so this case only keeps the switch exhaustive.
            break
        }
    }

    /// Dispatches a raw action through the pipeline (no binding context).
    func dispatchAction(_ action: KeyAction) {
        let context = ActionContext(action: action, binding: nil, mode: activeModeName)
        pipeline?.process(context)
    }

    /// Dispatches a binding through the pipeline, preserving its category context.
    private func dispatchBinding(_ binding: KeyBinding) {
        let context = ActionContext(action: binding.action, binding: binding, mode: activeModeName)
        pipeline?.process(context)
    }
}
