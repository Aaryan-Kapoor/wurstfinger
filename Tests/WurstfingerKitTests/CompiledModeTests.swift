//
//  CompiledModeTests.swift
//  WurstfingerTests
//
//  The compiled gesture tables must answer exactly what the resolver chains
//  they were compiled from answered. The oracles below are private copies of
//  the code the tables replaced: the chain construction from
//  `rebuildResolverChain`, and the branch order of `handleCircular` and
//  `previewLabel`.
//

import Foundation
import Testing
@testable import WurstfingerKit

// MARK: - Oracles (the pre-compilation behaviour, kept verbatim)

/// The two chains `rebuildResolverChain` used to build.
private func oracleChains(for definition: KeyboardDefinition) -> (standard: GestureResolverChain, returnSwipe: GestureResolverChain) {
    var baseResolvers: [GestureResolver] = [PrimaryResolver()]
    if let numericMode = definition.mode(ModeNames.numeric) {
        baseResolvers.append(GhostKeyResolver(fallbackMode: numericMode))
    }
    return (
        GestureResolverChain(resolvers: baseResolvers),
        GestureResolverChain(resolvers: [ReturnSwipeResolver()] + baseResolvers)
    )
}

/// What `handleCircular` would have dispatched, as a comparable value: the
/// binding (explicit or opposite direction) or the uppercased text.
private enum OracleCircular: Equatable {
    case binding(KeyBinding)
    case uppercase(String)
    case none
}

private func oracleCircular(key: KeyDefinition, gesture: GestureType, locale: Locale) -> OracleCircular {
    let opposite: GestureType = gesture == .circularClockwise
        ? .circularCounterclockwise : .circularClockwise
    if let binding = key.bindings[gesture] { return .binding(binding) }
    if let tap = key.bindings[.tap], case let .commitText(text) = tap.action, text.first?.isLetter == true {
        return .uppercase(text.keyboardUppercased(with: locale))
    }
    if let binding = key.bindings[opposite] { return .binding(binding) }
    return .none
}

/// The old `previewLabel(for:keyId:isReturn:)`, against a view model's state.
@MainActor
private func oraclePreview(
    _ vm: KeyboardViewModel, gesture: GestureType, keyId: String, isReturn: Bool,
    chains: (standard: GestureResolverChain, returnSwipe: GestureResolverChain)
) -> String? {
    guard let mode = vm.activeModeFromDefinition else { return nil }
    if gesture == .circularClockwise || gesture == .circularCounterclockwise {
        guard let key = mode.key(for: keyId) else { return nil }
        switch oracleCircular(key: key, gesture: gesture, locale: vm.pipelineLocale ?? Locale.current) {
        case let .binding(binding): return binding.label
        case let .uppercase(text): return text
        case .none: return nil
        }
    }
    let chain = isReturn ? chains.returnSwipe : chains.standard
    guard let binding = chain.resolve(keyId: keyId, gesture: gesture, in: mode) else { return nil }
    if case let .commitText(text) = binding.action, !text.isEmpty { return text }
    return binding.label
}

/// Every definition the equivalence tests cover: each language with the phone
/// numpad, and with the classic numpad swapped in as `applyNumpadType` does.
private func allDefinitions() -> [(name: String, definition: KeyboardDefinition)] {
    LanguageDefinitions.all.flatMap { descriptor -> [(String, KeyboardDefinition)] in
        let phone = descriptor.makeDefinition()
        let classic = phone.replacingMode(
            ModeNames.numeric,
            with: NumericLayouts.classic(
                digits: phone.numericDigits, backToAlphaLabel: phone.numericBackToAlphaLabel
            )
        )
        return [("\(descriptor.id)/phone", phone), ("\(descriptor.id)/classic", classic)]
    }
}

// MARK: - Table equivalence

struct CompiledModeEquivalenceTests {
    @Test func gestureIndexIsThePositionInAllCases() {
        for (position, gesture) in GestureType.allCases.enumerated() {
            #expect(gesture.index == position, "\(gesture)")
        }
        #expect(GestureType.count == GestureType.allCases.count)
    }

