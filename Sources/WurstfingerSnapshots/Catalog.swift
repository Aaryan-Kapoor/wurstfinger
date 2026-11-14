//
//  Catalog.swift
//  WurstfingerSnapshots
//
//  The scenarios: which pictures the tool takes.
//

import SwiftUI
@testable import WurstfingerKit
@testable import WurstfingerScenarioKit

/// One PNG the tool can produce. The shot is built lazily, so listing the
/// scenarios costs nothing.
struct Scenario {
    var group: String
    var name: String
    var make: @MainActor () -> Shot

    var fileName: String { "\(name).png" }
}

@MainActor
enum Catalog {
    static func all() -> [Scenario] {
        modes() + languages() + layouts() + optimized() + devices() + variants() + layoutOptions() + states() + feel() + typing() + completions() + surfaces()
    }

    private static func keyboard(
        _ group: String, _ name: String, _ configure: @escaping (inout KeyboardSpec) -> Void = { _ in }
    ) -> Scenario {
        Scenario(group: group, name: name) {
            var spec = KeyboardSpec()
            configure(&spec)
            return KeyboardShot.make(spec)
        }
    }

    private static func suffix(_ scheme: ColorScheme) -> String { scheme == .dark ? "-dark" : "" }

    // MARK: 1. Modes x appearance

    private static func modes() -> [Scenario] {
        let english = KeyboardRegistry.load(id: "en_US")
        let names = (english?.modes.keys.sorted() ?? [])
        var scenarios: [Scenario] = []
        for mode in names {
            for scheme in [ColorScheme.light, .dark] {
                scenarios.append(keyboard("modes", "modes-\(mode)\(suffix(scheme))") {
                    $0.mode = mode
                    $0.scheme = scheme
                })
            }
        }
        return scenarios
    }

    // MARK: 2. Every language

    private static func languages() -> [Scenario] {
        KeyboardRegistry.available.map { language in
            keyboard("languages", "lang-\(language.id)") {
                $0.language = language.id
                // Two enabled languages, so the globe key shows its label.
                $0.enabledLanguages = [language.id, language.id == "en_US" ? "de_DE" : "en_US"]
            }
        }
    }

    // MARK: 2b. Thumb-Key and custom layouts

    private static func layouts() -> [Scenario] {
        var scenarios: [Scenario] = []
        for scheme in [ColorScheme.light, .dark] {
            let tail = suffix(scheme)
            scenarios.append(keyboard("layouts", "layout-thumbkey\(tail)") {
                $0.language = "en_US_thumbkey"
                $0.scheme = scheme
            })
            scenarios.append(keyboard("layouts", "layout-thumbkey-shifted\(tail)") {
                $0.language = "en_US_thumbkey"
                $0.mode = ModeNames.shifted
                $0.scheme = scheme
            })
            scenarios.append(keyboard("layouts", "layout-custom\(tail)") {
                $0.customLayouts = [LayoutSurfaces.sampleLayout()]
                $0.language = LayoutSurfaces.sampleLayout().id
                $0.enabledLanguages = ["en_US", LayoutSurfaces.sampleLayout().id]
                $0.scheme = scheme
            })
            scenarios.append(Scenario(group: "layouts", name: "layout-list\(tail)") {
                LayoutSurfaces.list(scheme: scheme)
            })
            scenarios.append(Scenario(group: "layouts", name: "layout-editor\(tail)") {
                LayoutSurfaces.editor(scheme: scheme)
            })
            scenarios.append(Scenario(group: "layouts", name: "layout-key-sheet\(tail)") {
                LayoutSurfaces.keySheet(scheme: scheme)
            })
        }
        scenarios.append(Scenario(group: "layouts", name: "layout-editor-problem") {
            LayoutSurfaces.editorWithProblem(scheme: .light)
        })
        scenarios.append(Scenario(group: "layouts", name: "layout-languages") {
            LayoutSurfaces.languages(scheme: .light)
        })
        scenarios.append(keyboard("layouts", "layout-custom-typing") {
            $0.customLayouts = [LayoutSurfaces.sampleLayout()]
            $0.language = LayoutSurfaces.sampleLayout().id
            $0.typedText = "Süße Straße"
        })
        return scenarios
    }

