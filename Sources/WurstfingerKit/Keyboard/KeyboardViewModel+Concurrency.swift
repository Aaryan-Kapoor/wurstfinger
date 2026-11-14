//
//  KeyboardViewModel+Concurrency.swift
//  Wurstfinger
//
//  The view model's background and cross-process machinery: the signpost
//  intervals around a keystroke, the language prewarm, and the live settings
//  signal from the host app.
//

import Foundation
import os

extension KeyboardViewModel {
    // MARK: - Signposts

    /// Opens the `keystroke` interval at touch-down. A previous interval that
    /// never closed (a touch the system cancelled) is ended first, so
    /// Instruments never shows a keystroke that lasts until the next one.
    func beginKeystrokeInterval() {
        endKeystrokeInterval()
        keystrokeInterval = InputSignposts.signposter.beginInterval(InputSignposts.keystroke)
    }

    /// Closes the `keystroke` interval, if one is open.
    func endKeystrokeInterval() {
        guard let interval = keystrokeInterval else { return }
        keystrokeInterval = nil
        InputSignposts.signposter.endInterval(InputSignposts.keystroke, interval)
    }

    // MARK: - Definition prewarm

    /// Builds the enabled languages' definitions in the background, unless a
    /// prewarm is already running.
    ///
    /// Called when a view model that asked for it (`prewarmsLanguages`) loads a
    /// definition, and again by the controller on every appearance: the
    /// pre-suspension shedding evicts every language but the active one, so a
    /// keyboard that has been dismissed and reopened needs warming again.
    ///
    /// The task is detached at utility priority and never awaited: it populates
    /// `KeyboardRegistry`'s cache and nothing else. Languages that are already
    /// cached are trivial hits, so repeating the request is cheap; only the
    /// missing ones cost anything. The active language (which `loadDefinition`
    /// has just built synchronously) is among the hits. Language switching then
    /// lands on a warm cache; if a switch beats the prewarm to a language, the
    /// synchronous load shares the build in flight rather than starting a
    /// second one.
    func startPrewarmIfNeeded() {
        guard prewarmsLanguages, !isPrewarming else { return }
        let ids = enabledLanguageIds
        guard ids.count > 1 else { return }
        isPrewarming = true
        prewarmTask = Task.detached(priority: .utility) { [weak self] in
            await KeyboardRegistry.prewarm(ids)
            await self?.prewarmFinished()
        }
    }

    private func prewarmFinished() {
        isPrewarming = false
    }

    // MARK: - Cross-process settings signal

    /// Reloads settings whenever the host app announces a change.
    ///
    /// The app posts a Darwin notification (`DarwinNotificationCenter`) after
    /// writing shared settings; the keyboard extension used to notice only on
    /// the next `viewWillAppear`. This consumes the notification stream in a
    /// main-actor task, so a settings change reaches a *visible* keyboard live.
    ///
    /// **Debounce.** A slider drag in the app posts dozens of times a second.
    /// Each signal cancels the pending reload and arms a new one `debounce`
    /// (50 ms) out, so a burst collapses to a single trailing
    /// `reloadSettings()` after the last post — implemented with task
    /// cancellation, so no timer object has to be invalidated and a cancelled
    /// reload can never fire late.
    ///
    /// The returned handle is also kept on the view model: dropping it (or
    /// deallocating the view model) cancels the observation and, through
    /// stream termination, the system registration. Calling again replaces the
    /// previous observation.
    ///
    /// - Parameters:
    ///   - signals: The change signals. Defaults to the shared settings
    ///     notification; tests inject their own stream.
    ///   - debounce: The trailing window.
    @discardableResult
    func observeExternalSettingsChanges(
        signals: AsyncStream<Void> = DarwinNotificationCenter.shared.notifications(),
        debounce: Duration = .milliseconds(50)
    ) -> TaskHandle {
        let handle = TaskHandle(Task { @MainActor [weak self] in
            var pendingReload: Task<Void, Never>?
            for await _ in signals {
                pendingReload?.cancel()
                pendingReload = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(for: debounce)
                    } catch {
                        return // superseded by a newer signal
                    }
                    self?.reloadSettings()
                }
                // The view model is gone: stop listening rather than keep the
                // system registration alive for nothing.
                if self == nil { break }
            }
            pendingReload?.cancel()
        })
        externalSettingsObservation = handle
        return handle
    }
}
