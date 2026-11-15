//
//  KeyboardViewModel+Traces.swift
//  Wurstfinger
//
//  When the opt-in gesture recorder may run, and the hook that tells it the
//  user deleted.
//

import Foundation

extension KeyboardViewModel {
    /// Whether gesture traces may be recorded right now: the user turned the
    /// Expert setting on, the keyboard has Full Access (the traces go to the
    /// shared container), and the field is an ordinary one — not sensitive, and
    /// not one where the host asks for no suggestions (a URL, an email, a
    /// number, a username, autocorrection off: where code and addresses are
    /// typed).
    var mayRecordGestureTraces: Bool {
        sharedDefaults.bool(forKey: SettingsKey.gestureTraceRecording.rawValue)
            && sharedDefaults.bool(forKey: SettingsKey.keyboardFullAccess.rawValue)
            && !fieldTraits.isSensitive
            && !fieldTraits.suppressesCompletions
    }

    /// Brings the engine's recorder in line with `mayRecordGestureTraces`. Called
    /// when settings reload and when the field changes, never per touch. Turning
    /// it off drops the gestures in flight and writes what is waiting.
    func updateTraceRecording() {
        if mayRecordGestureTraces {
            if traceRecorder == nil {
                traceRecorder = GestureTraceRecorder(store: traceStore, timers: timers)
            }
            touchEngine.traceSink = traceRecorder
        } else if let recorder = traceRecorder {
            touchEngine.traceSink = nil
            recorder.stop()
            traceRecorder = nil
        }
    }
}
