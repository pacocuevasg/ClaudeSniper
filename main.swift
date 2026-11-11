// ClaudeSniper — capture anything on your screen and Claude explains it.
// Pixel-art menu bar icon with an on/off toggle. Press ⌘⇧1 and drag over part of the
// screen: the text is read on your Mac (Apple's Vision OCR) and sent to Claude (through
// Claude Code, using your plan), and the answer shows in a pop-up. TextSniper captures
// (⌘⇧2) are picked up too. Captures are grouped into a chat that expires after a
// while without use (15 min by default, see Settings); you can start a new chat or switch.
//
// File map: settings and modes · design tokens and Markdown · chats and history ·
// Claude Code processes · AppDelegate (menu, capture detection, asking Claude) ·
// pop-up · Mini Clawd · welcome window · history window.

import Cocoa
import ServiceManagement
import Carbon.HIToolbox
import ApplicationServices
import AVFoundation
import NaturalLanguage
import UniformTypeIdentifiers
import Vision

let defaults = UserDefaults.standard
let isDemo = CommandLine.arguments.contains { $0.hasPrefix("--demo") }
let home = FileManager.default.homeDirectoryForCurrentUser.path
let workDir = home + "/Library/Application Support/ClaudeSniper"
let claudeOrange = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)      // #D97757
let claudeOrangeDark = NSColor(srgbRed: 0.68, green: 0.33, blue: 0.22, alpha: 1)
let eyeColor = NSColor(srgbRed: 0.13, green: 0.09, blue: 0.07, alpha: 1)

struct Opt { let id: String; let label: String; let detail: String }
let models = [
    Opt(id: "haiku", label: "Haiku", detail: "fastest"),
    Opt(id: "sonnet", label: "Sonnet", detail: "balanced"),
    Opt(id: "opus", label: "Opus", detail: "very capable"),
    Opt(id: "fable", label: "Fable", detail: "most capable"),
]
let efforts = [
    Opt(id: "low", label: "Low", detail: ""),
    Opt(id: "medium", label: "Medium", detail: ""),
    Opt(id: "high", label: "High", detail: ""),
    Opt(id: "xhigh", label: "X-High", detail: ""),
    Opt(id: "max", label: "Max", detail: ""),
]
func label(_ opts: [Opt], _ id: String) -> String { opts.first { $0.id == id }?.label ?? id }

/// Quick action modes. In the pop-up, switch with the buttons or keys 1–6 (7–9 for your own modes).
struct Mode { let id: String; let label: String; let symbol: String; let instruction: String }
let builtInModes = [
    Mode(id: "auto", label: "Auto", symbol: "sparkles",
         instruction: "Interpret the capture and give the most useful answer, following the general rules."),
    Mode(id: "explain", label: "Explain", symbol: "lightbulb",
         instruction: "Explain clearly what it means, as if to a student, with a simple example."),
    Mode(id: "translate", label: "Translate", symbol: "character.bubble",
         instruction: "Translate it into the answer language; if it is already in that language, translate it into English (or into Spanish if the answer language is English). Write only the translation first. If notes on nuances help, add a line containing only --- and then 1–3 short notes."),
    Mode(id: "summarize", label: "Summarize", symbol: "list.bullet",
         instruction: "Summarize the essentials in 3–5 short bullet points."),
    Mode(id: "solve", label: "Solve", symbol: "function",
         instruction: "Solve it step by step, numbering the steps, and end with the final answer in bold."),
    Mode(id: "fix", label: "Fix", symbol: "checkmark.seal",
         instruction: "Fix spelling, grammar and style without changing the language or the meaning. Write the full corrected text first (plain text, no quotes or heading), then a line containing only ---, then a short list of the changes."),
]
/// Modes you create from the menu (up to 3, keys 7–9).
struct CustomMode: Codable { var name: String; var instruction: String }
var customModes: [CustomMode] {
    get { defaults.data(forKey: "customModes").flatMap { try? JSONDecoder().decode([CustomMode].self, from: $0) } ?? [] }
    set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "customModes") }
}
func allModes() -> [Mode] {
    builtInModes + customModes.map { Mode(id: "custom:" + $0.name, label: $0.name, symbol: "star", instruction: $0.instruction) }
}
func mode(_ id: String) -> Mode { allModes().first { $0.id == id } ?? builtInModes[0] }

/// Modes whose answer starts with text worth pasting back (the "Replace" button).
let replaceableModes: Set<String> = ["fix", "translate"]
/// The part of an answer before a line with only "---".
func mainPart(_ answer: String) -> String {
    let lines = answer.components(separatedBy: "\n")
    if let i = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).range(of: #"^-{3,}$"#, options: .regularExpression) != nil }) {
        return lines[..<i].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return answer.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Languages Claude can answer in. "system" follows the Mac's preferred language.
let languages = [
    Opt(id: "system", label: "Match my Mac", detail: ""),
    Opt(id: "en", label: "English", detail: ""),
    Opt(id: "es", label: "Español", detail: ""),
    Opt(id: "pt", label: "Português", detail: ""),
    Opt(id: "fr", label: "Français", detail: ""),
    Opt(id: "de", label: "Deutsch", detail: ""),
]

/// English name of the answer language, e.g. "Spanish".
func answerLanguageName(_ id: String) -> String {
    let code = id == "system" ? String((Locale.preferredLanguages.first ?? "en").prefix(2)) : id
    return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "English"
}

// MARK: - Settings (menu bar → Settings)

enum Settings {
    /// Chat memory in minutes. 0 = off (every capture starts a new chat).
    static var chatMinutes: Int { defaults.object(forKey: "chatMinutes") as? Int ?? 15 }
    static var answerLength: String { defaults.string(forKey: "answerLength") ?? "normal" }
    static var popupPosition: String { defaults.string(forKey: "popupPosition") ?? "cursor" }
    /// Seconds before the pop-up closes by itself. 0 = never.
    static var autoClose: Int { defaults.object(forKey: "autoClose") as? Int ?? 0 }
    static var autoCopy: Bool { defaults.bool(forKey: "autoCopy") }
    static var sound: Bool { defaults.bool(forKey: "sound") }
    /// Haiku with no thinking, from a Claude Code process that's already running.
    static var superFast: Bool { defaults.bool(forKey: "superFast") }
    /// Answers wait in a tiny Clawd instead of opening the pop-up.
    static var miniMode: Bool { defaults.bool(forKey: "miniMode") }
    /// Also put the captured text on the clipboard, like an OCR tool.
    static var copyCapture: Bool { defaults.object(forKey: "copyCapture") as? Bool ?? true }
    /// Off: the lines of a paragraph are joined into one (handy for PDFs).
    static var keepLineBreaks: Bool { defaults.object(forKey: "keepLineBreaks") as? Bool ?? true }
}
let chatMemoryOptions: [(Any, String)] = [(0, "Off · every capture is a new chat"), (5, "5 minutes"), (10, "10 minutes"),
                                          (15, "15 minutes"), (30, "30 minutes"), (60, "1 hour")]
let lengthOptions: [(Any, String)] = [("short", "Short"), ("normal", "Normal"), ("detailed", "Detailed")]
let lengthHint = ["short": "under 80 words", "normal": "under 200 words", "detailed": "under 400 words; go deeper when it helps"]
let positionOptions: [(Any, String)] = [("cursor", "Next to the cursor"), ("topRight", "Top-right corner"), ("center", "Center of the screen")]
let autoCloseOptions: [(Any, String)] = [(0, "Never"), (15, "After 15 seconds"), (30, "After 30 seconds"), (60, "After 1 minute")]

/// ClaudeSniper's own capture shortcut (Settings → Change capture shortcut).
let defaultHotkeyLabel = "⌘⇧1"
var hotkeyCode = defaults.object(forKey: "hotkeyCode") as? Int ?? Int(kVK_ANSI_1)
var hotkeyMods = UInt(defaults.object(forKey: "hotkeyMods") as? Int ?? Int(NSEvent.ModifierFlags([.command, .shift]).rawValue))
var hotkeyLabel = defaults.string(forKey: "hotkeyLabel") ?? defaultHotkeyLabel

func chatMemoryText() -> String {
    let m = Settings.chatMinutes
    return m == 0 ? "off" : m >= 60 ? "\(m / 60) h" : "\(m) min"
}

func systemPrompt(language: String, length: String) -> String {
    """
    The user captures snippets of their screen with TextSniper (OCR) and sends them to you. \
    You will receive that text (or an image). Work out what it is and answer in a useful, direct way:
    - If it's a question or an exercise, answer or solve it.
    - If it's a term, concept or definition, explain it clearly with a short example.
    - If it's code or an error, explain what it does or means and how to fix it.
    - If it's in another language, translate it and explain what matters.
    - If it's data or a table, summarize what's relevant.
    Captures in this conversation are usually related (same document, topic or exercise): \
    use the context of earlier captures when it helps. The text may contain OCR errors; \
    correct them silently. Don't ask follow-up questions: just give the answer. Each message \
    names a MODE with a specific instruction: follow it over the general rules. Answer in \
    \(language) (unless the mode asks otherwise), concisely (ideally \(lengthHint[length] ?? "under 200 words")), with \
    light markdown (bold, lists).
    """
}

// MARK: - Pixel art

func pixelArt(_ rows: [String], px: CGFloat, pxH: CGFloat? = nil, palette: [Character: NSColor]) -> NSImage {
    let ph = pxH ?? px
    let w = CGFloat(rows.map { $0.count }.max() ?? 0), h = CGFloat(rows.count)
    return NSImage(size: NSSize(width: w * px, height: h * ph), flipped: true) { _ in
        NSGraphicsContext.current?.shouldAntialias = false
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() {
                guard let c = palette[ch] else { continue }
                c.setFill()
                NSRect(x: CGFloat(x) * px, y: CGFloat(y) * ph, width: px, height: ph).fill()
            }
        }
        return true
    }
}

enum Pixel {
    // Claude spark (9x9)
    static let spark = [
        "....#....",
        ".#..#..#.",
        "..#.#.#..",
        "...###...",
        "#########",
        "...###...",
        "..#.#.#..",
        ".#..#..#.",
        "....#....",
    ]
    // Clawd, Claude Code's pixel mascot (17 wide)
    static let body = ["...############..", "...##@######@##..", ".################", "...############.."]
    static let blinkBody = ["...############..", "...############..", ".################", "...############.."]
    static let legsA = "....#.#....#.#..."
    static let legsB = "...#.#....#.#...."
    static let empty = "................."

    static func clawdPalette(_ on: Bool = true) -> [Character: NSColor] {
        on ? ["#": claudeOrange, "@": eyeColor] : ["#": .tertiaryLabelColor, "@": eyeColor]
    }
    static func clawd(px: CGFloat, on: Bool = true) -> NSImage {
        pixelArt([empty] + body + [legsA], px: px, pxH: px * 2, palette: clawdPalette(on))
    }
    /// Frames for the "thinking" animation: walks and hops.
    static func clawdFrames(px: CGFloat) -> [NSImage] {
        let seqs: [[String]] = [
            [empty] + body + [legsA],
            [empty] + body + [legsB],
            body + [legsA] + [empty],
            [empty] + body + [legsB],
            [empty] + body + [legsA],
            [empty] + blinkBody + [legsA],
        ]
        return seqs.map { pixelArt($0, px: px, pxH: px * 2, palette: clawdPalette()) }
    }
    // Frames for the menu bar while Claude is answering: + → ✳ → × → ✳ → small, a twinkle.
    static let sparkCross = ["....#....", "....#....", "....#....", "...###...", "#########", "...###...", "....#....", "....#....", "....#...."]
    static let sparkX = ["#.......#", ".#.....#.", "..#...#..", "...###...", "...###...", "...###...", "..#...#..", ".#.....#.", "#.......#"]
    static let sparkSmall = [".........", ".........", "....#....", "...###...", "..#####..", "...###...", "....#....", ".........", "........."]
    static let busyIcons: [NSImage] = [sparkCross, spark, sparkX, spark, sparkSmall].map {
        pixelArt($0, px: 2, palette: ["#": claudeOrange])
    }
    static func menuBarIcon(on: Bool) -> NSImage {
        let img = pixelArt(spark, px: 2, palette: ["#": on ? claudeOrange : .black])
        img.isTemplate = !on
        return img
    }
}

// MARK: - Design tokens

/// One place for the look: colors, radii and the warm gradient.
enum Theme {
    static let accent = claudeOrange
    /// A lighter orange that stays readable as text on the dark glass.
    static let accentSoft = claudeOrange.blended(withFraction: 0.35, of: .white)!
    static let radius: CGFloat = 18
    // On the pop-up's dark glass:
    static let ink = NSColor.white.withAlphaComponent(0.92)
    static let ink2 = NSColor.white.withAlphaComponent(0.60)
    static let ink3 = NSColor.white.withAlphaComponent(0.38)
    static let fill = NSColor.white.withAlphaComponent(0.07)
    static let fillHover = NSColor.white.withAlphaComponent(0.14)
    static let stroke = NSColor.white.withAlphaComponent(0.10)

    /// The warm gradient behind the pop-up in demos, the welcome header and the app icon.
    static func gradient(_ size: NSSize) -> CAGradientLayer {
        let g = CAGradientLayer()
        g.colors = [NSColor(srgbRed: 0.42, green: 0.20, blue: 0.13, alpha: 1).cgColor,
                    NSColor(srgbRed: 0.10, green: 0.08, blue: 0.09, alpha: 1).cgColor,
                    NSColor(srgbRed: 0.16, green: 0.12, blue: 0.20, alpha: 1).cgColor]
        g.startPoint = CGPoint(x: 0, y: 1)
        g.endPoint = CGPoint(x: 1, y: 0)
        g.frame = CGRect(origin: .zero, size: size)
        return g
    }
}

/// A borderless button with a rounded background that lights up under the mouse.
final class HoverButton: NSButton {
    var normalBg = NSColor.clear { didSet { apply() } }
    var hoverBg = Theme.fillHover { didSet { apply() } }
    private var hovering = false
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = area { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(a)
        area = a
    }
    override func mouseEntered(with e: NSEvent) { hovering = true; apply() }
    override func mouseExited(with e: NSEvent) { hovering = false; apply() }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func viewDidHide() { super.viewDidHide(); hovering = false; apply() }
    func apply() {
        wantsLayer = true
        layer?.backgroundColor = (hovering ? hoverBg : normalBg).cgColor
    }
}

// MARK: - Markdown

/// Colors and sizes for rendered answers: the dark pop-up, or a normal window (light or dark).
struct MDTheme {
    var size: CGFloat
    var width: CGFloat          // text width, used to space table columns
    var text: NSColor
    var strong: NSColor
    var secondary: NSColor
    var codeText: NSColor
    var codeBg: NSColor

    static let popup = MDTheme(size: 14, width: 560, text: Theme.ink, strong: .white, secondary: Theme.ink2,
                               codeText: Theme.accentSoft, codeBg: NSColor.white.withAlphaComponent(0.08))
    static let window = MDTheme(size: 13.5, width: 520, text: .labelColor, strong: .labelColor, secondary: .secondaryLabelColor,
                                codeText: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? Theme.accentSoft : claudeOrangeDark },
                                codeBg: NSColor.labelColor.withAlphaComponent(0.07))
}

/// Renders the Markdown Claude writes: headings, bold/italic/code, bullet and numbered
/// lists, quotes, fenced code blocks, simple tables and rules.
enum Markdown {
    static func inline(_ md: String, font: NSFont, color: NSColor, _ th: MDTheme) -> NSMutableAttributedString {
        let parsed = (try? AttributedString(markdown: md, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(md)
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            var f = font, c = color
            var attrs: [NSAttributedString.Key: Any] = [:]
            if let i = run.inlinePresentationIntent {
                if i.contains(.code) {
                    f = .monospacedSystemFont(ofSize: font.pointSize - 1.5, weight: .regular)
                    c = th.codeText
                    attrs[.backgroundColor] = th.codeBg
                } else {
                    var t = font.fontDescriptor.symbolicTraits
                    if i.contains(.stronglyEmphasized) { t.insert(.bold); c = th.strong }
                    if i.contains(.emphasized) { t.insert(.italic) }
                    f = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(t), size: font.pointSize) ?? font
                    if i.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                }
            }
            if let url = run.link { attrs[.link] = url }
            attrs[.font] = f
            attrs[.foregroundColor] = c
            out.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attrs))
        }
        return out
    }

    static func render(_ raw: String, _ th: MDTheme = .popup) -> NSAttributedString {
        let base = NSFont.systemFont(ofSize: th.size)
        var blocks: [NSAttributedString] = []
        var gap = false   // a blank line came before the next block

        func style(indent: CGFloat = 0, first: CGFloat? = nil, after: CGFloat = 3, tab: CGFloat? = nil) -> NSMutableParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.lineSpacing = 2.5
            p.paragraphSpacing = after
            p.paragraphSpacingBefore = blocks.isEmpty ? 0 : (gap ? 8 : 0)
            p.headIndent = indent
            p.firstLineHeadIndent = first ?? indent
            if let t = tab { p.tabStops = [NSTextTab(textAlignment: .left, location: t)]; p.defaultTabInterval = t }
            return p
        }
        func add(_ s: NSMutableAttributedString, _ p: NSParagraphStyle) {
            guard s.length > 0 else { return }
            s.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: s.length))
            blocks.append(s)
            gap = false
        }
        func depthAndX(_ marker: Substring) -> CGFloat {
            CGFloat(min(marker.prefix { $0 == " " || $0 == "\t" }.count / 2, 3)) * 16
        }

        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block
            if trimmed.hasPrefix("```") {
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i].replacingOccurrences(of: "\t", with: "    "))
                    i += 1
                }
                i += 1
                while code.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { code.removeLast() }
                // Pad every line to the same length so the background is one clean rectangle.
                let w = min(max(code.map { $0.count }.max() ?? 0, 28), 76)
                let mono = NSFont.monospacedSystemFont(ofSize: th.size - 2, weight: .regular)
                gap = true
                for (n, l) in code.enumerated() {
                    let s = NSMutableAttributedString(string: " " + l.padding(toLength: max(w, l.count), withPad: " ", startingAt: 0) + " ",
                                                      attributes: [.font: mono, .foregroundColor: th.text, .backgroundColor: th.codeBg])
                    let p = style(after: n == code.count - 1 ? 6 : 0)
                    p.lineSpacing = 0
                    p.lineBreakMode = .byCharWrapping
                    add(s, p)
                }
                gap = true
                continue
            }
            if trimmed.isEmpty { gap = true; i += 1; continue }

            // Rule
            if trimmed.range(of: #"^([-*_])\1{2,}$"#, options: .regularExpression) != nil {
                gap = true
                add(NSMutableAttributedString(string: String(repeating: "─", count: 26), attributes: [
                    .font: NSFont.systemFont(ofSize: 9), .foregroundColor: th.secondary.withAlphaComponent(0.4)]), style())
                gap = true
                i += 1; continue
            }
            // Heading
            if let r = trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                let level = trimmed[r].filter { $0 == "#" }.count
                let f = NSFont.systemFont(ofSize: th.size + (level == 1 ? 3.5 : level == 2 ? 2 : 0.5), weight: level <= 2 ? .bold : .semibold)
                let p = style(after: 4)
                if !blocks.isEmpty { p.paragraphSpacingBefore = 10 }
                add(inline(String(trimmed[r.upperBound...]), font: f, color: th.strong, th), p)
                i += 1; continue
            }
            // Quote
            if trimmed.hasPrefix(">") {
                let s = NSMutableAttributedString(string: "▎ ", attributes: [.font: base, .foregroundColor: Theme.accent.withAlphaComponent(0.75)])
                s.append(inline(trimmed.dropFirst().trimmingCharacters(in: .whitespaces), font: base, color: th.secondary, th))
                add(s, style(indent: 14, first: 0))
                i += 1; continue
            }
            // Table: consecutive |a|b| rows
            if trimmed.hasPrefix("|"), trimmed.hasSuffix("|"), trimmed.count > 2 {
                var table: [[String]] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix("|"), t.hasSuffix("|"), t.count > 2 else { break }
                    if t.range(of: #"^\|[\s:|-]+\|$"#, options: .regularExpression) == nil {
                        table.append(t.dropFirst().dropLast().components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) })
                    }
                    i += 1
                }
                let cols = max(table.map { $0.count }.max() ?? 1, 2)
                let colW = th.width / CGFloat(cols)
                gap = true
                for (n, row) in table.enumerated() {
                    let f = NSFont.systemFont(ofSize: th.size - 1, weight: n == 0 ? .semibold : .regular)
                    let s = NSMutableAttributedString()
                    for (c, cell) in row.enumerated() {
                        if c > 0 { s.append(NSAttributedString(string: "\t", attributes: [.font: f])) }
                        s.append(inline(cell, font: f, color: n == 0 ? th.strong : th.text, th))
                    }
                    let p = style(after: n == 0 ? 5 : 3)
                    p.tabStops = (1..<cols).map { NSTextTab(textAlignment: .left, location: colW * CGFloat($0)) }
                    add(s, p)
                }
                gap = true
                continue
            }
            // Bullet list
            if let r = line.range(of: #"^\s*[-*+•]\s+"#, options: .regularExpression) {
                let x = depthAndX(line[r])
                let s = NSMutableAttributedString(string: "•\t", attributes: [
                    .font: NSFont.systemFont(ofSize: th.size, weight: .heavy), .foregroundColor: Theme.accent])
                s.append(inline(String(line[r.upperBound...]), font: base, color: th.text, th))
                add(s, style(indent: x + 16, first: x + 2, tab: x + 16))
                i += 1; continue
            }
            // Numbered list
            if let r = line.range(of: #"^\s*\d{1,3}[.)]\s+"#, options: .regularExpression) {
                let x = depthAndX(line[r])
                let s = NSMutableAttributedString(string: line[r].trimmingCharacters(in: .whitespaces) + "\t", attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: th.size, weight: .semibold), .foregroundColor: Theme.accent])
                s.append(inline(String(line[r.upperBound...]), font: base, color: th.text, th))
                add(s, style(indent: x + 24, first: x + 2, tab: x + 24))
                i += 1; continue
            }
            // Plain paragraph (each line keeps its own line, as Claude wrote it)
            add(inline(trimmed, font: base, color: th.text, th), style())
            i += 1
        }

        let out = NSMutableAttributedString()
        for (n, b) in blocks.enumerated() {
            out.append(b)
            if n < blocks.count - 1 {
                let last = b.attributes(at: b.length - 1, effectiveRange: nil)
                var a: [NSAttributedString.Key: Any] = [.font: last[.font] ?? base]
                if let p = last[.paragraphStyle] { a[.paragraphStyle] = p }
                out.append(NSAttributedString(string: "\n", attributes: a))
            }
        }
        return out
    }
}