    // MARK: 2c. English (Optimized)

    /// The measured English layout next to the language sweep's plain shot: its
    /// hints in both appearances, the shifted mode (the four moved letters in
    /// capitals), and a sentence typed through the real engine.
    private static func optimized() -> [Scenario] {
        let id = "en_US_optimized"
        return [
            keyboard("optimized", "optimized-main") { $0.language = id },
            keyboard("optimized", "optimized-main-dark") {
                $0.language = id
                $0.scheme = .dark
            },
            keyboard("optimized", "optimized-shifted") {
                $0.language = id
                $0.mode = ModeNames.shifted
            },
            keyboard("optimized", "optimized-typing") {
                $0.language = id
                $0.typedText = "Hello, Hazel! Zeal aside, a lazy hill."
            },
            keyboard("optimized", "optimized-two-english-layouts") {
                $0.language = id
                $0.enabledLanguages = ["en_US", id]
            },
        ]
    }

    // MARK: 3. Widths and devices

    private static func devices() -> [Scenario] {
        var scenarios: [Scenario] = []
        for device in Device.widthSeries {
            scenarios.append(keyboard("devices", "device-\(device.name)") { $0.device = device })
            // The stock width wish (270 / 320 pt) leaves a wide device mostly
            // empty; the same device with the keyboard as wide as it may be.
            scenarios.append(keyboard("devices", "device-\(device.name)-wide") {
                $0.device = device
                $0.widthWish = min(Double(device.width), 600)
            })
        }
        return scenarios
    }

    // MARK: 3b. Numpad column, key spacing, iPad and split

