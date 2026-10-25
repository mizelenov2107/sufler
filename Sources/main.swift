import AppKit
import SwiftUI
import Carbon.HIToolbox

// MARK: - глобальные клавиши

/// Carbon-хоткеи работают без разрешения на управление компьютером,
/// поэтому суфлёр слушает клавиши, не забирая фокус у презентации.
final class Klavishi {
    static let shared = Klavishi()
    private var dejstviya: [UInt32: () -> Void] = [:]
    private var ssylki: [EventHotKeyRef?] = []
    private var sled: UInt32 = 1
    private var postavlen = false

    func dobavit(_ kod: Int, shift: Bool = false, _ f: @escaping () -> Void) {
        postavitObrabotchik()
        let id = sled; sled += 1
        dejstviya[id] = f
        var ref: EventHotKeyRef?
        let hkid = EventHotKeyID(signature: OSType(0x53554652), id: id)
        let mods = UInt32(optionKey) | (shift ? UInt32(shiftKey) : 0)
        RegisterEventHotKey(UInt32(kod), mods, hkid,
                            GetApplicationEventTarget(), 0, &ref)
        ssylki.append(ref)
    }

    fileprivate func vypolnit(_ id: UInt32) { dejstviya[id]?() }

    private func postavitObrabotchik() {
        guard !postavlen else { return }
        postavlen = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hkid = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkid)
            let nomer = hkid.id
            DispatchQueue.main.async { Klavishi.shared.vypolnit(nomer) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

// MARK: - приложение

@MainActor
final class Delegat: NSObject, NSApplicationDelegate, NSWindowDelegate {

    private let model = Model()
    private var matcher = Matcher(skript: Skript())
    private let sluh = Sluh()
    private var panel: Panel!
    private var fajl: URL?
    private var poslednyayaRech = Date.distantPast
    private var chasovoj: Timer?
    private var znachok: NSStatusItem?
    private var oknoVybora: NSWindow?
    private var nachalo: Date?          // когда занятие пошло
    private var pauzaOt: Date?
    private var pauzaVsego: TimeInterval = 0

    private let poUmolchaniyu = Poisk.vault

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        sobratOkno()
        sobratZnachok()
        if CommandLine.arguments.count > 1 {
            otkryt(URL(fileURLWithPath: CommandLine.arguments[1]))
        } else {
            pokazatVybor()
        }
        postavitKlavishi()

        sluh.novyeSlova = { [weak self] slova in self?.prishli(slova) }
        sluh.sostoyanie = { [weak self] t in self?.model.status = t }
        sluh.uslyshal = { [weak self] t in
            self?.model.slyshu = String(t.suffix(90))
        }
        model.perejtiNaToken = { [weak self] i in
            self?.matcher.postavit(naToken: i); self?.obnovit()
        }
        model.perejtiNaBlok = { [weak self] b in
            self?.matcher.postavit(na: b); self?.obnovit()
        }
        model.zakryt = { [weak self] in self?.vyjti() }
        model.spryatat = { [weak self] in self?.spryatat() }
        sluh.sprosit { [weak self] mozhno in
            guard let self else { return }
            if mozhno {
                if self.nachalo == nil { self.nachalo = Date() }
                self.puskat()
            } else {
                self.model.status = "нет микрофона, ручной режим"
            }
        }

        chasovoj = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in self.proverit() }
        }
    }

    // MARK: файл

    /// Список уроков при запуске: приложение открывается и спрашивает, что ведём.
    private func pokazatVybor() {
        if let o = oknoVybora {
            o.contentView = NSHostingView(rootView: vidVybora())
            pokazat(o)
            return
        }
        let o = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 520),
                         styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        o.title = "Суфлёр"
        o.titlebarAppearsTransparent = true
        o.isReleasedWhenClosed = false
        o.center()
        o.setFrameAutosaveName("sufler-vybor")
        o.contentView = NSHostingView(rootView: vidVybora())
        o.delegate = self
        oknoVybora = o
        pokazat(o)
    }

    private func vidVybora() -> VidVybora {
        VidVybora(uroki: Poisk.najti(),
                  vybran: { [weak self] u in self?.vybrali(u) },
                  drugojFajl: { [weak self] in
                      guard let self else { return }
                      if let u = self.sprosit() { self.vybrali(u) }
                  },
                  obnovit: { [weak self] in self?.pokazatVybor() },
                  vstavka: { [weak self] in self?.pokazatVstavku() })
    }

    // MARK: вставленный текст

    /// Вставку суфлёр кладёт файлом рядом со своими настройками: так работают
    /// и перечитывание по ⌥R, и возврат к тому же тексту на следующем запуске.
    private var fajlVstavki: URL {
        let papka = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Суфлёр", isDirectory: true)
        try? FileManager.default.createDirectory(at: papka, withIntermediateDirectories: true)
        return papka.appendingPathComponent("Вставка.md")
    }

    private func pokazatVstavku() {
        if oknoVybora == nil { pokazatVybor() }
        guard let o = oknoVybora else { return }
        let bylo = (try? String(contentsOf: fajlVstavki, encoding: .utf8)) ?? ""
        let vid = VidVstavki(tekst: bylo,
                             vesti: { [weak self] t in self?.vestiVstavku(t) },
                             nazad: { [weak self] in self?.pokazatVybor() })
        o.contentView = NSHostingView(rootView: vid)
        pokazat(o)
    }

    private func vestiVstavku(_ tekst: String) {
        try? tekst.write(to: fajlVstavki, atomically: true, encoding: .utf8)
        vybrali(fajlVstavki)
    }

    /// Иконка в доке нужна только на время выбора, дальше суфлёр снова живёт в строке меню.
    private func pokazat(_ o: NSWindow) {
        panel.orderOut(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        o.makeKeyAndOrderFront(nil)
    }

    private func vybrali(_ u: URL) {
        oknoVybora?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        otkryt(u)
        panel.orderFrontRegardless()
        snachala()
    }

    /// Закрытый список без выбранного урока означает, что вести нечего.
    func windowWillClose(_ note: Notification) {
        guard (note.object as? NSWindow) === oknoVybora else { return }
        NSApp.setActivationPolicy(.accessory)
        if fajl == nil { vyjti() } else { panel.orderFrontRegardless() }
    }

    private func sprosit() -> URL? {
        let p = NSOpenPanel()
        p.title = "Какой суфлёр открыть"
        p.allowedContentTypes = [.plainText]
        p.allowsOtherFileTypes = true
        p.directoryURL = poUmolchaniyu
        NSApp.activate(ignoringOtherApps: true)
        return p.runModal() == .OK ? p.url : nil
    }

    private func otkryt(_ u: URL?) {
        guard let u, let sk = try? Razbor.razobrat(fajl: u) else {
            model.status = "суфлёр не открылся"; return
        }
        fajl = u
        UserDefaults.standard.set(u.path, forKey: "fajl")
        model.skript = sk
        matcher.zanovo(skript: sk)
        matcher.postavit(na: sk.pervyjRechevojBlok)
        obnovit()
        model.prokrutka += 1
    }

    // MARK: слух

    private func puskat() {
        sluh.puskat()
        model.slushaet = sluh.rabotaet
        model.rezhim = sluh.rabotaet ? sluh.rezhim.rawValue : ""
        model.status = sluh.rabotaet ? "слушаю" : "не запустился"
        poslednyayaRech = Date()
    }

    private func prishli(_ slova: [String]) {
        poslednyayaRech = Date()
        if model.tishina { model.tishina = false; model.status = "слушаю" }
        if matcher.uslyshano(slova) { obnovit() }
    }

    private func proverit() {
        if let start = nachalo, model.slushaet {
            model.proshlo = Date().timeIntervalSince(start) - pauzaVsego
        }
        guard model.slushaet else { return }
        let molchit = Date().timeIntervalSince(poslednyayaRech) > 2.2
        if molchit != model.tishina {
            model.tishina = molchit
            model.status = molchit ? "молчание" : "слушаю"
        }
        model.rezhim = sluh.rezhim.rawValue
    }

    private func obnovit() {
        let m = matcher.mesto
        model.blok = m.blok
        model.slovo = m.tokenVBloke
        model.proshlyj = matcher.proshlyjRechevoj
        model.poteryan = matcher.poteryan
        model.prokrutka += 1
    }

    // MARK: значок в строке меню

    /// Приложение живёт без иконки в доке, поэтому команды собраны в строке меню.
    private func sobratZnachok() {
        let z = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let znak = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Суфлёр") {
            z.button?.image = znak
        } else {
            z.button?.title = "🎙"        // строка меню без символа тоже должна что-то показать
        }
        z.button?.toolTip = "Суфлёр"
        FileHandle.standardError.write(
            "значок в строке меню: \(z.button != nil ? "поставлен" : "не поставлен")\n".data(using: .utf8)!)

        let menyu = NSMenu()
        func punkt(_ imya: String, _ sel: Selector, _ klyuch: String, _ mods: NSEvent.ModifierFlags) {
            let p = NSMenuItem(title: imya, action: sel, keyEquivalent: klyuch)
            p.keyEquivalentModifierMask = mods
            p.target = self
            menyu.addItem(p)
        }
        punkt("Пауза и продолжение", #selector(menyuPauza), " ", [.option])
        punkt("Спрятать панель", #selector(menyuSpryatat), "h", [.option])
        menyu.addItem(.separator())
        punkt("Выбрать урок…", #selector(menyuVybor), "o", [.option])
        punkt("Вставить текст…", #selector(menyuVstavka), "v", [.option])
        punkt("Открыть файл суфлёра…", #selector(menyuOtkryt), "", [])
        punkt("Перечитать файл", #selector(menyuPerechitat), "r", [.option])
        punkt("Время занятия с нуля", #selector(menyuSnachala), "t", [.option])
        menyu.addItem(.separator())
        punkt("Закрыть Суфлёр", #selector(menyuVyjti), "q", [.option])
        z.menu = menyu
        znachok = z
    }

    @objc private func menyuPauza() { pauza() }
    @objc private func menyuSpryatat() { spryatat() }
    @objc private func menyuVybor() { pokazatVybor() }
    @objc private func menyuVstavka() { pokazatVstavku() }
    @objc private func menyuOtkryt() { if let u = sprosit() { vybrali(u) } }
    @objc private func menyuPerechitat() { perechitat() }
    @objc private func menyuSnachala() { snachala() }
    @objc private func menyuVyjti() { vyjti() }

    /// Выход закрывает микрофон, иначе индикатор записи остаётся висеть.
    private func vyjti() {
        sluh.stopnut()
        chasovoj?.invalidate()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ note: Notification) { sluh.stopnut() }

    // MARK: окно

    private func sobratOkno() {
        let ekran = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let shirina: CGFloat = 520
        let ramka = NSRect(x: ekran.maxX - shirina - 24, y: ekran.minY + 24,
                           width: shirina, height: ekran.height - 48)

        panel = Panel(contentRect: ramka,
                      styleMask: [.titled, .fullSizeContentView, .resizable, .nonactivatingPanel],
                      backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        // В демонстрацию экрана панель не попадает. Переменная SUFLER_VIDIM=1 снимает
        // это на время отладки, когда нужно снять с суфлёра скриншот.
        panel.sharingType = ProcessInfo.processInfo.environment["SUFLER_VIDIM"] == "1"
            ? .readOnly : .none
        for k in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(k)?.isHidden = true
        }
        panel.contentView = NSHostingView(rootView: Vid(m: model))
        panel.setFrameAutosaveName("sufler")
        panel.orderFrontRegardless()
    }

    private func postavitKlavishi() {
        let k = Klavishi.shared
        k.dobavit(49)  { [weak self] in self?.pauza() }                                      // ⌥Space
        k.dobavit(124) { [weak self] in self?.matcher.shagFraza(vpered: true); self?.obnovit() }
        k.dobavit(123) { [weak self] in self?.matcher.shagFraza(vpered: false); self?.obnovit() }
        k.dobavit(124, shift: true) { [weak self] in self?.matcher.shagBlok(vpered: true); self?.obnovit() }
        k.dobavit(123, shift: true) { [weak self] in self?.matcher.shagBlok(vpered: false); self?.obnovit() }
        k.dobavit(4)   { [weak self] in self?.spryatat() }                                   // ⌥H
        k.dobavit(15)  { [weak self] in self?.perechitat() }                                 // ⌥R
        k.dobavit(8)   { [weak self] in self?.skvoznoj() }                                   // ⌥C
        k.dobavit(11)  { [weak self] in self?.plotnost() }                                   // ⌥B
        k.dobavit(126) { [weak self] in self?.kegl(+1) }                                     // ⌥↑
        k.dobavit(125) { [weak self] in self?.kegl(-1) }                                     // ⌥↓
        k.dobavit(31)  { [weak self] in self?.pokazatVybor() }                               // ⌥O
        k.dobavit(9)   { [weak self] in self?.pokazatVstavku() }                             // ⌥V
        k.dobavit(17)  { [weak self] in self?.snachala() }                                   // ⌥T
        k.dobavit(12)  { [weak self] in self?.vyjti() }                                      // ⌥Q
    }

    private func pauza() {
        if sluh.rabotaet {
            sluh.stopnut()
            pauzaOt = Date()
            model.slushaet = false; model.tishina = false
            model.status = "пауза"; model.rezhim = ""
        } else {
            if let p = pauzaOt { pauzaVsego += Date().timeIntervalSince(p); pauzaOt = nil }
            if nachalo == nil { nachalo = Date() }
            puskat()
        }
    }

    /// Занятие начинается заново: время с нуля, курсор на первый абзац.
    private func snachala() {
        nachalo = Date(); pauzaVsego = 0; pauzaOt = nil
        model.proshlo = 0
        matcher.postavit(na: model.skript.pervyjRechevojBlok)
        obnovit()
    }

    private func plotnost() {
        let shag: [Double] = [0.72, 0.88, 0.96, 1.0]
        let i = shag.firstIndex(where: { $0 > model.neprozrachnost + 0.001 }) ?? 0
        model.neprozrachnost = shag[i]
    }

    private func spryatat() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }

    private func perechitat() {
        let bylo = model.blok
        otkryt(fajl)
        if bylo < model.skript.bloki.count {
            matcher.postavit(na: bylo); obnovit()
        }
    }

    private func skvoznoj() {
        model.skvoznoj.toggle()
        panel.ignoresMouseEvents = model.skvoznoj
    }

    private func kegl(_ d: CGFloat) {
        model.kegl = min(34, max(14, model.kegl + d))
    }
}

nonisolated(unsafe) var derzhatel: Delegat?

MainActor.assumeIsolated {
    let d = Delegat()
    derzhatel = d
    NSApplication.shared.delegate = d
}
NSApplication.shared.run()
