//
//  SoundDemo.swift
//  WurstfingerSnapshots
//
//  Renders the keyboard's derived key sounds for a typed phrase into a WAV
//  file, offline, through the same instruments and mixer the keyboard plays
//  them with — so they can be listened to without a device.
//
//      swift run WurstfingerSnapshots --sound-demo feel-demo.wav
//

import AVFAudio
import Foundation
@testable import WurstfingerKit
@testable import WurstfingerScenarioKit

@MainActor
enum SoundDemo {
    /// Types `phrase` on the English keyboard through the real engine with key
    /// clicks on, records every stroke the keyboard plays, and mixes them at a
    /// steady typing rhythm (150 ms between keystrokes) into `url`.
    static func render(phrase: String = "Hello, world! 123", to url: URL) throws -> (strokes: Int, seconds: Double) {
        ScenarioEnvironment.reset()
        let scenario = KeyboardScenario(language: "en_US", autoCapitalize: true, settings: [.keyClicksEnabled: true])
        var strokes: [FeelStroke] = []
        scenario.viewModel.keyClicks = KeyClickPlayer { _, stroke in strokes.append(stroke) }
        scenario.type(phrase)

        // Place each stroke: a full-level one is a new touch-down, a quieter
        // one the release or mode step that follows it.
        var events: [(time: Double, stroke: FeelStroke)] = []
        var time = 0.2
        for stroke in strokes {
            time += stroke.soundGain >= 1 ? 0.15 : 0.06
            events.append((time, stroke))
        }
        let sampleRate = 48000.0
        let mixer = KeySoundMixer(instruments: KeySoundSynth.renderAll(sampleRate: sampleRate), sampleRate: sampleRate)
        let total = Int((time + 0.6) * sampleRate)
        var output = [Float](repeating: 0, count: total)
        let chunk = 256
        var next = 0
        var frame = 0
        while frame < total {
            let end = Double(frame + chunk) / sampleRate
            while next < events.count, events[next].time < end {
                let offset = Float(events[next].time - Double(frame) / sampleRate)
                events[next].stroke.forEach { hit in
                    mixer.start(KeySoundTrigger(
                        timbre: UInt8(hit.timbre.rawValue), rate: hit.rate,
                        gain: hit.weight * hit.timbre.loudness * events[next].stroke.soundGain,
                        delay: max(offset, 0) + hit.delay
                    ))
                }
                next += 1
            }
            let count = min(chunk, total - frame)
            output.withUnsafeMutableBufferPointer { buffer in
                _ = mixer.render(frames: count, into: buffer.baseAddress! + frame)
            }
            frame += count
        }

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total))
        else { throw CocoaError(.featureUnsupported) }
        buffer.frameLength = AVAudioFrameCount(total)
        output.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: total)
        }
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return (strokes.count, Double(total) / sampleRate)
    }
}