    private static func layoutOptions() -> [Scenario] {
        var scenarios: [Scenario] = []
        // The numpad column on each side, light and dark, in a layout with Latin
        // digits and in the three native-numeral scripts.
        for placement in [NumpadColumnPlacement.leading, .trailing] {
            for scheme in [ColorScheme.light, .dark] {
                scenarios.append(keyboard("layout", "numpad-\(placement.rawValue)\(suffix(scheme))") {
                    $0.numpadColumn = placement
                    $0.scheme = scheme
                })
            }
            for language in ["ar", "hi_IN", "th_TH", "de_DE", "ru_RU"] {
                scenarios.append(keyboard("layout", "numpad-\(placement.rawValue)-\(language)") {
                    $0.numpadColumn = placement
                    $0.language = language
                })
            }
            scenarios.append(keyboard("layout", "numpad-\(placement.rawValue)-classic") {
                $0.numpadColumn = placement
                $0.numpadStyle = .classic
            })
            scenarios.append(keyboard("layout", "numpad-\(placement.rawValue)-utility-left") {
                $0.numpadColumn = placement
                $0.utilityColumnLeading = true
            })
            scenarios.append(keyboard("layout", "numpad-\(placement.rawValue)-numeric-mode") {
                $0.numpadColumn = placement
                $0.mode = ModeNames.numeric
            })
            scenarios.append(keyboard("layout", "numpad-\(placement.rawValue)-shifted") {
                $0.numpadColumn = placement
                $0.mode = ModeNames.shifted
            })
        }
        scenarios.append(keyboard("layout", "numpad-trailing-liquidglass") {
            $0.numpadColumn = .trailing
            $0.style = .liquidGlass
            $0.backdrop = .colorful
        })
        scenarios.append(keyboard("layout", "numpad-narrow-iphone-se") {
            $0.numpadColumn = .trailing
            $0.device = .iPhoneSE
        })
        scenarios.append(keyboard("layout", "numpad-hide-labels") {
            $0.numpadColumn = .trailing
            $0.hideLetters = true
            $0.hideStandardSymbols = true
            $0.hideExtraSymbols = true
        })
        // The guide card on a numpad key: beside it on the top row, above it
        // lower down, with the digit the finger is heading for lit.
        scenarios.append(keyboard("layout", "numpad-guide-top") {
            $0.numpadColumn = .trailing
            $0.finger = FingerTrail(keyId: NumpadColumn.keyIds[0], motion: .drag(.swipeRight, keyWidths: 0.5), paused: true)
        })
        scenarios.append(keyboard("layout", "numpad-guide-middle") {
            $0.numpadColumn = .leading
            $0.finger = FingerTrail(keyId: NumpadColumn.keyIds[1], motion: .drag(.swipeLeft, keyWidths: 0.5), paused: true)
        })
        scenarios.append(keyboard("layout", "numpad-guide-symbol") {
            $0.numpadColumn = .trailing
            $0.finger = FingerTrail(keyId: NumpadColumn.keyIds[2], motion: .drag(.swipeUpRight, keyWidths: 0.5))
        })
        scenarios.append(keyboard("layout", "numpad-typing") {
            $0.numpadColumn = .trailing
            $0.typedText = "Total: 1,250.00 + 3"
        })

        // Key spacing at both ends and the shipped value, with and without
        // the numpad column.
        for spacing in [0.0, 5.0, 12.0] {
            scenarios.append(keyboard("layout", "spacing-\(Int(spacing))") { $0.keySpacing = spacing })
            scenarios.append(keyboard("layout", "spacing-\(Int(spacing))-dark") {
                $0.keySpacing = spacing
                $0.scheme = .dark
            })
            scenarios.append(keyboard("layout", "spacing-\(Int(spacing))-numpad") {
                $0.keySpacing = spacing
                $0.numpadColumn = .trailing
            })
        }
        scenarios.append(keyboard("layout", "spacing-12-guide") {
            $0.keySpacing = 12
            $0.finger = FingerTrail(keyId: GridSlot.center, motion: .drag(.swipeUpRight, keyWidths: 0.5), paused: true)
        })

        // Every iPad width with the numpad column, and the split in landscape.
        for device in [Device.iPadMini, .iPadAir, .iPadPro, .iPadLandscape] {
            scenarios.append(keyboard("layout", "ipad-numpad-\(device.name)") {
                $0.device = device
                $0.numpadColumn = .trailing
            })
        }
        for device in [Device.iPadLandscape, .iPhoneLandscape] {
            scenarios.append(keyboard("layout", "split-\(device.name)") {
                $0.device = device
                $0.isSplit = true
            })
            scenarios.append(keyboard("layout", "split-numpad-\(device.name)") {
                $0.device = device
                $0.isSplit = true
                $0.numpadColumn = .trailing
            })
            scenarios.append(keyboard("layout", "split-numpad-utility-left-\(device.name)") {
                $0.device = device
                $0.isSplit = true
                $0.numpadColumn = .trailing
                $0.utilityColumnLeading = true
            })
        }
        scenarios.append(keyboard("layout", "split-numpad-ipad-landscape-dark") {
            $0.device = .iPadLandscape
            $0.isSplit = true
            $0.numpadColumn = .trailing
            $0.scheme = .dark
        })
        scenarios.append(keyboard("layout", "split-numpad-ipad-landscape-wide-keys") {
            $0.device = .iPadLandscape
            $0.isSplit = true
            $0.numpadColumn = .trailing
            $0.widthWish = 520
        })
        scenarios.append(keyboard("layout", "split-numeric-ipad-landscape") {
            $0.device = .iPadLandscape
            $0.isSplit = true
            $0.numpadColumn = .trailing
            $0.mode = ModeNames.numeric
        })
        scenarios.append(keyboard("layout", "split-guide-ipad-landscape") {
            $0.device = .iPadLandscape
            $0.isSplit = true
            $0.numpadColumn = .trailing
            $0.finger = FingerTrail(keyId: GridSlot.topLeft, motion: .drag(.swipeDown, keyWidths: 0.5), paused: true)
        })
        scenarios.append(keyboard("layout", "split-guide-numpad-ipad-landscape") {
            $0.device = .iPadLandscape
            $0.isSplit = true
            $0.numpadColumn = .trailing
            $0.finger = FingerTrail(keyId: NumpadColumn.keyIds[0], motion: .drag(.swipeRight, keyWidths: 0.5), paused: true)
        })
        // Split asked for on a screen it does not apply to: iPad portrait.
        scenarios.append(keyboard("layout", "split-ignored-ipad-portrait") {
            $0.device = .iPadAir
            $0.isSplit = true
        })
        // A floating iPad keyboard (~320 pt) with the numpad column.
        scenarios.append(keyboard("layout", "ipad-floating-numpad") {
            $0.device = Device(name: "ipad-floating-320", size: CGSize(width: 320, height: 1024), isPad: true)
            $0.numpadColumn = .trailing
        })
        return scenarios
    }

