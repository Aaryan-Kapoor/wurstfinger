//
//  GestureResolver.swift
//  Wurstfinger
//
//  Resolves a gesture on a key into the binding that should fire.
//

import Foundation

/// Resolves a gesture on a key into the `KeyBinding` that should fire.
///
/// Resolvers are composed into a `GestureResolverChain`. Each resolver in
/// the chain is asked in order; the first one to return a non-nil binding
/// wins. Returning `nil` means "I don't know" — the chain falls through to
/// the next resolver.
///
/// Concrete resolvers live in their own files (PrimaryResolver,
/// ReturnSwipeResolver, GhostKeyResolver) and are intentionally tiny so the
/// resolution policy is composable rather than hardcoded.
///
/// Resolvers are pure functions of (key, gesture, mode) — no state, no I/O — so
/// they are `Sendable` and live in the value domain, free of any actor.
///
/// They are the *specification* of the resolution policy, not the run-time
/// path: `CompiledMode` runs them once per (key, gesture, isReturn) when a
/// definition loads and stores the answers in flat tables, so a keystroke is an
/// array index instead of a chain of witness calls. Change the policy here and
/// the tables follow; nothing on the touch path calls a resolver.
protocol GestureResolver: Sendable {
    /// Tries to resolve `gesture` on the key with `keyId` in `mode`.
    /// Returns the binding to fire, or `nil` to delegate to the next resolver.
    func resolve(keyId: String, gesture: GestureType, in mode: KeyboardMode) -> KeyBinding?
}
