//
//  CustomLayoutCodec.swift
//  Wurstfinger
//
//  The JSON a custom layout is stored, exported and imported as.
//

import Foundation

/// Reads and writes the custom-layout JSON.
///
/// ```json
/// {
///   "schemaVersion": 1,
///   "id": "custom-1b4e28ba-2fa1-11d2-883f-0016d3cca427",
///   "title": "My layout",
///   "locale": "en_US",
///   "basedOn": "en_US",
///   "capitalization": true,
///   "sharedSymbols": true,
///   "keys": {
///     "topLeft": { "tap": "a", "swipeUp": "ä", "swipeRight": { "text": "-", "return": "÷" } },
///     "center":  { "tap": "o", "circularClockwise": "0", "swipeDown": "" }
///   }
/// }
/// ```
///
/// A gesture's value is its text, or `{"text": …, "return": …}` when a return
/// swipe types something other than the default; an empty text unbinds the
/// gesture. Every slot's `tap` is required; a gesture left out inherits the
/// shared punctuation (see ``CustomLayout/usesSharedSymbols``).
///
/// **Versioning.** `schemaVersion` is read first, alone, so a document from a
/// newer app is refused with `unsupportedSchema` instead of being half
/// understood. A change that older readers could misread bumps
/// `currentSchemaVersion` and adds a decoding path for the old version here;
/// version 1 is the only one so far.
///
/// **Safety.** Input is untrusted (a file the user picked, text from the
/// pasteboard): it is size-capped before parsing, every field is range-checked,
/// and only `CustomLayout.validate()`-clean layouts come out, so nothing
/// downstream can trap on a bad document.
///
/// Pure and `nonisolated`: callable from any isolation, which is how the
/// registry decodes off the input path.
enum CustomLayoutCodec {
    static let currentSchemaVersion = 1

    /// Largest document accepted, in bytes. A full layout is about 2 KB; the
    /// cap exists to refuse a huge file before it is read into memory.
    static let maxDocumentBytes = 64 * 1024

    // MARK: - Decoding

    /// Parses and validates a document.
    /// - Throws: `CustomLayoutError` — the first problem found.
    static func decode(_ data: Data) throws -> CustomLayout {
        guard data.count <= maxDocumentBytes else { throw CustomLayoutError.tooLarge(bytes: data.count) }

        let decoder = JSONDecoder()
        let version: Int
        do {
            version = try decoder.decode(VersionProbe.self, from: data).schemaVersion
        } catch {
            throw CustomLayoutError.notALayout
        }
        guard version >= 1, version <= currentSchemaVersion else {
            throw CustomLayoutError.unsupportedSchema(version: version)
        }

        let wire: Wire
        do {
            wire = try decoder.decode(Wire.self, from: data)
        } catch {
            throw CustomLayoutError.notALayout
        }

        var keys: [String: [GestureType: CustomBinding]] = [:]
        for (slot, gestures) in wire.keys {
            var bindings: [GestureType: CustomBinding] = [:]
            for (name, binding) in gestures {
                guard let gesture = GestureType(rawValue: name), CustomLayout.editableGestures.contains(gesture) else {
                    throw CustomLayoutError.unknownGesture(slot: slot, gesture: name)
                }
                bindings[gesture] = binding
            }
            keys[slot] = bindings
        }
        let layout = CustomLayout(
            id: wire.id,
            title: wire.title,
            localeIdentifier: wire.locale,
            basedOn: wire.basedOn,
            supportsCapitalization: wire.capitalization ?? true,
            usesSharedSymbols: wire.sharedSymbols ?? true,
            keys: keys
        )
        if let problem = layout.validate().first { throw problem }
        return layout
    }

    // MARK: - Encoding

    /// The JSON for `layout`: pretty-printed with sorted keys, so an export
    /// diffs and reads well.
    static func encode(_ layout: CustomLayout) throws -> Data {
        var keys: [String: [String: CustomBinding]] = [:]
        for (slot, bindings) in layout.keys {
            keys[slot] = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
        }
        let wire = Wire(
            schemaVersion: currentSchemaVersion,
            id: layout.id,
            title: layout.title,
            locale: layout.localeIdentifier,
            basedOn: layout.basedOn,
            capitalization: layout.supportsCapitalization,
            sharedSymbols: layout.usesSharedSymbols,
            keys: keys
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(wire)
    }

    // MARK: - Wire format

    private struct VersionProbe: Decodable {
        let schemaVersion: Int
    }

    private struct Wire: Codable {
        var schemaVersion: Int
        var id: String
        var title: String
        var locale: String
        var basedOn: String?
        var capitalization: Bool?
        var sharedSymbols: Bool?
        var keys: [String: [String: CustomBinding]]
    }
}

extension CustomBinding: Codable {
    private enum CodingKeys: String, CodingKey {
        case text
        case returnText = "return"
    }

    init(from decoder: Decoder) throws {
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            self.init(text)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            try container.decode(String.self, forKey: .text),
            returnText: try container.decodeIfPresent(String.self, forKey: .returnText)
        )
    }

    func encode(to encoder: Encoder) throws {
        if let returnText {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(text, forKey: .text)
            try container.encode(returnText, forKey: .returnText)
        } else {
            var container = encoder.singleValueContainer()
            try container.encode(text)
        }
    }
}
