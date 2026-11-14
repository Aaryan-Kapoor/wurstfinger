//
//  ContactSheet.swift
//  WurstfingerSnapshots
//
//  index.html next to the PNGs: every image with its name, grouped, in plain
//  static HTML.
//

import Foundation

struct ContactSheetEntry {
    var group: String
    var name: String
    var file: String
    var pixelSize: String
    var failure: String?
}

enum ContactSheet {
    static func html(entries: [ContactSheetEntry], scale: Int) -> String {
        var groups: [String] = []
        for entry in entries where !groups.contains(entry.group) { groups.append(entry.group) }

        var body = ""
        for group in groups {
            let members = entries.filter { $0.group == group }
            body += "<section>\n<h2>\(escape(group)) <small>\(members.count)</small></h2>\n<div class=\"grid\">\n"
            for entry in members {
                if let failure = entry.failure {
                    body += """
                    <figure class="failed"><div class="miss">failed</div>
                    <figcaption>\(escape(entry.name))<br><span>\(escape(failure))</span></figcaption></figure>

                    """
                } else {
                    body += """
                    <figure><a href="\(escape(entry.file))"><img src="\(escape(entry.file))" alt="\(escape(entry.name))" loading="lazy"></a>
                    <figcaption>\(escape(entry.name))<br><span>\(escape(entry.pixelSize))</span></figcaption></figure>

                    """
                }
            }
            body += "</div>\n</section>\n"
        }

        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Wurstfinger snapshots</title>
        <style>
        :root { color-scheme: light dark; --bg: #f2f2f7; --fg: #1c1c1e; --muted: #6c6c70; --card: #ffffff; --line: #d1d1d6; }
        @media (prefers-color-scheme: dark) { :root { --bg: #0b0b0d; --fg: #f2f2f7; --muted: #98989d; --card: #1c1c1e; --line: #38383a; } }
        body { margin: 0; padding: 24px 16px 64px; background: var(--bg); color: var(--fg); font: 14px/1.4 -apple-system, system-ui, sans-serif; }
        h1 { font-size: 22px; margin: 0 0 4px; }
        p.lead { color: var(--muted); margin: 0 0 24px; }
        h2 { font-size: 16px; margin: 32px 0 12px; }
        h2 small { color: var(--muted); font-weight: normal; margin-left: 6px; }
        .grid { display: flex; flex-wrap: wrap; gap: 16px; align-items: flex-start; }
        figure { margin: 0; padding: 8px; background: var(--card); border: 1px solid var(--line); border-radius: 10px; max-width: 100%; }
        figure img { display: block; max-width: 100%; height: auto; width: auto; max-height: 520px; }
        figcaption { margin-top: 6px; font-size: 12px; word-break: break-all; }
        figcaption span { color: var(--muted); }
        figure.failed { border-color: #ff453a; }
        .miss { width: 160px; height: 80px; display: grid; place-items: center; color: #ff453a; }
        </style>
        </head>
        <body>
        <h1>Wurstfinger snapshots</h1>
        <p class="lead">\(entries.count) images, rendered at \(scale)x with ImageRenderer.</p>
        \(body)</body>
        </html>

        """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
