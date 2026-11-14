//
//  LongSwipeTests.swift
//  WurstfingerTests
//
//  Long swipes (#79): the settings snapshot, the displacement the classifier
//  reports in key sizes, the "armed" check behind the trail colour, and the
//  view model resolving a long flick before the key's own binding.
//

import CoreGraphics
import Foundation
import Testing
@testable import WurstfingerKit
@testable import WurstfingerScenarioKit

private func expertStore(
    longSwipes: Bool = true, expert: Bool = true, _ extra: [SettingsKey: Any] = [:]
) -> InMemoryUserDefaults {
    let store = InMemoryUserDefaults()
    store.set(expert, forKey: SettingsKey.expertModeEnabled.rawValue)
    store.set(longSwipes, forKey: SettingsKey.isLongSwipeEnabled.rawValue)
    for (key, value) in extra { store.set(value, forKey: key.rawValue) }
    return store
}

private func swipe(_ gesture: GestureType, isReturn: Bool = false, keys: CGVector = CGVector(dx: 2, dy: 0))
    -> GestureClassification {
    GestureClassification(gesture: gesture, isReturn: isReturn, displacementInKeys: keys)
}

// MARK: - Settings snapshot

struct LongSwipeConfigurationTests {
    @Test func isOffInAFreshInstallation() {
        let configuration = LongSwipeConfiguration.load(from: InMemoryUserDefaults())
        #expect(!configuration.isEnabled)
        #expect(GestureTuning.default.longSwipe == LongSwipeConfiguration())
        #expect(!GestureTuning.default.longSwipe.isEnabled)
    }

    @Test func staysOffUnlessExpertModeIsOn() {
        #expect(!LongSwipeConfiguration.load(from: expertStore(longSwipes: true, expert: false)).isEnabled)
        #expect(!LongSwipeConfiguration.load(from: expertStore(longSwipes: false, expert: true)).isEnabled)
        #expect(LongSwipeConfiguration.load(from: expertStore()).isEnabled)
    }

    @Test func defaultsAreFlickboards() {
        let configuration = LongSwipeConfiguration.load(from: expertStore())
        #expect(configuration.threshold == 1.5)
        #expect(configuration.actions == [
            .swipeUp: .escape,
            .swipeDown: .newline,
            .swipeLeft: .deleteWordBackward,
            .swipeRight: .tab,
            .swipeUpLeft: .backTab,
            .swipeDownRight: .lineEnd,
            .swipeUpRight: .lineStart,
            .swipeDownLeft: .dismissKeyboard,
        ])
    }

    @Test func eachDirectionIsConfigurable() {
        let store = expertStore([
            .longSwipeUp: LongSwipeAction.documentStart.rawValue,
            .longSwipeRight: LongSwipeAction.none.rawValue,
            .longSwipeDownLeft: LongSwipeAction.space.rawValue,
        ])
        let configuration = LongSwipeConfiguration.load(from: store)
        #expect(configuration.actions[.swipeUp] == .documentStart)
        #expect(configuration.actions[.swipeRight] == nil)
        #expect(configuration.actions[.swipeDownLeft] == .space)
        // Untouched directions keep their default.
        #expect(configuration.actions[.swipeLeft] == .deleteWordBackward)
    }

    @Test func anUnknownStoredChoiceFallsBackToTheDefault() {
        let store = expertStore([.longSwipeUp: "teleport"])
        #expect(LongSwipeConfiguration.load(from: store).actions[.swipeUp] == .escape)
    }

    @Test(arguments: [(0.2, 1.0), (1.0, 1.0), (2.25, 2.25), (3.0, 3.0), (9.0, 3.0), (-4.0, 1.0)])
    func thresholdIsClampedToItsRange(stored: Double, expected: Double) {
        let store = expertStore([.longSwipeThreshold: stored])
        #expect(LongSwipeConfiguration.load(from: store).threshold == CGFloat(expected))
    }

    @Test func aNonFiniteThresholdFallsBackToTheDefault() {
        let store = expertStore([.longSwipeThreshold: Double.nan])
        #expect(LongSwipeConfiguration.load(from: store).threshold == 1.5)
    }

    @Test func everyChoiceMapsToItsPipelineAction() {
        #expect(LongSwipeAction.none.keyAction == nil)
        #expect(LongSwipeAction.allCases.filter { $0 != .none }.allSatisfy { $0.keyAction != nil })
        // Raw values are persisted: pin the ones that have shipped.
        #expect(LongSwipeAction.deleteWordBackward.rawValue == "deleteWordBackward")
        #expect(LongSwipeAction(rawValue: "backTab")?.keyAction == .backTab)
    }

    @Test func everySwipeDirectionHasAStorageKey() {
        let keys = LongSwipeConfiguration.directions.compactMap(LongSwipeConfiguration.settingsKey(for:))
        #expect(keys.count == 8)
        #expect(Set(keys.map(\.rawValue)).count == 8)
        #expect(LongSwipeConfiguration.settingsKey(for: .tap) == nil)
        #expect(LongSwipeConfiguration.settingsKey(for: .circularClockwise) == nil)
    }
}

