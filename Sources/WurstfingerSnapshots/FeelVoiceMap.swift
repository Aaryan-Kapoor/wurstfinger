//
//  FeelVoiceMap.swift
//  WurstfingerSnapshots
//
//  A diagram of the derived voices: every key of a mode in its place, with the
//  note, instrument and haptic intensity/sharpness its touch-down plays.
//

import SwiftUI
@testable import WurstfingerKit
@testable import WurstfingerScenarioKit

@MainActor
enum FeelVoiceMap {
    /// The voice map of `mode` in `language`, at the iPhone 15's width.
    static func make(language: String = "en_US", mode: String = ModeNames.main, scheme: ColorScheme = .light) -> Shot {
        ScenarioEnvironment.reset()
        let scenario = KeyboardScenario(language: language, containerWidth: Device.iPhone15.width, autoCapitalize: false)
        let viewModel = scenario.viewModel
        viewModel.switchToMode(mode)
        viewModel.configureTouchEngine(containerWidth: Device.iPhone15.width, isLongPressEnabled: false)
        let hitMap = viewModel.touchEngine.hitMap
        let keys = viewModel.activeModeFromDefinition?.keys ?? [:]
        let entries: [Entry] = hitMap.keys.compactMap { hit in
            guard let key = keys[hit.id] else { return nil }
            let voice = viewModel.keyVoice(for: key)
            let hit0 = FeelVoiceModel.touchDown(voice).first
            return Entry(
                frame: hit.frame,
                label: key.bindings[.tap]?.label ?? key.id,
                role: KeyRole(key: key),
                voice: voice,
                intensity: hit0.intensity,
                sharpness: hit0.sharpness
            )
        }
        let size = CGSize(width: hitMap.size.width + 24, height: hitMap.size.height + 64)
        let content = VStack(alignment: .leading, spacing: 6) {
            Text("\(language) · \(mode) — note · instrument · haptic intensity / sharpness")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                ForEach(entries.indices, id: \.self) { index in
                    EntryView(entry: entries[index])
                }
            }
            .frame(width: hitMap.size.width, height: hitMap.size.height, alignment: .topLeading)
        }
        .padding(12)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        return Shot(size: size, scheme: scheme, content: AnyView(content), keepAlive: [scenario])
    }

    struct Entry {
        var frame: CGRect
        var label: String
        var role: KeyRole
        var voice: KeyVoice
        var intensity: Float
        var sharpness: Float
    }

    /// The note name of a pitch (semitones above C5).
    static func noteName(_ pitch: Float) -> String {
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        let semitone = Int(pitch.rounded()) + 72 // C5 = MIDI 72
        let octave = semitone / 12 - 1
        return "\(names[((semitone % 12) + 12) % 12])\(octave)"
    }

    private struct EntryView: View {
        let entry: Entry

        var body: some View {
            let inset = entry.frame.insetBy(dx: 2, dy: 2)
            VStack(spacing: 1) {
                Text(entry.label)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .lineLimit(1)
                Text(FeelVoiceMap.noteName(entry.voice.pitch))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                Text(String(describing: entry.voice.timbre))
                    .font(.system(size: 9))
                Text(String(format: "%.2f / %.2f", entry.intensity, entry.sharpness))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .minimumScaleFactor(0.5)
            .frame(width: inset.width, height: inset.height)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Self.colour(for: entry.voice.timbre).opacity(0.18 + 0.5 * Double(entry.sharpness)))
            )
            .offset(x: inset.minX, y: inset.minY)
        }

        static func colour(for timbre: FeelTimbre) -> Color {
            switch timbre {
            case .wood: .orange
            case .glass: .cyan
            case .bell: .yellow
            case .felt: .purple
            case .thump: .brown
            case .dull: .red
            case .tick: .gray
            }
        }
    }
}
