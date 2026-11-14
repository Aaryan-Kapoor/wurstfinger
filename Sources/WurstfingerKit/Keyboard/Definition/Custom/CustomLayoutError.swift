//
//  CustomLayoutError.swift
//  Wurstfinger
//
//  Why a custom layout was rejected.
//

import Foundation

/// Why a custom layout was refused: on import, on save, or when read back from
/// storage.
///
/// Cases carry data, not prose: the definition layer ships in the keyboard
/// extension, which never shows an error. The host app turns a case into a
/// localized sentence (`CustomLayoutError.userMessage`, in the app's UI layer).
enum CustomLayoutError: Error, Equatable, Sendable {
    /// The document is larger than `CustomLayoutCodec.maxDocumentBytes`.
    case tooLarge(bytes: Int)

    /// The bytes are not a custom-layout document at all (not JSON, wrong shape,
    /// a field of the wrong type, or no schema version).
    case notALayout

    /// The document was written by a newer schema than this build reads.
    case unsupportedSchema(version: Int)

    /// The id is not a lowercase slug (`a-z`, `0-9`, `.`, `_`, `-`, 3 to 64 characters).
    case invalidId(String)

    /// The id belongs to a layout that ships with the app.
    case reservedId(String)

    /// A layout with this id is already stored.
    case duplicateId(String)

    /// The title is empty or longer than `CustomLayout.maxTitleLength`.
    case invalidTitle

    /// The locale identifier is not of the form `en`, `en_US`, `zh-Hans_CN`.
    case invalidLocale(String)

    /// A key slot the 3x3 grid does not have.
    case unknownSlot(String)

    /// A gesture name that does not exist.
    case unknownGesture(slot: String, gesture: String)

    /// One of the nine keys has no tap character.
    case missingTap(slot: String)

    /// A binding's text is too long, or contains control characters.
    case invalidText(slot: String, gesture: GestureType)

    /// A return-swipe output on a gesture that is not a swipe, or that has no
    /// binding of its own to return from.
    case returnWithoutBinding(slot: String, gesture: GestureType)

    /// The assembled keyboard failed `KeyboardDefinition.validate()`.
    case invalidDefinition(String)

    /// The store already holds `CustomLayoutStore.maxLayouts` layouts.
    case tooManyLayouts(limit: Int)

    /// Reading or writing the layout's file failed.
    case storageFailure
}
