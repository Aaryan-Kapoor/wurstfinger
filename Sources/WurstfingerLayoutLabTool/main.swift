//
//  main.swift
//  layoutlab
//
//  The command line of the layout lab. See docs/layout-science.md.
//
//    layoutlab derive   --language de_DE --words de_full.txt --out de_DE.tsv --source "..." [--limit N]
//    layoutlab optimize [--corpora tools/layout-lab/corpora] [--languages de_DE,fr_FR]
//                       [--seed 0] [--restarts 240] [--steps 40000] [--budget 4]
//                       [--generated Sources/.../OptimizedArrangements+Data.generated.swift]
//                       [--report docs/layout-lab-report.md]
//    layoutlab score    --language de_DE [--corpora ...]
//

import Foundation
@testable import WurstfingerKit
@testable import WurstfingerLayoutLab

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard CommandLine.arguments.count > 1 else {
    fail("usage: layoutlab derive|optimize|score ... (see docs/layout-science.md)")
}
let command = CommandLine.arguments[1]
let arguments = Array(CommandLine.arguments.dropFirst(2))

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: "--\(name)"), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let corporaDirectory = option("corpora") ?? "tools/layout-lab/corpora"

func loadTable(_ id: String) throws -> CorpusTable {
    let path = "\(corporaDirectory)/\(id).tsv"
    guard let text = try? String(contentsOfFile: path, encoding: .utf8), let table = CorpusTable(parsing: text) else {
        throw LabError.noCorpus(id)
    }
    return table
}

func read(_ path: String) -> String {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("cannot read \(path)") }
    return text
}

switch command {
case "derive":
    guard let language = option("language"), let words = option("words"), let out = option("out") else {
        fail("derive needs --language, --words and --out")
    }
    let limit = option("limit").flatMap(Int.init) ?? .max
    do {
        var (table, kept, seen) = try LabPipeline.derive(languageId: language, wordList: read(words), limit: limit)
        table.meta["language"] = language
        table.meta["words_seen"] = String(seen)
        table.meta["words_kept"] = String(kept)
        table.meta["tokens_kept"] = String(table.tokenCount)
        for line in (option("source") ?? "").split(separator: ";") {
            let pair = line.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { table.meta[pair[0].trimmingCharacters(in: .whitespaces)] = String(pair[1]) }
        }
        try table.serialized().write(toFile: out, atomically: true, encoding: .utf8)
        print("\(language): kept \(kept) of \(seen) words, \(table.bigrams.count) bigrams -> \(out)")
    } catch {
        fail("\(language): \(error)")
    }

case "optimize":
    var settings = AnnealingSettings()
    if let value = option("seed").flatMap(UInt64.init) { settings.seed = value }
    if let value = option("restarts").flatMap(Int.init) { settings.restarts = value }
    if let value = option("steps").flatMap(Int.init) { settings.steps = value }
    let budget = option("budget").flatMap(Int.init) ?? LabBudget.gentle
    let wanted = option("languages")?.split(separator: ",").map(String.init)
        ?? LanguageDefinitions.all.map(\.id).filter { LabPipeline.isOptimizable($0) }.sorted()
    var results: [LanguageResult] = []
    for id in wanted {
        do {
            let result = try LabPipeline.optimize(languageId: id, table: loadTable(id), settings: settings, budget: budget)
            results.append(result)
            print("\(id): shipped \(LabPipeline.format(result.shipped.cost)) gentle \(LabPipeline.format(result.gentle.cost)) full \(LabPipeline.format(result.full.cost))")
        } catch {
            print("\(id): skipped, \(error)")
        }
    }
    if let path = option("generated") {
        try? LabPipeline.generatedSwift(results, settings: settings, budget: budget).write(toFile: path, atomically: true, encoding: .utf8)
    }
    if let path = option("report") {
        try? LabPipeline.report(results, settings: settings, budget: budget).write(toFile: path, atomically: true, encoding: .utf8)
    }

case "score":
    guard let language = option("language") else { fail("score needs --language") }
    do {
        let problem = try LayoutProblem(languageId: language)
        let text = TextModel(table: try loadTable(language), problem: problem)
        let optimizer = LayoutOptimizer(problem: problem, text: text)
        let scored = optimizer.score(problem.base)
        print("\(language): \(LabPipeline.format(scored.cost)) bits/char, coverage \(String(format: "%.2f", 100 * text.coverage)) %")
        print("untypable: \(text.untypable.sorted { $0.value > $1.value }.prefix(10).map { "\($0.key)=\($0.value)" })")
    } catch {
        fail("\(language): \(error)")
    }

default:
    fail("unknown command \(command)")
}