// MARK: - Resolution from a classification

struct LongSwipeResolutionTests {
    private let on = LongSwipeConfiguration(isEnabled: true)

    @Test func aFlickPastTheThresholdFiresItsDirectionsAction() {
        #expect(on.action(for: swipe(.swipeRight, keys: CGVector(dx: 1.6, dy: 0))) == .tab)
        #expect(on.action(for: swipe(.swipeUp, keys: CGVector(dx: 0, dy: -2))) == .escape)
    }

    @Test func aFlickShortOfTheThresholdIsOrdinary() {
        #expect(on.action(for: swipe(.swipeRight, keys: CGVector(dx: 1.4, dy: 0))) == nil)
    }

    @Test func theThresholdItselfCounts() {
        #expect(on.action(for: swipe(.swipeRight, keys: CGVector(dx: 1.5, dy: 0))) == .tab)
    }

    @Test func distanceIsTheLengthOfTheKeyUnitVector() {
        // 1.1 keys across and 1.1 down is 1.56 keys of travel.
        #expect(on.action(for: swipe(.swipeDownRight, keys: CGVector(dx: 1.1, dy: 1.1))) == .lineEnd)
        // 1.0 and 1.0 is 1.41: not enough.
        #expect(on.action(for: swipe(.swipeDownRight, keys: CGVector(dx: 1, dy: 1))) == nil)
    }

    @Test func aRaisedThresholdAsksForMore() {
        let strict = LongSwipeConfiguration(isEnabled: true, threshold: 2.5)
        #expect(strict.action(for: swipe(.swipeRight, keys: CGVector(dx: 2, dy: 0))) == nil)
        #expect(strict.action(for: swipe(.swipeRight, keys: CGVector(dx: 2.6, dy: 0))) == .tab)
    }

    @Test func returnSwipesTapsAndCirclesAreNeverLongSwipes() {
        let far = CGVector(dx: 3, dy: 0)
        #expect(on.action(for: swipe(.swipeRight, isReturn: true, keys: far)) == nil)
        #expect(on.action(for: swipe(.tap, keys: far)) == nil)
        #expect(on.action(for: swipe(.circularClockwise, keys: far)) == nil)
        #expect(on.action(for: swipe(.longPress, keys: far)) == nil)
    }

    @Test func aDirectionSetToNoneStaysAnOrdinarySwipe() {
        var configuration = on
        configuration.actions[.swipeRight] = nil
        #expect(configuration.action(for: swipe(.swipeRight)) == nil)
    }

    @Test func offMeansOff() {
        #expect(LongSwipeConfiguration().action(for: swipe(.swipeRight)) == nil)
    }
}

// MARK: - Displacement from the classifier

struct LongSwipeDisplacementTests {
    private let keySize = CGSize(width: 80, height: 60)

    private func line(to end: CGPoint, steps: Int = 20) -> [CGPoint] {
        (0 ... steps).map {
            CGPoint(x: end.x * CGFloat($0) / CGFloat(steps), y: end.y * CGFloat($0) / CGFloat(steps))
        }
    }

    private func classify(_ points: [CGPoint], keySize: CGSize? = nil) -> GestureClassification {
        KeyGestureRecognizer.classify(
            positions: points, aspectRatio: 80.0 / 60.0, tuning: .default, keySize: keySize ?? self.keySize
        )
    }