/// Joins the lines of each paragraph into one line (blank lines still separate paragraphs).
func joinLines(_ t: String) -> String {
    var out = ""
    for line in t.components(separatedBy: "\n") {
        let l = line.trimmingCharacters(in: .whitespaces)
        if l.isEmpty { if !out.hasSuffix("\n\n") { out += "\n\n" }; continue }
        if out.isEmpty || out.hasSuffix("\n") { out += l }
        else if out.hasSuffix("-"), l.first?.isLowercase == true { out.removeLast(); out += l }   // a word split across lines
        else { out += " " + l }
    }
    return out.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// A small message next to the cursor that fades out by itself.
enum Toast {
    static var panel: NSPanel?
    static func show(_ text: String) {
        panel?.orderOut(nil)
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        let size = label.fittingSize
        let w = size.width + 36, h: CGFloat = 36
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        let v = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(srgbRed: 0.13, green: 0.10, blue: 0.10, alpha: 0.96).cgColor
        v.layer?.cornerRadius = 18
        v.layer?.borderWidth = 1
        v.layer?.borderColor = claudeOrange.withAlphaComponent(0.7).cgColor
        label.frame = NSRect(x: 18, y: (h - size.height) / 2, width: size.width, height: size.height)
        v.addSubview(label)
        p.contentView = v
        let m = NSEvent.mouseLocation
        p.setFrameOrigin(NSPoint(x: m.x + 14, y: m.y - h - 14))
        p.orderFrontRegardless()
        panel = p
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak p] in
            guard let p, panel === p else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; p.animator().alphaValue = 0 }, completionHandler: { p.orderOut(nil) })
        }
    }
}

// MARK: - Tables (rows of cells), for "Copy table"

typealias Table = [[String]]

/// The Markdown tables in a text, as rows of plain cells.
func markdownTables(_ md: String) -> [Table] {
    var out: [Table] = [], cur: Table = []
    func flush() { if cur.count > 1 { out.append(cur) }; cur = [] }
    for line in md.components(separatedBy: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("|"), t.hasSuffix("|"), t.count > 2 else { flush(); continue }
        if t.range(of: #"^\|[\s:|-]+\|$"#, options: .regularExpression) != nil { continue }   // the |---|---| row
        cur.append(t.dropFirst().dropLast().components(separatedBy: "|").map {
            $0.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "").trimmingCharacters(in: .whitespaces)
        })
    }
    flush()
    return out
}

func tableMarkdown(_ t: Table) -> String {
    var md = ""
    for (r, row) in t.enumerated() {
        md += "| " + row.joined(separator: " | ") + " |\n"
        if r == 0 { md += "|" + String(repeating: "---|", count: row.count) + "\n" }
    }
    return md
}

/// Puts tables on the clipboard so they paste as real tables: HTML for Notion, Word,
/// Docs and Mail; tab-separated text for Excel, Numbers and Sheets.
func copyTables(_ tables: [Table]) {
    func clean(_ c: String) -> String { c.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
    func esc(_ c: String) -> String {
        c.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
    let tsv = tables.map { $0.map { $0.map(clean).joined(separator: "\t") }.joined(separator: "\n") }.joined(separator: "\n\n")
    let html = "<meta charset=\"utf-8\">" + tables.map { t in
        "<table>" + t.enumerated().map { r, row in
            "<tr>" + row.map { r == 0 ? "<th>\(esc($0))</th>" : "<td>\(esc($0))</td>" }.joined() + "</tr>"
        }.joined() + "</table>"
    }.joined(separator: "<br>")
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(html, forType: .html)
    pb.setString(tsv, forType: .string)
}

// MARK: - Chats (memory length is a setting)

struct Chat: Codable { var id: String; var title: String; var created: Date; var lastUsed: Date; var count: Int }

final class ChatStore {
    static var ttl: TimeInterval { TimeInterval(Settings.chatMinutes * 60) }
    private(set) var chats: [Chat] = []
    private(set) var activeID: String?

    init() {
        if let d = defaults.data(forKey: "chats"), let c = try? JSONDecoder().decode([Chat].self, from: d) { chats = c }
        activeID = defaults.string(forKey: "activeChat")
        prune()
    }
    func save() {
        defaults.set(try? JSONEncoder().encode(chats), forKey: "chats")
        defaults.set(activeID, forKey: "activeChat")
    }
    func prune() {
        chats.removeAll { Date().timeIntervalSince($0.lastUsed) > Self.ttl }
        if let a = activeID, !chats.contains(where: { $0.id == a }) { activeID = nil }
    }
    var active: Chat? { prune(); return chats.first { $0.id == activeID } }
    var recent: [Chat] { prune(); return chats }
    func newChat() { activeID = nil; save() }
    func clearAll() { chats = []; activeID = nil; save() }
    func switchTo(_ id: String) { activeID = id; save() }
    func record(id: String, title: String, makeActive: Bool) {
        if let i = chats.firstIndex(where: { $0.id == id }) {
            chats[i].lastUsed = Date(); chats[i].count += 1
        } else {
            chats.append(Chat(id: id, title: title, created: Date(), lastUsed: Date(), count: 1))
        }
        chats.sort { $0.lastUsed > $1.lastUsed }
        if makeActive { activeID = id }
        save()
    }
    static func minutesLeft(_ c: Chat) -> Int {
        max(1, Int(ceil((ttl - Date().timeIntervalSince(c.lastUsed)) / 60)))
    }
    static func ago(_ d: Date) -> String {
        let m = Int(Date().timeIntervalSince(d) / 60)
        return m < 1 ? "just now" : "\(m) min ago"
    }
}

// MARK: - History (every answer, saved on disk)

struct HistoryEntry: Codable {
    var id = UUID().uuidString
    var date = Date()
    var chatID: String
    var mode: String
    var model: String
    var capture: String
    var followUp: String?
    var answer: String
}

final class HistoryStore {
    static let maxEntries = 500
    private(set) var entries: [HistoryEntry] = []
    let url = URL(fileURLWithPath: workDir + "/history.json")

    init() {
        if let d = try? Data(contentsOf: url) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            entries = (try? dec.decode([HistoryEntry].self, from: d)) ?? []
        }
    }
    func add(_ e: HistoryEntry) {
        entries.append(e)
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
        save()
    }
    func clear() { entries = []; save() }
    func chat(_ id: String) -> [HistoryEntry] { entries.filter { $0.chatID == id } }
    func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? enc.encode(entries).write(to: url, options: .atomic)
    }
}

func chatMarkdown(_ items: [HistoryEntry]) -> String {
    let df = DateFormatter(); df.dateStyle = .long; df.timeStyle = .short
    var md = "# ClaudeSniper chat\n\n_\(items.first.map { df.string(from: $0.date) } ?? "")_\n"
    var n = 0
    for e in items {
        if let q = e.followUp {
            md += "\n### ↳ \(q)\n\n\(e.answer)\n"
        } else {
            n += 1
            let quoted = e.capture.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
            md += "\n## Capture \(n) · \(e.mode)\n\n\(quoted)\n\n\(e.answer)\n"
        }
    }
    return md
}

func chatHTML(_ items: [HistoryEntry]) -> String {
    func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "\n", with: "<br>")
    }
    var h = "<h1>ClaudeSniper chat</h1>"
    var n = 0
    for e in items {
        if let q = e.followUp {
            h += "<h3>↳ \(esc(q))</h3><div>\(esc(e.answer))</div><br>"
        } else {
            n += 1
            h += "<h2>Capture \(n) · \(esc(e.mode))</h2><blockquote><i>\(esc(e.capture))</i></blockquote><div>\(esc(e.answer))</div><br>"
        }
    }
    return h
}

// MARK: - Claude Code

func findClaude() -> String? {
    let candidates = [home + "/.local/bin/claude", "/opt/homebrew/bin/claude",
                      "/usr/local/bin/claude", home + "/.claude/local/claude"]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

/// Clean environment, so the CLI uses your own Claude Code login (your plan).
func cleanEnv() -> [String: String] {
    [
        "HOME": home,
        "USER": NSUserName(),
        "PATH": "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
        "LANG": "en_US.UTF-8",
        "TERM": "dumb",
    ]
}

@discardableResult
func runSync(_ exe: String, _ args: [String], stdin: String?, timeout: TimeInterval,
             started: ((Process) -> Void)? = nil) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    p.environment = cleanEnv()
    p.currentDirectoryURL = URL(fileURLWithPath: workDir)
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    let inp = Pipe()
    p.standardInput = inp
    do { try p.run() } catch { return (-1, error.localizedDescription) }
    started?(p)
    if let s = stdin { inp.fileHandleForWriting.write(Data(s.utf8)) }
    try? inp.fileHandleForWriting.close()
    let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    timer.cancel()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// Runs `claude -p --output-format stream-json` and reports the answer while it's being written.
final class StreamingRun {
    let process = Process()
    private var buffer = Data()
    private(set) var text = ""
    private(set) var result: String?
    private(set) var isError = false
    var other = ""
    var onText: ((String) -> Void)?
    var extraEnv: [String: String] = [:]

    func start(_ exe: String, _ args: [String], stdin: String, timeout: TimeInterval,
               done: @escaping (Int32, StreamingRun) -> Void) -> Bool {
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        process.environment = cleanEnv().merging(extraEnv) { $1 }
        process.currentDirectoryURL = URL(fileURLWithPath: workDir)
        let out = Pipe(), err = Pipe(), inp = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = inp
        do { try process.run() } catch { other = error.localizedDescription; return false }
        inp.fileHandleForWriting.write(Data(stdin.utf8))
        try? inp.fileHandleForWriting.close()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            if self?.process.isRunning == true { self?.process.terminate() }
        }
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        DispatchQueue.global(qos: .userInitiated).async {
            while true {
                let d = out.fileHandleForReading.availableData
                if d.isEmpty { break }
                self.consume(d)
            }
            self.consume(Data("\n".utf8))
            self.process.waitUntilExit()
            group.wait()
            self.other += String(decoding: errData, as: UTF8.self)
            let status = self.process.terminationStatus
            DispatchQueue.main.async { done(status, self) }
        }
        return true
    }

    private func consume(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<nl])
            buffer.removeSubrange(buffer.startIndex...nl)
            handle(line)
        }
    }

    private func handle(_ line: Data) {
        guard !line.isEmpty else { return }
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            other += String(decoding: line, as: UTF8.self) + "\n"
            return
        }
        switch obj["type"] as? String {
        case "stream_event":
            guard let ev = obj["event"] as? [String: Any] else { return }
            if ev["type"] as? String == "message_start" { text = "" }
            if ev["type"] as? String == "content_block_delta", let delta = ev["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta", let t = delta["text"] as? String {
                text += t
                let snapshot = text
                DispatchQueue.main.async { self.onText?(snapshot) }
            }
        case "result":
            result = obj["result"] as? String
            isError = obj["is_error"] as? Bool ?? false
        default: break
        }
    }
}

/// Flags that make Claude Code start faster: no user settings, skills or MCP servers.
let lightStart = ["--setting-sources", "", "--disable-slash-commands", "--strict-mcp-config"]
let noThinkingEnv = ["MAX_THINKING_TOKENS": "0"]

/// Super fast mode: Haiku, no extended thinking, light start.
func fastArgs(_ systemPrompt: String) -> [String] {
    ["-p", "--model", "haiku", "--effort", "low",
     "--output-format", "stream-json", "--verbose", "--include-partial-messages",
     "--settings", #"{"alwaysThinkingEnabled": false}"#,
     "--tools", "Read", "--allowedTools", "Read", "--add-dir", workDir,
     "--system-prompt", systemPrompt] + lightStart
}

/// A Claude Code process started ahead of time that waits for the next question
/// (stream-json input). It skips the 1–2 s startup that every answer otherwise pays.
final class WarmProcess {
    enum Event { case text(String), done(String, Bool), exited(String) }

    let process = Process()
    let sessionID: String
    let key: String               // the system prompt it was started with
    private(set) var busy = false
    private(set) var used = false
    var handler: ((Event) -> Void)?
    private let input = Pipe()
    private var buffer = Data()
    private var text = ""
    private var errData = Data()

    init?(sessionID: String, resume: Bool, systemPrompt: String) {
        self.sessionID = sessionID
        self.key = systemPrompt
        guard let claude = findClaude() else { return nil }
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = fastArgs(systemPrompt) + ["--input-format", "stream-json"]
            + (resume ? ["--resume", sessionID] : ["--session-id", sessionID])
        process.environment = cleanEnv().merging(noThinkingEnv) { $1 }
        process.currentDirectoryURL = URL(fileURLWithPath: workDir)
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input
        do { try process.run() } catch { return nil }
        DispatchQueue.global().async { [weak self] in
            let d = err.fileHandleForReading.readDataToEndOfFile()
            DispatchQueue.main.async { self?.errData = d }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while true {
                let d = out.fileHandleForReading.availableData
                if d.isEmpty { break }
                self?.consume(d)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                guard let self, self.busy else { return }
                self.busy = false
                self.handler?(.exited(String(decoding: self.errData, as: UTF8.self)))
            }
        }
    }

    var alive: Bool { process.isRunning }

    /// Sends a question. Returns false if the process is gone.
    func send(_ prompt: String) -> Bool {
        guard alive else { return false }
        busy = true
        used = true
        text = ""
        let msg: [String: Any] = ["type": "user", "message": ["role": "user", "content": [["type": "text", "text": prompt]]]]
        guard let d = try? JSONSerialization.data(withJSONObject: msg) else { return false }
        do { try input.fileHandleForWriting.write(contentsOf: d + Data("\n".utf8)) } catch { busy = false; return false }
        return true
    }

    func stop() { if process.isRunning { process.terminate() } }

    private func consume(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<nl])
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            switch obj["type"] as? String {
            case "stream_event":
                guard let ev = obj["event"] as? [String: Any] else { continue }
                if ev["type"] as? String == "message_start" { text = "" }
                if ev["type"] as? String == "content_block_delta", let delta = ev["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta", let t = delta["text"] as? String {
                    text += t
                    let snapshot = text
                    DispatchQueue.main.async { self.handler?(.text(snapshot)) }
                }
            case "result":
                let r = obj["result"] as? String ?? text
                let e = obj["is_error"] as? Bool ?? false
                DispatchQueue.main.async { self.busy = false; self.handler?(.done(r, e)) }
            default: break
            }
        }
    }
}

// MARK: - Global shortcuts (no permission needed): capture, and ⌥⌘2 for the last answer

var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
let hotKeyShowLast: UInt32 = 1, hotKeyCapture: UInt32 = 2, hotKeyTextOnly: UInt32 = 3, hotKeyShot: UInt32 = 4, hotKeyScroll: UInt32 = 5

func installHotkeyHandler() {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
        var hk = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                          MemoryLayout<EventHotKeyID>.size, nil, &hk)
        let id = hk.id
        DispatchQueue.main.async {
            if id == hotKeyShowLast { appDelegate?.showLast() } else if id == hotKeyCapture { appDelegate?.captureScreen() }
            else if id == hotKeyTextOnly { appDelegate?.captureTextOnly() }
            else if id == hotKeyShot { appDelegate?.takeScreenshot() }
            else if id == hotKeyScroll { appDelegate?.scrollingCapture() }
        }
        return noErr
    }, 1, &spec, nil, nil)
}

/// Registers (or replaces) a global shortcut. Pass nil to remove it.
func setHotkey(_ id: UInt32, code: Int?, mods: NSEvent.ModifierFlags = []) {
    if let r = hotKeyRefs[id] { UnregisterEventHotKey(r); hotKeyRefs[id] = nil }
    guard let code else { return }
    var c: UInt32 = 0
    if mods.contains(.command) { c |= UInt32(cmdKey) }
    if mods.contains(.shift) { c |= UInt32(shiftKey) }
    if mods.contains(.option) { c |= UInt32(optionKey) }
    if mods.contains(.control) { c |= UInt32(controlKey) }
    var ref: EventHotKeyRef?
    RegisterEventHotKey(UInt32(code), c, EventHotKeyID(signature: 0x434C534E, id: id), GetApplicationEventTarget(), 0, &ref)
    hotKeyRefs[id] = ref
}

// MARK: - Reading the screen (local OCR with Apple's Vision)

/// Reads the text in an image, on this Mac. If it contains tables (macOS 26+), the text is
/// read row by row and each table is added as Markdown so Claude sees its structure.
func recognizeText(at path: String) -> (text: String, forClaude: String, tables: [Table]) {
    guard let img = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return ("", "", []) }
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = true
    req.automaticallyDetectsLanguage = true
    let codeReq = VNDetectBarcodesRequest()
    try? VNImageRequestHandler(cgImage: img).perform([req, codeReq])
    let classic = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    // QR codes and barcodes: their content counts as captured text.
    let codes = Array(Set((codeReq.results ?? []).compactMap { $0.payloadStringValue })).sorted()
    if !codes.isEmpty {
        let c = codes.joined(separator: "\n")
        let seen = classic.isEmpty ? "" : classic + "\n\n"
        return (classic.isEmpty ? c : classic + "\n" + c, seen + "QR code / barcode content:\n" + c, [])
    }

    // Table detection needs the macOS 26 SDK (Xcode 26, Swift 6.2) to build, and macOS 26 to run.
    #if compiler(>=6.2)
    if #available(macOS 26.0, *) {
        var transcript = "", tables: [Table] = []
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            if let doc = try? await RecognizeDocumentsRequest().perform(on: img, orientation: nil).first?.document {
                transcript = doc.text.transcript
                for t in doc.tables where t.rows.count > 1 {
                    tables.append(t.rows.map { $0.map { $0.content.text.transcript.replacingOccurrences(of: "\n", with: " ") } })
                }
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 8)
        if !tables.isEmpty, !transcript.isEmpty {
            return (transcript, transcript + "\n\nThe capture contains a table. Its structure:\n\n" + tables.map(tableMarkdown).joined(separator: "\n"), tables)
        }
    }
    #endif
    return (classic, classic, [])
}

// MARK: - TextSniper's ⌘⇧2 (optional, only with Input Monitoring; its overlay is detected anyway)

weak var appDelegate: AppDelegate?

