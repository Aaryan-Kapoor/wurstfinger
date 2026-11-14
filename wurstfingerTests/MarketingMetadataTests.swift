//
//  MarketingMetadataTests.swift
//  wurstfingerTests
//
//  The App Store copy and the README state the number of keyboard layouts by
//  hand. Reads them from the repo (like LocalizationCompletenessTests) and
//  checks the number against the registry, so a new layout cannot ship with
//  stale marketing copy.
//

import Foundation
import Testing
@testable import WurstfingerApp

private enum MarketingMetadataError: Error {
    case unreadableFile(String)
}

/// Repo root: this file lives in `wurstfingerTests/`, so go up two levels.
private func repoRoot(file: String = #filePath) -> URL {
    URL(fileURLWithPath: file)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

struct MarketingMetadataTests {
    /// Only the count is checked: the lists themselves are prose and stay a
    /// manual review item.
    @Test(arguments: [
        (path: "fastlane/metadata/en-US/description.txt", noun: "Keyboard Layouts"),
        (path: "fastlane/metadata/de-DE/description.txt", noun: "Tastaturlayouts"),
        (path: "fastlane/metadata/es-ES/description.txt", noun: "distribuciones de teclado"),
        (path: "fastlane/metadata/es-MX/description.txt", noun: "diseños de teclado"),
        (path: "fastlane/metadata/fr-FR/description.txt", noun: "dispositions de clavier"),
        (path: "fastlane/metadata/pt-BR/description.txt", noun: "layouts de teclado"),
        (path: "fastlane/metadata/pt-PT/description.txt", noun: "disposições de teclado"),
        (path: "fastlane/metadata/it/description.txt", noun: "layout di tastiera"),
        (path: "fastlane/metadata/nl-NL/description.txt", noun: "toetsenbordindelingen"),
        (path: "fastlane/metadata/sv/description.txt", noun: "tangentbordslayouter"),
        (path: "fastlane/metadata/no/description.txt", noun: "tastaturoppsett"),
        (path: "fastlane/metadata/da/description.txt", noun: "tastaturlayouts"),
        (path: "fastlane/metadata/fi/description.txt", noun: "näppäimistöasettelua"),
        (path: "fastlane/metadata/pl/description.txt", noun: "układów klawiatury"),
        (path: "fastlane/metadata/cs/description.txt", noun: "rozložení klávesnice"),
        (path: "fastlane/metadata/vi/description.txt", noun: "bố cục bàn phím"),
        (path: "fastlane/metadata/uk/description.txt", noun: "розкладок клавіатури"),
        (path: "fastlane/metadata/ru/description.txt", noun: "раскладок клавиатуры"),
        (path: "fastlane/metadata/ja/description.txt", noun: "種類のキーボードレイアウト"),
        (path: "fastlane/metadata/ko/description.txt", noun: "키보드 레이아웃"),
        (path: "fastlane/metadata/tr/description.txt", noun: "klavye düzeni"),
        (path: "fastlane/metadata/el/description.txt", noun: "διατάξεις πληκτρολογίου"),
        (path: "fastlane/metadata/hr/description.txt", noun: "rasporeda tipkovnice"),
        (path: "fastlane/metadata/th/description.txt", noun: "เลย์เอาต์แป้นพิมพ์"),
        (path: "fastlane/metadata/ar-SA/description.txt", noun: "تخطيطًا للوحة المفاتيح"),
        (path: "fastlane/metadata/he/description.txt", noun: "פריסות מקלדת"),
        (path: "fastlane/metadata/hi/description.txt", noun: "कीबोर्ड लेआउट"),
        (path: "README.md", noun: "keyboard layouts"),
    ])
    func statedLayoutCountMatchesTheRegistry(file: (path: String, noun: String)) throws {
        let url = repoRoot().appendingPathComponent(file.path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw MarketingMetadataError.unreadableFile(file.path)
        }

        let pattern = #"(\d+)\s+"# + NSRegularExpression.escapedPattern(for: file.noun)
        let regex = try NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        let match = try #require(
            regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
            "\(file.path) no longer states a number of \"\(file.noun)\""
        )
        let stated = try #require(Int(ns.substring(with: match.range(at: 1))))
        let shipped = KeyboardRegistry.available.count

        #expect(stated == shipped, "\(file.path) claims \(stated) \(file.noun), but \(shipped) layouts ship")
    }
}