    @Test func aFlickAcrossTwoKeyWidthsReadsTwoOnX() {
        let result = classify(line(to: CGPoint(x: 160, y: 0)))
        #expect(result.gesture == .swipeRight)
        #expect(abs(result.displacementInKeys.dx - 2) < 0.01)
        #expect(abs(result.displacementInKeys.dy) < 0.01)
    }

    @Test func eachAxisIsNormalisedByItsOwnKeyExtent() {
        let result = classify(line(to: CGPoint(x: -80, y: -90)))
        #expect(abs(result.displacementInKeys.dx - -1) < 0.01)
        #expect(abs(result.displacementInKeys.dy - -1.5) < 0.01)
        #expect(result.gesture == .swipeUpLeft)
    }

    @Test func aSquareKeyAndAWideKeyAgreeOnRelativeReach() {
        let square = KeyGestureRecognizer.classify(
            positions: line(to: CGPoint(x: 100, y: 0)), aspectRatio: 1, tuning: .default,
            keySize: CGSize(width: 50, height: 50)
        )
        let wide = KeyGestureRecognizer.classify(
            positions: line(to: CGPoint(x: 200, y: 0)), aspectRatio: 2, tuning: .default,
            keySize: CGSize(width: 100, height: 50)
        )
        #expect(abs(square.displacementInKeys.dx - wide.displacementInKeys.dx) < 0.01)
    }

    @Test func withoutAKeySizeTheDisplacementIsZero() {
        let result = KeyGestureRecognizer.classify(
            positions: line(to: CGPoint(x: 160, y: 0)), aspectRatio: 1.33, tuning: .default
        )
        #expect(result.displacementInKeys == .zero)
        #expect(result.gesture == .swipeRight)
    }

    @Test func aTapHasNoDisplacement() {
        let result = classify([.zero, CGPoint(x: 1, y: 1)])
        #expect(result.gesture == .tap)
        #expect(hypot(result.displacementInKeys.dx, result.displacementInKeys.dy) < 0.05)
    }

    @Test func theSequenceCarriesTheKeySizeThrough() {
        var sequence = KeyGestureSequence()
        for point in line(to: CGPoint(x: 0, y: 150), steps: 15) {
            _ = sequence.handleChanged(translation: CGSize(width: point.x, height: point.y))
        }
        let result = sequence.handleEnded(
            translation: CGSize(width: 0, height: 150), aspectRatio: 80.0 / 60.0, tuning: .default,
            keySize: keySize
        )
        #expect(result.gesture == .swipeDown)
        #expect(abs(result.displacementInKeys.dy - 2.5) < 0.01)
    }

    @Test func aReturnSwipeStaysOneHoweverFarItWent() {
        // A return swipe keeps classifying as one however far it went out.
        let out = line(to: CGPoint(x: 200, y: 0), steps: 12)
        let path = out + out.reversed().dropFirst().map { CGPoint(x: $0.x, y: $0.y + 4) }
        let result = classify(path)
        #expect(result.isReturn)
        #expect(LongSwipeConfiguration(isEnabled: true).action(for: result) == nil)
    }
}

// MARK: - The "armed" check

struct LongSwipeArmedTests {
    private let on = LongSwipeConfiguration(isEnabled: true)
    private let keySize = CGSize(width: 80, height: 60)

    @Test func armsOncePastTheThreshold() {
        #expect(!on.isArmed(translation: CGSize(width: 100, height: 0), keySize: keySize)) // 1.25 keys
        #expect(on.isArmed(translation: CGSize(width: 130, height: 0), keySize: keySize)) // 1.63 keys
    }

    @Test func disarmsWhenTheFingerComesBack() {
        #expect(on.isArmed(translation: CGSize(width: 0, height: -120), keySize: keySize))
        #expect(!on.isArmed(translation: CGSize(width: 0, height: -40), keySize: keySize))
    }

    @Test func measuresTheHeightInKeyHeightsNotWidths() {
        // 100 pt down is 1.67 key heights but only 1.25 key widths.
        #expect(on.isArmed(translation: CGSize(width: 0, height: 100), keySize: keySize))
        #expect(!on.isArmed(translation: CGSize(width: 100, height: 0), keySize: keySize))
    }

    @Test func aDirectionWithoutAnActionNeverArms() {
        var configuration = on
        configuration.actions[.swipeRight] = nil
        #expect(!configuration.isArmed(translation: CGSize(width: 300, height: 0), keySize: keySize))
        #expect(configuration.isArmed(translation: CGSize(width: -300, height: 0), keySize: keySize))
    }

