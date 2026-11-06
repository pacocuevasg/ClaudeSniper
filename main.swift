// ClaudeSniper — a companion for TextSniper.
// Pixel-art menu bar icon with an on/off toggle. When it's on and you press ⌘⇧2 in
// TextSniper, it sends the capture to Claude (through Claude Code, using your plan) and
// shows the answer in a pop-up. Captures are grouped into a chat that expires after a
// while without use (15 min by default, see Settings); you can start a new chat or switch.

import Cocoa
import ServiceManagement
import Carbon.HIToolbox

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

/// Quick action modes. In the pop-up, switch with the buttons or keys 1–6.
struct Mode { let id: String; let label: String; let symbol: String; let instruction: String }
let modes = [
    Mode(id: "auto", label: "Auto", symbol: "sparkles",
         instruction: "Interpret the capture and give the most useful answer, following the general rules."),
    Mode(id: "explain", label: "Explain", symbol: "lightbulb",
         instruction: "Explain clearly what it means, as if to a student, with a simple example."),
    Mode(id: "translate", label: "Translate", symbol: "character.bubble",
         instruction: "Translate it into the answer language; if it is already in that language, translate it into English (or into Spanish if the answer language is English). Give only the translation first, then, if useful, 1–3 short notes on nuances."),
    Mode(id: "summarize", label: "Summarize", symbol: "list.bullet",
         instruction: "Summarize the essentials in 3–5 short bullet points."),
    Mode(id: "solve", label: "Solve", symbol: "function",
         instruction: "Solve it step by step, numbering the steps, and end with the final answer in bold."),
    Mode(id: "fix", label: "Fix", symbol: "checkmark.seal",
         instruction: "Fix spelling, grammar and style without changing the language or the meaning. Return the full corrected text first, then a short list of the changes."),
]
func mode(_ id: String) -> Mode { modes.first { $0.id == id } ?? modes[0] }

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
    var running: Process?
    var requestID = 0
    let store = ChatStore()
    lazy var popup = PopupController()
    var loggedIn: Bool?
    var account = ""
    let menuWidth: CGFloat = 300

    var enabled: Bool {
        get { defaults.bool(forKey: "enabled") }
        set { defaults.set(newValue, forKey: "enabled"); updateIcon(); newValue ? startMonitoring() : stopMonitoring() }
    }
    var model: String { defaults.string(forKey: "model") ?? "haiku" }
    var effort: String { defaults.string(forKey: "effort") ?? "low" }
    var defaultMode: String { defaults.string(forKey: "mode") ?? "auto" }
    var answerLanguage: String { defaults.string(forKey: "answerLanguage") ?? "system" }

    struct Capture { let text: String?; let imagePath: String?; let preview: String }
    var lastCapture: Capture?

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
        if CommandLine.arguments.contains("--demo") { demo() }
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

    func updateIcon() {
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
        menu.addItem(.separator())

        // Status
        if findClaude() == nil {
            menu.addItem(status(false, "Claude Code is not installed", action: nil))
        } else if loggedIn == true {
            menu.addItem(status(true, "Connected to your Claude plan" + (account.isEmpty ? "" : " · \(account)"), action: nil))
        } else {
            menu.addItem(status(false, loggedIn == nil ? "Checking connection…" : "Sign in to Claude…", action: #selector(login)))
        }
        if CGPreflightListenEventAccess() {
            menu.addItem(status(true, "\(hotkeyLabel) shortcut detected", action: nil))
        } else {
            menu.addItem(status(false, "Allow keyboard access (\(hotkeyLabel))…", action: #selector(askKeyboardPermission)))
        }
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
        let seg = NSSegmentedControl(images: modes.map { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: $0.label)! },
                                     trackingMode: .selectOne, target: self, action: #selector(modeChanged(_:)))
        seg.segmentDistribution = .fillEqually
        seg.selectedSegment = modes.firstIndex { $0.id == defaultMode } ?? 0
        seg.frame = NSRect(x: 12, y: 6, width: menuWidth - 24, height: 24)
        if #available(macOS 14.0, *) { seg.selectedSegmentBezelColor = claudeOrange }
        for (i, m) in modes.enumerated() { seg.setToolTip("\(m.label) — key \(i + 1) in the pop-up", forSegment: i) }
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
        defaults.set(modes[s.selectedSegment].id, forKey: "mode")
        setModeTitle()
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
        if !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }
        installTap()
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
        if Date() < armedUntil {
            armedUntil = .distantPast
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.handleClipboard() }
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
        run(lastCapture!, modeID: defaultMode, again: false)
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

    func header() -> String { "\(label(models, model)) · \(label(efforts, effort).lowercased())" }

    func ask(prompt: String, image: Bool, preview: String) {
        guard let claude = findClaude() else {
            popup.show(header: header(), preview: preview, state: .error("Claude Code wasn't found. Install it with:\ncurl -fsSL https://claude.ai/install.sh | bash"), footer: "")
            return
        }
        running?.terminate()
        requestID += 1
        let myID = requestID
        let hdr = header()

        let existing = store.active
        let sessionID = existing?.id ?? UUID().uuidString.lowercased()
        let activeAtStart = store.activeID
        let title = preview.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)

        popup.show(header: hdr, preview: preview, state: .loading,
                   footer: existing.map { "Chat · \($0.count) capture\($0.count == 1 ? "" : "s") · continuing" } ?? "Starting a new chat…")

        var args = ["-p", "--model", model, "--effort", effort, "--output-format", "text",
                    "--system-prompt", systemPrompt(language: answerLanguageName(answerLanguage), length: Settings.answerLength)]
        args += existing == nil ? ["--session-id", sessionID] : ["--resume", sessionID]
        args += image ? ["--tools", "Read", "--allowedTools", "Read", "--add-dir", workDir] : ["--tools", ""]

        DispatchQueue.global(qos: .userInitiated).async {
            let r = runSync(claude, args, stdin: prompt, timeout: 300) { p in
                DispatchQueue.main.async { self.running = p }
            }
            DispatchQueue.main.async {
                guard myID == self.requestID else { return }
                self.running = nil
                let text = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
                if r.status == 0 && !text.isEmpty {
                    // If the user switched or reset the chat while waiting, don't override that.
                    self.store.record(id: sessionID, title: String(title.prefix(60)),
                                      makeActive: self.store.activeID == activeAtStart)
                    self.popup.show(header: hdr, preview: preview, state: .result(text), footer: self.chatFooter())
                    if Settings.autoCopy {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        self.lastChange = NSPasteboard.general.changeCount  // don't treat this as a capture
                    }
                    if Settings.sound { NSSound(named: "Pop")?.play() }
                } else if existing != nil && text.localizedCaseInsensitiveContains("no conversation found") {
                    self.store.newChat()
                    self.ask(prompt: prompt, image: image, preview: preview)  // retry in a new chat
                } else if text.contains("authenticate") || text.contains("/login") || text.contains("401") {
                    self.loggedIn = false
                    self.popup.show(header: hdr, preview: preview, state: .error("You're not signed in to Claude Code.\nOpen the menu bar menu → “Sign in to Claude…”."), footer: "")
                } else {
                    self.popup.show(header: hdr, preview: preview, state: .error(text.isEmpty ? "Unknown error (code \(r.status))." : text), footer: self.chatFooter())
                }
            }
        }
    }
}

// MARK: - Popup

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class PopupController: NSObject {
    enum State { case loading, result(String), error(String) }

    let width: CGFloat = 530
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
    let hintLabel = NSTextField(labelWithString: "1–6 switch mode · esc close")
    var copyBtn: NSButton!
    var newBtn: NSButton!
    let frames = Pixel.clawdFrames(px: 2)
    let idleImage = Pixel.clawd(px: 2)
    var frameIdx = 0
    var animTimer: Timer?
    var dots = 0
    var resultText = ""
    var keyMonitor: Any?
    let modeBar = NSStackView()
    var modeButtons: [NSButton] = []
    var mode = "auto" { didSet { refreshModeBar() } }

    override init() {
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 530, height: 220),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        super.init()
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

        copyBtn = iconButton("doc.on.doc", "Copy answer", #selector(copyResult))
        newBtn = iconButton("square.and.pencil", "New chat", #selector(newChat))
        let closeBtn = iconButton("xmark", "Close (esc)", #selector(close))

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

        let divider = NSBox(); divider.boxType = .separator

        modeBar.orientation = .horizontal
        modeBar.spacing = 4
        modeBar.alignment = .centerY
        for (i, m) in modes.enumerated() {
            let b = NSButton(title: m.label, image: NSImage(systemSymbolName: m.symbol, accessibilityDescription: m.label)!,
                             target: self, action: #selector(modeClicked(_:)))
            b.tag = i
            b.isBordered = false
            b.imagePosition = .imageLeading
            b.imageHugsTitle = true
            b.font = .systemFont(ofSize: 11, weight: .medium)
            b.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
            b.wantsLayer = true
            b.layer?.cornerRadius = 11
            b.toolTip = "\(m.label) (key \(i + 1)): re-run this capture in this mode"
            b.translatesAutoresizingMaskIntoConstraints = false
            b.heightAnchor.constraint(equalToConstant: 22).isActive = true
            b.widthAnchor.constraint(equalToConstant: b.intrinsicContentSize.width + 12).isActive = true
            modeButtons.append(b)
            modeBar.addArrangedSubview(b)
        }
        refreshModeBar()

        let all: [NSView] = [border, clawdView, titleLabel, chip, copyBtn, newBtn, closeBtn,
                             quoteBox, modeBar, scroll, divider, footerLabel, hintLabel]
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

            closeBtn.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -12),
            closeBtn.centerYAnchor.constraint(equalTo: clawdView.centerYAnchor),
            newBtn.trailingAnchor.constraint(equalTo: closeBtn.leadingAnchor, constant: -2),
            newBtn.centerYAnchor.constraint(equalTo: clawdView.centerYAnchor),
            copyBtn.trailingAnchor.constraint(equalTo: newBtn.leadingAnchor, constant: -2),
            copyBtn.centerYAnchor.constraint(equalTo: clawdView.centerYAnchor),

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
        ])

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.panel.isKeyWindow else { return e }
            if e.keyCode == UInt16(kVK_Escape) { self.close(); return nil }
            if e.modifierFlags.intersection([.command, .control, .option]).isEmpty,
               let ch = e.charactersIgnoringModifiers, let n = Int(ch), (1...modes.count).contains(n) {
                appDelegate?.rerun(modeID: modes[n - 1].id); return nil
            }
            return e
        }
    }

    func refreshModeBar() {
        for (i, b) in modeButtons.enumerated() {
            let on = modes[i].id == mode
            b.layer?.backgroundColor = (on ? claudeOrange.withAlphaComponent(0.25) : NSColor.white.withAlphaComponent(0.06)).cgColor
            b.layer?.borderWidth = on ? 1 : 0
            b.layer?.borderColor = claudeOrange.withAlphaComponent(0.6).cgColor
            b.contentTintColor = on ? claudeOrange : NSColor.white.withAlphaComponent(0.7)
            b.attributedTitle = NSAttributedString(string: " " + modes[i].label, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: on ? .semibold : .medium),
                .foregroundColor: on ? claudeOrange : NSColor.white.withAlphaComponent(0.7)])
        }
    }

    @objc func modeClicked(_ b: NSButton) { appDelegate?.rerun(modeID: modes[b.tag].id) }

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

    func show(header: String, preview: String, state: State, footer: String) {
        chip.stringValue = "  \(header)  "
        let pv = preview.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        quoteLabel.stringValue = pv.isEmpty ? "—" : pv
        footerLabel.stringValue = footer
        newBtn.contentTintColor = NSColor.white.withAlphaComponent(0.6)

        switch state {
        case .loading:
            closeWork?.cancel()
            copyBtn.isHidden = true
            resultText = ""
            startAnimating()
        case .result(let t):
            stopAnimating()
            scheduleAutoClose(isDemo ? 0 : Settings.autoClose)
            copyBtn.isHidden = false
            resultText = t
            textView.textStorage?.setAttributedString(renderMarkdown(t))
        case .error(let t):
            stopAnimating()
            copyBtn.isHidden = true
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

        if !panel.isVisible || isDemo {
            positionNearMouse(height: height)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1 }
        } else {
            var f = panel.frame
            f.origin.y += f.height - height
            f.size.height = height
            panel.setFrame(f, display: true, animate: true)
            panel.orderFrontRegardless()
        }
        panel.makeKey()
        scroll.contentView.scroll(to: .zero)
    }

    func startAnimating() {
        animTimer?.invalidate()
        frameIdx = 0; dots = 0
        animTimer = Timer.scheduledTimer(withTimeInterval: 0.16, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.frameIdx = (self.frameIdx + 1) % self.frames.count
            self.clawdView.image = self.frames[self.frameIdx]
            if self.frameIdx % 2 == 0 { self.dots = (self.dots + 1) % 4; self.setThinking() }
        }
        setThinking()
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

    /// Closes the pop-up after `seconds`, but waits while the mouse is over it.
    func scheduleAutoClose(_ seconds: Int) {
        closeWork?.cancel()
        guard seconds > 0 else { return }
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.panel.isVisible else { return }
            if NSMouseInRect(NSEvent.mouseLocation, self.panel.frame, false) { self.scheduleAutoClose(3) } else { self.close() }
        }
        closeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds), execute: w)
    }

    @objc func close() {
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

    @objc func newChat() {
        appDelegate?.store.newChat()
        footerLabel.stringValue = "✓ New chat · your next capture starts fresh"
        newBtn.contentTintColor = claudeOrange
    }

    func flash(_ b: NSButton, _ symbol: String) {
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    func renderMarkdown(_ md: String) -> NSAttributedString {
        let base = NSFont.systemFont(ofSize: 14)
        let text = NSColor.white.withAlphaComponent(0.92)
        let para = NSMutableParagraphStyle(); para.paragraphSpacing = 5; para.lineSpacing = 2.5
        let out = NSMutableAttributedString()
        let lines = md.components(separatedBy: "\n")
        for (i, rawLine) in lines.enumerated() {
            var line = rawLine
            var lineFont = base
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

// MARK: - main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