    // MARK: 4. Settings variants

    private static func variants() -> [Scenario] {
        var scenarios: [Scenario] = []
        scenarios.append(keyboard("variants", "variant-style-classic") { $0.style = .classic })
        scenarios.append(keyboard("variants", "variant-style-classic-dark") {
            $0.style = .classic
            $0.scheme = .dark
        })
        scenarios.append(keyboard("variants", "variant-style-liquidglass") {
            $0.style = .liquidGlass
            $0.backdrop = .colorful
        })
        scenarios.append(keyboard("variants", "variant-style-liquidglass-dark") {
            $0.style = .liquidGlass
            $0.backdrop = .colorful
            $0.scheme = .dark
        })
        scenarios.append(keyboard("variants", "variant-utility-trailing") { $0.utilityColumnLeading = false })
        scenarios.append(keyboard("variants", "variant-utility-leading") { $0.utilityColumnLeading = true })
        scenarios.append(keyboard("variants", "variant-hide-letters") { $0.hideLetters = true })
        scenarios.append(keyboard("variants", "variant-hide-standard-symbols") { $0.hideStandardSymbols = true })
        scenarios.append(keyboard("variants", "variant-hide-extra-symbols") { $0.hideExtraSymbols = true })
        scenarios.append(keyboard("variants", "variant-hide-all-labels") {
            $0.hideLetters = true
            $0.hideStandardSymbols = true
            $0.hideExtraSymbols = true
        })
        // The aspect ratio setting runs from 1.0 (square) to 1.62; anything
        // below 1.0 is clamped to square, so 0.7 would repeat 1.0.
        for ratio in [1.0, 1.2, 1.4, 1.62] {
            scenarios.append(keyboard("variants", "variant-aspect-\(String(format: "%.2f", ratio))") {
                $0.keyAspectRatio = ratio
            })
        }
        scenarios.append(keyboard("variants", "variant-longpress-digits") { $0.longPressDigits = true })
        scenarios.append(keyboard("variants", "variant-width-compact") { $0.widthWish = 200 })
        scenarios.append(keyboard("variants", "variant-width-full") { $0.widthWish = 600 })
        return scenarios
    }

    // MARK: 5. Interaction states