let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = appDelegate?.tap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    if type == .keyDown {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let f = event.flags
        var m: NSEvent.ModifierFlags = []
        if f.contains(.maskCommand) { m.insert(.command) }
        if f.contains(.maskShift) { m.insert(.shift) }
        if f.contains(.maskControl) { m.insert(.control) }
        if f.contains(.maskAlternate) { m.insert(.option) }
        if code == Int64(kVK_ANSI_2), m == [.command, .shift] {
            DispatchQueue.main.async { appDelegate?.hotkeyPressed() }
        }
    }
    return Unmanaged.passUnretained(event)
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var tap: CFMachPort?
    var pollTimer: Timer?
    var armedUntil = Date.distantPast
    var lastChange = NSPasteboard.general.changeCount
    var current: StreamingRun?
    var requestID = 0
    let store = ChatStore()
    let history = HistoryStore()
    var historyWindow: HistoryWindowController?
    /// Session of the last answer (follow-ups continue it, even with chat memory off).
    var lastSessionID: String?
    struct Shown {
        let header: String; let preview: String; let text: String; let mode: String; let footer: String
        let replace: Bool; let chatID: String
        var entryID: String? = nil   // from History: show the chat up to this answer
        var tables: [Table] = []     // tables detected in the capture
    }
    struct Request { let prompt: String; let image: Bool; let preview: String; let followUp: String? }
    /// The last question sent to Claude, for "Try again".
    var lastRequest: Request?
    var lastActivity = Date()
    var pollCount = 0
    var lastShown: Shown?
    var testMode: String?
    var testTimingLog: Bool { CommandLine.arguments.contains("--interpret-clipboard") }
    var pendingFollowUp: String?
    lazy var popup = PopupController()
    lazy var mini = MiniClawd()
    var miniThisRequest = false
    /// What clicking Mini Clawd opens (the answer, or the error).
    var miniPending: (() -> Void)?
    var miniLoading: (header: String, preview: String)?

    /// Shows a state in the pop-up, or in Mini Clawd when that mode is on for this request.
    func display(header: String, preview: String, state: PopupController.State, footer: String) {
        switch state {
        case .loading, .streaming: setBusy(true)
        case .result, .error: setBusy(false)
        }
        guard miniThisRequest else { popup.show(header: header, preview: preview, state: state, footer: footer); return }
        switch state {
        case .loading, .streaming:
            miniLoading = (header, preview)
            mini.show(.thinking)
        case .result:
            mini.show(.ready)
            // Clicking Clawd opens the whole conversation.
            miniPending = { [weak self] in
                self?.popup.showThread = true
                self?.popup.show(header: header, preview: preview, state: state, footer: footer)
            }
        case .error:
            mini.show(.error)
            miniPending = { [weak self] in self?.popup.show(header: header, preview: preview, state: state, footer: footer) }
        }
    }

    /// Click on Mini Clawd: open the answer (or follow the rest of the answer in the pop-up).
    func miniClicked() {
        mini.hide()
        if let open = miniPending {
            miniPending = nil
            open()
        } else if let l = miniLoading {
            miniThisRequest = false
            popup.show(header: l.header, preview: l.preview, state: .loading, footer: "Writing…")
        }
    }
    var loggedIn: Bool?
    var account = ""
    let menuWidth: CGFloat = 300

    var enabled: Bool {
        get { defaults.bool(forKey: "enabled") }
        set {
            defaults.set(newValue, forKey: "enabled"); updateIcon()
            if newValue { startMonitoring(); prewarm(); registerCaptureHotkey() }
            else { stopMonitoring(); stopWarm(); for id in [hotKeyCapture, hotKeyTextOnly, hotKeyShot, hotKeyScroll] { setHotkey(id, code: nil) } }
        }
    }
    var model: String { defaults.string(forKey: "model") ?? "haiku" }
    var effort: String { defaults.string(forKey: "effort") ?? "low" }
    var defaultMode: String { defaults.string(forKey: "mode") ?? "auto" }
    var answerLanguage: String { defaults.string(forKey: "answerLanguage") ?? "system" }

    struct Capture {
        let text: String?; let imagePath: String?; let preview: String
        var tables: [Table] = []
        var parts = 1   // multi-capture: how many pieces this question has
    }
    var lastCapture: Capture?

    func applicationWillTerminate(_ n: Notification) { stopWarm() }

    /// An accessory app shows no menu bar, but ⌘C, ⌘V, ⌘X, ⌘A and ⌘Z in text fields
    /// only work if an Edit menu exists.
    func installMainMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        let winItem = NSMenuItem()
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = win
        main.addItem(winItem)
        NSApp.mainMenu = main
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        appDelegate = self
        try? FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
        cleanOldCaptures()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.minimumWidth = menuWidth
        statusItem.menu = menu
        updateIcon()
        if enabled { startMonitoring() }
        refreshAuth()
        NSApp.servicesProvider = self   // "Ask ClaudeSniper" in the Services menu
        NSUpdateDynamicServices()
        installHotkeyHandler()
        setHotkey(hotKeyShowLast, code: Int(kVK_ANSI_2), mods: [.command, .option])
        if enabled { registerCaptureHotkey() }
        installMainMenu()
        if let e = history.entries.last {   // so ⌥⌘2 and follow-ups work right after a restart
            lastSessionID = e.chatID
            if e.capture != "[image]" { lastCapture = Capture(text: e.capture, imagePath: nil, preview: e.capture) }
            lastShown = shown(from: e)
        }
        signal(SIGPIPE, SIG_IGN)  // a preloaded process may close its input
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.prewarm() }
        // First launch: a short guide (Claude Code, sign-in, TextSniper, a test).
        if !defaults.bool(forKey: "onboarded") && !CommandLine.arguments.contains(where: { $0.hasPrefix("--") }) || CommandLine.arguments.contains("--demo-welcome") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.openWelcome() }
        }
        if ["--demo", "--demo-error", "--demo-md", "--demo-thread"].contains(where: CommandLine.arguments.contains) { demo() }
        // Testing without TextSniper: interpret what's on the clipboard, optionally in a mode,
        // then ask a follow-up. e.g. --interpret-clipboard --mode fix --follow-up "Why?"
        let a = CommandLine.arguments
        func value(_ k: String) -> String? { a.firstIndex(of: k).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }
        if let path = value("--export-md-to"), let last = history.entries.last {   // test the Markdown export
            try? chatMarkdown(history.chat(last.chatID)).write(toFile: path, atomically: true, encoding: .utf8)
        }
        if a.contains("--demo-mini") {   // Mini Clawd: thinking, then the answer is ready
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.mini.show(.thinking) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.mini.show(.ready) }
        }
        if let secs = value("--click-mini-after").flatMap(Double.init) {   // test: click Mini Clawd
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) { self.miniClicked() }
        }
        if a.contains("--thread") { popup.showThread = true }   // test: open answers as a conversation
        if a.contains("--demo-busy") { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.setBusy(true) } }
        if a.contains("--demo-pin") { DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.popup.togglePin() } }
        if a.contains("--demo-history") { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.openHistory() } }
        if let img = value("--demo-shot") {      // the thumbnail overlay for an image file
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                QuickAccess.shared.show(img)
                if a.contains("--demo-pin-shot") { PinnedShot.show(img) }
            }
        }
        if let tall = value("--stitch-test"), let out = value("--stitch-out"),
           let img = NSImage(contentsOfFile: tall)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            // Slices a tall image into overlapping frames, as if a page scrolled, and joins them again.
            let st = Stitcher(), h = 900
            var y = 0, log = [String]()
            for stepBy in [0, 137, 262, 90, 410, 333, 58, 480, 205, 377, 512, 144, 290, 466, 121, 350, 600, 0, 75, 230] {
                y = min(y + stepBy, img.height - h)
                if let f = img.cropping(to: CGRect(x: 0, y: y, width: img.width, height: h)) { log.append("\(st.add(f))") }
            }
            let ok = st.image().map { savePNG($0, to: out) } ?? false
            print("stitched height \(st.totalHeight), expected \(y + h), saved \(ok): \(log.joined(separator: " "))")
            exit(0)
        }
        if let secs = value("--extract-table-after").flatMap(Double.init) {   // test: ask Claude for the table
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) { self.extractTable() }
        }
        if let secs = value("--copy-table-after").flatMap(Double.init) {      // test: press Copy table
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) { self.popup.copyTable() }
        }
        if let file = value("--ocr-file") {   // test: treat an image file as a screen capture
            testMode = value("--mode")
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                let copy = workDir + "/capture-test-\(Int(Date().timeIntervalSince1970)).png"
                try? FileManager.default.copyItem(atPath: file, toPath: copy)
                let r = recognizeText(at: copy)
                DispatchQueue.main.async { self.captured(r, imagePath: copy, kind: a.contains("--text-only") ? .textOnly : .ask) }
                if let more = value("--add-file"), let secs = value("--add-after").flatMap(Double.init) {   // test: multi-capture
                    Thread.sleep(forTimeInterval: secs)
                    let copy2 = workDir + "/capture-test2-\(Int(Date().timeIntervalSince1970)).png"
                    try? FileManager.default.copyItem(atPath: more, toPath: copy2)
                    let r2 = recognizeText(at: copy2)
                    DispatchQueue.main.async { self.captured(r2, imagePath: copy2, kind: .add) }
                }
            }
        }
        if a.contains("--interpret-clipboard") {
            testMode = value("--mode")
            pendingFollowUp = value("--follow-up")
            let after = value("--after").flatMap(Double.init) ?? 1
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { self.handleClipboard() }
        }
        if CommandLine.arguments.contains("--demo-settings") {   // shows the Settings submenu on its own
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let m = self.settingsItem().submenu!
                let p = NSScreen.main!.visibleFrame
                m.popUp(positioning: nil, at: NSPoint(x: p.midX - 150, y: p.midY + 150), in: nil)
            }
        }
        if CommandLine.arguments.contains("--demo-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.statusItem.button?.performClick(nil) }
        }
    }

    /// Preview the pop-up without calling Claude: `open ClaudeSniper.app --args --demo`
    /// (also --demo-error, --demo-md for the Markdown sample, --demo-thread for a conversation).
    func demo() {
        let a = CommandLine.arguments
        let q = "What is photosynthesis and why does it matter?"
        lastCapture = Capture(text: q, imagePath: nil, preview: q)
        popup.mode = "explain"
        if a.contains("--demo-error") {
            popup.show(header: header(), preview: q, state: .error("You're not signed in to Claude Code.\nSign in with your Claude account to continue."), footer: "")
            return
        }
        let answer = """
        **Photosynthesis** is the process plants, algae and some bacteria use to turn sunlight into chemical energy.

        - **In:** light + water (`H₂O`) + carbon dioxide (`CO₂`)
        - **Out:** glucose (food) + oxygen (`O₂`)

        It matters because it produces *almost all the oxygen* we breathe and is the base of every food chain.
        """
        popup.show(header: header(), preview: q, state: .loading, footer: "Starting a new chat…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            var text = answer
            if a.contains("--demo-md") {
                text = """
                ## Binary search

                It finds a value in a **sorted** list by halving the range each step:

                1. Look at the middle element.
                2. If it's the target, stop.
                3. Otherwise keep only the half that can contain it.

                ```
                def search(xs, target):
                    lo, hi = 0, len(xs) - 1
                    while lo <= hi:
                        mid = (lo + hi) // 2
                        if xs[mid] == target: return mid
                        lo, hi = (mid + 1, hi) if xs[mid] < target else (lo, mid - 1)
                    return -1
                ```

                | Items | Linear search | Binary search |
                |---|---|---|
                | 1,000 | 1,000 steps | 10 steps |
                | 1,000,000 | 1,000,000 steps | 20 steps |

                > It only works if the list is already sorted.
                """
                self.popup.mode = "auto"
            }
            if a.contains("--demo-thread") {
                self.popup.thread = [
                    HistoryEntry(chatID: "demo", mode: "Explain", model: "Haiku · low", capture: q, followUp: nil, answer: answer),
                    HistoryEntry(chatID: "demo", mode: "Explain", model: "Haiku · low", capture: q, followUp: "Does it happen at night?",
                                 answer: "Not the light-dependent part: without light there is no energy to split water. The **Calvin cycle** can keep running for a short while on stored ATP and NADPH."),
                ]
                self.popup.showThread = true
                text = self.popup.thread[1].answer
            }
            self.popup.show(header: self.header(), preview: q, state: .result(text), footer: "Chat · 3 captures · 15 min left")
        }
    }

    func cleanOldCaptures() {
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(atPath: workDir)) ?? [] where f.hasSuffix(".png") {
            let p = workDir + "/" + f
            if let d = (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date,
               Date().timeIntervalSince(d) > 86400 { try? fm.removeItem(atPath: p) }
        }
    }

    var iconTimer: Timer?
    var iconFrame = 0

    /// The menu bar spark twinkles while Claude is answering.
    func setBusy(_ busy: Bool) {
        if busy {
            guard iconTimer == nil else { return }
            iconFrame = 0
            iconTimer = Timer.scheduledTimer(withTimeInterval: 0.14, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.iconFrame = (self.iconFrame + 1) % Pixel.busyIcons.count
                self.statusItem.button?.image = Pixel.busyIcons[self.iconFrame]
            }
            statusItem.button?.toolTip = "ClaudeSniper: Claude is answering…"
        } else {
            iconTimer?.invalidate(); iconTimer = nil
            updateIcon()
        }
    }

    func updateIcon() {
        guard iconTimer == nil else { return }
        statusItem.button?.image = Pixel.menuBarIcon(on: enabled)
        statusItem.button?.toolTip = enabled ? "ClaudeSniper: on" : "ClaudeSniper: off"
    }

    // MARK: Menu

    var effortSeg: NSSegmentedControl?
    var effortLabel: NSTextField?
    var lastSeg: NSSegmentedControl?
    var lastSegLabel: NSTextField?

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshAuth()
        menu.removeAllItems()
        menu.addItem(viewItem(headerView()))
        // Problems first, and only when there is one.
        if findClaude() == nil {
            menu.addItem(status(false, "Claude Code isn't installed · Set up…", action: #selector(openWelcome)))
        } else if loggedIn == false {
            menu.addItem(status(false, "Sign in to Claude…", action: #selector(login)))
        }
        if !hasScreenAccess {
            menu.addItem(status(false, "Allow screen recording…", action: #selector(askScreenAccess)))
        }
        menu.addItem(.separator())

        // How Claude answers
        let fast = Settings.superFast
        let fastOpt = Opt(id: "fast", label: "⚡ Fast", detail: "Super fast: Haiku with no extended thinking, from a Claude Code process that's already running. First words in about a second.")
        menu.addItem(viewItem(segmentView(title: "MODEL", opts: [fastOpt] + models, selected: fast ? "fast" : model, action: #selector(modelChanged(_:)))))
        menu.addItem(viewItem(segmentView(title: fast ? "EFFORT · not used in Fast" : "EFFORT", opts: efforts, selected: effort, action: #selector(effortChanged(_:)))))
        effortSeg = lastSeg
        effortLabel = lastSegLabel
        effortSeg?.isEnabled = !fast
        menu.addItem(viewItem(modeView()))
        menu.addItem(myModesItem())
        let langItem = item("Answer in: \(isDemo ? "English" : label(languages, answerLanguage))", "globe", nil)
        let langMenu = NSMenu()
        for l in languages {
            let it = NSMenuItem(title: l.id == "system" ? "\(l.label) (\(answerLanguageName("system")))" : l.label,
                                action: #selector(languageChanged(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = l.id
            it.state = l.id == answerLanguage ? .on : .off
            langMenu.addItem(it)
        }
        langItem.submenu = langMenu
        menu.addItem(langItem)
        menu.addItem(.separator())

        // Chat
        menu.addItem(viewItem(sectionLabel("CHAT")))
        // Demo mode shows a sample chat so screenshots don't expose real captures.
        let shown = isDemo ? Chat(id: "demo", title: "What is photosynthesis and why does it matter?",
                                  created: Date(), lastUsed: Date(), count: 3) : store.active
        if let c = shown {
            menu.addItem(info("bubble.left.and.bubble.right.fill", claudeOrange,
                              "“\(c.title)”", "\(c.count) capture\(c.count == 1 ? "" : "s") · \(ChatStore.minutesLeft(c)) min left"))
        } else {
            menu.addItem(info("bubble.left.and.bubble.right", .secondaryLabelColor,
                              "No active chat", "Your next capture starts a new one"))
        }
        let newItem = item("New chat", "square.and.pencil", #selector(newChat), key: "n")
        newItem.isEnabled = shown != nil
        menu.addItem(newItem)
        let switchItem = item("Switch chat", "arrow.left.arrow.right", nil)
        let sub = NSMenu()
        for c in store.recent {
            let it = NSMenuItem(title: "", action: #selector(switchChat(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = c.id
            it.state = c.id == store.activeID ? .on : .off
            it.attributedTitle = twoLine(c.title, "\(c.count) capture\(c.count == 1 ? "" : "s") · \(ChatStore.ago(c.lastUsed)) · \(ChatStore.minutesLeft(c)) min left")
            sub.addItem(it)
        }
        if sub.items.isEmpty {
            let it = NSMenuItem(title: Settings.chatMinutes == 0 ? "Chat memory is off (see Settings)" : "No recent chats (they last \(chatMemoryText()))", action: nil, keyEquivalent: "")
            it.isEnabled = false
            sub.addItem(it)
        }
        switchItem.submenu = sub
        menu.addItem(switchItem)
        menu.addItem(.separator())

        // Answers
        let last = item("Show last answer", "arrow.counterclockwise", #selector(showLast))
        last.keyEquivalent = "2"
        last.keyEquivalentModifierMask = [.option, .command]
        last.isEnabled = lastShown != nil
        menu.addItem(last)
        menu.addItem(item("History…", "clock.arrow.circlepath", #selector(openHistory)))
        let exportItem = item("Export chat", "square.and.arrow.up", nil)
        let em = NSMenu()
        em.addItem(item("As a Markdown file…", "doc.text", #selector(exportCurrentMarkdown)))
        em.addItem(item("To Apple Notes", "note.text", #selector(exportCurrentNotes)))
        exportItem.submenu = em
        menu.addItem(exportItem)
        menu.addItem(.separator())

        let cap = item("Capture and ask Claude", "viewfinder", #selector(captureScreen))
        cap.toolTip = "Drag over part of the screen (\(hotkeyLabel) when ClaudeSniper is on). Esc cancels."
        menu.addItem(cap)
        let only = item("Capture text only", "text.viewfinder", #selector(captureTextOnly))
        only.keyEquivalent = "1"
        only.keyEquivalentModifierMask = [.option, .command]
        only.toolTip = "Read the text and copy it, without asking Claude."
        menu.addItem(only)
        let phone = item("Import from iPhone or iPad", "iphone", nil)
        phone.identifier = NSMenuItem.importFromDeviceIdentifier   // macOS adds "Take Photo" and "Scan Documents"
        phone.submenu = NSMenu()
        menu.addItem(phone)
        let shotItem = item("Screenshot", "camera.viewfinder", nil)
        let sm = NSMenu()
        let area = item("Area", "rectangle.dashed", #selector(takeScreenshot))
        area.keyEquivalent = "3"
        area.keyEquivalentModifierMask = [.option, .command]
        sm.addItem(area)
        sm.addItem(item("Window", "macwindow", #selector(takeWindowShot)))
        let scrollItem = item("Scrolling capture", "arrow.up.and.down.text.horizontal", #selector(scrollingCapture))
        scrollItem.keyEquivalent = "4"
        scrollItem.keyEquivalentModifierMask = [.option, .command]
        scrollItem.toolTip = "Pick an area, scroll the page, and get one tall screenshot."
        sm.addItem(scrollItem)
        shotItem.submenu = sm
        menu.addItem(shotItem)
        menu.addItem(item("Interpret clipboard now", "wand.and.stars", #selector(testNow)))
        menu.addItem(settingsItem())
        menu.addItem(.separator())
        menu.addItem(item("Quit ClaudeSniper", "xmark.circle", #selector(NSApp.terminate(_:)), key: "q"))
    }

    func viewItem(_ v: NSView) -> NSMenuItem { let it = NSMenuItem(); it.view = v; return it }

    func item(_ title: String, _ symbol: String, _ action: Selector?, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        it.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return it
    }

    func status(_ ok: Bool, _ title: String, action: Selector?) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        it.isEnabled = action != nil || ok
        let sym = ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        it.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [ok ? .systemGreen : .systemOrange]))
        return it
    }

    func info(_ symbol: String, _ color: NSColor, _ title: String, _ sub: String) -> NSMenuItem {
        let it = NSMenuItem(title: "", action: #selector(noop), keyEquivalent: "")
        it.target = self
        it.attributedTitle = twoLine(title, sub)
        it.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [color]))
        return it
    }
    @objc func noop() {}

    func twoLine(_ a: String, _ b: String) -> NSAttributedString {
        let t = a.count > 38 ? String(a.prefix(37)) + "…" : a
        let s = NSMutableAttributedString(string: t, attributes: [.font: NSFont.menuFont(ofSize: 13)])
        s.append(NSAttributedString(string: "\n" + b, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        return s
    }

    func sectionLabel(_ t: String) -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: menuWidth, height: 20))
        let l = NSTextField(labelWithString: t)
        l.font = .systemFont(ofSize: 10, weight: .semibold)
        l.textColor = .secondaryLabelColor
        l.frame = NSRect(x: 14, y: 2, width: menuWidth - 28, height: 14)
        v.addSubview(l)
        return v
    }

    func headerView() -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: menuWidth, height: 58))
        let enabled = self.enabled || isDemo   // screenshots show it on
        let icon = NSImageView(image: Pixel.clawd(px: 2.5, on: enabled))
        icon.imageScaling = .scaleNone
        icon.frame = NSRect(x: 12, y: 14, width: 44, height: 30)
        let title = NSTextField(labelWithString: "ClaudeSniper")
        title.font = .systemFont(ofSize: 14, weight: .bold)
        title.frame = NSRect(x: 62, y: 29, width: 160, height: 18)
        let sub = NSTextField(labelWithString: enabled ? "On · press \(hotkeyLabel) to capture" : "Off")
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = enabled ? claudeOrange : .secondaryLabelColor
        sub.frame = NSRect(x: 62, y: 12, width: 180, height: 15)
        let sw = NSSwitch(frame: NSRect(x: menuWidth - 14 - 40, y: 18, width: 40, height: 22))
        sw.state = enabled ? .on : .off
        sw.target = self
        sw.action = #selector(switchChanged(_:))
        [icon, title, sub, sw].forEach { v.addSubview($0) }
        return v
    }

    func segmentView(title: String, opts: [Opt], selected: String, action: Selector) -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: menuWidth, height: 50))
        let l = NSTextField(labelWithString: title)
        l.font = .systemFont(ofSize: 10, weight: .semibold)
        l.textColor = .secondaryLabelColor
        l.frame = NSRect(x: 14, y: 32, width: menuWidth - 28, height: 14)
        let seg = NSSegmentedControl(labels: opts.map { $0.label }, trackingMode: .selectOne, target: self, action: action)
        lastSeg = seg
        lastSegLabel = l
        seg.controlSize = .small
        seg.segmentDistribution = .fillEqually
        seg.selectedSegment = opts.firstIndex { $0.id == selected } ?? 0
        seg.frame = NSRect(x: 12, y: 6, width: menuWidth - 24, height: 22)
        if #available(macOS 14.0, *) { seg.selectedSegmentBezelColor = claudeOrange }
        for (i, o) in opts.enumerated() where !o.detail.isEmpty { seg.setToolTip(o.detail, forSegment: i) }
        v.addSubview(l); v.addSubview(seg)
        return v
    }

    var modeTitle: NSTextField?

    func modeView() -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: menuWidth, height: 54))
        let l = NSTextField(labelWithString: "")
        l.frame = NSRect(x: 14, y: 34, width: menuWidth - 28, height: 14)
        modeTitle = l
        setModeTitle()
        let seg = NSSegmentedControl(images: builtInModes.map { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: $0.label)! },
                                     trackingMode: .selectOne, target: self, action: #selector(modeChanged(_:)))
        seg.segmentDistribution = .fillEqually
        seg.selectedSegment = builtInModes.firstIndex { $0.id == defaultMode } ?? -1
        seg.frame = NSRect(x: 12, y: 6, width: menuWidth - 24, height: 24)
        if #available(macOS 14.0, *) { seg.selectedSegmentBezelColor = claudeOrange }
        for (i, m) in builtInModes.enumerated() { seg.setToolTip("\(m.label) — key \(i + 1) in the pop-up", forSegment: i) }
        v.addSubview(l); v.addSubview(seg)
        return v
    }

    func setModeTitle() {
        let s = NSMutableAttributedString(string: "DEFAULT MODE  ", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor])
        s.append(NSAttributedString(string: mode(defaultMode).label, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: claudeOrange]))
        modeTitle?.attributedStringValue = s
    }

    @objc func modeChanged(_ s: NSSegmentedControl) {
        defaults.set(builtInModes[s.selectedSegment].id, forKey: "mode")
        setModeTitle()
    }

    // MARK: Your own modes

    func myModesItem() -> NSMenuItem {
        let it = item("My modes", "star", nil)
        let m = NSMenu()
        for (i, c) in customModes.enumerated() {
            let o = NSMenuItem(title: "\(c.name)   ·   key \(builtInModes.count + i + 1)", action: #selector(useCustomMode(_:)), keyEquivalent: "")
            o.target = self
            o.representedObject = "custom:" + c.name
            o.state = defaultMode == "custom:" + c.name ? .on : .off
            o.toolTip = c.instruction
            m.addItem(o)
        }
        if !customModes.isEmpty { m.addItem(.separator()) }
        if customModes.count < 3 {
            m.addItem(item("New mode…", "plus", #selector(newCustomMode)))
        } else {
            let full = NSMenuItem(title: "You have 3 modes (the maximum)", action: nil, keyEquivalent: "")
            m.addItem(full)
        }
        if !customModes.isEmpty {
            let del = item("Delete a mode", "trash", nil)
            let dm = NSMenu()
            for c in customModes {
                let o = NSMenuItem(title: c.name, action: #selector(deleteCustomMode(_:)), keyEquivalent: "")
                o.target = self
                o.representedObject = c.name
                dm.addItem(o)
            }
            del.submenu = dm
            m.addItem(del)
        }
        it.submenu = m
        return it
    }

    @objc func useCustomMode(_ i: NSMenuItem) { defaults.set(i.representedObject as? String, forKey: "mode") }

    @objc func deleteCustomMode(_ i: NSMenuItem) {
        guard let n = i.representedObject as? String else { return }
        customModes.removeAll { $0.name == n }
        if defaultMode == "custom:" + n { defaults.set("auto", forKey: "mode") }
        if popup.mode == "custom:" + n { popup.mode = "auto" }
        popup.refreshModeBar()
    }

    @objc func newCustomMode() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "New mode"
        a.informativeText = "Give it a short name and tell Claude what to do with each capture."
        let name = NSTextField(frame: NSRect(x: 0, y: 96, width: 340, height: 24))
        name.placeholderString = "Name, e.g. Flashcards"
        let instr = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 88))
        instr.placeholderString = "Instruction, e.g. Turn it into 3 question-and-answer flashcards."
        instr.cell?.wraps = true
        instr.cell?.isScrollable = false
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 120))
        v.addSubview(name); v.addSubview(instr)
        a.accessoryView = v
        a.addButton(withTitle: "Add")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = name
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let n = String(name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(18))
        let s = instr.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !s.isEmpty, !customModes.contains(where: { $0.name == n }), customModes.count < 3 else { NSSound.beep(); return }
        customModes.append(CustomMode(name: n, instruction: s))
        popup.refreshModeBar()
    }

    // MARK: Last answer, history and export

    @objc func showLast() {
        guard let s = lastShown else { NSSound.beep(); return }
        mini.hide()
        miniPending = nil
        popup.mode = s.mode
        popup.captureTables = s.tables
        popup.allowReplace = s.replace
        var chat = history.chat(s.chatID)
        if let id = s.entryID, let i = chat.firstIndex(where: { $0.id == id }) { chat = Array(chat[...i]) }
        popup.thread = chat
        popup.show(header: s.header, preview: s.preview, state: .result(s.text), footer: s.footer)
    }

    /// A saved answer, ready to show in the pop-up again.
    func shown(from e: HistoryEntry) -> Shown {
        let m = builtInModes.first { $0.label == e.mode }?.id ?? (customModes.contains { $0.name == e.mode } ? "custom:" + e.mode : "auto")
        let footer = store.active?.id == e.chatID ? chatFooter() : "From History · follow-ups continue this chat"
        return Shown(header: e.model, preview: e.followUp.map { "↳ " + $0 } ?? e.capture, text: e.answer, mode: m,
                     footer: footer, replace: e.followUp == nil, chatID: e.chatID, entryID: e.id)
    }

    /// History → "Open in pop-up": shows the answer; follow-up questions continue that chat.
    func openFromHistory(_ e: HistoryEntry) {
        lastSessionID = e.chatID
        if e.capture != "[image]" { lastCapture = Capture(text: e.capture, imagePath: nil, preview: e.capture) }
        lastShown = shown(from: e)
        popup.showThread = false
        showLast()
    }

    func retryLast() {
        guard let r = lastRequest else { return }
        ask(prompt: r.prompt, image: r.image, preview: r.preview, followUp: r.followUp)
    }

    var welcome: WelcomeWindowController?
    @objc func openWelcome() {
        if welcome == nil { welcome = WelcomeWindowController() }
        welcome?.show()
    }

    /// The welcome guide's test: a real answer about a sample sentence.
    func trySample() {
        let t = "A menu bar app lives in the top bar of your Mac and stays out of your way until you need it."
        lastCapture = Capture(text: t, imagePath: nil, preview: t)
        run(lastCapture!, modeID: "explain", again: false)
    }

    @objc func openHistory() {
        if historyWindow == nil { historyWindow = HistoryWindowController(store: history) }
        historyWindow?.show()
    }

    var currentChatID: String? { store.activeID ?? lastSessionID }
    @objc func exportCurrentMarkdown() { if let id = currentChatID { exportMarkdown(chatID: id) } else { NSSound.beep() } }
    @objc func exportCurrentNotes() { if let id = currentChatID { exportNotes(chatID: id) } else { NSSound.beep() } }

    func exportMarkdown(chatID: String) {
        let items = history.chat(chatID)
        guard !items.isEmpty else { alert("Nothing to export yet", "This chat has no saved answers."); return }
        NSApp.activate(ignoringOtherApps: true)
        let p = NSSavePanel()
        p.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH.mm"
        p.nameFieldStringValue = "ClaudeSniper chat \(df.string(from: items[0].date)).md"
        guard p.runModal() == .OK, let u = p.url else { return }
        do {
            try chatMarkdown(items).write(to: u, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([u])
        } catch { alert("Couldn't save the file", error.localizedDescription) }
    }

    func exportNotes(chatID: String) {
        let items = history.chat(chatID)
        guard !items.isEmpty else { alert("Nothing to export yet", "This chat has no saved answers."); return }
        let html = chatHTML(items).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var err: NSDictionary?
        NSAppleScript(source: "tell application \"Notes\" to make new note with properties {body:\"\(html)\"}")?.executeAndReturnError(&err)
        if let err {
            alert("Couldn't export to Notes",
                  "\(err[NSAppleScript.errorMessage] ?? "Unknown error")\n\nAllow ClaudeSniper to control Notes in System Settings → Privacy & Security → Automation.")
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Notes.app"))
        }
    }

    func alert(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.runModal()
    }

    // MARK: Settings menu

    final class Choice: NSObject { let key: String; let value: Any; init(_ k: String, _ v: Any) { key = k; value = v } }

    func choiceMenu(_ title: String, _ symbol: String, key: String, options: [(Any, String)], isOn: (Any) -> Bool) -> NSMenuItem {
        let cur = options.first { isOn($0.0) }?.1 ?? ""
        let it = item("\(title): \(cur.components(separatedBy: " · ").first!)", symbol, nil)
        let sub = NSMenu()
        for (v, l) in options {
            let o = NSMenuItem(title: l, action: #selector(choicePicked(_:)), keyEquivalent: "")
            o.target = self
            o.representedObject = Choice(key, v)
            o.state = isOn(v) ? .on : .off
            sub.addItem(o)
        }
        it.submenu = sub
        return it
    }

    func toggle(_ title: String, _ symbol: String, key: String) -> NSMenuItem {
        let it = item(title, symbol, #selector(togglePicked(_:)))
        it.representedObject = key
        it.state = defaults.bool(forKey: key) ? .on : .off
        return it
    }

    func settingsItem() -> NSMenuItem {
        let s = item("Settings", "gearshape", nil)
        let m = NSMenu()
        if loggedIn == true {
            let acct = NSMenuItem(title: "Signed in to Claude" + (account.isEmpty ? "" : " · \(account)"), action: nil, keyEquivalent: "")
            acct.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [.systemGreen]))
            m.addItem(acct)
            m.addItem(.separator())
        }
        m.addItem(choiceMenu("Chat memory", "clock.arrow.circlepath", key: "chatMinutes", options: chatMemoryOptions,
                             isOn: { ($0 as? Int) == Settings.chatMinutes }))
        m.addItem(choiceMenu("Answer length", "text.alignleft", key: "answerLength", options: lengthOptions,
                             isOn: { ($0 as? String) == Settings.answerLength }))
        m.addItem(choiceMenu("Pop-up position", "macwindow", key: "popupPosition", options: positionOptions,
                             isOn: { ($0 as? String) == Settings.popupPosition }))
        m.addItem(choiceMenu("Close pop-up", "timer", key: "autoClose", options: autoCloseOptions,
                             isOn: { ($0 as? Int) == Settings.autoClose }))
        m.addItem(.separator())
        let cc = item("Copy captured text to the clipboard", "text.viewfinder", #selector(toggleCopyCapture))
        cc.state = Settings.copyCapture ? .on : .off
        m.addItem(cc)
        let kb = item("Keep line breaks in captured text", "text.alignleft", #selector(toggleLineBreaks))
        kb.state = Settings.keepLineBreaks ? .on : .off
        m.addItem(kb)
        m.addItem(toggle("Copy the answer automatically", "doc.on.clipboard", key: "autoCopy"))
        m.addItem(toggle("Play a sound when the answer arrives", "speaker.wave.2", key: "sound"))
        m.addItem(toggle("Mini Clawd: answers wait in a tiny Clawd", "face.smiling", key: "miniMode"))
        if AXIsProcessTrusted() {
            let ap = NSMenuItem(title: "Auto-paste for Replace is on", action: nil, keyEquivalent: "")
            ap.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
            m.addItem(ap)
        } else {
            m.addItem(item("Allow auto-paste for Replace…", "arrow.down.doc", #selector(allowAutoPaste)))
        }
        let li = item("Open at login", "power", #selector(toggleLoginItem))
        li.state = SMAppService.mainApp.status == .enabled ? .on : .off
        m.addItem(li)
        m.addItem(.separator())
        m.addItem(item("Change capture shortcut (\(hotkeyLabel))…", "keyboard", #selector(changeShortcut)))
        m.addItem(item("Welcome guide…", "hand.wave", #selector(openWelcome)))
        if hotkeyLabel != defaultHotkeyLabel { m.addItem(item("Reset shortcut to \(defaultHotkeyLabel)", "arrow.uturn.backward", #selector(resetShortcut))) }
        let clear = item("Clear all chats", "trash", #selector(clearChats))
        clear.isEnabled = !store.recent.isEmpty
        m.addItem(clear)
        s.submenu = m
        return s
    }

    @objc func choicePicked(_ i: NSMenuItem) { if let c = i.representedObject as? Choice { defaults.set(c.value, forKey: c.key) } }
    @objc func togglePicked(_ i: NSMenuItem) { if let k = i.representedObject as? String { defaults.set(!defaults.bool(forKey: k), forKey: k) } }
    @objc func clearChats() { store.clearAll() }
    @objc func toggleCopyCapture() { defaults.set(!Settings.copyCapture, forKey: "copyCapture") }
    @objc func toggleLineBreaks() { defaults.set(!Settings.keepLineBreaks, forKey: "keepLineBreaks") }
    @objc func allowAutoPaste() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    var recorder: KeyPanel?
    var recorderMonitor: Any?

    /// Records a new capture shortcut: press it in the small window that opens.
    @objc func changeShortcut() {
        endRecording()
        let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 130), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        p.title = "Capture shortcut"
        p.level = .floating
        p.isReleasedWhenClosed = false
        let l = NSTextField(wrappingLabelWithString: "Press the shortcut you want for capturing.\nIt needs ⌘, ⌃ or ⌥. Esc cancels.")
        l.alignment = .center
        l.font = .systemFont(ofSize: 13)
        l.frame = NSRect(x: 20, y: 35, width: 320, height: 60)
        p.contentView?.addSubview(l)
        p.center()
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        recorder = p
        recorderMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.recorder?.isKeyWindow == true else { return e }
            if e.keyCode == UInt16(kVK_Escape) { self.endRecording(); return nil }
            let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
            guard !mods.intersection([.command, .control, .option]).isEmpty else { NSSound.beep(); return nil }
            let key = (e.characters(byApplyingModifiers: []) ?? e.charactersIgnoringModifiers ?? "?").uppercased()
            var lbl = ""
            if mods.contains(.control) { lbl += "⌃" }
            if mods.contains(.option) { lbl += "⌥" }
            if mods.contains(.shift) { lbl += "⇧" }
            if mods.contains(.command) { lbl += "⌘" }
            self.setShortcut(code: Int(e.keyCode), mods: mods.rawValue, label: lbl + key)
            self.endRecording()
            return nil
        }
    }

    @objc func resetShortcut() {
        setShortcut(code: Int(kVK_ANSI_1), mods: NSEvent.ModifierFlags([.command, .shift]).rawValue, label: defaultHotkeyLabel)
    }

    func setShortcut(code: Int, mods: UInt, label: String) {
        hotkeyCode = code; hotkeyMods = mods; hotkeyLabel = label
        defaults.set(code, forKey: "hotkeyCode")
        defaults.set(Int(mods), forKey: "hotkeyMods")
        defaults.set(label, forKey: "hotkeyLabel")
        if enabled { registerCaptureHotkey() }
    }

    func registerCaptureHotkey() {
        setHotkey(hotKeyCapture, code: hotkeyCode, mods: NSEvent.ModifierFlags(rawValue: hotkeyMods))
        setHotkey(hotKeyTextOnly, code: Int(kVK_ANSI_1), mods: [.command, .option])   // ⌥⌘1: copy the text only
        setHotkey(hotKeyShot, code: Int(kVK_ANSI_3), mods: [.command, .option])       // ⌥⌘3: screenshot
        setHotkey(hotKeyScroll, code: Int(kVK_ANSI_4), mods: [.command, .option])     // ⌥⌘4: scrolling capture
    }

    func endRecording() {
        if let m = recorderMonitor { NSEvent.removeMonitor(m) }
        recorderMonitor = nil
        recorder?.orderOut(nil)
        recorder = nil
    }

    @objc func languageChanged(_ i: NSMenuItem) { defaults.set(i.representedObject as? String, forKey: "answerLanguage") }

    @objc func switchChanged(_ s: NSSwitch) {
        enabled = s.state == .on
        if let m = statusItem.menu, let first = m.items.first { first.view = headerView() }
    }
    /// The first segment is ⚡ Fast (Super fast mode); the rest are the models.
    @objc func modelChanged(_ s: NSSegmentedControl) {
        let fast = s.selectedSegment == 0
        defaults.set(fast, forKey: "superFast")
        if fast { prewarm() } else {
            defaults.set(models[s.selectedSegment - 1].id, forKey: "model")
            stopWarm()
        }
        effortSeg?.isEnabled = !fast
        effortLabel?.stringValue = fast ? "EFFORT · not used in Fast" : "EFFORT"
    }
    @objc func effortChanged(_ s: NSSegmentedControl) { defaults.set(efforts[s.selectedSegment].id, forKey: "effort") }
    @objc func testNow() { handleClipboard() }
    @objc func newChat() { store.newChat() }
    @objc func switchChat(_ i: NSMenuItem) { if let id = i.representedObject as? String { store.switchTo(id) } }

    @objc func toggleLoginItem() {
        let s = SMAppService.mainApp
        do { s.status == .enabled ? try s.unregister() : try s.register() } catch { NSSound.beep() }
    }

    @objc func askKeyboardPermission() {
        CGRequestListenEventAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    @objc func login() {
        guard let claude = findClaude() else { return }
        let path = workDir + "/login.command"
        let script = """
        #!/bin/zsh
        unset ANTHROPIC_BASE_URL ANTHROPIC_API_KEY CLAUDECODE
        echo "Sign in with your Claude account (your Pro/Max plan)…"
        "\(claude)" auth login
        echo; echo "Done. You can close this window."
        """
        try? script.write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o755)
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    var lastAuthCheck = Date.distantPast

    /// Asks Claude Code whether you're signed in. From the menu, at most once a minute.
    func refreshAuth(_ done: ((Bool) -> Void)? = nil) {
        guard let claude = findClaude() else { done?(false); return }
        if done == nil && loggedIn == true && Date().timeIntervalSince(lastAuthCheck) < 60 { return }
        lastAuthCheck = Date()
        DispatchQueue.global().async {
            let out = runSync(claude, ["auth", "status"], stdin: nil, timeout: 20).output
            var ok = false, acct = ""
            if let start = out.firstIndex(of: "{"),
               let obj = try? JSONSerialization.jsonObject(with: Data(out[start...].utf8)) as? [String: Any] {
                ok = obj["loggedIn"] as? Bool ?? false
                acct = (obj["email"] ?? obj["subscriptionType"]) as? String ?? ""
            }
            DispatchQueue.main.async { self.loggedIn = ok; self.account = isDemo ? "" : acct; done?(ok) }
        }
    }

    // MARK: Monitoring

    func startMonitoring() {
        installTap()  // optional: only works if Input Monitoring is allowed
        lastChange = NSPasteboard.general.changeCount
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.poll() }
    }

    func stopMonitoring() {
        pollTimer?.invalidate(); pollTimer = nil
        armedUntil = .distantPast
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
        tap = nil
    }

    func installTap() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .listenOnly, eventsOfInterest: mask,
                                        callback: tapCallback, userInfo: nil) else { return }
        tap = t
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
    }

    func hotkeyPressed() {
        guard enabled else { return }
        lastChange = NSPasteboard.general.changeCount
        armedUntil = Date().addingTimeInterval(30)  // time to select the area
        lastActivity = Date()
        prewarm()   // Super fast: get a process ready while you select
    }

    func poll() {
        pollCount += 1
        if pollCount % 150 == 0 { tidyWarm() }   // every 30 s
        if tap == nil && CGPreflightListenEventAccess() { installTap() }
        let c = NSPasteboard.general.changeCount
        guard c != lastChange else { return }
        lastChange = c
        // Two ways to know the copy came from TextSniper:
        // 1. its capture overlay is on screen (no permission needed), or
        // 2. the capture shortcut was just pressed (needs Input Monitoring).
        if Date() < armedUntil || textSniperIsCapturing() {
            armedUntil = .distantPast
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.handleClipboard() }
        } else {
            // The overlay can lag the clipboard by a moment: look once more.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if self.lastChange == c && self.textSniperIsCapturing() { self.handleClipboard() }
            }
        }
    }

    /// True while TextSniper shows a capture window (anything above normal windows
    /// that isn't its menu bar icon). Reading window owners needs no permission.
    func textSniperIsCapturing() -> Bool {
        let wins = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return wins.contains { w in
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            return owner.hasPrefix("TextSniper") && layer > 0 && layer != 25
        }
    }

    // MARK: Claude

    func chatFooter() -> String {
        if let c = store.active {
            return "Chat · \(c.count) capture\(c.count == 1 ? "" : "s") · \(ChatStore.minutesLeft(c)) min left"
        }
        return Settings.chatMinutes == 0 ? "Chat memory is off" : "New chat · your next capture starts fresh"
    }

    // MARK: Screen recording permission

    /// Without it, macOS asks on every capture, and scrolling capture can't work.
    var hasScreenAccess: Bool { CGPreflightScreenCaptureAccess() }

    @objc func askScreenAccess() {
        CGRequestScreenCaptureAccess()   // adds ClaudeSniper to the list in System Settings
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    func explainScreenAccess() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Scrolling capture needs screen recording"
        a.informativeText = "Turn on ClaudeSniper in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen ClaudeSniper."
        a.addButton(withTitle: "Open Settings")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { askScreenAccess() }
    }

    // MARK: Screenshots

    @objc func takeScreenshot() { shoot(["-i"]) }
    @objc func takeWindowShot() { shoot(["-i", "-W"]) }
    @objc func scrollingCapture() { ScrollCapture.start() }

    /// A plain screenshot: the system's selection, then the thumbnail overlay.
    func shoot(_ flags: [String]) {
        guard !capturing else { return }
        capturing = true
        let path = workDir + "/shot-\(Int(Date().timeIntervalSince1970)).png"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = flags + ["-x", "-t", "png", path]
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.capturing = false
                if FileManager.default.fileExists(atPath: path) { QuickAccess.shared.show(path) }
            }
        }
        do { try p.run() } catch { capturing = false; NSSound.beep() }
    }

    /// Reads an image we already have (a screenshot, a photo from the iPhone) like a capture.
    func readImage(at source: String, kind: CaptureKind) {
        let path = workDir + "/capture-\(Int(Date().timeIntervalSince1970))-\(Int.random(in: 100...999)).png"
        guard (try? FileManager.default.copyItem(atPath: source, toPath: path)) != nil else { NSSound.beep(); return }
        if kind != .textOnly { setBusy(true); prewarm() }
        DispatchQueue.global(qos: .userInitiated).async {
            let r = recognizeText(at: path)
            DispatchQueue.main.async { self.captured(r, imagePath: path, kind: kind) }
        }
    }

    // MARK: Import from iPhone or iPad (Continuity Camera)

    /// macOS fills the "Import from iPhone or iPad" menu when something accepts an image.
    @objc func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if let t = returnType, NSImage.imageTypes.contains(t.rawValue) { return self }
        return nil
    }

    /// The photo or scan taken with the phone arrives here.
    @objc func readSelection(from pboard: NSPasteboard) -> Bool {
        guard let img = NSImage(pasteboard: pboard), let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return false }
        let tmp = NSTemporaryDirectory() + "claudesniper-phone-\(UUID().uuidString).png"
        guard (try? png.write(to: URL(fileURLWithPath: tmp))) != nil else { return false }
        readImage(at: tmp, kind: .ask)
        return true
    }

    // MARK: Capturing the screen

    /// What to do with a capture: ask Claude, only copy its text, or add it to the current question.
    enum CaptureKind { case ask, textOnly, add }
    var capturing = false

    @objc func captureScreen() { startCapture(.ask) }
    /// Like an OCR tool: read the text and copy it, without asking Claude.
    @objc func captureTextOnly() { startCapture(.textOnly) }
    /// Multi-capture: one question about several pieces (two pages, a question and its chart).
    @objc func addCapture() {
        guard lastCapture?.text != nil else { NSSound.beep(); return }
        popup.panel.orderOut(nil)   // out of the way while you select
        startCapture(.add)
    }

    /// Lets you drag over part of the screen (the system's own selection, like ⌘⇧4)
    /// and reads the text on this Mac. Esc cancels.
    func startCapture(_ kind: CaptureKind) {
        guard !capturing else { return }
        capturing = true
        lastActivity = Date()
        if kind != .textOnly { prewarm() }   // Fast: get a process ready while you select
        let path = workDir + "/capture-\(Int(Date().timeIntervalSince1970)).png"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-i", "-x", "-t", "png", path]
        p.terminationHandler = { [weak self] _ in
            let exists = FileManager.default.fileExists(atPath: path)
            if exists && kind != .textOnly { DispatchQueue.main.async { self?.setBusy(true) } }
            let r = exists ? recognizeText(at: path) : ("", "", [])
            DispatchQueue.main.async {
                guard let self else { return }
                self.capturing = false
                if exists { self.captured(r, imagePath: path, kind: kind) }   // no file: you pressed esc
            }
        }
        do { try p.run() } catch { capturing = false; NSSound.beep() }
    }

    func copyCaptured(_ t: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string)
        lastChange = NSPasteboard.general.changeCount   // our own copy isn't a new capture
    }

    /// A capture was read: text goes to Claude as text; a capture with no text goes as an image.
    func captured(_ r: (text: String, forClaude: String, tables: [Table]), imagePath: String, kind: CaptureKind = .ask) {
        var t = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var forClaude = r.forClaude.trimmingCharacters(in: .whitespacesAndNewlines)
        if !Settings.keepLineBreaks && r.tables.isEmpty {
            if forClaude == t { forClaude = joinLines(t) }
            t = joinLines(t)
        }

        if kind == .textOnly {
            try? FileManager.default.removeItem(atPath: imagePath)
            if t.isEmpty { Toast.show("No text found") } else {
                copyCaptured(t)
                let words = t.split { $0 == " " || $0 == "\n" }.count
                Toast.show("Copied · \(words) word\(words == 1 ? "" : "s")")
            }
            return
        }
        if kind == .add, let prev = lastCapture, let prevText = prev.text, !t.isEmpty {
            let n = prev.parts + 1
            let text = (prev.parts == 1 ? "[Part 1]\n" + prevText : prevText) + "\n\n[Part \(n)]\n" + forClaude
            let plain = prev.preview + "\n\n" + t
            lastCapture = Capture(text: text, imagePath: imagePath, preview: plain, tables: prev.tables + r.tables, parts: n)
            if Settings.copyCapture { copyCaptured(plain) }
            run(lastCapture!, modeID: popup.mode, again: false)
            return
        }
        if t.isEmpty {
            lastCapture = Capture(text: nil, imagePath: imagePath, preview: "🖼  Captured image")
        } else {
            lastCapture = Capture(text: forClaude, imagePath: imagePath, preview: t, tables: r.tables)
            if Settings.copyCapture { copyCaptured(t) }
        }
        run(lastCapture!, modeID: testMode ?? defaultMode, again: false)
    }

    /// Right-click selected text in any app → Services → "Ask ClaudeSniper".
    @objc func askSelection(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let t = pboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return }
        lastCapture = Capture(text: t, imagePath: nil, preview: t)
        run(lastCapture!, modeID: defaultMode, again: false)
    }

    /// The text reader missed something (a diagram, a formula, tricky code): let Claude see the image.
    var canSendImage: Bool {
        guard let c = lastCapture, c.text != nil, let p = c.imagePath else { return false }
        return FileManager.default.fileExists(atPath: p)
    }
    /// For tables the on-device reader misses (dark backgrounds, merged cells, older macOS):
    /// Claude reads the image and returns the table, which "Copy table" then copies.
    var canExtractTable: Bool {
        guard let p = lastCapture?.imagePath else { return false }
        return FileManager.default.fileExists(atPath: p)
    }
    @objc func extractTable() {
        guard canExtractTable, let c = lastCapture else { NSSound.beep(); return }
        run(Capture(text: nil, imagePath: c.imagePath, preview: c.preview), modeID: popup.mode, again: true,
            task: ("Table", "Extract the table in the image. Return only a Markdown table with the same rows and columns, keeping every number and word exactly as written, with no commentary before or after. If there are several tables, return each as its own Markdown table."))
    }

    @objc func rerunWithImage() {
        guard canSendImage, let c = lastCapture else { NSSound.beep(); return }
        run(Capture(text: nil, imagePath: c.imagePath, preview: c.preview), modeID: popup.mode, again: true)
    }

    func handleClipboard() {
        let pb = NSPasteboard.general
        if let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lastCapture = Capture(text: s, imagePath: nil, preview: s)
        } else if let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            let path = workDir + "/capture-\(Int(Date().timeIntervalSince1970)).png"
            try? png.write(to: URL(fileURLWithPath: path))
            lastCapture = Capture(text: nil, imagePath: path, preview: "🖼  Captured image")
        } else {
            popup.show(header: header(), preview: "", state: .error("The clipboard is empty."), footer: chatFooter())
            return
        }
        run(lastCapture!, modeID: testMode ?? defaultMode, again: false)
    }

    /// Sends a capture with a mode. `again` = the same capture re-run from the pop-up.
    func run(_ c: Capture, modeID: String, again: Bool, task: (label: String, instruction: String)? = nil) {
        var m = mode(modeID)
        if let task { m = Mode(id: m.id, label: task.label, symbol: m.symbol, instruction: task.instruction) }
        popup.captureTables = c.tables
        let fresh = c.parts > 1 ? "New capture in \(c.parts) parts: answer about all of them together." : "New capture."
        let head = again ? (c.text == nil && c.imagePath != nil ? "Same capture as before; this time look at the image itself." : "Same capture as before, now in another mode.") : fresh
        let body: String
        if let t = c.text {
            body = "\(head)\nMODE: \(m.label) — \(m.instruction)\n\nCapture:\n\n\(t)"
        } else {
            body = "\(head) It is an image: read it at \(c.imagePath!) with the Read tool.\nMODE: \(m.label) — \(m.instruction)"
        }
        popup.mode = m.id
        ask(prompt: body, image: c.text == nil, preview: c.preview)
    }

    func rerun(modeID: String) {
        guard let c = lastCapture else { NSSound.beep(); return }
        run(c, modeID: modeID, again: true)
    }

    func header() -> String {
        Settings.superFast ? "⚡ Fast · Haiku" : "\(label(models, model)) · \(label(efforts, effort).lowercased())"
    }

    func ask(prompt: String, image: Bool, preview: String, followUp: String? = nil, allowWarm: Bool = true, retried: Bool = false) {
        guard let claude = findClaude() else {
            popup.show(header: header(), preview: preview, state: .error("Claude Code wasn't found. Install it with:\ncurl -fsSL https://claude.ai/install.sh | bash"), footer: "")
            return
        }
        current?.process.terminate()
        current = nil
        requestID += 1
        lastRequest = Request(prompt: prompt, image: image, preview: preview, followUp: followUp)
        lastActivity = Date()
        // Mini Clawd: only when the pop-up isn't already open (re-runs and follow-ups stay in it).
        miniThisRequest = Settings.miniMode && !popup.panel.isVisible
        let myID = requestID
        let hdr = header()
        let modeLabel = mode(popup.mode).label
        let captureText = lastCapture?.text ?? "[image]"
        popup.allowReplace = followUp == nil
        let fast = Settings.superFast
        let sys = systemPrompt(language: answerLanguageName(answerLanguage), length: Settings.answerLength)

        // A follow-up always continues the conversation of the last answer.
        let existing = store.active
        let resumeID = followUp != nil ? lastSessionID : existing?.id
        // Super fast: use a Claude Code process that is already running and waiting.
        let warm = fast && allowWarm ? warmProcess(resumeID: resumeID, systemPrompt: sys) : nil
        let sessionID = warm?.sessionID ?? resumeID ?? UUID().uuidString.lowercased()
        let activeAtStart = store.activeID
        let title = preview.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)

        display(header: hdr, preview: preview, state: .loading,
                footer: followUp != nil ? "Follow-up · same chat"
                    : existing.map { "Chat · \($0.count) capture\($0.count == 1 ? "" : "s") · continuing" } ?? "Starting a new chat…")

        let t0 = Date()
        var firstText = true
        func logTiming(_ what: String) {   // only when testing with --interpret-clipboard
            guard self.testTimingLog else { return }
            let line = String(format: "%@ %@ %.2fs\n", followUp == nil ? "capture" : "follow-up", what, Date().timeIntervalSince(t0))
            if let h = FileHandle(forWritingAtPath: workDir + "/timing.log") { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
            else { try? line.write(toFile: workDir + "/timing.log", atomically: true, encoding: .utf8) }
        }
        let finish: (Int32, String, Bool, String) -> Void = { status, raw, isError, errRaw in
            guard myID == self.requestID else { return }
            logTiming("full answer (\(warm != nil ? "preloaded" : "normal"))" + (status == 0 && !isError ? "" : " ERROR status=\(status) isError=\(isError) text=\(raw.prefix(200)) err=\(errRaw.prefix(300))"))
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let errText = errRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            if status == 0 && !isError && !text.isEmpty {
                self.lastSessionID = sessionID
                // If the user switched or reset the chat while waiting, don't override that.
                self.store.record(id: sessionID, title: String(title.prefix(60)),
                                  makeActive: self.store.activeID == activeAtStart)
                self.history.add(HistoryEntry(chatID: sessionID, mode: modeLabel, model: hdr,
                                              capture: captureText, followUp: followUp, answer: text))
                let footer = self.chatFooter()
                self.popup.thread = self.history.chat(sessionID)
                self.display(header: hdr, preview: preview, state: .result(text), footer: footer)
                self.lastShown = Shown(header: hdr, preview: preview, text: text, mode: self.popup.mode, footer: footer, replace: followUp == nil, chatID: sessionID, tables: self.popup.captureTables)
                if Settings.autoCopy {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    self.lastChange = NSPasteboard.general.changeCount  // don't treat this as a capture
                }
                if Settings.sound { NSSound(named: "Pop")?.play() }
                if let q = self.pendingFollowUp {
                    self.pendingFollowUp = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.followUp(q) }
                }
                self.prewarm()  // get the next spare ready while you read
                return
            }
            let all = text + "\n" + errText
            if resumeID != nil && all.localizedCaseInsensitiveContains("no conversation found") {
                if followUp == nil { self.store.newChat() } else { self.lastSessionID = nil }
                self.ask(prompt: prompt, image: image, preview: preview, followUp: followUp)  // retry in a new chat
            } else if all.contains("authenticate") || all.contains("/login") || all.contains("401") {
                self.loggedIn = false
                self.display(header: hdr, preview: preview, state: .error("You're not signed in to Claude Code.\nSign in with your Claude account to continue."), footer: "")
            } else if !retried {
                // A hiccup (e.g. the session was busy for a moment): try once more the normal way.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.ask(prompt: prompt, image: image, preview: preview, followUp: followUp, allowWarm: false, retried: true)
                }
            } else {
                let msg = !text.isEmpty ? text : !errText.isEmpty ? errText : "Unknown error (code \(status))."
                self.display(header: hdr, preview: preview, state: .error(msg), footer: self.chatFooter())
            }
        }

        if let w = warm {
            w.handler = { [weak self] ev in
                guard let self, myID == self.requestID else { return }
                switch ev {
                case .text(let t):
                    if firstText && !t.isEmpty { firstText = false; logTiming("first words") }
                    if !t.isEmpty { self.display(header: hdr, preview: preview, state: .streaming(t), footer: "Writing…") }
                case .done(let r, let e):
                    finish(0, r, e, "")
                case .exited:
                    // The preloaded process stopped: answer the normal way instead.
                    if self.chatWarm === w { self.chatWarm = nil }
                    self.ask(prompt: prompt, image: image, preview: preview, followUp: followUp, allowWarm: false)
                }
            }
            if !w.send(prompt) {
                if chatWarm === w { chatWarm = nil }
                ask(prompt: prompt, image: image, preview: preview, followUp: followUp, allowWarm: false)
            }
            return
        }

        var args: [String]
        if fast {
            args = fastArgs(sys)
        } else {
            args = ["-p", "--model", model, "--effort", effort,
                    "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                    "--system-prompt", sys] + lightStart
            args += image ? ["--tools", "Read", "--allowedTools", "Read", "--add-dir", workDir] : ["--tools", ""]
        }
        args += resumeID == nil ? ["--session-id", sessionID] : ["--resume", sessionID]

        let run = StreamingRun()
        if fast { run.extraEnv = noThinkingEnv }
        current = run
        run.onText = { [weak self] t in
            guard let self, myID == self.requestID, !t.isEmpty else { return }
            if firstText { firstText = false; logTiming("first words") }
            self.display(header: hdr, preview: preview, state: .streaming(t), footer: "Writing…")
        }
        let started = run.start(claude, args, stdin: prompt, timeout: 300) { status, r in
            guard myID == self.requestID else { return }
            self.current = nil
            finish(status, r.result ?? r.text, r.isError, r.other)
        }
        if !started {
            display(header: hdr, preview: preview, state: .error("Couldn't start Claude Code: \(run.other)"), footer: "")
        }
    }

    // MARK: Super fast mode (preloaded Claude Code processes)

    var chatWarm: WarmProcess?    // the current chat, ready for the next capture
    var spareWarm: WarmProcess?   // a fresh session, ready for the next new chat

    /// Starts a spare process in the background so the next new chat answers right away.
    func prewarm() {
        guard Settings.superFast, enabled else { return }
        let sys = systemPrompt(language: answerLanguageName(answerLanguage), length: Settings.answerLength)
        if let s = spareWarm, s.alive, !s.used, s.key == sys { return }
        spareWarm?.stop()
        spareWarm = WarmProcess(sessionID: UUID().uuidString.lowercased(), resume: false, systemPrompt: sys)
    }

    /// Preloaded processes use memory: stop the chat's one when the chat expires, and the
    /// spare after 10 minutes without captures (the next answer then starts one again).
    func tidyWarm() {
        if let w = chatWarm, !w.busy, store.active?.id != w.sessionID { w.stop(); chatWarm = nil }
        if let s = spareWarm, !s.busy, Date().timeIntervalSince(lastActivity) > 600 { s.stop(); spareWarm = nil }
    }

    func stopWarm() {
        chatWarm?.stop(); spareWarm?.stop()
        chatWarm = nil; spareWarm = nil
    }

    /// The preloaded process to use for this request (starting one if needed).
    func warmProcess(resumeID: String?, systemPrompt sys: String) -> WarmProcess? {
        if let id = resumeID {
            if let w = chatWarm, w.sessionID == id, w.alive, !w.busy, w.key == sys { return w }
            chatWarm?.stop()
            chatWarm = WarmProcess(sessionID: id, resume: true, systemPrompt: sys)
            return chatWarm
        }
        var w = spareWarm
        if let s = w, !s.alive || s.used || s.busy || s.key != sys { s.stop(); w = nil }
        if w == nil { w = WarmProcess(sessionID: UUID().uuidString.lowercased(), resume: false, systemPrompt: sys) }
        spareWarm = nil
        chatWarm?.stop()
        chatWarm = w
        return w
    }

    /// A question about the last answer, typed in the pop-up (tab).
    func followUp(_ q: String) {
        let prompt = "Follow-up question about the previous capture. Answer it directly, with the same language and style rules:\n\n\(q)"
        ask(prompt: prompt, image: false, preview: "↳ " + q, followUp: q)
    }
}

// MARK: - Popup

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

/// Presses ⌘V in the front app (needs Accessibility permission).
func pasteKeystroke() {
    let src = CGEventSource(stateID: .combinedSessionState)
    let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
    let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
    down?.flags = .maskCommand
    up?.flags = .maskCommand
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
}

/// The answer pop-up.
///
///   [Clawd] Claude (model)                         [pin] [more] [close]
///   ▎ what you captured
///   (Auto) (Explain) (Translate) (Summarize) (Solve) (Fix) (★ yours)
///   the answer…
///   ─────────────────────────────────────────────────────────────────
///   Chat · 3 captures · 15 min left ›         [Ask ⇥] [Replace ⌘↩] [Copy ⌘C]
final class PopupController: NSObject, AVSpeechSynthesizerDelegate {
    enum State { case loading, streaming(String), result(String), error(String) }

    let width: CGFloat = 600
    let panel: KeyPanel
    // Header
    let clawdView = NSImageView()
    let titleLabel = NSTextField(labelWithString: "Claude")
    let chip = NSTextField(labelWithString: "")
    let chipBox = NSView()        // the pill behind the model label
    var stopBtn: HoverButton!     // only while reading aloud
    var pinBtn: HoverButton!
    var moreBtn: HoverButton!
    // Capture
    let quoteBox = NSView()
    let quoteBar = NSView()
    let quoteLabel = NSTextField(wrappingLabelWithString: "")
    // Modes
    let modeBar = NSStackView()
    var modeButtons: [HoverButton] = []
    var customPill: HoverButton!
    // Answer
    let scroll = NSScrollView()
    let textView = NSTextView()
    // Bottom bar
    let statusBtn = HoverButton()
    let actions = NSStackView()
    let askField = NSTextField()
    var askBtn: HoverButton!
    var copyBtn: HoverButton!
    var replaceBtn: HoverButton!
    var retryBtn: HoverButton!
    var fixBtn: HoverButton!      // "Sign in…" or "Set up…" on errors
    var tableBtn: HoverButton!
    /// Tables detected in the capture; a table in the answer takes priority.
    var captureTables: [Table] = []
    var tables: [Table] = []

    let frames = Pixel.clawdFrames(px: 2)
    let idleImage = Pixel.clawd(px: 2)
    var frameIdx = 0
    var animTimer: Timer?
    var loadingSince = Date()
    var streamingNow = false
    var resultText = ""
    var errorMessage = ""
    var isError = false
    var footerText = ""
    var keyMonitor: Any?
    var mode = "auto" { didSet { refreshModeBar() } }
    /// False for follow-up answers: Replace would paste an explanation, not the fixed text.
    var allowReplace = true
    /// The whole chat, oldest first (the last entry is the answer on screen).
    var thread: [HistoryEntry] = []
    /// Show the whole conversation instead of only the last answer.
    var showThread = false
    /// Pinned: the pop-up doesn't close by itself or with esc (only with ✕).
    var pinned = false
    var lastArgs: (header: String, preview: String, footer: String)?
    let speech = AVSpeechSynthesizer()
    // Streaming is drawn at most ~30 times a second.
    var pendingStream: (String, String, State, String)?
    var streamTimer: Timer?
    var lastStreamRender = Date.distantPast

    var done: Bool { !resultText.isEmpty && !streamingNow && !isError }

    override init() {
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 220),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        super.init()
        speech.delegate = self
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)

        let bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.state = .active
        bg.blendingMode = .behindWindow
        bg.maskImage = Self.roundedMask(Theme.radius)
        panel.contentView = bg

        // A warm dark tint over the blur keeps the text readable on bright backgrounds.
        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(srgbRed: 0.10, green: 0.08, blue: 0.075, alpha: 0.5).cgColor
        tint.layer?.cornerRadius = Theme.radius
        tint.layer?.borderWidth = 1
        tint.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        clawdView.image = idleImage
        clawdView.imageScaling = .scaleNone
        titleLabel.font = .systemFont(ofSize: 14, weight: .bold)
        titleLabel.textColor = .white
        chip.font = .systemFont(ofSize: 10.5, weight: .semibold)
        chip.textColor = Theme.accentSoft
        chipBox.wantsLayer = true
        chipBox.layer?.backgroundColor = Theme.accent.withAlphaComponent(0.18).cgColor
        chipBox.layer?.cornerRadius = 9
        chip.translatesAutoresizingMaskIntoConstraints = false
        chipBox.addSubview(chip)

        stopBtn = iconButton("stop.fill", "Stop reading aloud", #selector(speak))
        stopBtn.contentTintColor = Theme.accent
        stopBtn.isHidden = true
        pinBtn = iconButton("pin", "Keep this pop-up open (⌘P)", #selector(togglePin))
        moreBtn = iconButton("ellipsis", "More", #selector(showMore(_:)))
        let closeBtn = iconButton("xmark", "Close (esc)", #selector(close))
        let headerButtons = NSStackView(views: [stopBtn, pinBtn, moreBtn, closeBtn])
        headerButtons.orientation = .horizontal
        headerButtons.spacing = 2

        quoteBox.wantsLayer = true
        quoteBox.layer?.backgroundColor = Theme.fill.cgColor
        quoteBox.layer?.cornerRadius = 9
        quoteBar.wantsLayer = true
        quoteBar.layer?.backgroundColor = Theme.accent.cgColor
        quoteBar.layer?.cornerRadius = 1.5
        quoteLabel.font = .systemFont(ofSize: 12)
        quoteLabel.textColor = Theme.ink2
        quoteLabel.maximumNumberOfLines = 2
        quoteLabel.lineBreakMode = .byTruncatingTail
        quoteLabel.cell?.truncatesLastVisibleLine = true

        modeBar.orientation = .horizontal
        modeBar.spacing = 5
        modeBar.alignment = .centerY
        for (i, m) in builtInModes.enumerated() {
            let b = pill(m.label, m.symbol, #selector(modeClicked(_:)))
            b.tag = i
            b.toolTip = "\(m.label) (key \(i + 1)): re-run this capture in this mode"
            modeButtons.append(b)
            modeBar.addArrangedSubview(b)
        }
        customPill = pill("My modes", "star", #selector(customPillClicked(_:)))
        customPill.toolTip = "Your own modes (keys 7–9)"
        modeBar.addArrangedSubview(customPill)
        refreshModeBar()

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.linkTextAttributes = [.foregroundColor: Theme.accentSoft, .underlineStyle: NSUnderlineStyle.single.rawValue]
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Theme.stroke.cgColor

        statusBtn.isBordered = false
        statusBtn.apply()
        statusBtn.target = self
        statusBtn.action = #selector(toggleThread)
        statusBtn.alignment = .left
        statusBtn.layer?.cornerRadius = 6
        statusBtn.cell?.lineBreakMode = .byTruncatingTail
        statusBtn.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusBtn.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        askBtn = actionButton("Ask", "⇥", #selector(showAsk))
        askBtn.toolTip = "Ask a follow-up in the same chat"
        replaceBtn = actionButton("Replace", "⌘↩", #selector(replaceResult), primary: true)
        replaceBtn.toolTip = "Paste this where you captured it"
        copyBtn = actionButton("Copy", "⌘C", #selector(copyResult))
        retryBtn = actionButton("Try again", "", #selector(retry))
        fixBtn = actionButton("Sign in…", "", #selector(fixProblem), primary: true)
        tableBtn = actionButton("Copy table", "⇧⌘C", #selector(copyTable))
        for b in [retryBtn, fixBtn, askBtn, replaceBtn, tableBtn, copyBtn] as [NSView] { actions.addArrangedSubview(b) }
        actions.orientation = .horizontal
        actions.spacing = 6

        askField.placeholderString = "Ask a follow-up…   ↩ send · esc cancel"
        askField.font = .systemFont(ofSize: 12.5)
        askField.bezelStyle = .roundedBezel
        askField.focusRingType = .none
        askField.isHidden = true
        askField.target = self
        askField.action = #selector(askSubmitted)

        let all: [NSView] = [tint, clawdView, titleLabel, chipBox, headerButtons, quoteBox, modeBar,
                             scroll, divider, statusBtn, actions, askField]
        for v in all { v.translatesAutoresizingMaskIntoConstraints = false; bg.addSubview(v) }
        for v in [quoteBar, quoteLabel] { v.translatesAutoresizingMaskIntoConstraints = false; quoteBox.addSubview(v) }

        NSLayoutConstraint.activate([
            tint.topAnchor.constraint(equalTo: bg.topAnchor),
            tint.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
            tint.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: bg.trailingAnchor),

            clawdView.topAnchor.constraint(equalTo: bg.topAnchor, constant: 14),
            clawdView.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 16),
            clawdView.widthAnchor.constraint(equalToConstant: 34),
            clawdView.heightAnchor.constraint(equalToConstant: 24),
            titleLabel.leadingAnchor.constraint(equalTo: clawdView.trailingAnchor, constant: 9),
            titleLabel.centerYAnchor.constraint(equalTo: clawdView.centerYAnchor),
            chipBox.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            chipBox.centerYAnchor.constraint(equalTo: clawdView.centerYAnchor),
            chipBox.heightAnchor.constraint(equalToConstant: 18),
            chip.leadingAnchor.constraint(equalTo: chipBox.leadingAnchor, constant: 8),
            chip.trailingAnchor.constraint(equalTo: chipBox.trailingAnchor, constant: -8),
            chip.centerYAnchor.constraint(equalTo: chipBox.centerYAnchor),
            headerButtons.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -10),
            headerButtons.centerYAnchor.constraint(equalTo: clawdView.centerYAnchor),

            quoteBox.topAnchor.constraint(equalTo: clawdView.bottomAnchor, constant: 12),
            quoteBox.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 16),
            quoteBox.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -16),
            quoteBar.leadingAnchor.constraint(equalTo: quoteBox.leadingAnchor, constant: 8),
            quoteBar.topAnchor.constraint(equalTo: quoteBox.topAnchor, constant: 8),
            quoteBar.bottomAnchor.constraint(equalTo: quoteBox.bottomAnchor, constant: -8),
            quoteBar.widthAnchor.constraint(equalToConstant: 3),
            quoteLabel.leadingAnchor.constraint(equalTo: quoteBar.trailingAnchor, constant: 9),
            quoteLabel.trailingAnchor.constraint(equalTo: quoteBox.trailingAnchor, constant: -10),
            quoteLabel.topAnchor.constraint(equalTo: quoteBox.topAnchor, constant: 7),
            quoteLabel.bottomAnchor.constraint(equalTo: quoteBox.bottomAnchor, constant: -7),

            modeBar.topAnchor.constraint(equalTo: quoteBox.bottomAnchor, constant: 10),
            modeBar.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 16),
            modeBar.heightAnchor.constraint(equalToConstant: 24),

            scroll.topAnchor.constraint(equalTo: modeBar.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 18),
            scroll.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: divider.topAnchor, constant: -10),

            divider.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 1),
            divider.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -1),
            divider.heightAnchor.constraint(equalToConstant: 1),
            divider.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -44),

            statusBtn.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 10),
            statusBtn.centerYAnchor.constraint(equalTo: bg.bottomAnchor, constant: -22),
            statusBtn.heightAnchor.constraint(equalToConstant: 26),
            statusBtn.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -8),
            actions.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -10),
            actions.centerYAnchor.constraint(equalTo: statusBtn.centerYAnchor),
            askField.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 12),
            askField.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -12),
            askField.centerYAnchor.constraint(equalTo: statusBtn.centerYAnchor),
        ])

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.panel.isKeyWindow else { return e }
            return self.handleKey(e) ? nil : e
        }
    }

    /// Keyboard: esc, tab, 1–9, and ⌘C / ⌘↩ / ⌘N / ⌘T / ⌘P / ⌘R / ⌘W. Returns true if handled.
    func handleKey(_ e: NSEvent) -> Bool {
        let asking = !askField.isHidden
        if e.keyCode == UInt16(kVK_Escape) {
            if asking { hideAsk() } else if pinned { NSSound.beep() } else { close() }
            return true
        }
        if asking { return false }
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        let ch = e.charactersIgnoringModifiers?.lowercased() ?? ""
        if mods.isEmpty {
            if e.keyCode == UInt16(kVK_Tab) { if done { showAsk() }; return true }
            if ch == "+" || ch == "=" { appDelegate?.addCapture(); return true }
            let modes = allModes()
            if let n = Int(ch), (1...modes.count).contains(n) { appDelegate?.rerun(modeID: modes[n - 1].id); return true }
            return false
        }
        if mods == [.command, .shift], ch == "c" { copyTable(); return true }
        guard mods == .command else { return false }
        if e.keyCode == UInt16(kVK_Return) { if !replaceBtn.isHidden { replaceResult() }; return true }
        switch ch {
        case "c":
            // With a selection, ⌘C copies the selection; otherwise the whole answer.
            if textView.selectedRange().length > 0 { return false }
            if done { copyResult() }
            return true
        case "n": newChat(); return true
        case "t": toggleThread(); return true
        case "p": togglePin(); return true
        case "r": speak(); return true
        case "w": close(); return true
        default: return false
        }
    }

    // MARK: Building blocks

    static func roundedMask(_ r: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: 2 * r + 1, height: 2 * r + 1), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }

    func iconButton(_ symbol: String, _ tip: String, _ action: Selector) -> HoverButton {
        let b = HoverButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
        b.isBordered = false
        b.contentTintColor = Theme.ink2
        b.toolTip = tip
        b.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        b.apply()
        b.layer?.cornerRadius = 6
        b.widthAnchor.constraint(equalToConstant: 28).isActive = true
        b.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return b
    }

    func pill(_ title: String, _ symbol: String, _ action: Selector) -> HoverButton {
        let b = HoverButton(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: title)!,
                            target: self, action: action)
        b.isBordered = false
        b.imagePosition = .imageLeading
        b.imageHugsTitle = true
        b.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        b.apply()
        b.layer?.cornerRadius = 12
        b.translatesAutoresizingMaskIntoConstraints = false
        b.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return b
    }

    func style(_ b: HoverButton, _ title: String, on: Bool) {
        b.normalBg = on ? Theme.accent.withAlphaComponent(0.24) : Theme.fill
        b.hoverBg = on ? Theme.accent.withAlphaComponent(0.32) : Theme.fillHover
        b.layer?.borderWidth = on ? 1 : 0
        b.layer?.borderColor = Theme.accent.withAlphaComponent(0.6).cgColor
        b.contentTintColor = on ? Theme.accentSoft : Theme.ink2
        b.attributedTitle = NSAttributedString(string: " " + title, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: on ? .semibold : .medium),
            .foregroundColor: on ? Theme.accentSoft : NSColor.white.withAlphaComponent(0.78)])
        b.constraints.filter { $0.firstAttribute == .width }.forEach { b.removeConstraint($0) }
        b.widthAnchor.constraint(equalToConstant: b.intrinsicContentSize.width + 14).isActive = true
    }

    /// A labeled button for the bottom bar, with its shortcut shown dimmed.
    func actionButton(_ title: String, _ key: String, _ action: Selector, primary: Bool = false) -> HoverButton {
        let b = HoverButton(title: title, target: self, action: action)
        b.isBordered = false
        b.normalBg = primary ? Theme.accent.withAlphaComponent(0.92) : Theme.fill
        b.hoverBg = primary ? Theme.accent : Theme.fillHover
        b.layer?.cornerRadius = 7
        setTitle(b, title, key, primary: primary)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return b
    }

    func setTitle(_ b: HoverButton, _ title: String, _ key: String, primary: Bool = false) {
        let s = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white.withAlphaComponent(primary ? 1 : 0.9)])
        if !key.isEmpty {
            s.append(NSAttributedString(string: "  " + key, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(primary ? 0.7 : 0.4)]))
        }
        b.attributedTitle = s
        b.constraints.filter { $0.firstAttribute == .width }.forEach { b.removeConstraint($0) }
        b.widthAnchor.constraint(equalToConstant: ceil(s.size().width) + 22).isActive = true
    }

    func refreshModeBar() {
        for (i, b) in modeButtons.enumerated() { style(b, builtInModes[i].label, on: builtInModes[i].id == mode) }
        customPill.isHidden = customModes.isEmpty
        let isCustom = mode.hasPrefix("custom:")
        style(customPill, isCustom ? String(mode.dropFirst(7)) + " ▾" : "My modes ▾", on: isCustom)
    }

    @objc func modeClicked(_ b: NSButton) { appDelegate?.rerun(modeID: builtInModes[b.tag].id) }

    @objc func customPillClicked(_ b: NSButton) {
        let m = NSMenu()
        m.appearance = NSAppearance(named: .darkAqua)
        for (i, c) in customModes.enumerated() {
            let it = NSMenuItem(title: "\(c.name)   key \(builtInModes.count + i + 1)", action: #selector(customChosen(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = "custom:" + c.name
            it.state = mode == "custom:" + c.name ? .on : .off
            m.addItem(it)
        }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height + 4), in: b)
    }
    @objc func customChosen(_ i: NSMenuItem) { if let id = i.representedObject as? String { appDelegate?.rerun(modeID: id) } }

    /// The "more" menu: everything that isn't worth a permanent button.
    @objc func showMore(_ b: NSButton) {
        let m = NSMenu()
        m.autoenablesItems = false
        m.appearance = NSAppearance(named: .darkAqua)
        func add(_ title: String, _ symbol: String, _ sel: Selector, key: String = "", on: Bool = false, enabled: Bool = true, target: AnyObject? = nil) {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            it.target = target ?? self
            it.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            it.state = on ? .on : .off
            it.isEnabled = enabled
            m.addItem(it)
        }
        add(speech.isSpeaking ? "Stop reading" : "Read aloud", "speaker.wave.2", #selector(speak), key: "r", enabled: done)
        add("Show the whole conversation", "rectangle.stack", #selector(toggleThread), key: "t", on: showThread, enabled: done && thread.count > 1)
        add("Keep open (pin)", "pin", #selector(togglePin), key: "p", on: pinned)
        add("Add another capture to this question", "plus.viewfinder", #selector(AppDelegate.addCapture), key: "+", enabled: appDelegate?.lastCapture?.text != nil, target: appDelegate)
        add("Have Claude look at the image", "photo", #selector(AppDelegate.rerunWithImage), enabled: appDelegate?.canSendImage == true, target: appDelegate)
        add("Extract the table with Claude", "tablecells", #selector(AppDelegate.extractTable), enabled: appDelegate?.canExtractTable == true, target: appDelegate)
        m.addItem(.separator())
        add("New chat", "square.and.pencil", #selector(newChat), key: "n")
        let export = NSMenuItem(title: "Export chat", action: nil, keyEquivalent: "")
        export.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
        let em = NSMenu()
        for (t, s, sel) in [("As a Markdown file…", "doc.text", #selector(AppDelegate.exportCurrentMarkdown)),
                            ("To Apple Notes", "note.text", #selector(AppDelegate.exportCurrentNotes))] {
            let it = NSMenuItem(title: t, action: sel, keyEquivalent: "")
            it.target = appDelegate
            it.image = NSImage(systemSymbolName: s, accessibilityDescription: nil)
            em.addItem(it)
        }
        export.submenu = em
        m.addItem(export)
        add("History…", "clock.arrow.circlepath", #selector(AppDelegate.openHistory), target: appDelegate)
        m.addItem(.separator())
        let hint = NSMenuItem(title: "1–6 switch mode  ·  + add capture  ·  Tab ask  ·  Esc close", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        m.addItem(hint)
        m.popUp(positioning: nil, at: NSPoint(x: b.bounds.width - 240, y: b.bounds.height + 6), in: b)
    }

    // MARK: Showing a state

    func show(header: String, preview: String, state: State, footer: String) {
        if case .streaming = state {
            pendingStream = (header, preview, state, footer)
            if streamTimer == nil {
                let wait = max(0, 0.033 - Date().timeIntervalSince(lastStreamRender))
                let t = Timer(timeInterval: wait, repeats: false) { [weak self] _ in
                    guard let self else { return }
                    self.streamTimer = nil
                    guard let p = self.pendingStream else { return }
                    self.pendingStream = nil
                    self.lastStreamRender = Date()
                    self.render(header: p.0, preview: p.1, state: p.2, footer: p.3)
                }
                RunLoop.main.add(t, forMode: .common)
                streamTimer = t
            }
            return
        }
        streamTimer?.invalidate()
        streamTimer = nil
        pendingStream = nil
        render(header: header, preview: preview, state: state, footer: footer)
    }

    private func render(header: String, preview: String, state: State, footer: String) {
        lastArgs = (header, preview, footer)
        footerText = footer
        chip.stringValue = header
        let pv = preview.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        quoteLabel.stringValue = pv.isEmpty ? "—" : pv
        var streaming = false
        // Take the keyboard when the pop-up appears or a new answer starts, never while
        // an answer is being written: you can go back to typing in your own app.
        var wantKey = !panel.isVisible
        isError = false

        switch state {
        case .loading:
            closeWork?.cancel()
            stopSpeaking()
            hideAsk()
            resultText = ""
            streamingNow = false
            loadingSince = Date()
            wantKey = true
            startAnimating()
        case .streaming(let t):
            streaming = true
            streamingNow = true
            if animTimer == nil { startAnimating() }
            resultText = t
            let s = NSMutableAttributedString(attributedString: Markdown.render(t))
            s.append(NSAttributedString(string: " ▍", attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: Theme.accent]))
            textView.textStorage?.setAttributedString(s)
        case .result(let t):
            streamingNow = false
            stopAnimating()
            scheduleAutoClose(isDemo ? 0 : Settings.autoClose)
            resultText = t
            textView.textStorage?.setAttributedString(showThread && thread.count > 1 ? renderThread() : Markdown.render(t))
        case .error(let t):
            streamingNow = false
            stopAnimating()
            resultText = ""
            isError = true
            errorMessage = t
            textView.textStorage?.setAttributedString(errorText(t))
        }
        updateBar()

        let textWidth = width - 28
        textView.frame.size.width = textWidth
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let used = textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 40
        quoteLabel.preferredMaxLayoutWidth = width - 32 - 30
        let quoteH = quoteLabel.fittingSize.height + 14
        let chrome: CGFloat = 14 + 24 + 12 + quoteH + 10 + 24 + 12 + 10 + 1 + 44
        let screenH = (panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        let height = min(max(used + chrome + 6, 176), min(660, screenH - 60))

        if !panel.isVisible || (isDemo && !streaming) {
            positionNearMouse(height: height)
            let target = panel.frame
            panel.setFrame(target.offsetBy(dx: 0, dy: -8), display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(target, display: true)
            }
        } else if abs(panel.frame.height - height) > 0.5 {
            var f = panel.frame
            f.origin.y += f.height - height
            f.size.height = height
            panel.setFrame(f, display: true, animate: !streaming)
            panel.orderFrontRegardless()
        } else {
            panel.orderFrontRegardless()
        }
        if wantKey { panel.makeKey() }
        if streaming || (showThread && thread.count > 1 && done) { textView.scrollToEndOfDocument(nil) } else { scroll.contentView.scroll(to: .zero) }
    }

    /// Bottom bar: the status on the left, the actions that make sense right now on the right.
    func updateBar() {
        askBtn.isHidden = !done
        copyBtn.isHidden = !done
        replaceBtn.isHidden = !(done && allowReplace && replaceableModes.contains(mode))
        retryBtn.isHidden = !(isError && appDelegate?.lastRequest != nil)
        let needsSignIn = errorMessage.contains("not signed in"), needsSetup = errorMessage.contains("wasn't found")
        fixBtn.isHidden = !(isError && (needsSignIn || needsSetup))
        if !fixBtn.isHidden { setTitle(fixBtn, needsSignIn ? "Sign in…" : "Set up…", "", primary: true) }

        let answerTables = done ? markdownTables(resultText) : []
        tables = !answerTables.isEmpty ? answerTables : (isError ? [] : captureTables)
        tableBtn.isHidden = tables.isEmpty
        tableBtn.toolTip = (answerTables.isEmpty ? "Copy the captured table" : "Copy the table in the answer") + ", ready to paste into Excel, Sheets or Notion"

        let canThread = done && thread.count > 1
        var t = footerText
        if canThread { t = showThread ? "‹  " + t : t + "  ›" }
        statusBtn.attributedTitle = NSAttributedString(string: "  " + t + "  ", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: canThread ? Theme.ink2 : Theme.ink3])
        statusBtn.hoverBg = canThread ? Theme.fill : .clear
        statusBtn.toolTip = canThread ? (showThread ? "Show only the last answer (⌘T)" : "Show the whole conversation (⌘T)") : nil
    }

    func errorText(_ t: String) -> NSAttributedString {
        let title = t.contains("not signed in") ? "Sign in to continue"
            : t.contains("wasn't found") ? "Claude Code isn't installed"
            : t.contains("clipboard") ? "Nothing to interpret" : "Couldn't get an answer"
        let p = NSMutableParagraphStyle()
        p.paragraphSpacing = 4
        p.lineSpacing = 2
        let s = NSMutableAttributedString(string: "⚠︎  " + title + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: Theme.accentSoft, .paragraphStyle: p])
        s.append(NSAttributedString(string: t, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: Theme.ink2, .paragraphStyle: p]))
        return s
    }

    /// The chat as a thread: earlier captures and answers dimmed, the latest one at the bottom.
    func renderThread() -> NSAttributedString {
        let out = NSMutableAttributedString()
        var n = 0
        for (i, e) in thread.enumerated() {
            let latest = i == thread.count - 1
            var label: String
            if let q = e.followUp { label = "↳ " + q } else {
                n += 1
                label = "Capture \(n) · \(e.mode) — " + e.capture.replacingOccurrences(of: "\n", with: " ")
            }
            if label.count > 92 { label = String(label.prefix(91)) + "…" }
            let p = NSMutableParagraphStyle()
            p.paragraphSpacing = 5
            p.paragraphSpacingBefore = i == 0 ? 0 : 16
            out.append(NSAttributedString(string: label + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
                .foregroundColor: Theme.accentSoft.withAlphaComponent(latest ? 1 : 0.6), .paragraphStyle: p]))
            let body = NSMutableAttributedString(attributedString: Markdown.render(e.answer))
            if !latest {
                body.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: body.length)) { v, r, _ in
                    if let c = v as? NSColor { body.addAttribute(.foregroundColor, value: c.withAlphaComponent(c.alphaComponent * 0.55), range: r) }
                }
                body.append(NSAttributedString(string: "\n"))
            }
            out.append(body)
        }
        return out
    }

    // MARK: Thinking animation

    func startAnimating() {
        animTimer?.invalidate()
        frameIdx = 0
        let t = Timer(timeInterval: 0.16, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.frameIdx = (self.frameIdx + 1) % self.frames.count
            self.clawdView.image = self.frames[self.frameIdx]
            if !self.streamingNow { self.setThinking() }
        }
        RunLoop.main.add(t, forMode: .common)
        animTimer = t
        if !streamingNow { setThinking() }
    }
    func setThinking() {
        let secs = Int(Date().timeIntervalSince(loadingSince))
        let s = NSMutableAttributedString(string: "Thinking" + String(repeating: ".", count: (frameIdx / 2) % 4), attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: Theme.accentSoft])
        if secs >= 5 {   // slower models: show that it's still working
            s.append(NSAttributedString(string: "    \(secs) s", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular), .foregroundColor: Theme.ink3]))
        }
        textView.textStorage?.setAttributedString(s)
    }
    func stopAnimating() {
        animTimer?.invalidate()
        animTimer = nil
        clawdView.image = idleImage
    }

    // MARK: Position, opening and closing

    func positionNearMouse(height: CGFloat) {
        if isDemo, let vf = NSScreen.main?.visibleFrame {   // demo: centered, for screenshots
            panel.setFrame(NSRect(x: vf.midX - width / 2, y: vf.midY - height / 2, width: width, height: height), display: true)
            showBackdrop(around: panel.frame)
            return
        }
        let m = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main!
        let vf = screen.visibleFrame
        switch Settings.popupPosition {
        case "topRight":
            panel.setFrame(NSRect(x: vf.maxX - width - 16, y: vf.maxY - height - 16, width: width, height: height), display: true)
            return
        case "center":
            panel.setFrame(NSRect(x: vf.midX - width / 2, y: vf.midY - height / 2, width: width, height: height), display: true)
            return
        default: break
        }
        var x = m.x + 18, y = m.y - height - 18
        x = min(max(x, vf.minX + 8), vf.maxX - width - 8)
        if y < vf.minY + 8 { y = min(m.y + 18, vf.maxY - height - 8) }
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    var backdrop: NSWindow?
    /// Gradient behind the pop-up in demo mode (so the blur shows up in screenshots).
    func showBackdrop(around f: NSRect) {
        backdrop?.orderOut(nil)
        let r = f.insetBy(dx: -70, dy: -60)
        let w = NSWindow(contentRect: r, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        w.isReleasedWhenClosed = false
        let v = NSView()
        v.wantsLayer = true
        v.layer = Theme.gradient(r.size)
        w.contentView = v
        w.orderFrontRegardless()
        backdrop = w
    }

    var closeWork: DispatchWorkItem?

    /// Closes the pop-up after `seconds`, but waits while the mouse is over it or you're typing.
    func scheduleAutoClose(_ seconds: Int) {
        closeWork?.cancel()
        guard seconds > 0, !pinned else { return }
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.panel.isVisible else { return }
            if NSMouseInRect(NSEvent.mouseLocation, self.panel.frame, false) || !self.askField.isHidden || self.speech.isSpeaking {
                self.scheduleAutoClose(3)
            } else { self.close() }
        }
        closeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds), execute: w)
    }

    @objc func togglePin() {
        pinned.toggle()
        pinBtn.image = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin", accessibilityDescription: "Pin")
        pinBtn.contentTintColor = pinned ? Theme.accent : Theme.ink2
        pinBtn.toolTip = pinned ? "Pinned: only ✕ closes it. Click to unpin (⌘P)" : "Keep this pop-up open (⌘P)"
        if pinned { closeWork?.cancel() } else if done { scheduleAutoClose(Settings.autoClose) }
    }

    @objc func toggleThread() {
        guard done, thread.count > 1 else { return }
        showThread.toggle()
        if let a = lastArgs { render(header: a.header, preview: a.preview, state: .result(resultText), footer: a.footer) }
    }

    @objc func close() {
        if pinned { togglePin() }   // closing with ✕ also unpins
        stopSpeaking()
        hideAsk()
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; panel.animator().alphaValue = 0 },
                                             completionHandler: { self.panel.orderOut(nil); self.panel.alphaValue = 1 })
    }

    // MARK: Actions

    func flash(_ b: HoverButton, _ title: String, _ key: String, primary: Bool = false) {
        setTitle(b, "✓ Copied", "", primary: primary)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.setTitle(b, title, key, primary: primary) }
    }

    @objc func copyResult() {
        guard done else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resultText, forType: .string)
        appDelegate?.lastChange = NSPasteboard.general.changeCount  // don't treat this as a capture
        flash(copyBtn, "Copy", "⌘C")
    }

    /// Fix / Translate: put the corrected or translated text back where it came from.
    @objc func replaceResult() {
        guard done else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(mainPart(resultText), forType: .string)
        appDelegate?.lastChange = NSPasteboard.general.changeCount
        if AXIsProcessTrusted() {
            close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { pasteKeystroke() }
        } else {
            flash(replaceBtn, "Replace", "⌘↩", primary: true)
            footerText = "Copied · press ⌘V to paste (Settings → Allow auto-paste)"
            updateBar()
        }
    }

    @objc func copyTable() {
        guard !tables.isEmpty else { NSSound.beep(); return }
        copyTables(tables)
        appDelegate?.lastChange = NSPasteboard.general.changeCount  // don't treat this as a capture
        flash(tableBtn, "Copy table", "⇧⌘C")
    }

    @objc func retry() { appDelegate?.retryLast() }

    @objc func fixProblem() {
        if errorMessage.contains("not signed in") { appDelegate?.login() } else { appDelegate?.openWelcome() }
    }

    @objc func newChat() {
        appDelegate?.store.newChat()
        thread = []
        footerText = "✓ New chat · your next capture starts fresh"
        updateBar()
    }

    // Read aloud

    @objc func speak() {
        if speech.isSpeaking { stopSpeaking(); return }
        guard done else { return }
        let plain = resultText
            .replacingOccurrences(of: #"(?m)^\s*(-{3,}|```.*)\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[*`#>_|]"#, with: "", options: .regularExpression)
        guard !plain.isEmpty else { return }
        let u = AVSpeechUtterance(string: plain)
        let r = NLLanguageRecognizer()
        r.processString(plain)
        if let lang = r.dominantLanguage?.rawValue {
            let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(lang) }
            u.voice = voices.first { $0.language == AVSpeechSynthesisVoice.currentLanguageCode() } ?? voices.first
        }
        speech.speak(u)
        stopBtn.isHidden = false
    }
    func stopSpeaking() {
        if speech.isSpeaking { speech.stopSpeaking(at: .immediate) }
        stopBtn?.isHidden = true
    }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        DispatchQueue.main.async { self.stopBtn.isHidden = true }
    }

    // Follow-up questions

    @objc func showAsk() {
        guard done else { return }
        closeWork?.cancel()
        statusBtn.isHidden = true
        actions.isHidden = true
        askField.isHidden = false
        askField.stringValue = ""
        panel.makeKey()
        panel.makeFirstResponder(askField)
    }
    func hideAsk() {
        guard !askField.isHidden else { return }
        askField.isHidden = true
        statusBtn.isHidden = false
        actions.isHidden = false
        panel.makeFirstResponder(nil)
    }
    @objc func askSubmitted() {
        guard !askField.isHidden else { return }
        let q = askField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        hideAsk()
        appDelegate?.followUp(q)
    }
}

