//
//  Options.swift
//  WurstfingerSnapshots
//

import Foundation
@testable import WurstfingerKit

struct Options {
    var outputDirectory = ".build/snapshots"
    var filter: String?
    var listOnly = false
    var scale: CGFloat = 3
    var showHelp = false
    /// Render the derived key sounds of a typed phrase to this WAV file
    /// instead of taking pictures.
    var soundDemo: String?

    static let usage = """
    Usage: swift run WurstfingerSnapshots [options]

    Renders the real keyboard and app views to PNG with SwiftUI's ImageRenderer
    and writes an index.html contact sheet next to the images.

      --out DIR          Output directory (default .build/snapshots)
      --filter TEXT      Only scenarios whose name contains TEXT (case-insensitive)
      --list             Print the scenario names and exit
      --scale N          Render scale, pixels per point (default 3)
      --sound-demo FILE  Render the key sounds of a typed phrase to a WAV file
      -h, --help         Show this help

    For the speed of an optimised build:
      swift run -c release WurstfingerSnapshots
    """

    enum ParseError: Error, CustomStringConvertible {
        case unknown(String)
        case missingValue(String)
        case badValue(String, String)

        var description: String {
            switch self {
            case let .unknown(flag): "unknown option '\(flag)'"
            case let .missingValue(flag): "option '\(flag)' needs a value"
            case let .badValue(flag, value): "option '\(flag)' cannot take '\(value)'"
            }
        }
    }

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var iterator = arguments.makeIterator()
        func value(for flag: String) throws -> String {
            guard let next = iterator.next() else { throw ParseError.missingValue(flag) }
            return next
        }
        while let argument = iterator.next() {
            switch argument {
            case "--out": options.outputDirectory = try value(for: argument)
            case "--filter": options.filter = try value(for: argument)
            case "--list": options.listOnly = true
            case "--scale":
                let text = try value(for: argument)
                guard let scale = Double(text), scale > 0, scale <= 8 else {
                    throw ParseError.badValue(argument, text)
                }
                options.scale = CGFloat(scale)
            case "--sound-demo": options.soundDemo = try value(for: argument)
            case "-h", "--help": options.showHelp = true
            // Added by the launcher so the tool runs against a throwaway
            // defaults suite (see `main.swift`).
            case SharedDefaults.isolatedStoreArgument: break
            default: throw ParseError.unknown(argument)
            }
        }
        return options
    }
}