    @Test func neverArmsWhenOffOrWithoutAKeySize() {
        let far = CGSize(width: 400, height: 0)
        #expect(!LongSwipeConfiguration().isArmed(translation: far, keySize: keySize))
        #expect(!on.isArmed(translation: far, keySize: .zero))
        #expect(!on.isArmed(translation: far, keySize: CGSize(width: 0, height: 60)))
    }

    /// The colour must promise exactly what a release delivers.
    @Test func theTrailArmsExactlyWhereAReleaseWouldFire() {
        let size = CGSize(width: 72, height: 58)
        let configuration = LongSwipeConfiguration(isEnabled: true)
        var tuning = GestureTuning.default
        tuning.longSwipe = configuration
        var checked = 0
        for (index, gesture) in LongSwipeConfiguration.directions.enumerated() {
            for fraction in [0.4, 0.9, 1.2, 1.7, 2.1, 2.8] as [CGFloat] {
                var synthesizer = TouchSynthesizer(keySize: size, seed: UInt64(index * 10 + 3))
                let path = synthesizer.swipe(gesture, fraction: fraction)
                let classification = KeyGestureRecognizer.classify(
                    positions: KeyGestureRecognizer.anchoringOrigin(path.samples),
                    aspectRatio: size.width / size.height, tuning: tuning, keySize: size
                )
                guard !classification.isReturn, classification.gesture.isSwipe else { continue }
                let fires = configuration.action(for: classification) != nil
                let armed = configuration.isArmed(
                    translation: CGSize(width: path.end.x, height: path.end.y), keySize: size
                )
                #expect(fires == armed, "\(gesture) at \(fraction): fires \(fires), armed \(armed)")
                checked += 1
            }
        }
        #expect(checked >= 40)
    }
}

// MARK: - Trail feedback

@MainActor
struct LongSwipeTrailTests {
    private func recorder(enabled: Bool = true) -> GestureTrailRecorder {
        let defaults = InMemoryUserDefaults()
        defaults.set(enabled, forKey: SettingsKey.gestureTrailEnabled.rawValue)
        return GestureTrailRecorder(defaults: defaults, now: { 0 })
    }

    @Test func startsUnarmed() {
        #expect(!recorder().isLongSwipeArmed)
    }

    @Test func theOwnerOfTheTouchCanArmAndDisarmIt() {
        let recorder = recorder()
        let token = GestureTrailToken()
        recorder.begin(at: .zero, from: token)
        recorder.setLongSwipeArmed(true, from: token)
        #expect(recorder.isLongSwipeArmed)
        recorder.setLongSwipeArmed(false, from: token)
        #expect(!recorder.isLongSwipeArmed)
    }

    @Test func aSecondFingerCannotArmTheFirstFingersTrail() {
        let recorder = recorder()
        let first = GestureTrailToken()
        let second = GestureTrailToken()
        recorder.begin(at: .zero, from: first)
        recorder.setLongSwipeArmed(true, from: second)
        #expect(!recorder.isLongSwipeArmed)
    }

    @Test func nothingArmsWhileTheTrailIsOff() {
        let recorder = recorder(enabled: false)
        let token = GestureTrailToken()
        recorder.begin(at: .zero, from: token)
        recorder.setLongSwipeArmed(true, from: token)
        #expect(!recorder.isLongSwipeArmed)
    }

    @Test func releaseKeepsTheColourForTheFadeAndANewTouchClearsIt() {
        let recorder = recorder()
        let token = GestureTrailToken()
        recorder.begin(at: .zero, from: token)
        recorder.setLongSwipeArmed(true, from: token)
        recorder.finish(from: token)
        #expect(recorder.isLongSwipeArmed) // the fired long swipe fades in its colour

        recorder.begin(at: .zero, from: token)
        #expect(!recorder.isLongSwipeArmed)
    }

    @Test func cancelClearsIt() {
        let recorder = recorder()
        let token = GestureTrailToken()
        recorder.begin(at: .zero, from: token)
        recorder.setLongSwipeArmed(true, from: token)
        recorder.cancel(from: token)
        #expect(!recorder.isLongSwipeArmed)
    }
}

// MARK: - View model

