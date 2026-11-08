// ClaudeSniper — a companion for TextSniper.
// Pixel-art menu bar icon with an on/off toggle. When it's on and you press ⌘⇧2 in
// TextSniper, it sends the capture to Claude (through Claude Code, using your plan) and
// shows the answer in a pop-up. Captures are grouped into a chat that expires after a
// while without use (15 min by default, see Settings); you can start a new chat or switch.

import Cocoa
import ServiceManagement
import Carbon.HIToolbox
import ApplicationServices
import AVFoundation
import NaturalLanguage
import UniformTypeIdentifiers

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
}
let chatMemoryOptions: [(Any, String)] = [(0, "Off · every capture is a new chat"), (5, "5 minutes"), (10, "10 minutes"),
                                          (15, "15 minutes"), (30, "30 minutes"), (60, "1 hour")]
let lengthOptions: [(Any, String)] = [("short", "Short"), ("normal", "Normal"), ("detailed", "Detailed")]
let lengthHint = ["short": "under 80 words", "normal": "under 200 words", "detailed": "under 400 words; go deeper when it helps"]
let positionOptions: [(Any, String)] = [("cursor", "Next to the cursor"), ("topRight", "Top-right corner"), ("center", "Center of the screen")]
let autoCloseOptions: [(Any, String)] = [(0, "Never"), (15, "After 15 seconds"), (30, "After 30 seconds"), (60, "After 1 minute")]

/// The capture shortcut. Defaults to TextSniper's ⌘⇧2; change it if you changed it in TextSniper.
var hotkeyCode = defaults.object(forKey: "hotkeyCode") as? Int ?? Int(kVK_ANSI_2)
var hotkeyMods = UInt(defaults.object(forKey: "hotkeyMods") as? Int ?? Int(NSEvent.ModifierFlags([.command, .shift]).rawValue))
var hotkeyLabel = defaults.string(forKey: "hotkeyLabel") ?? "⌘⇧2"

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

/// Light markdown (bold, italic, code) as an attributed string, for the History window.
func inlineMarkdown(_ md: String, size: CGFloat, color: NSColor) -> NSAttributedString {
    let parsed = (try? AttributedString(markdown: md, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(md)
    let out = NSMutableAttributedString()
    let base = NSFont.systemFont(ofSize: size)
    for run in parsed.runs {
        var font = base
        if let i = run.inlinePresentationIntent {
            if i.contains(.code) { font = .monospacedSystemFont(ofSize: size - 1, weight: .regular) }
            else {
                var t: NSFontDescriptor.SymbolicTraits = []
                if i.contains(.stronglyEmphasized) { t.insert(.bold) }
                if i.contains(.emphasized) { t.insert(.italic) }
                if !t.isEmpty { font = NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(t), size: size) ?? base }
            }
        }
        out.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: [.font: font, .foregroundColor: color]))
    }
    return out
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

// MARK: - Global shortcut to reopen the last answer (⌥⌘2, no permission needed)

func registerShowLastHotkey() {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
        DispatchQueue.main.async { appDelegate?.showLast() }
        return noErr
    }, 1, &spec, nil, nil)
    var ref: EventHotKeyRef?
    RegisterEventHotKey(UInt32(kVK_ANSI_2), UInt32(cmdKey | optionKey),
                        EventHotKeyID(signature: 0x434C534E, id: 1), GetApplicationEventTarget(), 0, &ref)
}