    private static func states() -> [Scenario] {
        var scenarios: [Scenario] = []
        for scheme in [ColorScheme.light, .dark] {
            let tail = suffix(scheme)
            scenarios.append(keyboard("states", "state-pressed-center\(tail)") {
                $0.scheme = scheme
                $0.pressedKeys = [GridSlot.center]
            })
            scenarios.append(keyboard("states", "state-pressed-topleft\(tail)") {
                $0.scheme = scheme
                $0.pressedKeys = [GridSlot.topLeft]
            })
            scenarios.append(keyboard("states", "state-flick-upright\(tail)") {
                $0.scheme = scheme
                $0.finger = FingerTrail(keyId: GridSlot.center, motion: .drag(.swipeUpRight, keyWidths: 0.6))
            })
        }
        for scheme in [ColorScheme.light, .dark] {
            let tail = suffix(scheme)
            scenarios.append(keyboard("guide", "guide-flick-right\(tail)") {
                $0.scheme = scheme
                $0.finger = FingerTrail(keyId: GridSlot.center, motion: .drag(.swipeRight, keyWidths: 0.5))
            })
            scenarios.append(keyboard("guide", "guide-paused-center\(tail)") {
                $0.scheme = scheme
                $0.finger = FingerTrail(keyId: GridSlot.center, motion: .press, paused: true)
            })
        }
        scenarios.append(keyboard("guide", "guide-paused-heading-downleft") {
            $0.finger = FingerTrail(keyId: GridSlot.midRight, motion: .drag(.swipeDownLeft, keyWidths: 0.45), paused: true)
        })
        scenarios.append(keyboard("guide", "guide-top-row-beside") {
            $0.finger = FingerTrail(keyId: GridSlot.topLeft, motion: .drag(.swipeDown, keyWidths: 0.5), paused: true)
        })
        scenarios.append(keyboard("guide", "guide-return-swipe") {
            $0.finger = FingerTrail(keyId: GridSlot.center, motion: .returnSwipe(.swipeUp, keyWidths: 0.8))
        })
        scenarios.append(keyboard("guide", "guide-circle") {
            $0.finger = FingerTrail(keyId: GridSlot.center, motion: .circle(clockwise: true, fraction: 0.95))
        })
        scenarios.append(keyboard("guide", "guide-shifted") {
            $0.mode = ModeNames.shifted
            $0.finger = FingerTrail(keyId: GridSlot.bottomRight, motion: .drag(.swipeUp, keyWidths: 0.5))
        })
        scenarios.append(keyboard("guide", "guide-ipad") {
            $0.device = .iPadLandscape
            $0.finger = FingerTrail(keyId: GridSlot.center, motion: .drag(.swipeUpLeft, keyWidths: 0.4), paused: true)
        })
        scenarios.append(keyboard("states", "state-press-dot") {
            $0.finger = FingerTrail(keyId: GridSlot.midRight, motion: .press)
        })
        scenarios.append(keyboard("states", "state-flick-down") {
            $0.finger = FingerTrail(keyId: GridSlot.topLeft, motion: .drag(.swipeDown, keyWidths: 0.7))
        })
        scenarios.append(keyboard("states", "state-circle-clockwise") {
            $0.finger = FingerTrail(keyId: GridSlot.center, motion: .circle(clockwise: true, fraction: 0.8))
        })
        scenarios.append(keyboard("states", "state-circle-counterclockwise") {
            $0.finger = FingerTrail(keyId: GridSlot.center, motion: .circle(clockwise: false, fraction: 0.8))
        })
        scenarios.append(keyboard("states", "state-return-swipe") {
            $0.finger = FingerTrail(keyId: GridSlot.center, motion: .returnSwipe(.swipeUpRight, keyWidths: 0.8))
        })
        scenarios.append(keyboard("states", "state-flick-wide-keys") {
            $0.keyAspectRatio = 1.4
            $0.finger = FingerTrail(keyId: GridSlot.center, motion: .drag(.swipeUpRight, keyWidths: 0.6))
        })
        // Long swipes: the trail keeps its grey until the finger is far enough
        // that letting go would fire one, then turns to the accent colour.
        for scheme in [ColorScheme.light, .dark] {
            let tail = suffix(scheme)
            scenarios.append(keyboard("states", "state-longswipe-short\(tail)") {
                $0.scheme = scheme
                $0.finger = FingerTrail(
                    keyId: GridSlot.center, motion: .drag(.swipeRight, keyWidths: 1.0), longSwipes: true
                )
            })
            scenarios.append(keyboard("states", "state-longswipe-armed\(tail)") {
                $0.scheme = scheme
                $0.finger = FingerTrail(
                    keyId: GridSlot.center, motion: .drag(.swipeRight, keyWidths: 2.0), longSwipes: true
                )
            })
        }
        scenarios.append(keyboard("states", "state-longswipe-armed-diagonal") {
            $0.finger = FingerTrail(
                keyId: GridSlot.center, motion: .drag(.swipeUpLeft, keyWidths: 2.0), longSwipes: true
            )
        })
        // Circle behaviours: the guide card shows what the circle will type.
        scenarios.append(keyboard("states", "state-circle-digit") {
            $0.circles = (.digit, .uppercaseWord)
            $0.finger = FingerTrail(keyId: GridSlot.topLeft, motion: .circle(clockwise: true, fraction: 0.8))
        })
        scenarios.append(keyboard("states", "state-circle-word") {
            $0.circles = (.digit, .uppercaseWord)
            $0.finger = FingerTrail(keyId: GridSlot.topLeft, motion: .circle(clockwise: false, fraction: 0.8))
        })
        scenarios.append(keyboard("states", "state-flick-liquidglass") {
            $0.style = .liquidGlass
            $0.backdrop = .colorful
            $0.finger = FingerTrail(keyId: GridSlot.center, motion: .drag(.swipeUpRight, keyWidths: 0.6))
        })
        return scenarios
    }

