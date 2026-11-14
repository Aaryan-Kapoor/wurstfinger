//
//  KeyboardViewModel.swift
//  Wurstfinger
//
//  Created by Claas Flint on 24.10.25.
//

import CoreGraphics
import Foundation
import Observation
import os
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum KeyboardHapticEvent: Sendable {
    case tap
    case drag
    /// Mode/language changes and system actions (globe, dismiss, clipboard)
    case stateChange

    /// Feedback for an action flowing through the pipeline, or `nil` for
    /// silence. Text actions are silent here: their haptic already fired on
    /// touch-down, and firing again on dispatch would double every keystroke.
    /// Only actions that change keyboard or system state get a distinct
    /// confirmation tick. Clipboard actions are silent here too: whether
    /// copy/cut/paste actually does anything is only known inside
    /// `AdvancedTextMiddleware` (full access, non-empty selection or
    /// pasteboard), so their tick fires from its success paths instead.
    static func forPipelineAction(_ action: KeyAction) -> KeyboardHapticEvent? {
        switch action {
        case .switchMode, .switchToNextLanguage, .switchToPreviousLanguage,
             .toggleUtilityColumnSide, .advanceToNextInputMode, .dismissKeyboard:
            .stateChange
        default:
            nil
        }
    }
}

/// Device-class layout constants. `@MainActor` because `UIScreen` and
/// `UIDevice` are (on iOS; the macOS shims mirror that): every reader is
/// layout or settings code that already runs on the main actor.
@MainActor
struct DeviceLayout {
    /// Returns screen bounds for layout calculations.
    /// UIScreen.main is deprecated in iOS 16+ but UIApplication.shared is unavailable in app extensions,
    /// so UIScreen.main remains the pragmatic choice for keyboard extensions.
    static var screenBounds: CGRect {
        UIScreen.main.bounds
    }

    /// Default keyboard width wish per device class, in points.
    ///
    /// Points are the density-independent unit, so the default deliberately
    /// never consults screen bounds: the previous screen-relative default
    /// was orientation-dependent and halved the keyboard on a fresh install
    /// opened in landscape (review finding H1).
    ///
    /// iPad: 380 pt. An iPad point is physically larger than an iPhone's
    /// (132 ppi on the 12.9" and 11" models against ~163 pt/in on a phone), and
    /// two thumbs rest on a much larger glass, so the 270 pt block would leave
    /// keys under 0.5 in wide; 380 gives ~85 pt cells (0.6-0.65 in) — the same
    /// proportion of the thumb that the iPhone default has — and with the numpad
    /// column on still fits the narrowest iPad portrait (744 pt) with room to
    /// spare. A floating iPad keyboard (~320 pt) or a Split View pane shrinks it
    /// to fit through the usual width fit-clamp.
    static var defaultKeyboardWidth: Double {
        UIDevice.current.userInterfaceIdiom == .pad ? 380.0 : 270.0
    }

    static let defaultKeyAspectRatio: Double = 1.0
    static let defaultKeyboardPosition: Double = 0.5
}

/// The keyboard's single source of truth: current definition, active mode,
/// geometry, and the pipeline that turns gestures into text.
///
/// **Isolation.** `@MainActor` and `@Observable`. Main-actor because the
/// pipeline it assembles drives the host's text proxy, which is main-thread
/// only, and because every touch handler that calls into it is. `@Observable`
/// (the Observation framework, iOS 17 / macOS 14) replaces `ObservableObject`:
/// SwiftUI tracks *which properties each view's body reads* and invalidates only
/// those views, where `objectWillChange` re-rendered the whole keyboard for any
/// change. Only state a view actually draws from is tracked; everything the
/// gesture runtime mutates per keystroke (drag residuals, the pipeline, the
/// settings snapshots) is `@ObservationIgnored`, which also keeps those hot
/// writes free of observation bookkeeping.
///
/// **Nothing on the input path awaits.** The touch-to-`insertText` route is a
/// chain of plain synchronous main-actor calls (`handleGesture` -> pipeline ->
/// target), reading only in-memory snapshots (`gestureTuning`,
/// `typingBehavior`) that are refreshed by `reloadSettings()` when a settings
/// signal arrives. Background work (definition prewarm, the cross-process
/// settings signal) happens in tasks that hop *to* the main actor, never the
/// other way round.
@MainActor
@Observable
final class KeyboardViewModel {
    // MARK: - State