// MARK: - Screenshots: thumbnail overlay, pinned images, scrolling capture

func savePNG(_ image: CGImage, to path: String) -> Bool {
    guard let d = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return false }
    return (try? d.write(to: URL(fileURLWithPath: path))) != nil
}

/// A borderless window that can take the keyboard (for esc and return).
final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// The screenshot thumbnail: click and drag it into any app to drop the image file there.
final class ShotThumb: NSImageView, NSDraggingSource {
    var fileURL: URL?
    private var down = NSPoint.zero
    private var dragging = false

    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) { down = e.locationInWindow; dragging = false }
    override func mouseDragged(with e: NSEvent) {
        guard !dragging, let url = fileURL,
              hypot(e.locationInWindow.x - down.x, e.locationInWindow.y - down.y) > 4 else { return }
        dragging = true
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: e, source: self)
    }
    func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor c: NSDraggingContext) -> NSDragOperation { .copy }
}

/// After a screenshot: a small thumbnail in the corner with what you can do with it.
final class QuickAccess: NSObject {
    static let shared = QuickAccess()
    var panel: NSPanel?
    var path = ""
    var hideWork: DispatchWorkItem?

    func show(_ path: String) {
        panel?.orderOut(nil)
        guard let img = NSImage(contentsOfFile: path) else { return }
        self.path = path
        let s = min(260 / img.size.width, 170 / img.size.height, 1)
        let tw = max(img.size.width * s, 216), th = max(img.size.height * s, 70)
        let w = tw + 16, h = th + 16 + 34
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.appearance = NSAppearance(named: .darkAqua)
        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        bg.material = .hudWindow
        bg.state = .active
        bg.blendingMode = .behindWindow
        bg.maskImage = PopupController.roundedMask(14)
        p.contentView = bg

        let thumb = ShotThumb(frame: NSRect(x: 8, y: 42, width: tw, height: th))
        thumb.image = img
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.fileURL = URL(fileURLWithPath: path)
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 8
        thumb.layer?.masksToBounds = true
        thumb.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
        thumb.toolTip = "Drag into any app to drop the image"
        bg.addSubview(thumb)

        let specs: [(String, String, Selector)] = [
            ("doc.on.doc", "Copy the image", #selector(copyImage)),
            ("square.and.arrow.down", "Save to the Desktop", #selector(save)),
            ("sparkles", "Ask Claude about it", #selector(ask)),
            ("text.viewfinder", "Copy its text", #selector(copyText)),
            ("pin", "Pin it on screen", #selector(pin)),
            ("xmark", "Close", #selector(hide)),
        ]
        let gap = (w - 16 - CGFloat(specs.count) * 30) / CGFloat(specs.count - 1)
        for (i, (symbol, tip, action)) in specs.enumerated() {
            let b = HoverButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
            b.isBordered = false
            b.contentTintColor = symbol == "sparkles" ? Theme.accentSoft : Theme.ink2
            b.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
            b.toolTip = tip
            b.apply()
            b.layer?.cornerRadius = 6
            b.frame = NSRect(x: 8 + CGFloat(i) * (30 + gap), y: 8, width: 30, height: 26)
            bg.addSubview(b)
        }

        let vf = (NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!).visibleFrame
        p.setFrameOrigin(NSPoint(x: vf.minX + 20, y: vf.minY + 12))
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            p.animator().alphaValue = 1
            p.animator().setFrameOrigin(NSPoint(x: vf.minX + 20, y: vf.minY + 20))
        }
        panel = p
        scheduleHide(15)
    }

    /// Goes away by itself, but not while the mouse is over it.
    func scheduleHide(_ seconds: Double) {
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, let p = self.panel, p.isVisible else { return }
            if NSMouseInRect(NSEvent.mouseLocation, p.frame, false) { self.scheduleHide(4) } else { self.hide() }
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    @objc func hide() {
        hideWork?.cancel()
        guard let p = panel else { return }
        panel = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; p.animator().alphaValue = 0 }, completionHandler: { p.orderOut(nil) })
    }

    @objc func copyImage() {
        guard let img = NSImage(contentsOfFile: path) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
        appDelegate?.lastChange = NSPasteboard.general.changeCount
        Toast.show("Image copied")
    }

    @objc func save() {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let dest = home + "/Desktop/ClaudeSniper \(df.string(from: Date())).png"
        do {
            try FileManager.default.copyItem(atPath: path, toPath: dest)
            Toast.show("Saved to the Desktop")
        } catch { Toast.show("Couldn't save") }
    }

    @objc func ask() { hide(); appDelegate?.readImage(at: path, kind: .ask) }
    @objc func copyText() { appDelegate?.readImage(at: path, kind: .textOnly) }
    @objc func pin() { PinnedShot.show(path); hide() }
}

/// A screenshot that stays on top of everything. Drag to move, double-click to close.
final class PinView: NSImageView {
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2 { PinnedShot.close(window) } else { window?.performDrag(with: e) }
    }
    override func rightMouseDown(with e: NSEvent) {
        let m = NSMenu()
        let c = NSMenuItem(title: "Copy", action: #selector(copyImage), keyEquivalent: "")
        c.target = self
        m.addItem(c)
        let x = NSMenuItem(title: "Close", action: #selector(closePin), keyEquivalent: "")
        x.target = self
        m.addItem(x)
        NSMenu.popUpContextMenu(m, with: e, for: self)
    }
    @objc func copyImage() {
        guard let img = image else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
        appDelegate?.lastChange = NSPasteboard.general.changeCount
    }
    @objc func closePin() { PinnedShot.close(window) }
}

enum PinnedShot {
    static var windows: [NSWindow] = []

    static func show(_ path: String) {
        guard let img = NSImage(contentsOfFile: path), let vf = NSScreen.main?.visibleFrame else { return }
        let s = min(1, vf.width * 0.6 / img.size.width, vf.height * 0.7 / img.size.height)
        let size = NSSize(width: img.size.width * s, height: img.size.height * s)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel, .resizable],
                        backing: .buffered, defer: false)
        p.level = .floating
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentAspectRatio = size
        let v = PinView(frame: NSRect(origin: .zero, size: size))
        v.image = img
        v.imageScaling = .scaleAxesIndependently
        v.autoresizingMask = [.width, .height]
        v.toolTip = "Drag to move · double-click to close"
        p.contentView = v
        p.center()
        p.setFrameOrigin(NSPoint(x: p.frame.origin.x + CGFloat(windows.count) * 24, y: p.frame.origin.y - CGFloat(windows.count) * 24))
        p.orderFrontRegardless()
        windows.append(p)
    }

    static func close(_ w: NSWindow?) {
        guard let w else { return }
        w.orderOut(nil)
        windows.removeAll { $0 === w }
    }
}

/// Joins screenshots of the same area taken while the page scrolls into one tall image.
/// Each new frame is matched against the previous one to find how far the content moved;
/// only the new rows at the bottom are added.
final class Stitcher {
    static let cols = 48
    private(set) var strips: [CGImage] = []
    private(set) var totalHeight = 0
    private var last: [UInt8] = []
    private var width = 0, height = 0

    /// Each row of the image as 48 gray values (first row = top).
    static func signature(_ img: CGImage) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: cols * img.height)
        buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: cols, height: img.height, bitsPerComponent: 8, bytesPerRow: cols,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: cols, height: img.height))
        }
        return buf
    }

    enum Result { case first, added(Int), same, lost }

    func add(_ img: CGImage) -> Result {
        let sig = Self.signature(img)
        if strips.isEmpty || img.width != width || img.height != height {
            strips = [img]; totalHeight = img.height; last = sig; width = img.width; height = img.height
            return .first
        }
        let h = height, cols = Self.cols
        // How much detail each row has (blank rows score 0). Blank rows match anything, so the
        // rows with text and edges decide where the two frames overlap.
        func detail(_ g: [UInt8]) -> [Int] {
            (0..<h).map { y in
                var t = 0
                let r = y * cols
                for c in 1..<cols { t += abs(Int(g[r + c]) - Int(g[r + c - 1])) }
                return t
            }
        }
        let texOld = detail(last), texNew = detail(sig)
        // Skip the top strip: a sticky header doesn't move with the page.
        let top = h / 8
        var bestD = 0, bestScore = Double.infinity, bestWeight = 0
        sig.withUnsafeBufferPointer { new in
            last.withUnsafeBufferPointer { old in
                for d in 0...(h * 7 / 10) {
                    var num = 0, den = 0
                    var y = top
                    while y < h - d {
                        let w = texOld[y + d] + texNew[y]
                        if w > 0 {
                            let a = y * cols, b = (y + d) * cols
                            var diff = 0
                            for c in 0..<cols { diff += abs(Int(new[a + c]) - Int(old[b + c])) }
                            num += w * diff
                            den += w
                        }
                        y += 2
                    }
                    guard den > 0 else { continue }
                    let score = Double(num) / Double(den) / Double(cols)
                    if score < bestScore - 0.0001 { bestScore = score; bestD = d; bestWeight = den }
                }
            }
        }
        if bestWeight < cols * 40 { return .same }   // nothing but blank in the overlap: wait for the next frame
        if bestScore > 3.5 { return .lost }           // scrolled too far to find the overlap
        if bestD == 0 { return .same }
        guard let strip = img.cropping(to: CGRect(x: 0, y: h - bestD, width: width, height: bestD)) else { return .same }
        strips.append(strip)
        totalHeight += bestD
        last = sig
        return .added(bestD)
    }

    func image() -> CGImage? {
        guard let first = strips.first,
              let ctx = CGContext(data: nil, width: width, height: totalHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: first.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var y = totalHeight
        for s in strips {
            y -= s.height
            ctx.draw(s, in: CGRect(x: 0, y: y, width: s.width, height: s.height))
        }
        return ctx.makeImage()
    }
}

