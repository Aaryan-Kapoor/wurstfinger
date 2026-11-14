//
//  ActionMiddleware.swift
//  Wurstfinger
//
//  Protocol and context type for the action-processing pipeline.
//

import Foundation

/// Context that flows through the `ActionPipeline`.
///
/// Middlewares may mutate the action they forward (e.g. `ComposeMiddleware`
/// replaces `.compose` with `.commitText`), and subsequent middlewares see
/// the mutated context. The context intentionally does **not** carry a
/// `UITextDocumentProxy` reference — middlewares inject whatever host
/// dependencies they need via their initializer so every middleware can be
/// unit-tested without a view controller.
struct ActionContext: Sendable {
    /// The action currently being processed. Middlewares may transform it
    /// before calling `next`.
    var action: KeyAction

    /// The binding that produced the action, if any. Used for category-based
    /// decisions (e.g. auto-shift after a `.letter`).
    let binding: KeyBinding?

    /// Name of the currently active keyboard mode. Middlewares may read it
    /// for mode-aware decisions; mode transitions themselves are triggered
    /// via callbacks (see `ModeTransitionMiddleware`).
    var mode: String
}

/// A single step in the action-processing pipeline.
///
/// A middleware receives the `ActionContext` and must call `next(_:)` zero
/// or one time to forward a (possibly transformed) context to the next step.
/// Not calling `next` short-circuits the pipeline.
///
/// **Main-actor.** Middlewares drive the host's text proxy, which is
/// main-thread-only, and they run synchronously inside the touch handler: the
/// whole chain from "finger lifted" to `insertText` is one uninterrupted
/// main-actor call, with no suspension point a second touch or a settings
/// change could slip into. Conforming types therefore inherit `@MainActor`,
/// and their injected closures may call main-actor state directly.
@MainActor
protocol ActionMiddleware {
    func process(_ context: ActionContext, next: (ActionContext) -> Void)
}