    @Test func everyBindingMatchesTheOldChainForEveryLanguage() {
        for (name, definition) in allDefinitions() {
            let compiled = CompiledDefinition(definition)
            let chains = oracleChains(for: definition)
            #expect(Set(compiled.modes.keys) == Set(definition.modes.keys), "\(name)")
            for (modeName, mode) in definition.modes {
                guard let compiledMode = compiled.mode(modeName) else { continue }
                #expect(compiledMode.keys.count == mode.keys.count, "\(name)/\(modeName)")
                for keyId in mode.keys.keys {
                    guard let slot = compiledMode.slot(for: keyId) else {
                        Issue.record("\(name)/\(modeName): no slot for \(keyId)")
                        continue
                    }
                    #expect(compiledMode.key(at: slot) == mode.keys[keyId], "\(name)/\(modeName)/\(keyId)")
                    for gesture in GestureType.allCases where !gesture.isCircular {
                        for isReturn in [false, true] {
                            let chain = isReturn ? chains.returnSwipe : chains.standard
                            let expected = chain.resolve(keyId: keyId, gesture: gesture, in: mode)
                            let actual = compiledMode.binding(slot: slot, gesture: gesture, isReturn: isReturn)
                            if actual != expected {
                                Issue.record("\(name)/\(modeName)/\(keyId) \(gesture) return=\(isReturn): \(String(describing: actual)) != \(String(describing: expected))")
                            }
                        }
                    }
                }
            }
        }
    }

    @Test func everyCircularOutcomeMatchesTheOldHandleCircularForEveryLanguage() {
        for (name, definition) in allDefinitions() {
            let compiled = CompiledDefinition(definition)
            for (modeName, mode) in definition.modes {
                guard let compiledMode = compiled.mode(modeName) else { continue }
                for (keyId, key) in mode.keys {
                    guard let slot = compiledMode.slot(for: keyId) else { continue }
                    for gesture in [GestureType.circularClockwise, .circularCounterclockwise] {
                        let expected = oracleCircular(key: key, gesture: gesture, locale: definition.locale)
                        let outcome = compiledMode.circular(slot: slot, clockwise: gesture == .circularClockwise)
                        let actual: OracleCircular = switch outcome {
                        case let .binding(index): .binding(compiledMode.binding(at: index))
                        case let .commitUppercase(text): .uppercase(text)
                        case .none: .none
                        }
                        if actual != expected {
                            Issue.record("\(name)/\(modeName)/\(keyId) \(gesture): \(actual) != \(expected)")
                        }
                    }
                }
            }
        }
    }

    @Test func aKeyThatIsNotInTheModeHasNoSlot() throws {
        let definition = LanguageDefinitions.german.makeDefinition()
        let main = try #require(CompiledDefinition(definition).mode(ModeNames.main))
        #expect(main.slot(for: "no-such-key") == nil)
        #expect(CompiledDefinition(definition).mode("no-such-mode") == nil)
    }

    @Test func slotsFollowSortedKeyIdsAndTheKeyAtASlotCarriesItsId() throws {
        let definition = LanguageDefinitions.german.makeDefinition()
        let main = try #require(CompiledDefinition(definition).mode(ModeNames.main))
        #expect(main.keys.map(\.id) == main.keys.map(\.id).sorted())
        for (slot, key) in main.keys.enumerated() {
            #expect(main.slot(for: key.id) == slot)
        }
    }

    @Test func theBindingPoolHoldsNoDuplicatesAndTheTableIsFullySized() throws {
        let definition = LanguageDefinitions.german.makeDefinition()
        for (_, mode) in CompiledDefinition(definition).modes {
            for (i, a) in mode.bindings.enumerated() {
                for b in mode.bindings[(i + 1)...] {
                    #expect(a != b)
                }
            }
            #expect(mode.table.count == mode.keys.count * 2 * GestureType.count)
            #expect(mode.circularTable.count == mode.keys.count * 2)
        }
    }

    @Test func aCaselessEszettKeyCirclesToASingleCapitalEszett() throws {
        let key = KeyDefinition(
            id: "k",
            bindings: [.tap: KeyBinding(
                label: "ß", action: .commitText("ß"), category: nil, returnAction: nil, accessibilityLabel: nil
            )],
            swipeMode: .eightWay, slideType: .none, style: .primary, tapCycleActions: nil
        )
        let mode = KeyboardMode(
            name: ModeNames.main, keys: [key.id: key], arrangements: [:], autoTransitions: [:]
        )
        let compiled = CompiledMode(mode: mode, fallbackMode: nil, locale: Locale(identifier: "de_DE"))
        let slot = try #require(compiled.slot(for: "k"))
        #expect(compiled.circular(slot: slot, clockwise: true) == .commitUppercase("ẞ"))
        #expect(compiled.circular(slot: slot, clockwise: false) == .commitUppercase("ẞ"))
    }
}

// MARK: - View model

