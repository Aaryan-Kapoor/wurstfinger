//
//  KeyboardAccessoryRow.swift
//  Wurstfinger
//
//  The row above the keys.
//

import SwiftUI

/// The row above the keys: shown, at `KeyboardLayoutMetrics.accessoryHeight`,
/// whenever `KeyboardViewModel.accessoryRowHeight` is non-zero. The layout
/// plan reserves its height (the keys shrink rather than the keyboard
/// outgrowing the screen) and it moves with the keys through every resize.
///
/// Empty until something fills it (word completions).
struct KeyboardAccessoryRow: View {
    let viewModel: KeyboardViewModel

    var body: some View {
        Color.clear
    }
}