/// A dim overlay to drag a rectangle on the screen under the mouse.
final class RegionPicker: NSView {
    static var window: NSWindow?
    var start: NSPoint?
    var current: NSPoint?
    var done: ((NSRect?) -> Void)?

    static func pick(hint: String, _ done: @escaping (NSRect?) -> Void) {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main else { done(nil); return }
        let w = KeyWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = .screenSaver
        w.isOpaque = false
        w.backgroundColor = .clear
        w.isReleasedWhenClosed = false
        let v = RegionPicker(frame: NSRect(origin: .zero, size: screen.frame.size))
        v.hint = hint
        v.done = { r in
            w.orderOut(nil)
            window = nil
            done(r.map { $0.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY) })
        }
        w.contentView = v
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(v)
        window = w
    }

    var hint = ""
    var rect: NSRect? {
        guard let a = start, let b = current else { return nil }
        return NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func draw(_ dirty: NSRect) {
        NSColor.black.withAlphaComponent(0.3).setFill()
        bounds.fill()
        if let r = rect {
            NSColor.clear.setFill()
            r.fill(using: .copy)
            claudeOrange.setStroke()
            let p = NSBezierPath(rect: r.insetBy(dx: -1, dy: -1))
            p.lineWidth = 2
            p.stroke()
        } else {
            let s = NSAttributedString(string: hint, attributes: [.font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: NSColor.white])
            let size = s.size()
            let box = NSRect(x: bounds.midX - size.width / 2 - 18, y: bounds.midY - size.height / 2 - 10, width: size.width + 36, height: size.height + 20)
            NSColor.black.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12).fill()
            s.draw(at: NSPoint(x: box.minX + 18, y: box.minY + 10))
        }
    }
    override func mouseDown(with e: NSEvent) { start = convert(e.locationInWindow, from: nil); current = start; needsDisplay = true }
    override func mouseDragged(with e: NSEvent) { current = convert(e.locationInWindow, from: nil); needsDisplay = true }
    override func mouseUp(with e: NSEvent) {
        if let r = rect, r.width > 60, r.height > 60 { done?(r.integral) } else { done?(nil) }
    }
    override func keyDown(with e: NSEvent) { if e.keyCode == UInt16(kVK_Escape) { done?(nil) } }
}