@MainActor
@Suite(.serialized)
struct CompiledModeViewModelTests {
    private func typed(_ target: MockTextTarget) -> [String] {
        target.events.compactMap {
            if case let .insertText(text) = $0 { text } else { nil }
        }
    }

    @Test func tapOnCenterTypesTheCentreLetter() throws {
        let (vm, target) = makeViewModel(languageId: "de_DE")
        let key = try #require(vm.activeModeFromDefinition?.key(for: GridSlot.center))
        guard case let .commitText(letter) = key.bindings[.tap]?.action else {
            Issue.record("centre key has no tap letter")
            return
        }

        #expect(vm.handleGesture(.tap, keyId: GridSlot.center, isReturn: false))

        #expect(target.events == [.insertText(letter)])
    }

    @Test func swipeAndReturnSwipeCommitTheirOwnText() throws {
        let (vm, target) = makeViewModel(languageId: "de_DE")
        let key = try #require(vm.activeModeFromDefinition?.key(for: GridSlot.topLeft))
        guard case let .commitText(swipeText) = key.bindings[.swipeRight]?.action,
              case let .commitText(returnText) = key.bindings[.swipeRight]?.returnAction
        else {
            Issue.record("topLeft → carries no text and return text")
            return
        }

        vm.handleGesture(.swipeRight, keyId: GridSlot.topLeft, isReturn: false)
        vm.handleGesture(.swipeRight, keyId: GridSlot.topLeft, isReturn: true)

        #expect(typed(target) == [swipeText, returnText])
    }

    @Test func circleOnALetterKeyTypesItsUppercaseAndTheOtherDirectionAgrees() throws {
        let (vm, target) = makeViewModel(languageId: "de_DE")
        let key = try #require(vm.activeModeFromDefinition?.key(for: GridSlot.center))
        guard case let .commitText(letter) = key.bindings[.tap]?.action else {
            Issue.record("centre key has no tap letter")
            return
        }
        let upper = letter.keyboardUppercased(with: Locale(identifier: "de_DE"))

        #expect(vm.handleGesture(.circularClockwise, keyId: GridSlot.center, isReturn: false))
        #expect(vm.handleGesture(.circularCounterclockwise, keyId: GridSlot.center, isReturn: false))

        #expect(typed(target) == [upper, upper])
    }

    @Test func circleOnAnUnknownKeyIsHandledAndTypesNothing() {
        let (vm, target) = makeViewModel(languageId: "de_DE")
        #expect(vm.handleGesture(.circularClockwise, keyId: "no-such-key", isReturn: false))
        #expect(target.events.isEmpty)
    }

    @Test func unresolvedGesturesReturnFalseAndTypeNothing() {
        let (vm, target) = makeViewModel(languageId: "de_DE")
        // The globe has no swipe mode of the swipeUp kind, and an unknown key
        // and a mode without a loaded definition resolve to nothing at all.
        #expect(!vm.handleGesture(.swipeUp, keyId: UtilitySlot.globe, isReturn: false))
        #expect(!vm.handleGesture(.tap, keyId: "no-such-key", isReturn: false))
        #expect(target.events.isEmpty)

        let bare = KeyboardViewModel(userDefaults: InMemoryUserDefaults(), shouldPersistSettings: false)
        #expect(!bare.handleGesture(.tap, keyId: GridSlot.center, isReturn: false))
        #expect(!bare.handleGesture(.circularClockwise, keyId: GridSlot.center, isReturn: false))
    }

    @Test func longPressOnALetterKeyTypesItsGhostDigit() {
        let (vm, target) = makeViewModel(languageId: "de_DE")
        #expect(vm.handleGesture(.longPress, keyId: GridSlot.topLeft, isReturn: false))
        #expect(target.events == [.insertText("1")])
    }