    /// Current width of the keyboard's containing view.
    /// Updated by the controller in `viewWillLayoutSubviews()` so that
    /// SwiftUI re-evaluates layout after orientation changes.
    private(set) var viewWidth: CGFloat = UIScreen.main.bounds.width
    /// Width cap for the keyboard so it keeps its portrait width in
    /// landscape and follows narrow panes (Slide Over, Stage Manager).
    /// Derived from the hosting window's *width* — the keyboard's own window
    /// is only as tall as the keyboard itself, so its height carries no
    /// container information — bounded by the screen's shortest side, which
    /// keeps landscape at the portrait width. Falls back to the screen until
    /// a window is attached.
    private(set) var keyboardWidthCap: CGFloat = min(
        DeviceLayout.screenBounds.width, DeviceLayout.screenBounds.height
    )
    /// A screen size to lay out against instead of the device's, so a test can
    /// put the keyboard on a landscape iPad without touching the process-wide
    /// simulated screen the other suites read. Nil in the app.
    @ObservationIgnored var screenSizeOverride: CGSize?
    /// Height of the row above the keys (word completions), 0 for none. Set
    /// by whatever fills that row; the layout plan makes room for it.
    var accessoryRowHeight: CGFloat = 0
    // WORD COMPLETIONS hook (KeyboardViewModel+Completions.swift): the engine
    // behind the row above the keys. Lazy so a view model that never types
    // (previews, the bench's rigs before the first keystroke) builds none.
    @ObservationIgnored lazy var completions: WordCompletions = makeCompletions()
    /// How geometry changes move (`LayoutMotionClock`), shared by the root
    /// view and the controller so the keys and the frame move together.
    @ObservationIgnored let layoutMotionClock = LayoutMotionClock()
    /// Name of the currently active mode in the data-driven definition.
    var activeModeName: String = ModeNames.main {
        didSet { refreshActiveCompiledMode() }
    }

    /// The compiled tables of the active mode (`CompiledMode`), looked up once
    /// per mode change rather than once per keystroke and per preview update:
    /// it removes the mode-name hash from the resolve path, leaving the key
    /// id's. Nil until a definition is loaded.
    @ObservationIgnored private(set) var activeCompiledMode: CompiledMode?

    func refreshActiveCompiledMode() {
        activeCompiledMode = compiledDefinition?.mode(activeModeName)
    }

    // MARK: - Data-Driven Pipeline State (internal for extension access)

    /// The loaded definition. Observed: the grid renders from it, so a
    /// language switch must invalidate the views that read it.
    var currentDefinition: KeyboardDefinition?
    /// Signature of the inputs that produced `currentDefinition` (see
    /// `definitionSignature(languageId:numpadType:)`). Kept on the view model
    /// — not the controller — so in-keyboard language switches, which load a
    /// new definition directly, keep it in sync.
    @ObservationIgnored var loadedDefinitionSignature: String?
    /// The gesture policy of `currentDefinition`, compiled into lookup tables
    /// (see `CompiledMode`). Replaces the per-load resolver chains: a gesture
    /// resolves by indexing into it. Filled by `loadDefinition` from the
    /// registry's cache and by `rebuildResolverChain()` for a definition set
    /// directly; `nil` until a definition is loaded.
    @ObservationIgnored var compiledDefinition: CompiledDefinition? {
        didSet { refreshActiveCompiledMode() }
    }
    @ObservationIgnored var pipeline: ActionPipeline?
    /// Whether the current `shifted` mode was engaged by auto-capitalization
    /// (as opposed to a manual shift tap). Only auto-engaged shift may be
    /// released by `refreshAutoCapitalization()`; cleared on any mode change.
    @ObservationIgnored var shiftEngagedByAutoCapitalization = false
    @ObservationIgnored weak var textInputTarget: TextInputTarget?
    @ObservationIgnored var onAdvanceToNextInputMode: (() -> Void)?
    @ObservationIgnored var onDismissKeyboard: (() -> Void)?
    /// Locale used by the pipeline (set from the keyboard definition).
    /// Observed: the globe key's language label is derived from it.
    var pipelineLocale: Locale?
    /// Observed so the globe hint (`hasMultipleLanguages`) re-renders when the
    /// enabled-language set changes in Settings without the active language
    /// changing. `private(set)` keeps the normalisation invariants intact.
    private(set) var enabledLanguageIds: [String] = []

