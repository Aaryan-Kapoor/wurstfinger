//
//  LongSwipeSettingsView.swift
//  wurstfinger
//
//  Long swipes (issue #79): a flick that travels well past its key fires a
//  global action chosen per direction. Reached from the Expert screen.
//

import SwiftUI

struct LongSwipeSettingsView: View {
    @AppStorage(SettingsKey.isLongSwipeEnabled.rawValue, store: SharedDefaults.store)
    private var isLongSwipeEnabled = false

    @AppStorage(SettingsKey.longSwipeThreshold.rawValue, store: SharedDefaults.store)
    private var threshold = Double(LongSwipeConfiguration.defaultThreshold)

    var body: some View {
        Form {
            Section {
                Toggle("Enable Long Swipes", isOn: $isLongSwipeEnabled)
            } footer: {
                Text("Swipe a key farther than the distance below to run one of these actions instead of the key's own swipe. The trail changes color when letting go would run it.")
            }

            if isLongSwipeEnabled {
                Section {
                    HStack {
                        Slider(value: $threshold, in: LongSwipeConfiguration.thresholdRange, step: 0.1)
                        Text(verbatim: String(format: "%.1f×", clampedThreshold))
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                            .frame(minWidth: 44, alignment: .trailing)
                    }
                } header: {
                    Text("Distance")
                } footer: {
                    Text("Measured in key sizes: 1.5 means a swipe one and a half keys long.")
                }

                Section {
                    ForEach(LongSwipeConfiguration.directions, id: \.self) { direction in
                        LongSwipeActionPicker(direction: direction)
                    }
                } header: {
                    Text("Actions")
                }
            }
        }
        .navigationTitle("Long Swipes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Reset") { reset() }
            }
        }
    }

    private var clampedThreshold: Double {
        min(max(threshold, LongSwipeConfiguration.thresholdRange.lowerBound), LongSwipeConfiguration.thresholdRange.upperBound)
    }

    private func reset() {
        threshold = Double(LongSwipeConfiguration.defaultThreshold)
        for direction in LongSwipeConfiguration.directions {
            if let key = LongSwipeConfiguration.settingsKey(for: direction) {
                SharedDefaults.store.removeObject(forKey: key.rawValue)
            }
        }
    }
}

/// One direction's row: a picker over every `LongSwipeAction`.
private struct LongSwipeActionPicker: View {
    let direction: GestureType

    @AppStorage private var choiceRaw: String

    init(direction: GestureType) {
        self.direction = direction
        let key = LongSwipeConfiguration.settingsKey(for: direction)?.rawValue ?? "longSwipe.\(direction.rawValue)"
        let fallback = LongSwipeConfiguration.defaultChoices[direction] ?? .none
        _choiceRaw = AppStorage(wrappedValue: fallback.rawValue, key, store: SharedDefaults.store)
    }

    var body: some View {
        Picker(selection: $choiceRaw) {
            ForEach(LongSwipeAction.allCases, id: \.rawValue) { action in
                Text(action.displayName).tag(action.rawValue)
            }
        } label: {
            Label(directionName, systemImage: arrow)
        }
    }

    private var directionName: LocalizedStringKey {
        switch direction {
        case .swipeUp: "Up"
        case .swipeDown: "Down"
        case .swipeLeft: "Left"
        case .swipeRight: "Right"
        case .swipeUpLeft: "longSwipe.upLeft"
        case .swipeUpRight: "longSwipe.upRight"
        case .swipeDownLeft: "longSwipe.downLeft"
        case .swipeDownRight: "longSwipe.downRight"
        default: ""
        }
    }

    private var arrow: String {
        switch direction {
        case .swipeUp: "arrow.up"
        case .swipeDown: "arrow.down"
        case .swipeLeft: "arrow.left"
        case .swipeRight: "arrow.right"
        case .swipeUpLeft: "arrow.up.left"
        case .swipeUpRight: "arrow.up.right"
        case .swipeDownLeft: "arrow.down.left"
        case .swipeDownRight: "arrow.down.right"
        default: "questionmark"
        }
    }
}

extension LongSwipeAction {
    /// What the settings screen calls this choice. Lives here, next to the
    /// screen, and not with the enum: the strings are host-app only, and the
    /// enum is compiled into the keyboard extension too (see
    /// `docs/localization.md`).
    var displayName: String {
        switch self {
        case .none: String(localized: "None")
        case .escape: String(localized: "Escape")
        case .tab: String(localized: "Tab")
        case .backTab: String(localized: "Shift-Tab")
        case .newline: String(localized: "New line")
        case .space: String(localized: "Space")
        case .deleteBackward: String(localized: "Delete")
        case .deleteWordBackward: String(localized: "Delete word")
        case .deleteWordForward: String(localized: "Delete word ahead")
        case .lineUp: String(localized: "Line up")
        case .lineDown: String(localized: "Line down")
        case .shiftOn: String(localized: "Shift")
        case .shiftOff: String(localized: "Lowercase")
        case .control: String(localized: "Ctrl")
        case .alt: String(localized: "Alt")
        case .lineStart: String(localized: "Line start")
        case .lineEnd: String(localized: "Line end")
        case .documentStart: String(localized: "Document start")
        case .documentEnd: String(localized: "Document end")
        case .dismissKeyboard: String(localized: "Hide keyboard")
        }
    }
}

#if !WURSTFINGER_NO_PREVIEWS
#Preview {
    NavigationStack {
        LongSwipeSettingsView()
    }
}
#endif