    @Test func theClassicNumpadGhostDigitIsCompiledSeparately() {
        let defaults = InMemoryUserDefaults()
        defaults.set(NumpadType.classic.rawValue, forKey: SettingsKey.numpadStyle.rawValue)
        let vm = KeyboardViewModel(userDefaults: defaults, shouldPersistSettings: false)
        let target = MockTextTarget()
        vm.bindTextInputTarget(target)
        vm.loadDefinition(for: "de_DE")

        vm.handleGesture(.longPress, keyId: GridSlot.topLeft, isReturn: false)

        #expect(target.events == [.insertText("7")])
        #expect(KeyboardRegistry.isCompiledCached(
            signature: KeyboardRegistry.compiledSignature(languageId: "de_DE", numpadType: "classic")
        ))
    }

    @Test func modeSwitchesStillBypassThePipeline() {
        let (vm, target) = makeViewModel(languageId: "de_DE")
        vm.handleGesture(.tap, keyId: UtilitySlot.symbols, isReturn: false)
        #expect(vm.activeModeName == ModeNames.numeric)
        #expect(target.events.isEmpty)
    }

    @Test func circleInNumericModeDispatchesTheExplicitBinding() throws {
        let (vm, target) = makeViewModel(languageId: "de_DE")
        vm.handleGesture(.tap, keyId: UtilitySlot.symbols, isReturn: false)
        let numeric = try #require(vm.activeModeFromDefinition)
        let (slot, key) = try #require(GridSlot.allSlots.flatMap(\.self).compactMap { id in
            numeric.key(for: id).flatMap { $0.bindings[.circularClockwise] != nil ? (id, $0) : nil }
        }.first)
        guard case let .commitText(expected) = key.bindings[.circularClockwise]?.action else {
            Issue.record("\(slot) circular binding is not text")
            return
        }

        vm.handleGesture(.circularClockwise, keyId: slot, isReturn: false)

        #expect(typed(target) == [expected])
    }

    /// Every (key, gesture, isReturn) of the main, shifted and numeric modes:
    /// the preview label equals the old implementation's, and `handleGesture`
    /// reports "handled" exactly when the old chain resolved (or the gesture
    /// was a circle on an existing key).
    @Test func previewLabelAndHandledFlagMatchTheOldBehaviourOnEveryKey() throws {
        for languageId in ["de_DE", "en_US", "es_ES", "ar_SA", "ja_JP"] {
            guard LanguageDefinitions.all.contains(where: { $0.id == languageId }) else { continue }
            let (vm, target) = makeViewModel(languageId: languageId)
            let definition = try #require(vm.currentDefinition)
            let chains = oracleChains(for: definition)
            for modeName in [ModeNames.main, ModeNames.shifted, ModeNames.numeric] {
                guard let mode = definition.mode(modeName) else { continue }
                for keyId in mode.keys.keys.sorted() {
                    for gesture in GestureType.allCases {
                        for isReturn in [false, true] {
                            vm.activeModeName = modeName
                            let expectedLabel = oraclePreview(
                                vm, gesture: gesture, keyId: keyId, isReturn: isReturn, chains: chains
                            )
                            #expect(
                                vm.previewLabel(for: gesture, keyId: keyId, isReturn: isReturn) == expectedLabel,
                                "\(languageId)/\(modeName)/\(keyId) \(gesture) return=\(isReturn)"
                            )

                            let expectedHandled = gesture.isCircular
                                || (isReturn ? chains.returnSwipe : chains.standard)
                                    .resolve(keyId: keyId, gesture: gesture, in: mode) != nil
                            target.events.removeAll()
                            let handled = vm.handleGesture(gesture, keyId: keyId, isReturn: isReturn)
                            #expect(
                                handled == expectedHandled,
                                "handled \(languageId)/\(modeName)/\(keyId) \(gesture) return=\(isReturn)"
                            )
                            // A globe swipe may legitimately switch language; put
                            // the language under test back so the oracle keeps
                            // describing the loaded definition.
                            if vm.currentDefinition?.id != definition.id {
                                vm.loadDefinition(for: languageId)
                            }
                        }
                    }
                }
            }
        }
    }

    @Test func aDefinitionAssignedDirectlyIsCompiledByRebuildResolverChain() {
        let (vm, target) = makeViewModel(languageId: "de_DE")
        vm.currentDefinition = LanguageDefinitions.german.makeDefinition()
        vm.compiledDefinition = nil
        #expect(!vm.handleGesture(.tap, keyId: GridSlot.center, isReturn: false))

        vm.rebuildResolverChain()

        #expect(vm.handleGesture(.tap, keyId: GridSlot.center, isReturn: false))
        #expect(!target.events.isEmpty)
    }
}

// MARK: - Registry cache

/// The compiled cache is process-global, and `KeyboardRegistryTests` calls
/// `evictAll()` while this suite runs in parallel, which can wipe an entry
/// between "compile it" and "look for it". Absence of a signature only this
/// suite ever fills cannot be forged by another suite, so those assertions are
/// direct; a scenario that also needs *presence* is re-run (a bounded number of
/// times) until an uninterrupted pass observes it all. A real regression fails
/// every attempt; a foreign eviction fails at most the attempt it lands in.
private func holdsInSomeAttempt(_ scenario: () -> Bool) -> Bool {
    (0 ..< 50).contains { _ in scenario() }
}