final class OutlineView: NSView {
    override func draw(_ dirty: NSRect) {
        claudeOrange.setStroke()
        let p = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        p.lineWidth = 3
        p.stroke()
    }
}

/// Scrolling capture: pick an area, scroll the page yourself, and the frames are joined
/// into one tall screenshot. Needs the screen recording permission.
final class ScrollCapture: NSObject {
    static var current: ScrollCapture?
    let rect: NSRect   // on screen, Cocoa coordinates
    let stitcher = Stitcher()
    var outline: NSWindow?
    var hud: NSPanel?
    let label = NSTextField(labelWithString: "Scroll down slowly…")
    var timer: Timer?
    var grabbing = false
    var finished = false
    let queue = DispatchQueue(label: "claudesniper.scrollcapture")

    static func start() {
        if let c = current { c.finish(); return }   // the shortcut again = done
        guard CGPreflightScreenCaptureAccess() else { appDelegate?.explainScreenAccess(); return }
        let front = NSWorkspace.shared.frontmostApplication
        RegionPicker.pick(hint: "Drag over the area that scrolls · esc cancels") { r in
            front?.activate()
            guard let r else { return }
            let s = ScrollCapture(rect: r)
            current = s
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { s.begin() }   // let the overlay disappear first
        }
    }

    init(rect: NSRect) { self.rect = rect }

