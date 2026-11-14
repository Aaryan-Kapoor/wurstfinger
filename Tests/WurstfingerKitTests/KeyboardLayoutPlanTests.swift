//
//  KeyboardLayoutPlanTests.swift
//  WurstfingerTests
//
//  The layout decisions behind the numpad column, the key spacing, the iPad
//  widths and the split: that a column grows the keyboard instead of shrinking
//  the keys, that spacing flows into every metric, and when and how the split
//  applies. Pure functions, so no screen or view is needed.
//

import CoreGraphics
import Foundation
import Testing
@testable import WurstfingerKit

// MARK: - Spacing and the numpad column in the metrics

struct KeyboardLayoutMetricsSpacingTests {
    private func resolve(
        wish: CGFloat = 270, columns: Int = 4, wishColumns: Int? = nil,
        available: CGFloat = 2000, spacing: CGFloat = KeyboardConstants.Layout.defaultKeySpacing,
        screenHeight: CGFloat = 0
    ) -> KeyboardLayoutMetrics {
        KeyboardLayoutMetrics.resolve(
            wishWidth: wish, aspectRatio: 1.0, columns: columns, wishColumns: wishColumns,
            availableWidth: available, screenHeight: screenHeight, spacing: spacing
        )
    }

    @Test func theDefaultSpacingIsTheShippedConstant() {
        #expect(resolve().keySpacing == KeyboardConstants.Layout.defaultKeySpacing)
        #expect(KeyboardConstants.Layout.defaultKeySpacing == 5)
        #expect(KeyboardLayoutMetrics.reference.keySpacing == 5)
    }

    @Test(arguments: [CGFloat(0), 3, 5, 8, 12])
    func widthStaysTheWishAndSpacingTakesItsShareFromTheKeys(spacing: CGFloat) {
        let metrics = resolve(spacing: spacing)
        #expect(metrics.keyboardWidth == 270)
        let chrome = KeyboardLayoutMetrics.horizontalChrome(columns: 4, spacing: spacing)
        #expect(abs(metrics.cellWidth - (270 - chrome) / 4) < 0.0001)
        #expect(metrics.keySpacing == spacing)
    }

    @Test func wideGapsMakeSmallerKeys() {
        #expect(resolve(spacing: 12).cellWidth < resolve(spacing: 0).cellWidth)
    }

    @Test(arguments: [CGFloat(0), 5, 12])
    func totalHeightUsesTheSpacing(spacing: CGFloat) {
        let metrics = resolve(spacing: spacing)
        let expected = metrics.cellHeight * 4
            + KeyboardConstants.Layout.verticalPaddingTop + KeyboardConstants.Layout.verticalPaddingBottom
            + spacing * 3
        #expect(abs(metrics.totalHeight - expected) < 0.0001)
    }

    @Test func gridSizeIsTheKeyboardMinusItsPaddings() {
        let metrics = resolve(spacing: 8)
        let size = metrics.gridSize(rows: 4)
        #expect(size.width == 270 - 2 * KeyboardConstants.Layout.horizontalPadding)
        #expect(abs(size.height - (metrics.cellHeight * 4 + 8 * 3)) < 0.0001)
    }

    @Test(arguments: [CGFloat.nan, -3, .infinity])
    func aCorruptSpacingFallsBackToTheShippedOne(spacing: CGFloat) {
        #expect(resolve(spacing: spacing).keySpacing == KeyboardConstants.Layout.defaultKeySpacing)
    }

    @Test func theHeightGuardKeepsTheAspectRatioAtAnySpacing() {
        for spacing in [CGFloat(0), 12] {
            let metrics = resolve(wish: 600, available: 2000, spacing: spacing, screenHeight: 400)
            #expect(abs(metrics.cellAspectRatio - 1.0) < 0.0001)
            #expect(metrics.totalHeight <= max(400 - 120, 400 * 0.7) + 0.5)
        }
    }

    // MARK: Extra columns

    @Test func anExtraColumnGrowsTheKeyboardAndKeepsTheKeySize() {
        let four = resolve(columns: 4)
        let five = resolve(columns: 5, wishColumns: 4)
        #expect(abs(five.cellWidth - four.cellWidth) < 0.0001)
        #expect(abs(five.keyboardWidth - (four.keyboardWidth + four.cellWidth + four.keySpacing)) < 0.0001)
        #expect(five.cellHeight == four.cellHeight)
    }