    // MARK: - Settings snapshots

    /// The user's gesture-recognition settings, resolved once. Read on every
    /// key release by the recognizers (threaded down through the grid), so it
    /// is a value in memory — never a `UserDefaults` lookup. Replaced only by
    /// `reloadSettings()`, and only when something actually changed, so an
    /// unrelated reload does not invalidate the keys that receive it. Observed
    /// because the root view passes it down to the keys.
    private(set) var gestureTuning: GestureTuning

    /// Typing-behaviour toggles (auto-capitalize, double-space period,
    /// cut-all, cursor-movement style) the pipeline consults on a keystroke,
    /// snapshotted for the same reason as `gestureTuning`. Not observed: no
    /// view draws from them.
    @ObservationIgnored private(set) var typingBehavior: TypingBehavior

    /// What the field being typed into says about itself (a sensitive field
    /// shows no trail, guide card or lifting glyph). Set by the controller
    /// whenever the field changes; observed because the root view reads it.
    var fieldTraits = FieldTraits.standard {
        didSet {
            guard fieldTraits != oldValue else { return }
            let tuning = GestureTuning.load(from: sharedDefaults).applying(fieldTraits)
            if gestureTuning != tuning { gestureTuning = tuning }
            completionsConfigurationDidChange() // WORD COMPLETIONS hook
        }
    }

    /// Who speaks gesture targets under VoiceOver (see `SpokenFeedback`).
    @ObservationIgnored var spokenFeedback = SpokenFeedback.voiceOver
    /// Who plays key clicks (see `KeyClickPlayer`).
    @ObservationIgnored var keyClicks = KeyClickPlayer.system

    /// How many times `reloadSettings()` has run. Lets tests and the bench
    /// observe that a signal produced exactly one reload (the debounce).
    @ObservationIgnored private(set) var settingsReloadCount = 0

    // MARK: - Settings (delegated to extracted classes)

    let hapticSettings: HapticSettings
    let layoutSettings: LayoutSettings
    @ObservationIgnored let hapticPlayer: HapticFeedbackPlayer
    /// The feel layer: haptic cues and transient visuals for every touch
    /// moment (`KeyboardViewModel+Feel.swift`). Owns no input state.
    @ObservationIgnored let feel: KeyboardFeel

    // MARK: - Computed Properties for Backward Compatibility

    var hapticIntensityTap: CGFloat {
        get { hapticSettings.tapIntensity }
        set { hapticSettings.tapIntensity = newValue }
    }

    var hapticIntensityDrag: CGFloat {
        get { hapticSettings.dragIntensity }
        set { hapticSettings.dragIntensity = newValue }
    }

    var utilityColumnLeading: Bool {
        get { layoutSettings.utilityColumnLeading }
        set { layoutSettings.utilityColumnLeading = newValue }
    }

    var keyAspectRatio: Double {
        get { layoutSettings.keyAspectRatio }
        set { layoutSettings.keyAspectRatio = newValue }
    }

    var keyboardWidth: Double {
        get { layoutSettings.keyboardWidth }
        set { layoutSettings.keyboardWidth = newValue }
    }

    var keyboardHorizontalPosition: Double {
        get { layoutSettings.keyboardHorizontalPosition }
        set { layoutSettings.keyboardHorizontalPosition = newValue }
    }

    var keySpacing: Double {
        get { layoutSettings.keySpacing }
        set { layoutSettings.keySpacing = newValue }
    }

    var numpadColumn: NumpadColumnPlacement {
        get { layoutSettings.numpadColumn }
        set { layoutSettings.numpadColumn = newValue }
    }

    var isSplitLayoutEnabled: Bool {
        get { layoutSettings.isSplitLayoutEnabled }
        set { layoutSettings.isSplitLayoutEnabled = newValue }
    }

    // MARK: - Private State

    @ObservationIgnored let sharedDefaults: UserDefaults
    @ObservationIgnored let shouldPersistSettings: Bool
    /// Where copy, cut and paste go (see `Clipboard`).
    @ObservationIgnored let clipboard: any Clipboard