    func begin() {
        // An outline just outside the area (so it isn't in the pictures) that lets scrolling through.
        let o = NSWindow(contentRect: rect.insetBy(dx: -4, dy: -4), styleMask: .borderless, backing: .buffered, defer: false)
        o.level = .floating
        o.isOpaque = false
        o.backgroundColor = .clear
        o.ignoresMouseEvents = true
        o.isReleasedWhenClosed = false
        o.contentView = OutlineView(frame: NSRect(origin: .zero, size: o.frame.size))
        o.orderFrontRegardless()
        outline = o

        let w: CGFloat = 400, h: CGFloat = 46
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.appearance = NSAppearance(named: .darkAqua)
        let bg = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor(srgbRed: 0.13, green: 0.10, blue: 0.10, alpha: 0.96).cgColor
        bg.layer?.cornerRadius = 12
        bg.layer?.borderWidth = 1
        bg.layer?.borderColor = claudeOrange.withAlphaComponent(0.7).cgColor
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = .white
        label.frame = NSRect(x: 14, y: 14, width: 210, height: 18)
        label.lineBreakMode = .byTruncatingTail
        bg.addSubview(label)
        let doneBtn = NSButton(title: "Done", target: self, action: #selector(finish))
        doneBtn.bezelStyle = .rounded
        doneBtn.bezelColor = claudeOrange
        doneBtn.frame = NSRect(x: 232, y: 8, width: 74, height: 30)
        let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.frame = NSRect(x: 310, y: 8, width: 80, height: 30)
        bg.addSubview(doneBtn)
        bg.addSubview(cancelBtn)
        p.contentView = bg
        // Below the area if there's room, otherwise above it.
        let vf = (NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main!).visibleFrame
        var y = rect.minY - h - 14
        if y < vf.minY + 6 { y = min(rect.maxY + 14, vf.maxY - h - 6) }
        p.setFrameOrigin(NSPoint(x: min(max(rect.midX - w / 2, vf.minX + 6), vf.maxX - w - 6), y: y))
        p.orderFrontRegardless()
        hud = p

        let t = Timer(timeInterval: 0.22, repeats: true) { [weak self] _ in self?.grab() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        grab()
    }

    /// One picture of the area, added to the stitched image.
    func grab() {
        guard !grabbing, !finished else { return }
        grabbing = true
        let r = rect
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let arg = "\(Int(r.minX)),\(Int(primaryH - r.maxY)),\(Int(r.width)),\(Int(r.height))"   // screencapture counts from the top-left
        queue.async {
            let path = NSTemporaryDirectory() + "claudesniper-scroll-\(UUID().uuidString).png"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-R", arg, "-t", "png", path]
            try? p.run()
            p.waitUntilExit()
            var result = Stitcher.Result.same
            if let img = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                result = self.stitcher.add(img)
            }
            try? FileManager.default.removeItem(atPath: path)
            let total = self.stitcher.totalHeight
            DispatchQueue.main.async {
                self.grabbing = false
                if self.finished { return }
                let scale = (NSScreen.screens.first { $0.frame.intersects(r) } ?? NSScreen.main)?.backingScaleFactor ?? 2
                switch result {
                case .lost: self.label.stringValue = "Too fast: scroll back a little"; self.label.textColor = Theme.accentSoft
                default: self.label.stringValue = "Scroll down slowly · \(Int(CGFloat(total) / scale)) pt captured"; self.label.textColor = .white
                }
            }
        }
    }

    func teardown() {
        finished = true
        timer?.invalidate()
        outline?.orderOut(nil)
        hud?.orderOut(nil)
        Self.current = nil
    }

    @objc func cancel() { teardown() }

    @objc func finish() {
        guard !finished else { return }
        teardown()
        queue.async {   // after any picture still being taken
            let path = workDir + "/shot-\(Int(Date().timeIntervalSince1970)).png"
            let ok = self.stitcher.image().map { savePNG($0, to: path) } ?? false
            DispatchQueue.main.async { if ok { QuickAccess.shared.show(path) } else { Toast.show("Nothing captured") } }
        }
    }
}

// MARK: - Mini Clawd (a tiny floating Clawd instead of the pop-up)

final class MiniView: NSView {
    weak var owner: MiniClawd?
    private var downAt = NSPoint.zero
    private var dragged = false
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) { downAt = e.locationInWindow; dragged = false }
    override func mouseDragged(with e: NSEvent) {
        guard let w = window else { return }
        let dx = e.locationInWindow.x - downAt.x, dy = e.locationInWindow.y - downAt.y
        if abs(dx) + abs(dy) > 2 { dragged = true }
        w.setFrameOrigin(NSPoint(x: w.frame.origin.x + dx, y: w.frame.origin.y + dy))
    }
    override func mouseUp(with e: NSEvent) { if !dragged { owner?.clicked() } }
    override func rightMouseUp(with e: NSEvent) { owner?.hide() }
}

final class MiniClawd: NSObject {
    enum Phase { case thinking, ready, error }