@Suite(.serialized)
struct CompiledCacheTests {
    @Test func theSignatureNormalisesTheNumpadType() {
        #expect(KeyboardRegistry.compiledSignature(languageId: "de_DE", numpadType: nil) == "de_DE|phone")
        #expect(KeyboardRegistry.compiledSignature(languageId: "de_DE", numpadType: "bogus") == "de_DE|phone")
        #expect(KeyboardRegistry.compiledSignature(languageId: "de_DE", numpadType: "phone") == "de_DE|phone")
        #expect(KeyboardRegistry.compiledSignature(languageId: "de_DE", numpadType: "classic") == "de_DE|classic")
    }

    @Test func compiledTablesAreBuiltOnceAndShared() {
        let german = LanguageDefinitions.german.makeDefinition()
        let other = LanguageDefinitions.all.first { $0.id != german.id }?.makeDefinition() ?? german
        let signature = "cache-test-shared|phone"
        let held = holdsInSomeAttempt {
            let first = KeyboardRegistry.compiled(for: german, signature: signature)
            // A second request must not rebuild: hand it a different definition
            // and expect the first one's tables back.
            let second = KeyboardRegistry.compiled(for: other, signature: signature)
            let shared = first.modes[ModeNames.main]?.keys == second.modes[ModeNames.main]?.keys
            let cached = KeyboardRegistry.isCompiledCached(signature: signature)
            KeyboardRegistry.evict(id: "cache-test-shared")
            return shared && cached && !KeyboardRegistry.isCompiledCached(signature: signature)
        }
        #expect(held)
    }

    @Test func evictDropsEveryNumpadStyleOfThatLanguageOnly() {
        let definition = LanguageDefinitions.german.makeDefinition()
        let held = holdsInSomeAttempt {
            for signature in ["evict-a|phone", "evict-a|classic", "evict-ab|phone", "evict-b|phone"] {
                _ = KeyboardRegistry.compiled(for: definition, signature: signature)
            }
            KeyboardRegistry.evict(id: "evict-a")
            // "evict-a" must not match "evict-ab": the separator is part of the prefix.
            let result = !KeyboardRegistry.isCompiledCached(signature: "evict-a|phone")
                && !KeyboardRegistry.isCompiledCached(signature: "evict-a|classic")
                && KeyboardRegistry.isCompiledCached(signature: "evict-ab|phone")
                && KeyboardRegistry.isCompiledCached(signature: "evict-b|phone")
            KeyboardRegistry.evict(id: "evict-ab")
            KeyboardRegistry.evict(id: "evict-b")
            return result
        }
        #expect(held)
    }

    @Test func evictAllDropsCompiledEntries() {
        let definition = LanguageDefinitions.german.makeDefinition()
        let signature = "evict-all-test|phone"
        let held = holdsInSomeAttempt {
            _ = KeyboardRegistry.compiled(for: definition, signature: signature)
            let present = KeyboardRegistry.isCompiledCached(signature: signature)
            KeyboardRegistry.evictAll()
            return present && !KeyboardRegistry.isCompiledCached(signature: signature)
        }
        #expect(held)
    }

    @Test func evictAllExceptKeepsOnlyThatLanguagesTables() {
        let definition = LanguageDefinitions.german.makeDefinition()
        let held = holdsInSomeAttempt {
            for signature in ["keep-me|phone", "keep-me|classic", "drop-me|phone"] {
                _ = KeyboardRegistry.compiled(for: definition, signature: signature)
            }
            KeyboardRegistry.evictAll(except: "keep-me")
            let result = KeyboardRegistry.isCompiledCached(signature: "keep-me|phone")
                && KeyboardRegistry.isCompiledCached(signature: "keep-me|classic")
                && !KeyboardRegistry.isCompiledCached(signature: "drop-me|phone")
            KeyboardRegistry.evict(id: "keep-me")
            return result
        }
        #expect(held)
    }

    @Test func prewarmCompilesEachLanguageForThePhoneNumpad() async {
        let ids = ["de_DE", "fr_FR"].filter { id in LanguageDefinitions.all.contains { $0.id == id } }
        var held = false
        for _ in 0 ..< 50 where !held {
            await KeyboardRegistry.prewarm(ids)
            held = ids.allSatisfy { id in
                KeyboardRegistry.isCached(id: id)
                    && KeyboardRegistry.isCompiledCached(
                        signature: KeyboardRegistry.compiledSignature(languageId: id, numpadType: nil)
                    )
            }
        }
        #expect(held)
    }
}