    // MARK: Feel (press light, ripple, pops, ring, ratchet, trail ink)

    private static func feel() -> [Scenario] {
        var scenarios: [Scenario] = []
        // A press off-centre, so the light visibly starts at the finger.
        let press = FingerTrail(keyId: GridSlot.center, motion: .press, touchOffset: CGVector(dx: -0.2, dy: -0.16))
        for scheme in [ColorScheme.light, .dark] {
            let tail = suffix(scheme)
            scenarios.append(keyboard("feel", "feel-press-classic\(tail)") {
                $0.scheme = scheme
                $0.finger = press
                $0.showsTrail = false
            })
            scenarios.append(keyboard("feel", "feel-press-glass\(tail)") {
                $0.scheme = scheme
                $0.style = .liquidGlass
                $0.backdrop = .colorful
                $0.finger = press
                $0.showsTrail = false
            })
            scenarios.append(keyboard("feel", "feel-press-glass-fallback\(tail)") {
                $0.scheme = scheme
                $0.style = .liquidGlass
                $0.backdrop = .colorful
                $0.finger = press
                $0.showsTrail = false
                $0.withoutShaders = true
            })
            scenarios.append(keyboard("feel", "feel-ripple-glass\(tail)") {
                $0.scheme = scheme
                $0.style = .liquidGlass
                $0.backdrop = .colorful
                $0.finger = press
                $0.showsTrail = false
                $0.feelStill = 0.3
            })
            scenarios.append(keyboard("feel", "feel-pop-swipe\(tail)") {
                $0.scheme = scheme
                $0.finger = FingerTrail(
                    keyId: GridSlot.center, motion: .drag(.swipeUpRight, keyWidths: 0.6), lifts: true
                )
                $0.showsTrail = false
                $0.feelStill = 0.35
            })
            scenarios.append(keyboard("feel", "feel-longpress-ring\(tail)") {
                $0.scheme = scheme
                $0.longPressDigits = true
                $0.finger = FingerTrail(keyId: GridSlot.center, motion: .press)
                $0.showsTrail = false
                $0.feelStill = 0.62
            })
            scenarios.append(keyboard("feel", "feel-longpress-capitals\(tail)") {
                $0.scheme = scheme
                $0.longPress = .capitals
                $0.finger = FingerTrail(keyId: GridSlot.center, motion: .press)
                $0.showsTrail = false
                $0.feelStill = 0.62
            })
            scenarios.append(keyboard("feel", "feel-slide-cursor\(tail)") {
                $0.scheme = scheme
                $0.slide = (UtilitySlot.space, 3)
            })
            scenarios.append(keyboard("feel", "feel-trail-fast\(tail)") {
                $0.scheme = scheme
                $0.finger = FingerTrail(
                    keyId: GridSlot.midLeft, motion: .drag(.swipeRight, keyWidths: 1.6), dragSpeed: 1600
                )
            })
        }
        scenarios.append(keyboard("feel", "feel-press-glass-reducetransparency") {
            $0.style = .liquidGlass
            $0.backdrop = .colorful
            $0.finger = press
            $0.showsTrail = false
            $0.reduceTransparency = true
        })
        scenarios.append(keyboard("feel", "feel-press-reducemotion") {
            $0.finger = press
            $0.showsTrail = false
            $0.reduceMotion = true
        })
        scenarios.append(keyboard("feel", "feel-press-animations-off") {
            $0.finger = press
            $0.showsTrail = false
            $0.keyAnimations = false
        })
        scenarios.append(keyboard("feel", "feel-pop-longpress") {
            $0.longPressDigits = true
            $0.finger = FingerTrail(keyId: GridSlot.midRight, motion: .press, firesLongPress: true)
            $0.showsTrail = false
            $0.feelStill = 0.3
        })
        scenarios.append(keyboard("feel", "feel-pop-circle") {
            $0.finger = FingerTrail(
                keyId: GridSlot.midLeft, motion: .circle(clockwise: true, fraction: 1), lifts: true
            )
            $0.showsTrail = false
            $0.feelStill = 0.25
        })
        scenarios.append(keyboard("feel", "feel-pop-swipe-reducemotion") {
            $0.finger = FingerTrail(
                keyId: GridSlot.center, motion: .drag(.swipeUpRight, keyWidths: 0.6), lifts: true
            )
            $0.showsTrail = false
            $0.feelStill = 0.35
            $0.reduceMotion = true
        })
        scenarios.append(keyboard("feel", "feel-pop-longswipe") {
            $0.finger = FingerTrail(
                keyId: GridSlot.center, motion: .drag(.swipeLeft, keyWidths: 2.0), longSwipes: true, lifts: true
            )
            $0.showsTrail = false
            $0.feelStill = 0.3
        })
        scenarios.append(keyboard("feel", "feel-longpress-ring-glass") {
            $0.style = .liquidGlass
            $0.backdrop = .colorful
            $0.longPressDigits = true
            $0.finger = FingerTrail(keyId: GridSlot.topLeft, motion: .press)
            $0.showsTrail = false
            $0.feelStill = 0.35
        })
        scenarios.append(keyboard("feel", "feel-slide-delete") {
            $0.slide = (UtilitySlot.delete, -4)
        })
        scenarios.append(keyboard("feel", "feel-trail-slow") {
            $0.finger = FingerTrail(
                keyId: GridSlot.midLeft, motion: .drag(.swipeRight, keyWidths: 1.6), dragSpeed: 200
            )
        })
        scenarios.append(keyboard("feel", "feel-trail-armed-dark") {
            $0.scheme = .dark
            $0.finger = FingerTrail(
                keyId: GridSlot.center, motion: .drag(.swipeRight, keyWidths: 2.0), longSwipes: true
            )
        })
        scenarios.append(keyboard("feel", "feel-trail-fallback-dark") {
            $0.scheme = .dark
            $0.withoutShaders = true
            $0.finger = FingerTrail(
                keyId: GridSlot.midLeft, motion: .drag(.swipeRight, keyWidths: 1.6), dragSpeed: 1600
            )
        })
        return scenarios
    }

