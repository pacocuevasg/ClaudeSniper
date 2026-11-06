// ClaudeSniper — companion de TextSniper.
// Icono pixel-art en la barra de menú con toggle on/off. Cuando está activo y usas ⌘⇧2
// en TextSniper, manda lo capturado a Claude (vía Claude Code, usando tu plan) y muestra
// la respuesta en un pop-up. Las capturas se agrupan en un chat que expira tras 15 min
// sin uso; desde el menú o el pop-up puedes empezar un chat nuevo o cambiar a otro.

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
    Opt(id: "haiku", label: "Haiku", detail: "el más rápido"),
    Opt(id: "sonnet", label: "Sonnet", detail: "equilibrado"),
    Opt(id: "opus", label: "Opus", detail: "muy capaz"),
    Opt(id: "fable", label: "Fable", detail: "el más capaz"),
]
let efforts = [
    Opt(id: "low", label: "Bajo", detail: ""),
    Opt(id: "medium", label: "Medio", detail: ""),
    Opt(id: "high", label: "Alto", detail: ""),
    Opt(id: "xhigh", label: "Muy alto", detail: ""),
    Opt(id: "max", label: "Máx", detail: ""),
]
func label(_ opts: [Opt], _ id: String) -> String { opts.first { $0.id == id }?.label ?? id }

/// Modos de acción rápida. En el pop-up se cambian con los botones o las teclas 1–6.
struct Mode { let id: String; let label: String; let symbol: String; let instruction: String }
let modes = [
    Mode(id: "auto", label: "Auto", symbol: "sparkles",
         instruction: "Interpreta la captura y da la respuesta más útil según las reglas generales."),
    Mode(id: "explain", label: "Explicar", symbol: "lightbulb",
         instruction: "Explica con claridad qué significa, como a un estudiante, con un ejemplo sencillo."),
    Mode(id: "translate", label: "Traducir", symbol: "character.bubble",
         instruction: "Tradúcelo: si está en español, al inglés; si está en otro idioma, al español. Da primero solo la traducción y después, si hace falta, 1–3 notas breves sobre matices."),
    Mode(id: "summarize", label: "Resumir", symbol: "list.bullet",
         instruction: "Resume lo esencial en 3–5 viñetas cortas."),
    Mode(id: "solve", label: "Resolver", symbol: "function",
         instruction: "Resuélvelo paso a paso, numerando los pasos, y termina con la respuesta final en negrita."),
    Mode(id: "fix", label: "Corregir", symbol: "checkmark.seal",
         instruction: "Corrige ortografía, gramática y estilo sin cambiar el idioma ni el sentido. Devuelve primero el texto corregido completo y después una lista breve de los cambios."),
]
func mode(_ id: String) -> Mode { modes.first { $0.id == id } ?? modes[0] }

let systemPrompt = """
El usuario captura fragmentos de su pantalla con TextSniper (OCR) y te los envía. \
Recibirás ese texto (o una imagen). Interpreta qué es y responde de forma útil y directa:
- Si es una pregunta o ejercicio, respóndela/resuélvelo.
- Si es un término, concepto o definición, explícalo con claridad y un ejemplo breve.
- Si es código o un error, explica qué hace o qué significa y cómo arreglarlo.
- Si está en otro idioma, tradúcelo al español y explica lo importante.
- Si son datos o una tabla, resume lo relevante.
Las capturas de esta conversación suelen estar relacionadas (mismo documento, tema o \
ejercicio): usa el contexto de capturas anteriores cuando ayude. El texto puede tener \
errores de OCR; corrígelos mentalmente. No hagas preguntas de seguimiento: solo da la \
respuesta. Cada mensaje indica un MODO con una instrucción concreta: síguela por encima \
de las reglas generales. Responde en español (salvo lo que pida el modo), conciso (idealmente menos de 200 palabras), con markdown \
ligero (negritas, listas).
"""

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
    // Chispa de Claude (9x9)
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
    // Clawd, la mascota pixel de Claude Code (17 de ancho)
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
    /// Fotogramas para la animación de "pensando": camina y salta.
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