    /// The input engine every touch on this keyboard runs through. Owned here
    /// rather than by a view, so it outlives view re-creation and the
    /// controller can cancel touches in flight when the keyboard goes away.
    @ObservationIgnored let touchEngine: TouchEngine

    /// The clock and timer every deadline of this keyboard runs on (the
    /// engine's long press and rollover hold, the trail's fade, the settings
    /// debounce). System time in the keyboard; tests inject a
    /// `ManualTimerSource` and drive it by hand.
    @ObservationIgnored let timers: any TimerSource

    /// The engine's callbacks into this view model, built once: the closures
    /// hold the view model weakly and never change, so handing them to the
    /// engine on every layout update allocates nothing.
    @ObservationIgnored lazy var touchEngineActions: TouchEngineActions = makeTouchEngineActions()
    @ObservationIgnored var isSpaceDragging = false
    @ObservationIgnored var spaceDragResidual: CGFloat = 0
    /// Peak signed displacement during the current space drag. Used by the
    /// discrete cursor-movement mode to classify regular vs. return swipes.
    @ObservationIgnored var spaceDragPeak: CGFloat = 0
    /// Cursor-movement type captured at the start of the current space drag, so
    /// a mid-drag settings change cannot switch classification mode mid-gesture.
    @ObservationIgnored var spaceDragCursorType: CursorMovementType = .continuous
    @ObservationIgnored var isDeleteDragging = false
    @ObservationIgnored var deleteDragResidual: CGFloat = 0

    /// Removes the in-process defaults observer when the view model goes away.
    @ObservationIgnored private var userDefaultsObserver: ObserverToken?
    /// The in-flight touch-down -> text interval, see `InputSignposts`.
    @ObservationIgnored var isKeystrokeIntervalOpen = false
    /// The debounced cross-process settings observation, if started.
    @ObservationIgnored var externalSettingsObservation: TaskHandle?
    /// The most recent background definition prewarm, if one was started.
    @ObservationIgnored var prewarmTask: Task<Void, Never>?
    /// Whether a prewarm is running right now (cleared on the main actor when
    /// it finishes), so overlapping requests do not stack up builds.
    @ObservationIgnored var isPrewarming = false
    /// Whether `loadDefinition` kicks off the language prewarm (the keyboard
    /// extension asks for it; previews, tests and screenshots do not).
    @ObservationIgnored let prewarmsLanguages: Bool