    // MARK: Typing

    private static func typing() -> [Scenario] {
        [
            keyboard("typing", "typing-en-hello") {
                $0.typedText = "Hello, World!"
            },
            keyboard("typing", "typing-en-hello-dark") {
                $0.typedText = "Hello, World!"
                $0.scheme = .dark
            },
            keyboard("typing", "typing-de-umlauts") {
                $0.language = "de_DE"
                $0.typedText = "Schöne Grüße aus Köln"
            },
            keyboard("typing", "typing-ru") {
                $0.language = "ru_RU"
                $0.typedText = "Привет, мир"
            },
        ]
    }

    // MARK: Word completions

    /// The row above the keys: in both appearances and both styles, with one,
    /// two and three completions, one pressed, a long word, other languages and
    /// scripts (German, Arabic right to left), no completions, a sensitive field.
    private static func completions() -> [Scenario] {
        let hello = ["hello", "help", "helpful"]
        var scenarios: [Scenario] = []
        for scheme in [ColorScheme.light, .dark] {
            let tail = suffix(scheme)
            scenarios.append(keyboard("completions", "completions-classic\(tail)") {
                $0.typedText = "Say hel"
                $0.completionWords = hello
                $0.scheme = scheme
            })
            scenarios.append(keyboard("completions", "completions-glass\(tail)") {
                $0.typedText = "Say hel"
                $0.completionWords = hello
                $0.style = .liquidGlass
                $0.backdrop = .colorful
                $0.scheme = scheme
            })
            scenarios.append(keyboard("completions", "completions-pressed\(tail)") {
                $0.typedText = "Say hel"
                $0.completionWords = hello
                $0.pressedCompletion = 1
                $0.scheme = scheme
            })
        }
        scenarios.append(keyboard("completions", "completions-one") {
            $0.typedText = "Please read the helpf"
            $0.completionWords = ["helpful"]
        })
        scenarios.append(keyboard("completions", "completions-two") {
            $0.typedText = "Say hel"
            $0.completionWords = ["hello", "help"]
        })
        scenarios.append(keyboard("completions", "completions-long-words") {
            $0.typedText = "internat"
            $0.completionWords = ["internationalization", "international", "internationally"]
        })
        scenarios.append(keyboard("completions", "completions-empty") {
            $0.typedText = "Say "
            $0.completionWords = []
        })
        scenarios.append(keyboard("completions", "completions-german") {
            $0.language = "de_DE"
            $0.typedText = "Guten Tag, ich komm"
            $0.completionWords = ["kommen", "komme", "kommt"]
        })
        scenarios.append(keyboard("completions", "completions-arabic") {
            $0.language = "ar"
            $0.typedText = "مر"
            $0.completionWords = ["مرحبا", "مركز", "مرة"]
        })
        scenarios.append(keyboard("completions", "completions-hebrew-dark") {
            $0.language = "he_IL"
            $0.typedText = "של"
            $0.completionWords = ["שלום", "שלושה", "שלמה"]
            $0.scheme = .dark
        })
        scenarios.append(keyboard("completions", "completions-sensitive-field") {
            $0.typedText = "hel"
            $0.completionWords = hello
            $0.isSensitiveField = true
        })
        scenarios.append(keyboard("completions", "completions-finger-on-space") {
            $0.typedText = "Say hel"
            $0.completionWords = hello
            $0.finger = FingerTrail(keyId: UtilitySlot.space, motion: .press)
        })
        scenarios.append(keyboard("completions", "completions-ipad") {
            $0.device = .iPadLandscape
            $0.typedText = "Say hel"
            $0.completionWords = hello
        })
        return scenarios
    }