    @Test func theColumnShrinksTheKeysOnlyWhenTheContainerIsTooNarrow() {
        let four = resolve(columns: 4, available: 320)
        let five = resolve(columns: 5, wishColumns: 4, available: 320)
        #expect(five.keyboardWidth == 320)
        #expect(five.cellWidth < four.cellWidth)
        // The same fit-clamp the plain wish gets: the grid exactly fills it.
        let chrome = KeyboardLayoutMetrics.horizontalChrome(columns: 5, spacing: 5)
        #expect(abs(five.cellWidth - (320 - chrome) / 5) < 0.0001)
    }

    @Test func withoutWishColumnsTheResolutionIsTheOldOne() {
        let old = resolve(columns: 4, available: 300)
        #expect(old.keyboardWidth == 270)
        #expect(resolve(columns: 5, wishColumns: 5).keyboardWidth == 270)
    }
}

// MARK: - Plans

struct KeyboardLayoutPlanTests {
    private func inputs(
        utilityLeading: Bool = false,
        numpad: NumpadColumnPlacement = .off,
        split: Bool = false,
        wish: CGFloat = 380,
        spacing: CGFloat = 5,
        container: CGFloat,
        screen: CGSize,
        numeric: Bool = false,
        hasNumpadKeys: Bool = true
    ) -> KeyboardLayoutPlan.Inputs {
        let table = numeric ? StandardArrangements.numeric3x3 : StandardArrangements.grid3x3
        return KeyboardLayoutPlan.Inputs(
            base: table[utilityLeading ? .portraitUtilityLeft : .portrait]!,
            hasNumpadKeys: hasNumpadKeys && !numeric,
            numpadColumn: numpad,
            isUtilityLeading: utilityLeading,
            isSplitEnabled: split,
            wishWidth: wish,
            aspectRatio: 1.0,
            spacing: spacing,
            containerWidth: container,
            widthCap: min(container, min(screen.width, screen.height)),
            screen: screen
        )
    }

    private let ipadLandscape = CGSize(width: 1366, height: 1024)
    private let phoneLandscape = CGSize(width: 852, height: 393)

    // MARK: iPad widths

    /// The iPad portrait widths, landscape, and a floating keyboard.
    private static let ipadContainers: [(name: String, width: CGFloat, screen: CGSize)] = [
        ("floating", 320, CGSize(width: 820, height: 1180)),
        ("744", 744, CGSize(width: 744, height: 1133)),
        ("820", 820, CGSize(width: 820, height: 1180)),
        ("1024", 1024, CGSize(width: 1024, height: 1366)),
        ("1366 landscape", 1366, CGSize(width: 1366, height: 1024)),
    ]

    @Test(arguments: ipadContainers)
    func theKeyboardFitsEveryIPadWidthWithAndWithoutTheColumn(
        container: (name: String, width: CGFloat, screen: CGSize)
    ) {
        for numpad in [NumpadColumnPlacement.off, .leading, .trailing] {
            let plan = KeyboardLayoutPlan.resolve(inputs(numpad: numpad, container: container.width, screen: container.screen))
            #expect(!plan.isSplit)
            #expect(plan.metrics.keyboardWidth <= container.width + 0.001, "\(container.name) \(numpad)")
            #expect(plan.metrics.cellWidth >= 40, "keys stay big enough: \(container.name) \(numpad)")
            #expect(plan.arrangement.columns == (numpad == .off ? 4 : 5))
        }
    }

    @Test func aWideIPadKeepsTheKeySizeWhenTheColumnIsSwitchedOn() {
        let off = KeyboardLayoutPlan.resolve(inputs(numpad: .off, container: 820, screen: CGSize(width: 820, height: 1180)))
        let on = KeyboardLayoutPlan.resolve(inputs(numpad: .trailing, container: 820, screen: CGSize(width: 820, height: 1180)))
        #expect(abs(on.metrics.cellWidth - off.metrics.cellWidth) < 0.0001)
        #expect(on.metrics.keyboardWidth > off.metrics.keyboardWidth)
    }