    /// - Parameters:
    ///   - prewarmsLanguages: Build every enabled language's definition on a
    ///     background task when a definition loads, so the globe key hits a
    ///     warm cache. Only the real keyboard wants that; previews and tests
    ///     construct view models by the dozen and must not spawn builds.
    ///   - clipboard: Where clipboard actions read and write; defaults to
    ///     `ClipboardStore.shared`.
    init(
        userDefaults: UserDefaults? = nil,
        shouldPersistSettings: Bool = true,
        prewarmsLanguages: Bool = false,
        clipboard: (any Clipboard)? = nil,
        timers: (any TimerSource)? = nil
    ) {
        self.clipboard = clipboard ?? ClipboardStore.shared
        let timers = timers ?? SystemTimerSource()
        self.timers = timers
        touchEngine = TouchEngine(trail: GestureTrailRecorder(timers: timers), timers: timers)
        // Initialize UserDefaults once
        let defaults = userDefaults ?? SharedDefaults.store
        sharedDefaults = defaults
        self.shouldPersistSettings = shouldPersistSettings
        self.prewarmsLanguages = prewarmsLanguages

        // The old "Numbers on long press" switch becomes the Long Press
        // picker's value the first time either the app or the keyboard runs
        // (whichever is first; the second finds it done). Only a persisting
        // view model — the real keyboard — writes to the store.
        if shouldPersistSettings {
            LongPressType.migrateLegacyIfNeeded(in: defaults)
        }

        // Initialize extracted settings classes
        hapticSettings = HapticSettings(defaults: defaults, shouldPersist: shouldPersistSettings)
        layoutSettings = LayoutSettings(defaults: defaults, shouldPersist: shouldPersistSettings)
        hapticPlayer = HapticFeedbackPlayer(settings: hapticSettings)
        feel = KeyboardFeel(haptics: hapticPlayer)

        enabledLanguageIds = LanguageSettings.normalizedEnabledLanguageIds(from: defaults)
        gestureTuning = GestureTuning.load(from: defaults)
        typingBehavior = TypingBehavior.load(from: defaults)

        // Observe in-process UserDefaults changes (e.g. utility column toggle).
        // Note: didChangeNotification only fires within the same process.
        // Cross-process updates from the host app arrive as a Darwin
        // notification (`observeExternalSettingsChanges`) and, as a backstop,
        // via KeyboardViewController.viewWillAppear → reloadSettings().
        // Non-persisting view models (previews, showcases, screenshots) are
        // configured programmatically; reloading everything from the store
        // would revert forced values (e.g. the full-size screenshot scale) on
        // the next runloop pass — but haptic settings are never forced, and
        // the settings screen's preview keyboard should play slider changes
        // live, so non-persisting view models follow the store for haptics only.
        //
        // Delivered on the main queue, so the closure may assume main-actor
        // isolation; it holds the view model weakly and the token removes
        // the observer on deallocation (a non-isolated `deinit` could not
        // touch these main-actor properties).
        userDefaultsObserver = ObserverToken(observer: NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: sharedDefaults,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.shouldPersistSettings {
                    self.reloadSettings()
                } else {
                    self.hapticSettings.reload()
                }
            }
        })
    }

    /// Updates the tracked view width. Called by the controller in
    /// `viewWillLayoutSubviews()` so SwiftUI re-renders after orientation changes.
    func updateViewWidth(_ width: CGFloat) {
        guard width != viewWidth else { return }
        viewWidth = width
    }

    /// Updates the tracked window bounds. Called by the controller in
    /// `viewWillLayoutSubviews()` with the hosting window's bounds; a nil
    /// window (not yet attached) falls back to the device screen.
    ///
    /// Only the window's *width* is meaningful: the keyboard extension's
    /// window is merely keyboard-sized, so `min(width, height)` would return
    /// the keyboard height (~300 pt) and squeeze the keys horizontally while
    /// the height constraint stays — visibly breaking the key aspect ratio.
    func updateWindowBounds(_ bounds: CGRect?) {
        let screenShortestSide = min(
            DeviceLayout.screenBounds.width, DeviceLayout.screenBounds.height
        )
        let cap = bounds.map { min($0.width, screenShortestSide) } ?? screenShortestSide
        guard cap > 0, cap != keyboardWidthCap else { return }
        keyboardWidthCap = cap
    }

    // MARK: - Arrangement Selection

    /// Determines the active arrangement context from the user's utility-column
    /// preference.
    ///
    /// The keyboard intentionally keeps the portrait arrangement in **all**
    /// orientations so the key positions stay constant when the device rotates
    /// (muscle memory). The data model still defines dedicated `.landscape`
    /// arrangements, but the runtime does not select them.
    var currentContext: ArrangementContext {
        layoutSettings.utilityColumnLeading ? .portraitUtilityLeft : .portrait
    }

    /// The arrangement the active mode is drawn with at the tracked view width
    /// (see `layoutPlan(forContainerWidth:)`). Returns `nil` if no definition is
    /// loaded.
    var currentArrangement: GridArrangement? {
        layoutPlan(forContainerWidth: viewWidth)?.arrangement
    }

    /// The active mode resolved from the current definition and mode name.
    /// The one place the mode is resolved: the grid renders from it and
    /// `currentArrangement` sizes the keyboard from it, so a height computed
    /// for a different mode than the one on screen cannot happen.
    var activeModeFromDefinition: KeyboardMode? {
        currentDefinition?.mode(activeModeName)
    }

    // MARK: - Layout Metrics

    /// Resolved layout metrics for the tracked view width — the single
    /// geometry source for the grid, key fonts, gesture classification, and
    /// the controller's height constraint. Recomputed whenever settings
    /// reload or `viewWidth`/`keyboardWidthCap` change (all observed).
    var layoutMetrics: KeyboardLayoutMetrics {
        layoutMetrics(forContainerWidth: viewWidth)
    }

    /// Metrics resolved against an explicit container width, for preview and
    /// screenshot surfaces that render at a width other than the tracked
    /// view width. The height guard reads the *screen* bounds — the
    /// extension's own window is only keyboard-sized and carries no usable
    /// height information (see `updateWindowBounds`).
    func layoutMetrics(forContainerWidth width: CGFloat) -> KeyboardLayoutMetrics {
        layoutPlan(forContainerWidth: width)?.metrics ?? layoutSettings.resolveMetrics(
            columns: 4,
            availableWidth: width > 0 ? min(width, keyboardWidthCap) : keyboardWidthCap,
            screenHeight: (screenSizeOverride ?? DeviceLayout.screenBounds.size).height
        )
    }

    /// The arrangement the active mode is drawn with, and the metrics resolved
    /// for it, at `width`: the mode's arrangement for the utility-column side,
    /// with the numpad column and the split applied as the settings ask
    /// (`KeyboardLayoutPlan`). `nil` if no definition is loaded.
    ///
    /// The keyboard intentionally keeps the portrait arrangement in **all**
    /// orientations so the key positions stay constant when the device rotates
    /// (muscle memory); the split is the one orientation-dependent decision, and
    /// it is the user's opt-in.
    func layoutPlan(forContainerWidth width: CGFloat) -> KeyboardLayoutPlan? {
        guard let mode = activeModeFromDefinition,
              let base = mode.arrangement(for: currentContext)
        else { return nil }
        let screen = screenSizeOverride ?? DeviceLayout.screenBounds.size
        return KeyboardLayoutPlan.resolve(KeyboardLayoutPlan.Inputs(
            base: base,
            hasNumpadKeys: mode.keys[NumpadColumn.keyIds[0]] != nil,
            numpadColumn: layoutSettings.numpadColumn,
            isUtilityLeading: layoutSettings.utilityColumnLeading,
            isSplitEnabled: layoutSettings.isSplitLayoutEnabled,
            wishWidth: CGFloat(layoutSettings.keyboardWidth),
            aspectRatio: CGFloat(layoutSettings.keyAspectRatio),
            spacing: CGFloat(layoutSettings.keySpacing),
            containerWidth: width,
            widthCap: keyboardWidthCap,
            screen: screen,
            accessoryHeight: accessoryRowHeight
        ))
    }

    /// Pipeline hook: fires a confirmation for state-changing actions.
    /// Text actions stay silent here — they are felt at touch-down and on
    /// release (`KeyboardViewModel+Feel.swift`).
    func triggerHaptic(for action: KeyAction) {
        guard let cue = HapticCue.forPipelineAction(action) else { return }
        hapticPlayer.play(cue)
    }

    func reloadSettings() {
        settingsReloadCount += 1
        // Delegate to extracted settings classes - eliminates duplicate code
        hapticSettings.reload()
        layoutSettings.reload()

        // Custom layouts first: the enabled-language list below is filtered to
        // layouts the registry knows, so a layout the host app just added must
        // already be registered. A no-op unless the host app bumped the revision.
        let staleLayouts = KeyboardRegistry.syncCustomLayouts(defaults: sharedDefaults)

        // Equality-guarded: this runs on every in-process defaults write (via
        // the didChangeNotification observer), and an unguarded assignment to
        // an observed property would re-render what reads it each time.
        let newEnabledLanguageIds = LanguageSettings.normalizedEnabledLanguageIds(from: sharedDefaults)
        if enabledLanguageIds != newEnabledLanguageIds {
            enabledLanguageIds = newEnabledLanguageIds
        }

        // The one place the per-keystroke settings are read from the store.
        // Compared before assigning so a reload that changed nothing leaves the
        // snapshot (and the views holding it) untouched.
        let newTuning = GestureTuning.load(from: sharedDefaults).applying(fieldTraits)
        if gestureTuning != newTuning {
            gestureTuning = newTuning
        }
        typingBehavior = TypingBehavior.load(from: sharedDefaults, reusing: typingBehavior)
        completionsConfigurationDidChange() // WORD COMPLETIONS hook

        // The layout on screen was edited, or deleted, in the host app: load
        // what the registry holds now (an English fallback if it is gone).
        if let active = currentDefinition?.id, staleLayouts.contains(active) {
            loadDefinition(for: active)
        }
        // The numpad column was switched on or off in the host app: its keys
        // belong to the definition, so the definition follows.
        reloadDefinitionIfNumpadColumnChanged()
    }

    func switchToNextLanguage() {
        switchLanguage { LanguageSettings.nextLanguageId(after: $0, in: $1) }
    }

    func switchToPreviousLanguage() {
        switchLanguage { LanguageSettings.previousLanguageId(before: $0, in: $1) }
    }

    /// Moves along the enabled-language ring, `target` choosing the neighbour.
    private func switchLanguage(to target: (_ currentId: String, _ enabledIds: [String]) -> String) {
        guard enabledLanguageIds.count > 1 else { return }

        // Cycle from the layout that is actually on screen. Startup can load a
        // pinned language whose id differs from the stored selection, so the
        // active definition — not shared defaults — is the source of truth;
        // otherwise the first swipe would just reload the current layout.
        let currentId = currentDefinition?.id
            ?? sharedDefaults.string(forKey: SettingsKey.selectedLanguageId.rawValue)
            ?? "en_US"
        // Static lookup on the already-normalized enabled list: constructing
        // a throwaway LanguageSettings here would re-run init normalization
        // (an app-group read/write cycle) on every globe swipe.
        let nextId = target(currentId, enabledLanguageIds)

        if nextId != currentId {
            sharedDefaults.set(nextId, forKey: SettingsKey.selectedLanguageId.rawValue)
            loadDefinition(for: nextId)
        }
    }

    var hasMultipleLanguages: Bool {
        enabledLanguageIds.count > 1
    }

    var currentLanguageLabel: String {
        guard let locale = pipelineLocale else { return "" }
        // A layout may carry its own mark (the second English layout), so two
        // layouts of one language are told apart on the globe key.
        if let id = currentDefinition?.id,
           let mark = KeyboardRegistry.available.first(where: { $0.id == id })?.globeLabel {
            return mark
        }
        return LanguageSettings.label(for: locale)
    }

    // MARK: - Haptic Feedback (delegated to HapticFeedbackPlayer)

    /// Haptic feedback for key touch-down — called by button views on first contact
    func feedbackTap() {
        hapticPlayer.tap()
    }

    /// A finger touched a key: opens the `keystroke` signpost interval (closed
    /// when the pipeline has delivered the result, or the touch is abandoned)
    /// and fires the touch-down haptic — plus, as the user set them, the key
    /// click and, under VoiceOver gesture typing, the key's own character.
    /// The interval costs nothing unless Instruments is recording.
    func touchDown(_ key: KeyDefinition? = nil) {
        beginKeystrokeInterval()
        feedbackTap()
        guard let key else { return }
        if typingBehavior.areKeyClicksEnabled { keyClicks.play(KeyClick(for: key)) }
        if typingBehavior.isVoiceOverGestureTypingEnabled {
            speakTarget(.tap, on: key, label: previewLabel(for: .tap, keyId: key.id, isReturn: false))
        }
    }

    /// Says what releasing now would do — the binding's name where it has one
    /// ("Delete word"), otherwise the `label` it would type, spelled out —
    /// when gesture typing under VoiceOver is on and VoiceOver is listening.
    /// One flag check otherwise.
    ///
    /// The name is used only for the gesture's own binding: a return swipe
    /// or a long swipe does something else than the binding's name says.
    func speakTarget(_ gesture: GestureType, isPlain: Bool = true, on key: KeyDefinition, label: String?) {
        guard typingBehavior.isVoiceOverGestureTypingEnabled, spokenFeedback.isActive() else { return }
        if isPlain, let name = key.bindings[gesture]?.accessibilityLabel, !name.isEmpty {
            spokenFeedback.announce(.name(name))
        } else if let label, !label.trimmingCharacters(in: .whitespaces).isEmpty {
            spokenFeedback.announce(.glyph(label))
        }
    }

    /// Warms the Taptic Engine ahead of the first touch (called when the
    /// keyboard appears); the player re-warms on each touch-down after a pause.
    func prepareHaptics() {
        hapticPlayer.prepareIfNeeded()
    }

    /// Releases the Taptic Engine while the keyboard is off screen.
    func suspendHaptics() {
        hapticPlayer.suspend()
    }

    /// Whether the keyboard has Full Access, which haptics require in an
    /// extension (set by the controller).
    func setHapticAccess(_ isGranted: Bool) {
        hapticPlayer.isAccessGranted = isGranted
    }

    func feedbackDrag() {
        hapticPlayer.drag()
    }

    /// Confirmation tick for explicit mode/language switches.
    func feedbackStateChange() {
        hapticPlayer.stateChange()
    }
}