    let panel: NSPanel
    let clawd = NSImageView()
    let shadow = NSView()
    let bubble = NSView()
    let bubbleLabel = NSTextField(labelWithString: "")
    let frames = Pixel.clawdFrames(px: 3)
    let idle = Pixel.clawd(px: 3)
    var phase = Phase.thinking
    var timer: Timer?
    var since = Date()
    var tick = 0

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 88),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let v = MiniView(frame: NSRect(x: 0, y: 0, width: 100, height: 88))
        v.owner = self
        v.toolTip = "Click to see the answer · drag to move · right-click to hide"
        panel.contentView = v

        shadow.wantsLayer = true
        shadow.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        shadow.layer?.cornerRadius = 4
        shadow.frame = NSRect(x: 14, y: 4, width: 40, height: 8)

        clawd.imageScaling = .scaleNone
        clawd.image = idle
        clawd.frame = NSRect(x: 8, y: 8, width: 51, height: 36)

        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 12
        bubble.layer?.borderWidth = 2
        bubble.layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        bubble.frame = NSRect(x: 52, y: 46, width: 40, height: 26)
        bubbleLabel.font = .systemFont(ofSize: 14, weight: .heavy)
        bubbleLabel.textColor = .white
        bubbleLabel.alignment = .center
        bubbleLabel.frame = NSRect(x: 0, y: 3, width: 40, height: 18)
        bubble.addSubview(bubbleLabel)

        for x in [shadow, clawd, bubble] as [NSView] { v.addSubview(x) }
    }

    func show(_ p: Phase) {
        phase = p
        since = Date()
        tick = 0
        if !panel.isVisible {
            let m = NSEvent.mouseLocation
            let vf = (NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main!).visibleFrame
            let x = min(max(m.x + 14, vf.minX + 4), vf.maxX - 104)
            let y = min(max(m.y - 96, vf.minY + 4), vf.maxY - 92)
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in self?.step() }
        step()
    }

    func hide() {
        timer?.invalidate(); timer = nil
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; panel.animator().alphaValue = 0 },
                                             completionHandler: { self.panel.orderOut(nil); self.panel.alphaValue = 1 })
    }

    func clicked() { appDelegate?.miniClicked() }

    /// One animation frame: walk while thinking, a happy hop when the answer is ready.
    func step() {
        tick += 1
        let t = Date().timeIntervalSince(since)
        var lift: CGFloat = 0
        switch phase {
        case .thinking:
            clawd.image = frames[(tick / 2) % 5]
            bubbleLabel.stringValue = String(repeating: "·", count: 1 + (tick / 4) % 3)
            bubble.layer?.backgroundColor = NSColor(white: 0.2, alpha: 0.9).cgColor
        case .ready:
            // three hops that fade out, then a small hop and a blink every few seconds
            let cycle = t < 1.6 ? t : (t - 1.6).truncatingRemainder(dividingBy: 3.2)
            let hop = t < 1.6 ? abs(sin(t * .pi / 0.53)) * CGFloat(1.6 - t) * 12 : (cycle < 0.35 ? abs(sin(cycle * .pi / 0.35)) * 6 : 0)
            lift = hop
            clawd.image = (t > 1.6 && cycle > 1.5 && cycle < 1.7) ? frames[5] : idle
            bubbleLabel.stringValue = "!"
            let pulse = 0.85 + 0.15 * sin(t * 4)
            bubble.layer?.backgroundColor = claudeOrange.withAlphaComponent(pulse).cgColor
        case .error:
            clawd.image = idle
            bubbleLabel.stringValue = "?"
            bubble.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.85).cgColor
        }
        clawd.frame.origin.y = 8 + lift
        bubble.frame.origin.y = 46 + lift
        let s = 1 - min(lift, 12) / 40
        shadow.frame = NSRect(x: 14 + (1 - s) * 20, y: 4, width: 40 * s, height: 8)
    }
}

// MARK: - Welcome window (first launch)

final class WelcomeWindowController: NSObject, NSWindowDelegate {
    struct Row { let icon: NSImageView; let detail: NSTextField; let button: NSButton }
    let window: NSWindow
    var rows: [Row] = []
    let startBtn = NSButton(title: "Turn on ClaudeSniper", target: nil, action: nil)

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 624),
                          styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = "Welcome to ClaudeSniper"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        let content = NSView()
        window.contentView = content

        // The same warm gradient as the pop-up's backdrop and the app icon.
        let band = NSView()
        band.wantsLayer = true
        band.layer = Theme.gradient(NSSize(width: 540, height: 176))
        band.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(band)
        let clawd = NSImageView(image: Pixel.clawd(px: 5))
        clawd.imageScaling = .scaleNone
        let title = NSTextField(labelWithString: "Welcome to ClaudeSniper")
        title.font = .systemFont(ofSize: 22, weight: .bold)
        title.textColor = .white
        let sub = NSTextField(wrappingLabelWithString: "Press \(hotkeyLabel), drag over anything on your screen, and Claude explains it in a pop-up, using your Claude plan. A few quick checks:")
        sub.font = .systemFont(ofSize: 13)
        sub.textColor = .secondaryLabelColor
        sub.alignment = .center

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        let specs: [(String, String, String, Selector)] = [
            ("Claude Code", "The free command-line tool that talks to Claude.", "Install…", #selector(installClaude)),
            ("Signed in to your Claude plan", "Pro or Max. It uses your plan, with no API key.", "Sign in…", #selector(signIn)),
            ("Screen recording", "So macOS doesn't ask on every capture. Scrolling capture needs it.", "Allow…", #selector(allowScreen)),
            ("Capture", "Press \(hotkeyLabel) and drag over any text. Esc cancels.", "Try a capture", #selector(tryCapture)),
            ("Sample", "Or see a real answer for a sample sentence.", "Try a sample", #selector(trySample)),
        ]
        for (name, detail, button, action) in specs {
            let icon = NSImageView()
            icon.symbolConfiguration = .init(pointSize: 20, weight: .medium)
            let n = NSTextField(labelWithString: name)
            n.font = .systemFont(ofSize: 13.5, weight: .semibold)
            let d = NSTextField(labelWithString: detail)
            d.font = .systemFont(ofSize: 11.5)
            d.textColor = .secondaryLabelColor
            d.lineBreakMode = .byTruncatingTail
            let texts = NSStackView(views: [n, d])
            texts.orientation = .vertical
            texts.alignment = .leading
            texts.spacing = 2
            let b = NSButton(title: button, target: self, action: action)
            b.bezelStyle = .rounded
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let row = NSStackView(views: [icon, texts, spacer, b])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 12
            row.edgeInsets = NSEdgeInsets(top: 11, left: 14, bottom: 11, right: 12)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalToConstant: 476).isActive = true
            row.heightAnchor.constraint(equalToConstant: 56).isActive = true
            let card = NSBox()
            card.boxType = .custom
            card.titlePosition = .noTitle
            card.cornerRadius = 10
            card.borderWidth = 0
            card.fillColor = NSColor.labelColor.withAlphaComponent(0.05)
            card.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(card, positioned: .below, relativeTo: nil)
            NSLayoutConstraint.activate([
                card.topAnchor.constraint(equalTo: row.topAnchor), card.bottomAnchor.constraint(equalTo: row.bottomAnchor),
                card.leadingAnchor.constraint(equalTo: row.leadingAnchor), card.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            ])
            icon.widthAnchor.constraint(equalToConstant: 26).isActive = true
            stack.addArrangedSubview(row)
            rows.append(Row(icon: icon, detail: d, button: b))
        }

        let again = NSButton(title: "Check again", target: self, action: #selector(refresh))
        again.bezelStyle = .rounded
        startBtn.target = self
        startBtn.action = #selector(finish)
        startBtn.bezelStyle = .rounded
        startBtn.bezelColor = claudeOrange
        startBtn.keyEquivalent = "\r"
        let bottom = NSStackView(views: [again, startBtn])
        bottom.orientation = .horizontal
        bottom.spacing = 10

        for v in [clawd, title, sub, stack, bottom] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            band.topAnchor.constraint(equalTo: content.topAnchor),
            band.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            band.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            band.heightAnchor.constraint(equalToConstant: 176),
            clawd.topAnchor.constraint(equalTo: content.topAnchor, constant: 46),
            clawd.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            clawd.widthAnchor.constraint(equalToConstant: 85),
            clawd.heightAnchor.constraint(equalToConstant: 60),
            title.topAnchor.constraint(equalTo: clawd.bottomAnchor, constant: 14),
            title.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            sub.topAnchor.constraint(equalTo: band.bottomAnchor, constant: 18),
            sub.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            sub.widthAnchor.constraint(equalToConstant: 440),
            stack.topAnchor.constraint(equalTo: sub.bottomAnchor, constant: 18),
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            bottom.topAnchor.constraint(greaterThanOrEqualTo: stack.bottomAnchor, constant: 24),
            bottom.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -32),
            bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
        ])
    }

    func show() {
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    /// Re-check when you come back from Terminal (installing or signing in).
    func windowDidBecomeKey(_ n: Notification) { refresh() }

    func set(_ i: Int, _ state: Bool?) {
        let (sym, color): (String, NSColor) = state == nil ? ("hourglass", .secondaryLabelColor)
            : state! ? ("checkmark.circle.fill", .systemGreen) : ("exclamationmark.circle.fill", .systemOrange)
        rows[i].icon.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: state == nil ? [color] : [.white, color]))
        rows[i].button.isHidden = state == true && i < 3
    }

    static func textSniperInstalled() -> Bool {
        ["com.valerijs.boguckis.store.TextSniper", "com.valerijs.boguckis.TextSniper"]
            .contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
            || FileManager.default.fileExists(atPath: "/Applications/TextSniper.app")
    }

    @objc func refresh() {
        let hasClaude = findClaude() != nil
        set(0, hasClaude)
        set(2, appDelegate?.hasScreenAccess == true)
        for (i, symbol) in [(3, "viewfinder"), (4, "sparkles")] {
            rows[i].icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [claudeOrange]))
            rows[i].button.isEnabled = false
        }
        rows[1].button.isEnabled = hasClaude
        guard hasClaude else { set(1, false); return }
        set(1, nil)
        appDelegate?.refreshAuth { [weak self] ok in
            self?.set(1, ok)
            self?.rows[3].button.isEnabled = ok
            self?.rows[4].button.isEnabled = ok
        }
    }

    @objc func installClaude() {
        let path = workDir + "/install-claude.command"
        let script = """
        #!/bin/zsh
        echo "Installing Claude Code (https://claude.ai/install.sh)…"
        curl -fsSL https://claude.ai/install.sh | bash
        echo; echo "Done. Go back to ClaudeSniper and click Check again."
        """
        try? script.write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o755)
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
    @objc func signIn() { appDelegate?.login() }
    @objc func tryCapture() { appDelegate?.captureScreen() }
    @objc func allowScreen() { appDelegate?.askScreenAccess() }
    @objc func trySample() { appDelegate?.trySample() }
    @objc func finish() {
        defaults.set(true, forKey: "onboarded")
        if appDelegate?.enabled == false { appDelegate?.enabled = true }
        window.close()
    }
}

// MARK: - History window

final class HistoryCell: NSTableCellView {
    let icon = NSImageView()
    let title = NSTextField(labelWithString: "")
    let sub = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        icon.contentTintColor = claudeOrange
        title.font = .systemFont(ofSize: 12.5, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        sub.font = .systemFont(ofSize: 10.5)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingTail
        for v in [icon, title, sub] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            sub.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            sub.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// Every saved answer: a searchable list grouped by day on the left, the answer on the right.
final class HistoryWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    enum Row { case day(String), entry(HistoryEntry) }

    let window: NSWindow
    let table = NSTableView()
    let search = NSSearchField()
    let detail = NSTextView()
    let detailScroll = NSScrollView()
    let modeTag = NSTextField(labelWithString: "")
    let meta = NSTextField(labelWithString: "")
    let emptyBox = NSStackView()
    let emptyLabel = NSTextField(wrappingLabelWithString: "")
    var entryButtons: [NSControl] = []
    var clearBtn: NSButton!
    var rows: [Row] = []
    let store: HistoryStore

    init(store: HistoryStore) {
        self.store = store
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 600),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "ClaudeSniper History"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 420)
        let content = NSView()
        window.contentView = content

        // Sidebar
        let side = NSVisualEffectView()
        side.material = .sidebar
        side.blendingMode = .behindWindow
        let heading = NSTextField(labelWithString: "History")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        search.placeholderString = "Search captures and answers"
        search.delegate = self
        search.controlSize = .large
        let col = NSTableColumn(identifier: .init("entry"))
        table.addTableColumn(col)
        table.headerView = nil
        table.style = .sourceList
        table.backgroundColor = .clear
        table.floatsGroupRows = false
        table.dataSource = self
        table.delegate = self
        let tScroll = NSScrollView()
        tScroll.documentView = table
        tScroll.hasVerticalScroller = true
        tScroll.drawsBackground = false
        let line = NSBox()
        line.boxType = .separator

        // Detail
        modeTag.font = .systemFont(ofSize: 11, weight: .semibold)
        modeTag.textColor = MDTheme.window.codeText
        modeTag.wantsLayer = true
        modeTag.layer?.backgroundColor = claudeOrange.withAlphaComponent(0.16).cgColor
        modeTag.layer?.cornerRadius = 9
        meta.font = .systemFont(ofSize: 11.5)
        meta.textColor = .secondaryLabelColor
        detail.isEditable = false
        detail.drawsBackground = false
        detail.textContainerInset = NSSize(width: 24, height: 8)
        detail.isVerticallyResizable = true
        detail.autoresizingMask = [.width]
        detail.textContainer?.widthTracksTextView = true
        detail.linkTextAttributes = [.foregroundColor: claudeOrange, .underlineStyle: NSUnderlineStyle.single.rawValue]
        detailScroll.documentView = detail
        detailScroll.hasVerticalScroller = true
        detailScroll.drawsBackground = false

        let clawd = NSImageView(image: Pixel.clawd(px: 4, on: false))
        clawd.imageScaling = .scaleNone
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyBox.orientation = .vertical
        emptyBox.spacing = 14
        emptyBox.addArrangedSubview(clawd)
        emptyBox.addArrangedSubview(emptyLabel)

        let copy = NSButton(title: "Copy answer", target: self, action: #selector(copyAnswer))
        let open = NSButton(title: "Open in pop-up", target: self, action: #selector(openInPopup))
        open.toolTip = "Show this answer in the pop-up. Follow-up questions continue that chat."
        let export = NSPopUpButton(frame: .zero, pullsDown: true)
        export.addItems(withTitles: ["Export chat", "As a Markdown file…", "To Apple Notes"])
        export.item(at: 1)?.target = self
        export.item(at: 1)?.action = #selector(exportMD)
        export.item(at: 2)?.target = self
        export.item(at: 2)?.action = #selector(exportToNotes)
        clearBtn = NSButton(title: "Clear history…", target: self, action: #selector(clearAll))
        for b in [copy, open, export, clearBtn] as [NSButton] { b.bezelStyle = .rounded }
        entryButtons = [copy, open, export]
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [copy, open, export, spacer, clearBtn])
        bar.orientation = .horizontal
        bar.spacing = 8
        let barLine = NSBox()
        barLine.boxType = .separator

        for v in [side, line, modeTag, meta, detailScroll, emptyBox, barLine, bar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        for v in [heading, search, tScroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            side.addSubview(v)
        }
        NSLayoutConstraint.activate([
            side.topAnchor.constraint(equalTo: content.topAnchor),
            side.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            side.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            side.widthAnchor.constraint(equalToConstant: 320),
            line.topAnchor.constraint(equalTo: content.topAnchor),
            line.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: side.trailingAnchor),
            line.widthAnchor.constraint(equalToConstant: 1),

            heading.topAnchor.constraint(equalTo: side.topAnchor, constant: 7),
            heading.leadingAnchor.constraint(equalTo: side.leadingAnchor, constant: 78),
            search.topAnchor.constraint(equalTo: side.topAnchor, constant: 38),
            search.leadingAnchor.constraint(equalTo: side.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: side.trailingAnchor, constant: -12),
            tScroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            tScroll.leadingAnchor.constraint(equalTo: side.leadingAnchor),
            tScroll.trailingAnchor.constraint(equalTo: side.trailingAnchor),
            tScroll.bottomAnchor.constraint(equalTo: side.bottomAnchor),

            modeTag.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            modeTag.leadingAnchor.constraint(equalTo: line.trailingAnchor, constant: 28),
            modeTag.heightAnchor.constraint(equalToConstant: 18),
            meta.leadingAnchor.constraint(equalTo: modeTag.trailingAnchor, constant: 10),
            meta.centerYAnchor.constraint(equalTo: modeTag.centerYAnchor),
            detailScroll.topAnchor.constraint(equalTo: modeTag.bottomAnchor, constant: 8),
            detailScroll.leadingAnchor.constraint(equalTo: line.trailingAnchor),
            detailScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            detailScroll.bottomAnchor.constraint(equalTo: barLine.topAnchor),
            emptyBox.centerXAnchor.constraint(equalTo: detailScroll.centerXAnchor),
            emptyBox.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            emptyLabel.widthAnchor.constraint(equalToConstant: 280),

            barLine.leadingAnchor.constraint(equalTo: line.trailingAnchor),
            barLine.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            barLine.heightAnchor.constraint(equalToConstant: 1),
            barLine.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -52),
            bar.leadingAnchor.constraint(equalTo: line.trailingAnchor, constant: 20),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            bar.centerYAnchor.constraint(equalTo: content.bottomAnchor, constant: -26),
        ])
    }

    func show() {
        reload()
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    /// Sample answers for `--demo-history`, so screenshots never show real captures.
    static let sample: [HistoryEntry] = {
        func e(_ hoursAgo: Double, _ mode: String, _ capture: String, _ answer: String, followUp: String? = nil, chat: String = "a") -> HistoryEntry {
            var x = HistoryEntry(chatID: chat, mode: mode, model: "Haiku · low", capture: capture, followUp: followUp, answer: answer)
            x.date = Date().addingTimeInterval(-hoursAgo * 3600)
            return x
        }
        let photo = "What is photosynthesis and why does it matter?"
        return [
            e(50, "Translate", "La entropía mide el número de configuraciones microscópicas de un sistema.", "Entropy measures the number of microscopic configurations of a system.", chat: "c"),
            e(27, "Fix", "i has went to the libary yesterday", "I went to the library yesterday.\n\n---\n\n- \"i\" → \"I\"\n- \"has went\" → \"went\"\n- \"libary\" → \"library\"", chat: "b"),
            e(26, "Solve", "Solve 3x + 7 = 22", "1. Subtract 7 from both sides: `3x = 15`\n2. Divide by 3: `x = 5`\n\n**x = 5**", chat: "b"),
            e(1.2, "Summarize", "The mitochondrion is an organelle that produces most of the chemical energy (ATP) needed to power the cell.", "- Mitochondria are organelles inside cells\n- They produce most of the cell's **ATP**\n- ATP is the energy the cell runs on"),
            e(0.4, "Explain", photo, "**Photosynthesis** is the process plants, algae and some bacteria use to turn sunlight into chemical energy.\n\n- **In:** light + water (`H₂O`) + carbon dioxide (`CO₂`)\n- **Out:** glucose (food) + oxygen (`O₂`)\n\nIt matters because it produces *almost all the oxygen* we breathe and is the base of every food chain."),
            e(0.3, "Explain", photo, "Not the light-dependent part: without light there is no energy to split water. The **Calvin cycle** can keep running for a short while on stored ATP and NADPH.", followUp: "Does it happen at night?"),
        ]
    }()
    var entries: [HistoryEntry] { isDemo ? Self.sample : store.entries }

    func reload() {
        let q = search.stringValue.lowercased()
        let list = entries.reversed().filter {
            q.isEmpty || $0.capture.lowercased().contains(q) || $0.answer.lowercased().contains(q)
                || ($0.followUp?.lowercased().contains(q) ?? false)
        }
        rows = []
        var lastDay = ""
        let df = DateFormatter()
        df.dateStyle = .medium
        let cal = Calendar.current
        for e in list {
            let day = cal.isDateInToday(e.date) ? "Today" : cal.isDateInYesterday(e.date) ? "Yesterday" : df.string(from: e.date)
            if day != lastDay { rows.append(.day(day)); lastDay = day }
            rows.append(.entry(e))
        }
        table.reloadData()
        let has = !list.isEmpty
        emptyBox.isHidden = has
        for v in [detailScroll, modeTag, meta] as [NSView] { v.isHidden = !has }
        entryButtons.forEach { $0.isEnabled = has }
        clearBtn.isEnabled = !entries.isEmpty
        emptyLabel.stringValue = entries.isEmpty ? "No answers yet.\nCapture something with TextSniper and it will show up here." : "No matches."
        if has, let first = rows.firstIndex(where: { if case .entry = $0 { return true }; return false }) {
            table.selectRowIndexes([first], byExtendingSelection: false)
            showSelected()
        }
    }

    func controlTextDidChange(_ obj: Notification) { reload() }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { if case .day = rows[row] { return true }; return false }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { if case .day = rows[row] { return 26 }; return 46 }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { if case .entry = rows[row] { return true }; return false }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .day(let name):
            let id = NSUserInterfaceItemIdentifier("day")
            let tf = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField) ?? {
                let t = NSTextField(labelWithString: "")
                t.identifier = id
                t.font = .systemFont(ofSize: 11, weight: .semibold)
                t.textColor = .tertiaryLabelColor
                return t
            }()
            tf.stringValue = name
            return tf
        case .entry(let e):
            let id = NSUserInterfaceItemIdentifier("entry")
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? HistoryCell) ?? {
                let c = HistoryCell(frame: .zero)
                c.identifier = id
                return c
            }()
            let symbol = e.followUp != nil ? "arrow.turn.down.right" : (builtInModes.first { $0.label == e.mode }?.symbol ?? "star")
            cell.icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: e.mode)
            cell.title.stringValue = (e.followUp ?? e.capture).replacingOccurrences(of: "\n", with: " ")
            let tf = DateFormatter()
            tf.timeStyle = .short
            cell.sub.stringValue = "\(tf.string(from: e.date)) · \(e.mode) · \(e.model)"
            return cell
        }
    }

    var selected: HistoryEntry? {
        let r = table.selectedRow
        guard r >= 0, r < rows.count, case .entry(let e) = rows[r] else { return nil }
        return e
    }

    func tableViewSelectionDidChange(_ n: Notification) { showSelected() }

    func showSelected() {
        guard let e = selected else { return }
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        modeTag.stringValue = "  \(e.followUp != nil ? "Follow-up" : e.mode)  "
        meta.stringValue = "\(df.string(from: e.date)) · \(e.model)"
        // What was captured (or asked), as a quote; then the answer.
        var q = e.followUp ?? e.capture
        if q.count > 700 { q = String(q.prefix(700)) + "…" }
        let quote = NSMutableParagraphStyle()
        quote.headIndent = 14
        quote.lineSpacing = 2
        quote.paragraphSpacing = 2
        let s = NSMutableAttributedString(string: "▎ ", attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: claudeOrange])
        s.append(NSAttributedString(string: q + "\n", attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: NSColor.secondaryLabelColor]))
        s.addAttribute(.paragraphStyle, value: quote, range: NSRange(location: 0, length: s.length))
        s.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 6)]))
        var th = MDTheme.window
        th.width = max(detailScroll.frame.width - 60, 320)
        s.append(Markdown.render(e.answer, th))
        detail.textStorage?.setAttributedString(s)
        detail.scroll(.zero)
    }

    @objc func copyAnswer() {
        guard let e = selected else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(e.answer, forType: .string)
        appDelegate?.lastChange = NSPasteboard.general.changeCount
    }
    @objc func openInPopup() { if let e = selected { appDelegate?.openFromHistory(e) } }
    @objc func exportMD() { if let e = selected { appDelegate?.exportMarkdown(chatID: e.chatID) } }
    @objc func exportToNotes() { if let e = selected { appDelegate?.exportNotes(chatID: e.chatID) } }
    @objc func clearAll() {
        let a = NSAlert()
        a.messageText = "Clear all history?"
        a.informativeText = "This deletes every saved capture and answer. Your chats in Claude Code are not affected."
        a.addButton(withTitle: "Clear")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { store.clear(); reload() }
    }
}

// MARK: - main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