    @Test func aFloatingIPadKeyboardShrinksItsKeysToFitTheColumn() {
        let screen = CGSize(width: 820, height: 1180)
        let off = KeyboardLayoutPlan.resolve(inputs(numpad: .off, container: 320, screen: screen))
        let on = KeyboardLayoutPlan.resolve(inputs(numpad: .trailing, container: 320, screen: screen))
        #expect(on.metrics.keyboardWidth == 320)
        #expect(on.metrics.cellWidth < off.metrics.cellWidth)
        #expect(on.metrics.cellWidth > 40)
    }

    @MainActor
    @Test func theIPadDefaultIsWiderThanThePhoneDefault() {
        #expect(DeviceLayoutDefaults.ipad > DeviceLayoutDefaults.phone)
    }

    // MARK: Split eligibility

    @Test func theSplitNeedsTheSettingAWideContainerAndALandscapeScreen() {
        #expect(KeyboardLayoutPlan.isSplitApplicable(isEnabled: true, containerWidth: 1366, screen: ipadLandscape))
        #expect(KeyboardLayoutPlan.isSplitApplicable(isEnabled: true, containerWidth: 852, screen: phoneLandscape))
        // Off.
        #expect(!KeyboardLayoutPlan.isSplitApplicable(isEnabled: false, containerWidth: 1366, screen: ipadLandscape))
        // Portrait, however wide the iPad.
        #expect(!KeyboardLayoutPlan.isSplitApplicable(
            isEnabled: true, containerWidth: 1024, screen: CGSize(width: 1024, height: 1366)
        ))
        // A floating keyboard or a Split View pane on a landscape iPad.
        #expect(!KeyboardLayoutPlan.isSplitApplicable(isEnabled: true, containerWidth: 320, screen: ipadLandscape))
        #expect(!KeyboardLayoutPlan.isSplitApplicable(isEnabled: true, containerWidth: 507, screen: ipadLandscape))
        // The smallest landscape phone.
        #expect(!KeyboardLayoutPlan.isSplitApplicable(
            isEnabled: true, containerWidth: 568, screen: CGSize(width: 568, height: 320)
        ))
        // The boundary itself.
        #expect(KeyboardLayoutPlan.isSplitApplicable(
            isEnabled: true, containerWidth: KeyboardLayoutPlan.splitMinimumWidth, screen: ipadLandscape
        ))
    }

    @Test func aSplitAskedForOnAPortraitScreenIsThePlainBlock() {
        let screen = CGSize(width: 820, height: 1180)
        let plan = KeyboardLayoutPlan.resolve(inputs(split: true, container: 820, screen: screen))
        #expect(!plan.isSplit)
        #expect(plan.arrangement.columns == 4)
    }

    // MARK: The split

    @Test func theSplitSpansTheContainerWithBiggerKeys() {
        let plain = KeyboardLayoutPlan.resolve(inputs(container: 1366, screen: ipadLandscape))
        let split = KeyboardLayoutPlan.resolve(inputs(split: true, container: 1366, screen: ipadLandscape))
        #expect(split.isSplit)
        #expect(split.metrics.keyboardWidth == 1366)
        // Bigger than the block's, never past the split scale (rounded up to
        // whole columns, so at most a column's worth of share below it).
        #expect(split.metrics.cellWidth > plain.metrics.cellWidth * 1.05)
        #expect(split.metrics.cellWidth <= plain.metrics.cellWidth * KeyboardLayoutPlan.splitKeyScale + 0.0001)
    }

    /// The letters cluster stays within a thumb's reach of its edge, however
    /// large the width wish.
    @Test(arguments: [380 as CGFloat, 520, 700])
    func aSplitClusterStaysWithinThumbReach(wish: CGFloat) throws {
        let split = KeyboardLayoutPlan.resolve(inputs(split: true, wish: wish, container: 1366, screen: ipadLandscape))
        let cells = GridLayoutSolver.solve(split.arrangement)
        let topRight = try #require(cells.first { $0.keyId == GridSlot.topRight })
        let reach = KeyboardConstants.Layout.horizontalPadding
            + CGFloat(topRight.column + 1) * split.metrics.cellWidth
            + CGFloat(topRight.column) * split.metrics.keySpacing
        // One column's rounding of slack above the share.
        #expect(reach <= 1366 * KeyboardLayoutPlan.splitClusterShare + split.metrics.cellWidth)
    }

    // MARK: The accessory row

    @Test func theAccessoryRowAddsToTheHeightAndTheKeysKeepTheirSize() {
        let without = KeyboardLayoutPlan.resolve(inputs(container: 393, screen: CGSize(width: 393, height: 852)))
        var withRow = inputs(container: 393, screen: CGSize(width: 393, height: 852))
        withRow.accessoryHeight = 40
        let plan = KeyboardLayoutPlan.resolve(withRow)
        #expect(plan.metrics.accessoryHeight == 40)
        #expect(plan.metrics.cellWidth == without.metrics.cellWidth)
        #expect(abs(plan.metrics.totalHeight - without.metrics.totalHeight - 40) < 0.001)
    }

    /// On a short landscape screen the row is paid for by the keys, not by
    /// the host's text: the keyboard stays within the height guard.
    @Test func onAShortScreenTheKeysShrinkToMakeRoomForTheRow() {
        let screen = CGSize(width: 852, height: 393)
        let without = KeyboardLayoutPlan.resolve(inputs(wish: 700, container: 852, screen: screen))
        var withRow = inputs(wish: 700, container: 852, screen: screen)
        withRow.accessoryHeight = 44
        let plan = KeyboardLayoutPlan.resolve(withRow)
        #expect(plan.metrics.cellHeight < without.metrics.cellHeight)
        #expect(plan.metrics.totalHeight <= without.metrics.totalHeight + 0.001)
    }

    @Test(arguments: [(852 as CGFloat, 393 as CGFloat), (1133, 744), (1180, 820), (1366, 1024)])
    func theSplitFillsTheContainerAtEveryLandscapeWidth(width: CGFloat, height: CGFloat) {
        for numpad in [NumpadColumnPlacement.off, .trailing] {
            let plan = KeyboardLayoutPlan.resolve(inputs(
                numpad: numpad, split: true, container: width, screen: CGSize(width: width, height: height)
            ))
            #expect(plan.isSplit)
            #expect(abs(plan.metrics.keyboardWidth - width) < 0.001)
            // The metrics resolved for exactly the columns the arrangement has.
            #expect(plan.metrics.columns == plan.arrangement.columns)
            let cells = GridLayoutSolver.solve(plan.arrangement)
            #expect(cells.map { $0.column + $0.columnSpan }.max() == plan.arrangement.columns)
        }
    }

    @Test func theLettersAreOnOneSideAndTheUtilityAndNumpadKeysOnTheOther() throws {
        let plan = KeyboardLayoutPlan.resolve(inputs(numpad: .trailing, split: true, container: 1366, screen: ipadLandscape))
        let cells = GridLayoutSolver.solve(plan.arrangement)
        let letters = cells.filter { GridSlot.allSlots.joined().contains($0.keyId) || $0.keyId == UtilitySlot.space }
        let others = cells.filter { !letters.contains($0) }
        let lettersEnd = try #require(letters.map { $0.column + $0.columnSpan }.max())
        let othersStart = try #require(others.map(\.column).min())
        #expect(lettersEnd == 3, "the 3×3 grid and the space bar stay together at the left edge")
        #expect(othersStart > lettersEnd, "an empty middle separates the clusters")
        #expect(others.map { $0.column + $0.columnSpan }.max() == plan.arrangement.columns)
        // Numpad keys sit inside the utility cluster, one column in from its edge.
        let numpadColumns = Set(cells.filter { NumpadColumn.isNumpadKey($0.keyId) }.map(\.column))
        let globe = try #require(cells.first { $0.keyId == UtilitySlot.globe })
        #expect(numpadColumns == [globe.column - 1])
    }

    @Test func utilityKeysOnTheLeftMirrorTheSplit() throws {
        let plan = KeyboardLayoutPlan.resolve(inputs(
            utilityLeading: true, numpad: .trailing, split: true, container: 1366, screen: ipadLandscape
        ))
        let cells = GridLayoutSolver.solve(plan.arrangement)
        let globe = try #require(cells.first { $0.keyId == UtilitySlot.globe })
        let numpad = try #require(cells.first { $0.keyId == "numpad0" })
        let topLeft = try #require(cells.first { $0.keyId == GridSlot.topLeft })
        #expect(globe.column == 0)
        #expect(numpad.column == 1)
        #expect(topLeft.column > numpad.column + 1)
        #expect(topLeft.column + 3 == plan.arrangement.columns)
    }

    @Test func theNumpadSettingsSideDoesNotMatterInTheSplit() {
        let leading = KeyboardLayoutPlan.resolve(inputs(numpad: .leading, split: true, container: 1366, screen: ipadLandscape))
        let trailing = KeyboardLayoutPlan.resolve(inputs(numpad: .trailing, split: true, container: 1366, screen: ipadLandscape))
        #expect(leading.arrangement == trailing.arrangement)
    }

    @Test func noColumnMeansNoNumpadKeysInTheSplit() {
        let plan = KeyboardLayoutPlan.resolve(inputs(numpad: .off, split: true, container: 1366, screen: ipadLandscape))
        let cells = GridLayoutSolver.solve(plan.arrangement)
        #expect(!cells.contains { NumpadColumn.isNumpadKey($0.keyId) })
        #expect(cells.count == 14, "nine letters, the space bar, four utility keys")
    }

    @Test func theNumericModeKeepsTheSplitShapeWithAGapForTheColumn() {
        let letters = KeyboardLayoutPlan.resolve(inputs(numpad: .trailing, split: true, container: 1366, screen: ipadLandscape))
        let numeric = KeyboardLayoutPlan.resolve(inputs(numpad: .trailing, split: true, container: 1366, screen: ipadLandscape, numeric: true))
        #expect(numeric.arrangement.columns == letters.arrangement.columns)
        let globe = { (plan: KeyboardLayoutPlan) in GridLayoutSolver.solve(plan.arrangement).first { $0.keyId == UtilitySlot.globe }?.column }
        #expect(globe(numeric) == globe(letters))
    }

    @Test func biggerKeysMeanAShorterGapNeverALongerOne() {
        let small = KeyboardLayoutPlan.resolve(inputs(split: true, wish: 300, container: 1366, screen: ipadLandscape))
        let big = KeyboardLayoutPlan.resolve(inputs(split: true, wish: 520, container: 1366, screen: ipadLandscape))
        #expect(big.arrangement.columns < small.arrangement.columns)
        #expect(big.metrics.cellWidth > small.metrics.cellWidth)
    }

    @Test(arguments: [CGFloat(0), 5, 12])
    func theSplitWorksAtEverySpacing(spacing: CGFloat) {
        let plan = KeyboardLayoutPlan.resolve(inputs(split: true, spacing: spacing, container: 1366, screen: ipadLandscape))
        #expect(plan.metrics.keySpacing == spacing)
        #expect(abs(plan.metrics.keyboardWidth - 1366) < 0.001)
    }

    @Test func aBarelyWideEnoughContainerStillGetsAGap() {
        let screen = CGSize(width: 700, height: 400)
        let plan = KeyboardLayoutPlan.resolve(inputs(numpad: .trailing, split: true, container: 700, screen: screen))
        #expect(plan.isSplit)
        let cells = GridLayoutSolver.solve(plan.arrangement)
        let lettersEnd = cells.filter { $0.keyId == GridSlot.topRight }.map { $0.column + $0.columnSpan }.max() ?? 0
        let numpad = cells.first { $0.keyId == "numpad0" }?.column ?? 0
        #expect(numpad > lettersEnd)
    }
}

/// The two idiom defaults, read without a simulated screen by computing them
/// the way `DeviceLayout.defaultKeyboardWidth` does.
@MainActor
private enum DeviceLayoutDefaults {
    static var phone: Double {
        let saved = UIDevice.simulatedIdiom
        defer { UIDevice.simulatedIdiom = saved }
        UIDevice.simulatedIdiom = .phone
        return DeviceLayout.defaultKeyboardWidth
    }

    static var ipad: Double {
        let saved = UIDevice.simulatedIdiom
        defer { UIDevice.simulatedIdiom = saved }
        UIDevice.simulatedIdiom = .pad
        return DeviceLayout.defaultKeyboardWidth
    }
}