// MARK: - Chats (caché de 15 min)

struct Chat: Codable { var id: String; var title: String; var created: Date; var lastUsed: Date; var count: Int }

final class ChatStore {
    static let ttl: TimeInterval = 15 * 60
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
        return m < 1 ? "ahora" : "hace \(m) min"
    }
}

// MARK: - Claude Code

func findClaude() -> String? {
    let candidates = [home + "/.local/bin/claude", "/opt/homebrew/bin/claude",
                      "/usr/local/bin/claude", home + "/.claude/local/claude"]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

/// Entorno limpio: así el CLI usa tu sesión de Claude Code (tu plan).
func cleanEnv() -> [String: String] {
    [
        "HOME": home,
        "USER": NSUserName(),
        "PATH": "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
        "LANG": "es_ES.UTF-8",
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

// MARK: - Hotkey (⌘⇧2)

weak var appDelegate: AppDelegate?

let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = appDelegate?.tap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    if type == .keyDown {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let f = event.flags
        if code == Int64(kVK_ANSI_2), f.contains(.maskCommand), f.contains(.maskShift),
           !f.contains(.maskControl), !f.contains(.maskAlternate) {
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
        if CommandLine.arguments.contains("--demo-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.statusItem.button?.performClick(nil) }
        }
    }

    /// Vista previa del pop-up sin llamar a Claude: `open ClaudeSniper.app --args --demo`
    func demo() {
        let q = "¿Qué es la fotosíntesis y por qué es importante?"
        lastCapture = Capture(text: q, imagePath: nil, preview: q)
        popup.mode = "explain"
        popup.show(header: header(), preview: q, state: .loading, footer: "Empezando chat nuevo…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            self.popup.show(header: self.header(), preview: q, state: .result("""
            La **fotosíntesis** es el proceso con el que plantas, algas y algunas bacterias convierten luz solar en energía química.

            - **Entrada:** luz + agua (`H₂O`) + dióxido de carbono (`CO₂`)
            - **Salida:** glucosa (alimento) + oxígeno (`O₂`)

            Es importante porque produce *casi todo el oxígeno* que respiramos y es la base de las cadenas alimenticias.
            """), footer: "Chat · 3 capturas · expira en 15 min")
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
        statusItem.button?.toolTip = enabled ? "ClaudeSniper: activado" : "ClaudeSniper: desactivado"
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshAuth()
        menu.removeAllItems()
        menu.addItem(viewItem(headerView()))
        menu.addItem(.separator())
        menu.addItem(viewItem(segmentView(title: "MODELO", opts: models, selected: model, action: #selector(modelChanged(_:)))))
        menu.addItem(viewItem(segmentView(title: "ESFUERZO", opts: efforts, selected: effort, action: #selector(effortChanged(_:)))))
        menu.addItem(viewItem(modeView()))
        menu.addItem(.separator())

        // Chat
        menu.addItem(viewItem(sectionLabel("CHAT")))
        if let c = store.active {
            menu.addItem(info("bubble.left.and.bubble.right.fill", claudeOrange,
                              "“\(c.title)”", "\(c.count) captura\(c.count == 1 ? "" : "s") · expira en \(ChatStore.minutesLeft(c)) min"))
        } else {
            menu.addItem(info("bubble.left.and.bubble.right", .secondaryLabelColor,
                              "Sin chat activo", "La próxima captura empieza uno nuevo"))
        }
        let newItem = item("Nuevo chat", "square.and.pencil", #selector(newChat), key: "n")
        newItem.isEnabled = store.active != nil
        menu.addItem(newItem)
        let switchItem = item("Cambiar de chat", "arrow.left.arrow.right", nil)
        let sub = NSMenu()
        for c in store.recent {
            let it = NSMenuItem(title: "", action: #selector(switchChat(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = c.id
            it.state = c.id == store.activeID ? .on : .off
            it.attributedTitle = twoLine(c.title, "\(c.count) captura\(c.count == 1 ? "" : "s") · \(ChatStore.ago(c.lastUsed)) · expira en \(ChatStore.minutesLeft(c)) min")
            sub.addItem(it)
        }
        if sub.items.isEmpty {
            let it = NSMenuItem(title: "No hay chats recientes (duran 15 min)", action: nil, keyEquivalent: "")
            it.isEnabled = false
            sub.addItem(it)
        }
        switchItem.submenu = sub
        menu.addItem(switchItem)
        menu.addItem(.separator())

        // Estado
        if findClaude() == nil {
            menu.addItem(status(false, "Claude Code no está instalado", action: nil))
        } else if loggedIn == true {
            menu.addItem(status(true, "Conectado a tu plan de Claude" + (account.isEmpty ? "" : " · \(account)"), action: nil))
        } else {
            menu.addItem(status(false, loggedIn == nil ? "Comprobando conexión…" : "Iniciar sesión en Claude…", action: #selector(login)))
        }
        if CGPreflightListenEventAccess() {
            menu.addItem(status(true, "Atajo ⌘⇧2 detectado", action: nil))
        } else {
            menu.addItem(status(false, "Dar permiso de teclado (⌘⇧2)…", action: #selector(askKeyboardPermission)))
        }
        menu.addItem(.separator())
        menu.addItem(item("Interpretar portapapeles ahora", "wand.and.stars", #selector(testNow)))
        let li = item("Abrir al iniciar sesión", "power", #selector(toggleLoginItem))
        li.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(li)
        menu.addItem(.separator())
        menu.addItem(item("Salir de ClaudeSniper", "xmark.circle", #selector(NSApp.terminate(_:)), key: "q"))
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
        let sub = NSTextField(labelWithString: enabled ? "Activo · usa ⌘⇧2 en TextSniper" : "Desactivado")
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
        for (i, m) in modes.enumerated() { seg.setToolTip("\(m.label) — tecla \(i + 1) en el pop-up", forSegment: i) }
        v.addSubview(l); v.addSubview(seg)
        return v
    }

    func setModeTitle() {
        let s = NSMutableAttributedString(string: "MODO POR DEFECTO  ", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor])
        s.append(NSAttributedString(string: mode(defaultMode).label, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: claudeOrange]))
        modeTitle?.attributedStringValue = s
    }

    @objc func modeChanged(_ s: NSSegmentedControl) {
        defaults.set(modes[s.selectedSegment].id, forKey: "mode")
        setModeTitle()
    }

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
        echo "Inicia sesión con tu cuenta de Claude (tu plan Pro/Max)…"
        "\(claude)" auth login
        echo; echo "Listo. Ya puedes cerrar esta ventana."
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
        armedUntil = Date().addingTimeInterval(30)  // tiempo para seleccionar el área
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
            return "Chat · \(c.count) captura\(c.count == 1 ? "" : "s") · expira en \(ChatStore.minutesLeft(c)) min"
        }
        return "Chat nuevo · la próxima captura empieza de cero"
    }

    func handleClipboard() {
        let pb = NSPasteboard.general
        if let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lastCapture = Capture(text: s, imagePath: nil, preview: s)
        } else if let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            let path = workDir + "/captura-\(Int(Date().timeIntervalSince1970)).png"
            try? png.write(to: URL(fileURLWithPath: path))
            lastCapture = Capture(text: nil, imagePath: path, preview: "🖼  Imagen capturada")
        } else {
            popup.show(header: header(), preview: "", state: .error("El portapapeles está vacío."), footer: chatFooter())
            return
        }
        run(lastCapture!, modeID: defaultMode, again: false)
    }

    /// Envía la captura con un modo. `again` = la misma captura repetida desde el pop-up.
    func run(_ c: Capture, modeID: String, again: Bool) {
        let m = mode(modeID)
        let head = again ? "Misma captura de antes, ahora en otro modo." : "Nueva captura."
        let body: String
        if let t = c.text {
            body = "\(head)\nMODO: \(m.label) — \(m.instruction)\n\nCaptura:\n\n\(t)"
        } else {
            body = "\(head) Es una imagen: léela en \(c.imagePath!) con la herramienta Read.\nMODO: \(m.label) — \(m.instruction)"
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
            popup.show(header: header(), preview: preview, state: .error("No encontré Claude Code. Instálalo con:\ncurl -fsSL https://claude.ai/install.sh | bash"), footer: "")
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
                   footer: existing.map { "Chat · \($0.count) captura\($0.count == 1 ? "" : "s") · continúa" } ?? "Empezando chat nuevo…")

        var args = ["-p", "--model", model, "--effort", effort, "--output-format", "text",
                    "--system-prompt", systemPrompt]
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
                    // Si el usuario cambió/reinició el chat mientras esperaba, no lo pisamos.
                    self.store.record(id: sessionID, title: String(title.prefix(60)),
                                      makeActive: self.store.activeID == activeAtStart)
                    self.popup.show(header: hdr, preview: preview, state: .result(text), footer: self.chatFooter())
                } else if existing != nil && text.localizedCaseInsensitiveContains("no conversation found") {
                    self.store.newChat()
                    self.ask(prompt: prompt, image: image, preview: preview)  // reintenta en chat nuevo
                } else if text.contains("authenticate") || text.contains("/login") || text.contains("401") {
                    self.loggedIn = false
                    self.popup.show(header: hdr, preview: preview, state: .error("No has iniciado sesión en Claude Code.\nAbre el menú de la barra superior → “Iniciar sesión en Claude…”."), footer: "")
                } else {
                    self.popup.show(header: hdr, preview: preview, state: .error(text.isEmpty ? "Error desconocido (código \(r.status))." : text), footer: self.chatFooter())
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
    let hintLabel = NSTextField(labelWithString: "1–6 cambiar modo · esc cerrar")
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

        copyBtn = iconButton("doc.on.doc", "Copiar respuesta", #selector(copyResult))
        newBtn = iconButton("square.and.pencil", "Nuevo chat", #selector(newChat))
        let closeBtn = iconButton("xmark", "Cerrar (esc)", #selector(close))

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
            b.toolTip = "\(m.label) (tecla \(i + 1)): repite esta captura en este modo"
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
            copyBtn.isHidden = true
            resultText = ""
            startAnimating()
        case .result(let t):
            stopAnimating()
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
        textView.textStorage?.setAttributedString(NSAttributedString(string: "Pensando" + String(repeating: ".", count: dots),
            attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: claudeOrange]))
    }
    func stopAnimating() {
        animTimer?.invalidate(); animTimer = nil
        clawdView.image = idleImage
    }

    func positionNearMouse(height: CGFloat) {
        if isDemo, let vf = NSScreen.main?.visibleFrame {   // demo: centrado, para capturas
            panel.setFrame(NSRect(x: vf.midX - width / 2, y: vf.midY - height / 2, width: width, height: height), display: true)
            showBackdrop(around: panel.frame)
            return
        }
        let m = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main!
        let vf = screen.visibleFrame
        var x = m.x + 18, y = m.y - height - 18
        x = min(max(x, vf.minX + 8), vf.maxX - width - 8)
        if y < vf.minY + 8 { y = min(m.y + 18, vf.maxY - height - 8) }
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    var backdrop: NSWindow?
    /// Fondo degradado detrás del pop-up en modo demo (para que el desenfoque se vea en capturas).
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

    @objc func close() {
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; panel.animator().alphaValue = 0 },
                                             completionHandler: { self.panel.orderOut(nil); self.panel.alphaValue = 1 })
    }

    @objc func copyResult() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resultText, forType: .string)
        appDelegate?.lastChange = NSPasteboard.general.changeCount  // no lo trates como captura
        flash(copyBtn, "checkmark")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.copyBtn.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil) }
    }

    @objc func newChat() {
        appDelegate?.store.newChat()
        footerLabel.stringValue = "✓ Chat nuevo · la próxima captura empieza de cero"
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
