//
//  CustomLayoutError+Message.swift
//  Wurstfinger
//
//  What the app tells the user when a custom layout is refused.
//

import Foundation

extension CustomLayoutError {
    /// A localized sentence for the user. Deliberately free of ids and file
    /// names: it says what to fix, not where the parser stopped.
    var userMessage: String {
        switch self {
        case .tooLarge:
            String(localized: "This file is too large to be a keyboard layout.")
        case .notALayout, .invalidId, .reservedId, .unknownSlot, .unknownGesture,
             .returnWithoutBinding, .invalidDefinition:
            String(localized: "This is not a Wurstfinger layout file.")
        case .unsupportedSchema:
            String(localized: "This layout was made with a newer version of Wurstfinger. Update the app to use it.")
        case .duplicateId:
            String(localized: "A layout with the same identifier already exists.")
        case .invalidTitle:
            String(localized: "The name must be between 1 and 40 characters.")
        case .invalidLocale:
            String(localized: "The language code is not valid. Use a code like en or en_US.")
        case .missingTap:
            String(localized: "Every key needs a character for a tap.")
        case .invalidText:
            String(localized: "A key's text is longer than 8 characters or contains control characters.")
        case .tooManyLayouts:
            String(localized: "You can keep 16 custom layouts. Delete one to make room.")
        case .storageFailure:
            String(localized: "The layout could not be saved or read.")
        }
    }
}