// MARK: - Hotkey (⌘⇧2 by default)

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
        if code == Int64(hotkeyCode), m.rawValue == hotkeyMods {
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
    struct Shown { let header: String; let preview: String; let text: String; let mode: String; let footer: String; let replace: Bool }
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
            miniPending = { [weak self] in self?.popup.show(header: header, preview: preview, state: state, footer: footer) }
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
            if newValue { startMonitoring(); prewarm() } else { stopMonitoring(); stopWarm() }
        }
    }
    var model: String { defaults.string(forKey: "model") ?? "haiku" }
    var effort: String { defaults.string(forKey: "effort") ?? "low" }
    var defaultMode: String { defaults.string(forKey: "mode") ?? "auto" }
    var answerLanguage: String { defaults.string(forKey: "answerLanguage") ?? "system" }

    struct Capture { let text: String?; let imagePath: String?; let preview: String }
    var lastCapture: Capture?

    func applicationWillTerminate(_ n: Notification) { stopWarm() }

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
        registerShowLastHotkey()
        signal(SIGPIPE, SIG_IGN)  // a preloaded process may close its input
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.prewarm() }
        if CommandLine.arguments.contains("--demo") { demo() }
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
        if a.contains("--demo-busy") { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.setBusy(true) } }
        if a.contains("--demo-pin") { DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.popup.togglePin() } }
        if a.contains("--demo-history") { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.openHistory() } }
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
    func demo() {
        let q = "What is photosynthesis and why does it matter?"
        lastCapture = Capture(text: q, imagePath: nil, preview: q)
        popup.mode = "explain"
        popup.show(header: header(), preview: q, state: .loading, footer: "Starting a new chat…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            self.popup.show(header: self.header(), preview: q, state: .result("""
            **Photosynthesis** is the process plants, algae and some bacteria use to turn sunlight into chemical energy.

            - **In:** light + water (`H₂O`) + carbon dioxide (`CO₂`)
            - **Out:** glucose (food) + oxygen (`O₂`)

            It matters because it produces *almost all the oxygen* we breathe and is the base of every food chain.
            """), footer: "Chat · 3 captures · expires in 15 min")
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

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshAuth()
        menu.removeAllItems()
        menu.addItem(viewItem(headerView()))
        menu.addItem(.separator())
        menu.addItem(viewItem(segmentView(title: "MODEL", opts: models, selected: model, action: #selector(modelChanged(_:)))))
        menu.addItem(viewItem(segmentView(title: "EFFORT", opts: efforts, selected: effort, action: #selector(effortChanged(_:)))))
        menu.addItem(viewItem(modeView()))
        menu.addItem(myModesItem())
        let fastItem = item("Super fast mode", "bolt.fill", #selector(toggleSuperFast))
        fastItem.state = Settings.superFast ? .on : .off
        fastItem.toolTip = "Haiku with no extended thinking, from a Claude Code process that's already waiting. Answers in about a second."
        menu.addItem(fastItem)
        if Settings.superFast {
            for it in menu.items { it.view?.subviews.compactMap { $0 as? NSSegmentedControl }.filter { $0.action == #selector(modelChanged(_:)) || $0.action == #selector(effortChanged(_:)) }.forEach { $0.isEnabled = false } }
        }
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
                              "“\(c.title)”", "\(c.count) capture\(c.count == 1 ? "" : "s") · expires in \(ChatStore.minutesLeft(c)) min"))
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
            it.attributedTitle = twoLine(c.title, "\(c.count) capture\(c.count == 1 ? "" : "s") · \(ChatStore.ago(c.lastUsed)) · expires in \(ChatStore.minutesLeft(c)) min")
            sub.addItem(it)
        }
        if sub.items.isEmpty {
            let it = NSMenuItem(title: Settings.chatMinutes == 0 ? "Chat memory is off (see Settings)" : "No recent chats (they last \(chatMemoryText()))", action: nil, keyEquivalent: "")
            it.isEnabled = false
            sub.addItem(it)
        }
        switchItem.submenu = sub
        menu.addItem(switchItem)
        let last = item("Show last answer", "arrow.counterclockwise", #selector(showLast))
        last.keyEquivalent = "2"
        last.keyEquivalentModifierMask = [.option, .command]
        menu.addItem(last)
        let exportItem = item("Export chat", "square.and.arrow.up", nil)
        let em = NSMenu()
        em.addItem(item("As a Markdown file…", "doc.text", #selector(exportCurrentMarkdown)))
        em.addItem(item("To Apple Notes", "note.text", #selector(exportCurrentNotes)))
        exportItem.submenu = em
        menu.addItem(exportItem)
        menu.addItem(item("History…", "clock.arrow.circlepath", #selector(openHistory)))
        menu.addItem(.separator())

        // Status
        if findClaude() == nil {
            menu.addItem(status(false, "Claude Code is not installed", action: nil))
        } else if loggedIn == true {
            menu.addItem(status(true, "Connected to your Claude plan" + (account.isEmpty ? "" : " · \(account)"), action: nil))
        } else {
            menu.addItem(status(false, loggedIn == nil ? "Checking connection…" : "Sign in to Claude…", action: #selector(login)))
        }
        menu.addItem(status(true, "Watching for TextSniper captures", action: nil))
        menu.addItem(.separator())
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
        let icon = NSImageView(image: Pixel.clawd(px: 2.5, on: enabled))
        icon.imageScaling = .scaleNone
        icon.frame = NSRect(x: 12, y: 14, width: 44, height: 30)
        let title = NSTextField(labelWithString: "ClaudeSniper")
        title.font = .systemFont(ofSize: 14, weight: .bold)
        title.frame = NSRect(x: 62, y: 29, width: 160, height: 18)
        let sub = NSTextField(labelWithString: enabled ? "On · press \(hotkeyLabel) in TextSniper" : "Off")
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
        l.frame = NSRect(x: 14, y: 32, width: 120, height: 14)
        let seg = NSSegmentedControl(labels: opts.map { $0.label }, trackingMode: .selectOne, target: self, action: action)
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
        popup.allowReplace = s.replace
        popup.show(header: s.header, preview: s.preview, state: .result(s.text), footer: s.footer)
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
        m.addItem(choiceMenu("Chat memory", "clock.arrow.circlepath", key: "chatMinutes", options: chatMemoryOptions,
                             isOn: { ($0 as? Int) == Settings.chatMinutes }))
        m.addItem(choiceMenu("Answer length", "text.alignleft", key: "answerLength", options: lengthOptions,
                             isOn: { ($0 as? String) == Settings.answerLength }))
        m.addItem(choiceMenu("Pop-up position", "macwindow", key: "popupPosition", options: positionOptions,
                             isOn: { ($0 as? String) == Settings.popupPosition }))
        m.addItem(choiceMenu("Close pop-up", "timer", key: "autoClose", options: autoCloseOptions,
                             isOn: { ($0 as? Int) == Settings.autoClose }))
        m.addItem(.separator())
        m.addItem(toggle("Copy the answer automatically", "doc.on.clipboard", key: "autoCopy"))
        m.addItem(toggle("Play a sound when the answer arrives", "speaker.wave.2", key: "sound"))
        m.addItem(toggle("Mini Clawd mode: answers wait in a tiny Clawd", "face.smiling", key: "miniMode"))
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
        if hotkeyLabel != "⌘⇧2" { m.addItem(item("Reset shortcut to ⌘⇧2", "arrow.uturn.backward", #selector(resetShortcut))) }
        let clear = item("Clear all chats", "trash", #selector(clearChats))
        clear.isEnabled = !store.recent.isEmpty
        m.addItem(clear)
        s.submenu = m
        return s
    }

    @objc func choicePicked(_ i: NSMenuItem) { if let c = i.representedObject as? Choice { defaults.set(c.value, forKey: c.key) } }
    @objc func togglePicked(_ i: NSMenuItem) { if let k = i.representedObject as? String { defaults.set(!defaults.bool(forKey: k), forKey: k) } }
    @objc func clearChats() { store.clearAll() }
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
        let l = NSTextField(wrappingLabelWithString: "Press the shortcut you use in TextSniper.\nIt needs ⌘, ⌃ or ⌥. Esc cancels.")
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
        setShortcut(code: Int(kVK_ANSI_2), mods: NSEvent.ModifierFlags([.command, .shift]).rawValue, label: "⌘⇧2")
    }

    func setShortcut(code: Int, mods: UInt, label: String) {
        hotkeyCode = code; hotkeyMods = mods; hotkeyLabel = label
        defaults.set(code, forKey: "hotkeyCode")
        defaults.set(Int(mods), forKey: "hotkeyMods")
        defaults.set(label, forKey: "hotkeyLabel")
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
    @objc func modelChanged(_ s: NSSegmentedControl) { defaults.set(models[s.selectedSegment].id, forKey: "model") }
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

    func refreshAuth() {
        guard let claude = findClaude() else { return }
        DispatchQueue.global().async {
            let out = runSync(claude, ["auth", "status"], stdin: nil, timeout: 20).output
            var ok = false, acct = ""
            if let start = out.firstIndex(of: "{"),
               let obj = try? JSONSerialization.jsonObject(with: Data(out[start...].utf8)) as? [String: Any] {
                ok = obj["loggedIn"] as? Bool ?? false
                acct = (obj["email"] ?? obj["subscriptionType"]) as? String ?? ""
            }
            DispatchQueue.main.async { self.loggedIn = ok; self.account = isDemo ? "" : acct }
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
    }

    func poll() {
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
            return "Chat · \(c.count) capture\(c.count == 1 ? "" : "s") · expires in \(ChatStore.minutesLeft(c)) min"
        }
        return Settings.chatMinutes == 0 ? "Chat memory is off" : "New chat · your next capture starts fresh"
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
    func run(_ c: Capture, modeID: String, again: Bool) {
        let m = mode(modeID)
        let head = again ? "Same capture as before, now in another mode." : "New capture."
        let body: String
        if let t = c.text {
            body = "\(head)\nMODE: \(m.label) — \(m.instruction)\n\nCapture:\n\n\(t)"
        } else {
            body = "\(head) It is an image: read it at \(c.imagePath!) with the Read tool.\nMODE: \(m.label) — \(m.instruction)"
        }
        popup.mode = m.id
        ask(prompt: body, image: c.imagePath != nil, preview: c.preview)
    }

    func rerun(modeID: String) {
        guard let c = lastCapture else { NSSound.beep(); return }
        run(c, modeID: modeID, again: true)
    }

    func header() -> String {
        Settings.superFast ? "Haiku · ⚡ super fast" : "\(label(models, model)) · \(label(efforts, effort).lowercased())"
    }

    func ask(prompt: String, image: Bool, preview: String, followUp: String? = nil, allowWarm: Bool = true, retried: Bool = false) {
        guard let claude = findClaude() else {
            popup.show(header: header(), preview: preview, state: .error("Claude Code wasn't found. Install it with:\ncurl -fsSL https://claude.ai/install.sh | bash"), footer: "")
            return
        }
        current?.process.terminate()
        current = nil
        requestID += 1
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
                self.display(header: hdr, preview: preview, state: .result(text), footer: footer)
                self.lastShown = Shown(header: hdr, preview: preview, text: text, mode: self.popup.mode, footer: footer, replace: followUp == nil)
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
                self.display(header: hdr, preview: preview, state: .error("You're not signed in to Claude Code.\nOpen the menu bar menu → “Sign in to Claude…”."), footer: "")
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

    @objc func toggleSuperFast() {
        defaults.set(!Settings.superFast, forKey: "superFast")
        Settings.superFast ? prewarm() : stopWarm()
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

final class FlippedView: NSView { override var isFlipped: Bool { true } }

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

final class PopupController: NSObject, AVSpeechSynthesizerDelegate {
    enum State { case loading, streaming(String), result(String), error(String) }

    let width: CGFloat = 600
    let panel: KeyPanel
    let clawdView = NSImageView()
    let titleLabel = NSTextField(labelWithString: "Claude")
    let chip = NSTextField(labelWithString: "")
    let quoteBox = NSView()
    let quoteBar = NSView()
    let quoteLabel = NSTextField(wrappingLabelWithString: "")
    let scroll = NSScrollView()
    let textView = NSTextView()
    let footerLabel = NSTextField(labelWithString: "")
    let hintLabel = NSTextField(labelWithString: "1–6 modes · tab ask · esc close")
    let askField = NSTextField()
    var copyBtn: NSButton!
    var newBtn: NSButton!
    var replaceBtn: NSButton!
    var pinBtn: NSButton!
    /// Pinned: the pop-up doesn't close by itself or with esc (only with ✕).
    var pinned = false
    var speakBtn: NSButton!
    var askBtn: NSButton!
    let frames = Pixel.clawdFrames(px: 2)
    let idleImage = Pixel.clawd(px: 2)
    var frameIdx = 0
    var animTimer: Timer?
    var dots = 0
    var streamingNow = false
    var resultText = ""
    var keyMonitor: Any?
    let modeBar = NSStackView()
    var modeButtons: [NSButton] = []
    var customPill: NSButton!
    var mode = "auto" { didSet { refreshModeBar() } }
    /// False for follow-up answers: Replace would paste an explanation, not the fixed text.
    var allowReplace = true
    let speech = AVSpeechSynthesizer()

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
        bg.maskImage = Self.roundedMask(18)
        panel.contentView = bg

        let border = NSView()
        border.wantsLayer = true
        border.layer?.cornerRadius = 18
        border.layer?.borderWidth = 1
        border.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor

        clawdView.image = idleImage
        clawdView.imageScaling = .scaleNone

        titleLabel.font = .systemFont(ofSize: 14, weight: .bold)
        titleLabel.textColor = .white

        chip.font = .systemFont(ofSize: 10.5, weight: .semibold)
        chip.textColor = claudeOrange
        chip.wantsLayer = true
        chip.layer?.backgroundColor = claudeOrange.withAlphaComponent(0.16).cgColor
        chip.layer?.cornerRadius = 8

        replaceBtn = iconButton("text.insert", "Replace: paste this where you captured it", #selector(replaceResult))
        speakBtn = iconButton("speaker.wave.2", "Read aloud", #selector(speak))
        askBtn = iconButton("text.bubble", "Ask a follow-up (tab)", #selector(showAsk))
        copyBtn = iconButton("doc.on.doc", "Copy answer", #selector(copyResult))
        newBtn = iconButton("square.and.pencil", "New chat", #selector(newChat))
        let closeBtn = iconButton("xmark", "Close (esc)", #selector(close))
        pinBtn = iconButton("pin", "Pin: keep this pop-up open", #selector(togglePin))
        let buttons = NSStackView(views: [pinBtn, replaceBtn, speakBtn, askBtn, copyBtn, newBtn, closeBtn])
        buttons.orientation = .horizontal
        buttons.spacing = 2

        quoteBox.wantsLayer = true
        quoteBox.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        quoteBox.layer?.cornerRadius = 8
        quoteBar.wantsLayer = true
        quoteBar.layer?.backgroundColor = claudeOrange.cgColor
        quoteBar.layer?.cornerRadius = 1.5
        quoteLabel.font = .systemFont(ofSize: 12)
        quoteLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        quoteLabel.maximumNumberOfLines = 2
        quoteLabel.lineBreakMode = .byTruncatingTail
        quoteLabel.cell?.truncatesLastVisibleLine = true

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.linkTextAttributes = [.foregroundColor: claudeOrange]
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        footerLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        footerLabel.textColor = NSColor.white.withAlphaComponent(0.45)
        hintLabel.font = .systemFont(ofSize: 10.5)
        hintLabel.textColor = NSColor.white.withAlphaComponent(0.3)

        askField.placeholderString = "Ask a follow-up…   ↩ send · esc cancel"
        askField.font = .systemFont(ofSize: 12.5)
        askField.bezelStyle = .roundedBezel
        askField.focusRingType = .none
        askField.isHidden = true
        askField.target = self
        askField.action = #selector(askSubmitted)

        let divider = NSBox(); divider.boxType = .separator

        modeBar.orientation = .horizontal
        modeBar.spacing = 4
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

        let all: [NSView] = [border, clawdView, titleLabel, chip, buttons,
                             quoteBox, modeBar, scroll, divider, footerLabel, hintLabel, askField]
        for v in all { v.translatesAutoresizingMaskIntoConstraints = false; bg.addSubview(v) }
        for v in [quoteBar, quoteLabel] { v.translatesAutoresizingMaskIntoConstraints = false; quoteBox.addSubview(v) }

        NSLayoutConstraint.activate([
            border.topAnchor.constraint(equalTo: bg.topAnchor),
            border.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
            border.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            border.trailingAnchor.constraint(equalTo: bg.trailingAnchor),

            clawdView.topAnchor.constraint(equalTo: bg.topAnchor, constant: 14),
            clawdView.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 16),
            clawdView.widthAnchor.constraint(equalToConstant: 34),
            clawdView.heightAnchor.constraint(equalToConstant: 24),
            titleLabel.leadingAnchor.constraint(equalTo: clawdView.trailingAnchor, constant: 9),
            titleLabel.centerYAnchor.constraint(equalTo: clawdView.centerYAnchor),
            chip.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            chip.centerYAnchor.constraint(equalTo: clawdView.centerYAnchor),
            chip.heightAnchor.constraint(equalToConstant: 17),

            buttons.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -12),
            buttons.centerYAnchor.constraint(equalTo: clawdView.centerYAnchor),

            quoteBox.topAnchor.constraint(equalTo: clawdView.bottomAnchor, constant: 14),
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
            modeBar.heightAnchor.constraint(equalToConstant: 22),
            scroll.topAnchor.constraint(equalTo: modeBar.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: divider.topAnchor, constant: -10),

            divider.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 16),
            divider.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -16),
            divider.bottomAnchor.constraint(equalTo: footerLabel.topAnchor, constant: -9),
            footerLabel.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 16),
            footerLabel.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -11),
            hintLabel.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -16),
            hintLabel.centerYAnchor.constraint(equalTo: footerLabel.centerYAnchor),
            askField.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 14),
            askField.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -14),
            askField.centerYAnchor.constraint(equalTo: footerLabel.centerYAnchor),
        ])

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.panel.isKeyWindow else { return e }
            let asking = !self.askField.isHidden
            if e.keyCode == UInt16(kVK_Escape) {
                if asking { self.hideAsk() } else if self.pinned { NSSound.beep() } else { self.close() }
                return nil
            }
            if asking { return e }
            if e.keyCode == UInt16(kVK_Tab) && !self.resultText.isEmpty && !self.streamingNow { self.showAsk(); return nil }
            let modes = allModes()
            if e.modifierFlags.intersection([.command, .control, .option]).isEmpty,
               let ch = e.charactersIgnoringModifiers, let n = Int(ch), (1...modes.count).contains(n) {
                appDelegate?.rerun(modeID: modes[n - 1].id); return nil
            }
            return e
        }
    }

    func pill(_ title: String, _ symbol: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: title)!,
                         target: self, action: action)
        b.isBordered = false
        b.imagePosition = .imageLeading
        b.imageHugsTitle = true
        b.font = .systemFont(ofSize: 11, weight: .medium)
        b.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        b.wantsLayer = true
        b.layer?.cornerRadius = 11
        b.translatesAutoresizingMaskIntoConstraints = false
        b.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return b
    }

    func style(_ b: NSButton, _ title: String, on: Bool) {
        b.layer?.backgroundColor = (on ? claudeOrange.withAlphaComponent(0.25) : NSColor.white.withAlphaComponent(0.06)).cgColor
        b.layer?.borderWidth = on ? 1 : 0
        b.layer?.borderColor = claudeOrange.withAlphaComponent(0.6).cgColor
        b.contentTintColor = on ? claudeOrange : NSColor.white.withAlphaComponent(0.7)
        b.attributedTitle = NSAttributedString(string: " " + title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: on ? .semibold : .medium),
            .foregroundColor: on ? claudeOrange : NSColor.white.withAlphaComponent(0.7)])
        b.constraints.filter { $0.firstAttribute == .width }.forEach { b.removeConstraint($0) }
        b.widthAnchor.constraint(equalToConstant: b.intrinsicContentSize.width + 12).isActive = true
    }

    func refreshModeBar() {
        for (i, b) in modeButtons.enumerated() { style(b, builtInModes[i].label, on: builtInModes[i].id == mode) }
        let custom = customModes
        customPill.isHidden = custom.isEmpty
        let isCustom = mode.hasPrefix("custom:")
        style(customPill, isCustom ? String(mode.dropFirst(7)) + " ▾" : "My modes ▾", on: isCustom)
    }

    @objc func modeClicked(_ b: NSButton) { appDelegate?.rerun(modeID: builtInModes[b.tag].id) }

    @objc func customPillClicked(_ b: NSButton) {
        let m = NSMenu()
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

    func iconButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
        b.isBordered = false
        b.bezelStyle = .accessoryBarAction
        b.contentTintColor = NSColor.white.withAlphaComponent(0.6)
        b.toolTip = tip
        b.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        b.widthAnchor.constraint(equalToConstant: 26).isActive = true
        b.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return b
    }

    func setAnswerButtons(visible: Bool) {
        copyBtn.isHidden = !visible
        speakBtn.isHidden = !visible
        askBtn.isHidden = !visible
        replaceBtn.isHidden = !(visible && allowReplace && replaceableModes.contains(mode))
    }

    func show(header: String, preview: String, state: State, footer: String) {
        chip.stringValue = "  \(header)  "
        let pv = preview.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        quoteLabel.stringValue = pv.isEmpty ? "—" : pv
        footerLabel.stringValue = footer
        newBtn.contentTintColor = NSColor.white.withAlphaComponent(0.6)
        var streaming = false

        switch state {
        case .loading:
            closeWork?.cancel()
            stopSpeaking()
            hideAsk()
            setAnswerButtons(visible: false)
            resultText = ""
            streamingNow = false
            startAnimating()
        case .streaming(let t):
            streaming = true
            if !streamingNow { streamingNow = true; if animTimer == nil { startAnimating() } }
            setAnswerButtons(visible: false)
            resultText = t
            let s = NSMutableAttributedString(attributedString: renderMarkdown(t))
            s.append(NSAttributedString(string: " ▍", attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: claudeOrange]))
            textView.textStorage?.setAttributedString(s)
        case .result(let t):
            streamingNow = false
            stopAnimating()
            scheduleAutoClose(isDemo ? 0 : Settings.autoClose)
            resultText = t
            setAnswerButtons(visible: true)
            textView.textStorage?.setAttributedString(renderMarkdown(t))
        case .error(let t):
            streamingNow = false
            stopAnimating()
            setAnswerButtons(visible: false)
            resultText = ""
            textView.textStorage?.setAttributedString(NSAttributedString(string: t,
                attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.systemRed.blended(withFraction: 0.3, of: .white)!]))
        }

        let textWidth = width - 28
        textView.frame.size.width = textWidth
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let used = textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 40
        quoteLabel.preferredMaxLayoutWidth = width - 32 - 30
        let quoteH = quoteLabel.fittingSize.height + 14
        let chrome: CGFloat = 14 + 24 + 14 + quoteH + 10 + 22 + 12 + 10 + 1 + 9 + 13 + 11
        let height = min(max(used + chrome + 4, 170), 620)

        if !panel.isVisible || (isDemo && !streaming) {
            positionNearMouse(height: height)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1 }
        } else if abs(panel.frame.height - height) > 0.5 {
            var f = panel.frame
            f.origin.y += f.height - height
            f.size.height = height
            panel.setFrame(f, display: true, animate: !streaming)
            panel.orderFrontRegardless()
        } else {
            panel.orderFrontRegardless()
        }
        panel.makeKey()
        if streaming { textView.scrollToEndOfDocument(nil) } else { scroll.contentView.scroll(to: .zero) }
    }

    func startAnimating() {
        animTimer?.invalidate()
        frameIdx = 0; dots = 0
        animTimer = Timer.scheduledTimer(withTimeInterval: 0.16, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.frameIdx = (self.frameIdx + 1) % self.frames.count
            self.clawdView.image = self.frames[self.frameIdx]
            if self.frameIdx % 2 == 0 && !self.streamingNow { self.dots = (self.dots + 1) % 4; self.setThinking() }
        }
        if !streamingNow { setThinking() }
    }
    func setThinking() {
        textView.textStorage?.setAttributedString(NSAttributedString(string: "Thinking" + String(repeating: ".", count: dots),
            attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: claudeOrange]))
    }
    func stopAnimating() {
        animTimer?.invalidate(); animTimer = nil
        clawdView.image = idleImage
    }

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
        let g = CAGradientLayer()
        g.colors = [NSColor(srgbRed: 0.42, green: 0.20, blue: 0.13, alpha: 1).cgColor,
                    NSColor(srgbRed: 0.10, green: 0.08, blue: 0.09, alpha: 1).cgColor,
                    NSColor(srgbRed: 0.16, green: 0.12, blue: 0.20, alpha: 1).cgColor]
        g.startPoint = CGPoint(x: 0, y: 1); g.endPoint = CGPoint(x: 1, y: 0)
        g.frame = CGRect(origin: .zero, size: r.size)
        v.layer = g
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
        pinBtn.contentTintColor = pinned ? claudeOrange : NSColor.white.withAlphaComponent(0.6)
        pinBtn.toolTip = pinned ? "Unpin" : "Pin: keep this pop-up open"
        hintLabel.stringValue = pinned ? "📌 pinned · ✕ to close" : "1–6 modes · tab ask · esc close"
        if pinned { closeWork?.cancel() } else if !resultText.isEmpty { scheduleAutoClose(Settings.autoClose) }
    }

    @objc func close() {
        if pinned { togglePin() }   // closing with ✕ also unpins
        stopSpeaking()
        hideAsk()
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; panel.animator().alphaValue = 0 },
                                             completionHandler: { self.panel.orderOut(nil); self.panel.alphaValue = 1 })
    }

    @objc func copyResult() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resultText, forType: .string)
        appDelegate?.lastChange = NSPasteboard.general.changeCount  // don't treat this as a capture
        flash(copyBtn, "checkmark")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.copyBtn.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil) }
    }

    /// Fix / Translate: put the corrected or translated text back where it came from.
    @objc func replaceResult() {
        let t = mainPart(resultText)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string)
        appDelegate?.lastChange = NSPasteboard.general.changeCount
        if AXIsProcessTrusted() {
            close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { pasteKeystroke() }
        } else {
            footerLabel.stringValue = "✓ Copied · press ⌘V to paste (Settings → Allow auto-paste)"
            flash(replaceBtn, "checkmark")
        }
    }

    // Read aloud

    @objc func speak() {
        if speech.isSpeaking { stopSpeaking(); return }
        let plain = resultText
            .replacingOccurrences(of: #"(?m)^\s*-{3,}\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[*`#>_]"#, with: "", options: .regularExpression)
        guard !plain.isEmpty else { return }
        let u = AVSpeechUtterance(string: plain)
        let r = NLLanguageRecognizer()
        r.processString(plain)
        if let lang = r.dominantLanguage?.rawValue {
            let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(lang) }
            u.voice = voices.first { $0.language == AVSpeechSynthesisVoice.currentLanguageCode() } ?? voices.first
        }
        speech.speak(u)
        speakBtn.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Stop")
    }
    func stopSpeaking() {
        if speech.isSpeaking { speech.stopSpeaking(at: .immediate) }
        speakBtn?.image = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: "Read aloud")
    }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        DispatchQueue.main.async { self.speakBtn.image = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: "Read aloud") }
    }

    // Follow-up questions

    @objc func showAsk() {
        guard !resultText.isEmpty, !streamingNow else { return }
        closeWork?.cancel()
        footerLabel.isHidden = true
        hintLabel.isHidden = true
        askField.isHidden = false
        askField.stringValue = ""
        panel.makeKey()
        panel.makeFirstResponder(askField)
    }
    func hideAsk() {
        guard !askField.isHidden else { return }
        askField.isHidden = true
        footerLabel.isHidden = false
        hintLabel.isHidden = false
        panel.makeFirstResponder(nil)
    }
    @objc func askSubmitted() {
        guard !askField.isHidden else { return }
        let q = askField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        hideAsk()
        appDelegate?.followUp(q)
    }

    @objc func newChat() {
        appDelegate?.store.newChat()
        footerLabel.stringValue = "✓ New chat · your next capture starts fresh"
        newBtn.contentTintColor = claudeOrange
    }

    func flash(_ b: NSButton, _ symbol: String) {
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    func renderMarkdown(_ raw: String) -> NSAttributedString {
        // No blank lines around a "---" divider: the line itself is the spacing.
        let md = raw.replacingOccurrences(of: #"\n[ \t]*\n([ \t]*-{3,}[ \t]*)\n[ \t]*\n"#, with: "\n$1\n", options: .regularExpression)
        let base = NSFont.systemFont(ofSize: 14)
        let text = NSColor.white.withAlphaComponent(0.92)
        let para = NSMutableParagraphStyle(); para.paragraphSpacing = 5; para.lineSpacing = 2.5
        let out = NSMutableAttributedString()
        let lines = md.components(separatedBy: "\n")
        for (i, rawLine) in lines.enumerated() {
            var line = rawLine
            var lineFont = base
            if line.trimmingCharacters(in: .whitespaces).range(of: #"^-{3,}$"#, options: .regularExpression) != nil {
                out.append(NSAttributedString(string: String(repeating: "─", count: 22),
                    attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.white.withAlphaComponent(0.2), .paragraphStyle: para]))
                if i < lines.count - 1 { out.append(NSAttributedString(string: "\n", attributes: [.font: base, .paragraphStyle: para])) }
                continue
            }
            if let r = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                line.removeSubrange(r); lineFont = .systemFont(ofSize: 15, weight: .bold)
            } else if let r = line.range(of: #"^(\s*)[-*]\s+"#, options: .regularExpression) {
                let indent = String(line[r].prefix { $0 == " " })
                out.append(NSAttributedString(string: indent + "▪︎ ", attributes: [.font: base, .foregroundColor: claudeOrange, .paragraphStyle: para]))
                line.removeSubrange(r)
            }
            let parsed = (try? AttributedString(markdown: line, options:
                .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(line)
            for run in parsed.runs {
                let s = String(parsed[run.range].characters)
                var font = lineFont
                var color = text
                var attrs: [NSAttributedString.Key: Any] = [:]
                if let intent = run.inlinePresentationIntent {
                    if intent.contains(.code) {
                        font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
                        color = claudeOrange.blended(withFraction: 0.35, of: .white)!
                        attrs[.backgroundColor] = NSColor.white.withAlphaComponent(0.08)
                    } else {
                        var traits: NSFontDescriptor.SymbolicTraits = []
                        if intent.contains(.stronglyEmphasized) { traits.insert(.bold); color = .white }
                        if intent.contains(.emphasized) { traits.insert(.italic) }
                        if !traits.isEmpty {
                            font = NSFont(descriptor: lineFont.fontDescriptor.withSymbolicTraits(traits), size: lineFont.pointSize) ?? lineFont
                        }
                    }
                }
                attrs[.font] = font; attrs[.foregroundColor] = color; attrs[.paragraphStyle] = para
                out.append(NSAttributedString(string: s, attributes: attrs))
            }
            if i < lines.count - 1 {
                out.append(NSAttributedString(string: "\n", attributes: [.font: base, .paragraphStyle: para]))
            }
        }
        return out
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

// MARK: - History window

final class HistoryWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let window: NSWindow
    let table = NSTableView()
    let search = NSSearchField()
    let detail = NSTextView()
    var rows: [HistoryEntry] = []
    let store: HistoryStore

    init(store: HistoryStore) {
        self.store = store
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 540),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "ClaudeSniper History"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 380)
        let content = NSView()
        window.contentView = content

        search.placeholderString = "Search captures and answers"
        search.delegate = self
        let col = NSTableColumn(identifier: .init("entry"))
        col.width = 310
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 44
        table.dataSource = self
        table.delegate = self
        let tScroll = NSScrollView()
        tScroll.documentView = table
        tScroll.hasVerticalScroller = true
        tScroll.borderType = .bezelBorder

        detail.isEditable = false
        detail.textContainerInset = NSSize(width: 12, height: 12)
        detail.isVerticallyResizable = true
        detail.autoresizingMask = [.width]
        detail.textContainer?.widthTracksTextView = true
        let dScroll = NSScrollView()
        dScroll.documentView = detail
        dScroll.hasVerticalScroller = true
        dScroll.borderType = .bezelBorder

        let copy = NSButton(title: "Copy answer", target: self, action: #selector(copyAnswer))
        let md = NSButton(title: "Export chat as Markdown…", target: self, action: #selector(exportMD))
        let notes = NSButton(title: "Export chat to Notes", target: self, action: #selector(exportToNotes))
        let clear = NSButton(title: "Clear history…", target: self, action: #selector(clearAll))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [copy, md, notes, spacer, clear])
        buttons.orientation = .horizontal

        for v in [search, tScroll, dScroll, buttons] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            search.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            search.widthAnchor.constraint(equalToConstant: 310),
            tScroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            tScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            tScroll.widthAnchor.constraint(equalToConstant: 310),
            tScroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10),
            dScroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            dScroll.leadingAnchor.constraint(equalTo: tScroll.trailingAnchor, constant: 10),
            dScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            dScroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
    }

    func show() {
        reload()
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    func reload() {
        let q = search.stringValue.lowercased()
        rows = store.entries.reversed().filter {
            q.isEmpty || $0.capture.lowercased().contains(q) || $0.answer.lowercased().contains(q)
                || ($0.followUp?.lowercased().contains(q) ?? false)
        }
        table.reloadData()
        if rows.isEmpty {
            detail.string = store.entries.isEmpty ? "No answers yet. Capture something with TextSniper." : "No matches."
        } else {
            table.selectRowIndexes([0], byExtendingSelection: false)
            tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
        }
    }

    func controlTextDidChange(_ obj: Notification) { reload() }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let e = rows[row]
        let id = NSUserInterfaceItemIdentifier("cell")
        let tf = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField) ?? {
            let t = NSTextField(labelWithString: "")
            t.identifier = id
            t.maximumNumberOfLines = 2
            return t
        }()
        let df = DateFormatter(); df.dateStyle = .short; df.timeStyle = .short
        var title = (e.followUp.map { "↳ " + $0 } ?? e.capture).replacingOccurrences(of: "\n", with: " ")
        if title.count > 48 { title = String(title.prefix(47)) + "…" }
        let s = NSMutableAttributedString(string: title + "\n", attributes: [.font: NSFont.systemFont(ofSize: 12.5)])
        s.append(NSAttributedString(string: "\(df.string(from: e.date)) · \(e.mode)",
                                    attributes: [.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: NSColor.secondaryLabelColor]))
        tf.attributedStringValue = s
        return tf
    }

    var selected: HistoryEntry? {
        let r = table.selectedRow
        return r >= 0 && r < rows.count ? rows[r] : nil
    }

    func tableViewSelectionDidChange(_ n: Notification) {
        guard let e = selected else { return }
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: "\(df.string(from: e.date)) · \(e.mode) · \(e.model)\n\n",
                                    attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        s.append(NSAttributedString(string: (e.followUp.map { "↳ " + $0 } ?? e.capture) + "\n\n",
                                    attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: NSColor.secondaryLabelColor]))
        s.append(inlineMarkdown(e.answer, size: 13.5, color: .labelColor))
        detail.textStorage?.setAttributedString(s)
    }

    @objc func copyAnswer() {
        guard let e = selected else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(e.answer, forType: .string)
        appDelegate?.lastChange = NSPasteboard.general.changeCount
    }
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