@MainActor
@Suite(.serialized)
struct LongSwipeViewModelTests {
    private func makeModel(
        _ store: InMemoryUserDefaults, dismissKeyboard: @escaping () -> Void = {}
    ) -> (KeyboardViewModel, MockTextTarget) {
        let model = KeyboardViewModel(userDefaults: store, shouldPersistSettings: false)
        let target = MockTextTarget()
        model.bindTextInputTarget(target)
        model.bindViewControllerActions(advanceToNextInputMode: {}, dismissKeyboard: dismissKeyboard)
        model.loadDefinition(for: "en_US")
        return (model, target)
    }

    @Test func aLongSwipeBeatsTheKeysOwnBinding() {
        let (model, target) = makeModel(expertStore())
        // Swipe right on the top-left key is "-" when ordinary.
        let handled = model.handleClassification(
            swipe(.swipeRight, keys: CGVector(dx: 2, dy: 0)), keyId: GridSlot.topLeft
        )
        #expect(handled)
        #expect(target.events == [.insertText("\t")])
    }

    @Test func anOrdinarySwipeStillTypesTheKeysBinding() {
        let (model, target) = makeModel(expertStore())
        model.handleClassification(swipe(.swipeRight, keys: CGVector(dx: 1, dy: 0)), keyId: GridSlot.topLeft)
        #expect(target.events == [.insertText("-")])
    }

    @Test func withLongSwipesOffTheKeyKeepsItsBinding() {
        let (model, target) = makeModel(InMemoryUserDefaults())
        model.handleClassification(swipe(.swipeRight, keys: CGVector(dx: 3, dy: 0)), keyId: GridSlot.topLeft)
        #expect(target.events == [.insertText("-")])
    }

    @Test func aLongSwipeWorksOnEveryKeyEvenOneWithNoBindingThere() {
        let (model, target) = makeModel(expertStore())
        // Up on the centre key has a binding; on the return key swipe-up has none.
        let handled = model.handleClassification(
            swipe(.swipeUp, keys: CGVector(dx: 0, dy: -2)), keyId: UtilitySlot.return
        )
        #expect(handled)
        #expect(target.events == [.insertText("\u{1B}")])
    }

    @Test func deleteWordRunsThroughThePipeline() {
        let (model, target) = makeModel(expertStore())
        target.documentContextBeforeInput = "good morning"
        model.handleClassification(swipe(.swipeLeft, keys: CGVector(dx: -2, dy: 0)), keyId: GridSlot.center)
        #expect(target.documentContextBeforeInput == "good ")
    }

    @Test func hideKeyboardReachesTheViewController() {
        var dismissed = 0
        let (model, _) = makeModel(expertStore(), dismissKeyboard: { dismissed += 1 })
        model.handleClassification(
            swipe(.swipeDownLeft, keys: CGVector(dx: -1.5, dy: 1.5)), keyId: GridSlot.center
        )
        #expect(dismissed == 1)
    }

    @Test func aReturnSwipeIsNotALongSwipe() {
        let (model, target) = makeModel(expertStore())
        model.handleClassification(
            swipe(.swipeRight, isReturn: true, keys: CGVector(dx: 3, dy: 0)), keyId: GridSlot.topLeft
        )
        #expect(!target.events.contains(.insertText("\t")))
    }

    @Test func changingTheSettingsTakesEffectOnReload() {
        let store = InMemoryUserDefaults()
        let (model, target) = makeModel(store)
        let far = swipe(.swipeRight, keys: CGVector(dx: 2, dy: 0))
        model.handleClassification(far, keyId: GridSlot.topLeft)
        #expect(target.events == [.insertText("-")])

        store.set(true, forKey: SettingsKey.expertModeEnabled.rawValue)
        store.set(true, forKey: SettingsKey.isLongSwipeEnabled.rawValue)
        store.set(LongSwipeAction.documentEnd.rawValue, forKey: SettingsKey.longSwipeRight.rawValue)
        // Invisible until the settings signal, exactly as in production.
        model.handleClassification(far, keyId: GridSlot.topLeft)
        #expect(target.events.last == .insertText("-"))

        model.reloadSettings()
        target.events.removeAll()
        target.documentContextAfterInput = "tail"
        model.handleClassification(far, keyId: GridSlot.topLeft)
        #expect(target.events == [.adjustCursor(4)])
    }
}
