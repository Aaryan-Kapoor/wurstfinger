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
        modes() + languages() + layouts() + devices() + variants() + states() + typing() + surfaces()
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
        scenarios.append(keyboard("states", "state-flick-liquidglass") {
            $0.style = .liquidGlass
            $0.backdrop = .colorful
            $0.finger = FingerTrail(keyId: GridSlot.center, motion: .drag(.swipeUpRight, keyWidths: 0.6))
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
        }
        return scenarios
    }
}