    // MARK: 6. App surfaces

    private static func surfaces() -> [Scenario] {
        var scenarios: [Scenario] = []
        for scheme in [ColorScheme.light, .dark] {
            let tail = suffix(scheme)
            for device in [Device.appStore69, .appStore65] {
                scenarios.append(Scenario(group: "app", name: "app-appstore-\(device.name)\(tail)") {
                    AppSurfaces.appStore(device: device, scheme: scheme)
                })
                scenarios.append(Scenario(group: "app", name: "app-showcase-\(device.name)\(tail)") {
                    AppSurfaces.showcase(device: device, scheme: scheme)
                })
            }
            scenarios.append(Scenario(group: "app", name: "app-settings\(tail)") {
                AppSurfaces.settings(scheme: scheme)
            })
            scenarios.append(Scenario(group: "app", name: "app-textreplacement\(tail)") {
                AppSurfaces.textReplacement(scheme: scheme)
            })
            scenarios.append(Scenario(group: "app", name: "app-settings-capitals\(tail)") {
                AppSurfaces.settings(scheme: scheme, longPress: .capitals)
            })
            scenarios.append(Scenario(group: "app", name: "app-circles\(tail)") {
                AppSurfaces.circles(scheme: scheme)
            })
            scenarios.append(Scenario(group: "app", name: "app-longswipes\(tail)") {
                AppSurfaces.longSwipes(scheme: scheme)
            })
            scenarios.append(Scenario(group: "app", name: "app-haptics\(tail)") {
                AppSurfaces.haptics(scheme: scheme)
            })
            scenarios.append(Scenario(group: "app", name: "app-style\(tail)") {
                AppSurfaces.style(scheme: scheme)
            })
            scenarios.append(Scenario(group: "app", name: "app-wordsuggestions\(tail)") {
                AppSurfaces.wordSuggestions(scheme: scheme)
            })
            if scheme == .light {
                scenarios.append(Scenario(group: "app", name: "app-textreplacement-empty") {
                    AppSurfaces.textReplacement(scheme: .light, isEmpty: true)
                })
            }
        }
        return scenarios
    }
}
