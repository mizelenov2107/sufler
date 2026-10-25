import AppKit
import SwiftUI
import Speech
import AVFoundation
import ScreenCaptureKit
import Carbon.HIToolbox

// Суфлёр · вопросы. Слушает звук созвона (или микрофон), режет речь на фразы по паузам,
// отправляет фразу в постоянно открытый процесс Claude с материалами доклада
// и показывает короткий ответ в панели, которая не попадает в демонстрацию экрана.


/// Журнал событий: статус, услышанные фразы и ответы — в ~/Library/Logs/sufler-voprosy.log.
func zhurnal(_ t: String) {
    let s = ISO8601DateFormatter().string(from: Date()) + " " + t + "\n"
    let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/sufler-voprosy.log")
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(s.data(using: .utf8)!); try? h.close() }
    else { try? s.data(using: .utf8)!.write(to: url) }
}

// MARK: - состояние

struct Para: Identifiable {
    let id = UUID()
    var vopros: String
    var otvet: String = ""
    var gotov = false
}

@MainActor
final class Sostoyanie: ObservableObject {
    @Published var slyshu = ""
    @Published var istochnik = "созвон"
    @Published var status = "запуск"
    @Published var claude = "Claude запускается"
    @Published var pary: [Para] = []
    @Published var kegl: CGFloat = 22
    @Published var pauza = true
    @Published var vvod = ""
    var otpravit: ((String) -> Void)?
    var pereklyuchitPauzu: (() -> Void)?
}

// MARK: - Claude: один процесс на весь доклад, без перезапуска на каждый вопрос

@MainActor
final class Mozg {
    private var process: Process?
    private var vhod: FileHandle?
    private var hvost = Data()
    private var ochered: [UUID] = []
    var delta: ((UUID, String) -> Void)?
    var gotovo: ((UUID, String) -> Void)?
    var status: ((String) -> Void)?

    func zapustit(materialy: URL, model: String) {
        let p = Process()
        let put = ["\(NSHomeDirectory())/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let put else { status?("claude не найден"); return }
        p.executableURL = URL(fileURLWithPath: put)
        p.arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                       "--include-partial-messages", "--model", model,
                       "--system-prompt-file", materialy.path, "--tools", "", "--strict-mcp-config",
                       "--no-session-persistence", "--setting-sources", ""]
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        p.environment = env
        let vh = Pipe(), vyh = Pipe()
        p.standardInput = vh; p.standardOutput = vyh; p.standardError = FileHandle.nullDevice
        vyh.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            Task { @MainActor in self?.prinyat(d) }
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.status?("Claude остановился, ⌥R — перезапуск") }
        }
        do { try p.run() } catch { status?("Claude не запустился"); return }
        process = p; vhod = vh.fileHandleForWriting
        status?("Claude готов · \(model)")
    }

    func ostanovit() { process?.terminate(); process = nil; vhod = nil; ochered.removeAll() }

    func sprosit(_ id: UUID, _ tekst: String) {
        guard let vhod else { status?("Claude не запущен"); return }
        let msg: [String: Any] = ["type": "user", "message": ["role": "user", "content": "Фраза из созвона: «\(tekst)»"]]
        guard var d = try? JSONSerialization.data(withJSONObject: msg) else { return }
        d.append(0x0A)
        ochered.append(id)
        vhod.write(d)
    }

    private func prinyat(_ d: Data) {
        guard !d.isEmpty else { return }
        hvost.append(d)
        while let i = hvost.firstIndex(of: 0x0A) {
            let stroka = hvost.subdata(in: hvost.startIndex..<i)
            hvost.removeSubrange(hvost.startIndex...i)
            guard let o = try? JSONSerialization.jsonObject(with: stroka) as? [String: Any],
                  let tip = o["type"] as? String, let id = ochered.first else { continue }
            if tip == "stream_event", let ev = o["event"] as? [String: Any],
               ev["type"] as? String == "content_block_delta",
               let dl = ev["delta"] as? [String: Any], let t = dl["text"] as? String {
                delta?(id, t)
            } else if tip == "result" {
                ochered.removeFirst()
                gotovo?(id, (o["result"] as? String) ?? "")
            }
        }
    }
}

// MARK: - слух: звук созвона через ScreenCaptureKit или микрофон, распознавание по-русски

@MainActor
final class Uho: NSObject, SCStreamOutput, SCStreamDelegate {
    enum Istochnik { case sozvon, mikrofon }
    private(set) var istochnik: Istochnik = .sozvon
    private let rasp = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))
    private var zapros: SFSpeechAudioBufferRecognitionRequest?
    private var zadacha: SFSpeechRecognitionTask?
    private var potok: SCStream?
    private let dvizhok = AVAudioEngine()
    private let ochered = DispatchQueue(label: "uho.audio")
    private var poslednee = ""
    private var otdano = 0
    private var izmeneno = Date()
    private var tajmer: Timer?
    private var perezapusk: Timer?
    private var naUstrojstve = true
    private var pusk = Date()
    /// Пока пауза, фразы не уходят в Claude; при снятии паузы всё услышанное раньше отбрасывается.
    var pauza = true {
        didSet { if !pauza { otdano = poslednee.split(separator: " ").count } }
    }
    var slyshu: ((String) -> Void)?
    var fraza: ((String) -> Void)?
    var status: ((String) -> Void)?

    func start() {
        SFSpeechRecognizer.requestAuthorization { st in
            Task { @MainActor in
                guard st == .authorized else { self.status?("нет доступа к распознаванию речи"); return }
                self.vklyuchit()
            }
        }
        // Фраза кончилась, если распознанный текст не менялся 1,3 секунды.
        tajmer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            Task { @MainActor in self.proveritPauzu() }
        }
        perezapusk = Timer.scheduledTimer(withTimeInterval: 50, repeats: true) { _ in
            Task { @MainActor in self.novayaZadacha() }
        }
    }

    func pereklyuchit() {
        ostanovitIstochnik()
        istochnik = istochnik == .sozvon ? .mikrofon : .sozvon
        vklyuchit()
    }

    private func vklyuchit() {
        novayaZadacha()
        switch istochnik {
        case .sozvon: Task { await self.zapustitSozvon() }
        case .mikrofon: zapustitMikrofon()
        }
    }

    private func ostanovitIstochnik() {
        if let potok { Task { try? await potok.stopCapture() } }
        potok = nil
        if dvizhok.isRunning { dvizhok.stop() }
        dvizhok.inputNode.removeTap(onBus: 0)
    }

    private func zapustitSozvon() async {
        do {
            let kontent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let ekran = kontent.displays.first else { status?("нет экрана для захвата звука"); return }
            let filtr = SCContentFilter(display: ekran, excludingWindows: [])
            let k = SCStreamConfiguration()
            k.capturesAudio = true
            k.excludesCurrentProcessAudio = true
            k.sampleRate = 48000
            k.channelCount = 1
            k.width = 2; k.height = 2
            k.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            let s = SCStream(filter: filtr, configuration: k, delegate: self)
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: ochered)
            try await s.startCapture()
            potok = s
            status?("слушаю звук созвона")
        } catch {
            zhurnal("ошибка захвата: \(error)")
            status?("нет доступа к записи экрана: разрешите в Настройках → Конфиденциальность → Запись экрана и звука, затем перезапустите")
        }
    }

    private func zapustitMikrofon() {
        let vhod = dvizhok.inputNode
        let f = vhod.inputFormat(forBus: 0)
        guard f.sampleRate > 0 else { status?("микрофон не найден"); return }
        vhod.removeTap(onBus: 0)
        vhod.installTap(onBus: 0, bufferSize: 4096, format: f) { [weak self] b, _ in
            Task { @MainActor in self?.zapros?.append(b) }
        }
        dvizhok.prepare()
        do { try dvizhok.start(); status?("слушаю микрофон") } catch { status?("микрофон не открылся") }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid else { return }
        Task { @MainActor in self.zapros?.appendAudioSampleBuffer(sb) }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in self.status?("захват звука остановился: \(error.localizedDescription)") }
    }

    private func novayaZadacha() {
        zapros?.endAudio(); zadacha?.cancel()
        guard let rasp, rasp.isAvailable else { status?("распознавание недоступно"); return }
        let z = SFSpeechAudioBufferRecognitionRequest()
        z.shouldReportPartialResults = true
        z.taskHint = .dictation
        z.requiresOnDeviceRecognition = naUstrojstve && rasp.supportsOnDeviceRecognition
        zapros = z; poslednee = ""; otdano = 0; pusk = Date()
        zadacha = rasp.recognitionTask(with: z) { [weak self] r, e in
            Task { @MainActor in
                guard let self else { return }
                if let r {
                    let t = r.bestTranscription.formattedString
                    if t != self.poslednee { self.poslednee = t; self.izmeneno = Date(); self.slyshu?(String(t.suffix(160))) }
                }
                if e != nil || (r?.isFinal ?? false) {
                    if e != nil && Date().timeIntervalSince(self.pusk) < 3 && z.requiresOnDeviceRecognition {
                        self.naUstrojstve = false   // модели на устройстве нет — идём через сеть
                    }
                    self.otdatHvost()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { Task { @MainActor in self.novayaZadacha() } }
                }
            }
        }
    }

    private func proveritPauzu() {
        guard Date().timeIntervalSince(izmeneno) > 1.3 else { return }
        otdatHvost()
    }

    private func otdatHvost() {
        let slova = poslednee.split(separator: " ").map(String.init)
        guard slova.count > otdano else { return }
        let novye = slova[otdano...].joined(separator: " ")
        otdano = slova.count
        guard !pauza, novye.split(separator: " ").count >= 4 else { return }
        fraza?(novye)
    }
}

// MARK: - панель

final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }      // нужно только для поля ручного ввода
    override var canBecomeMain: Bool { false }
}

struct Vid: View {
    @ObservedObject var s: Sostoyanie
    private let fon = Color(red: 0.055, green: 0.07, blue: 0.082)
    private let chernila = Color(red: 0.93, green: 0.945, blue: 0.925)
    private let karandash = Color(red: 0.55, green: 0.585, blue: 0.615)
    private let akcent = Color(red: 1.0, green: 0.373, blue: 0.18)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ВОПРОСЫ ПО ДОКЛАДУ").font(.system(size: 11, weight: .bold)).foregroundColor(akcent)
                Spacer()
                Button(action: { s.pereklyuchitPauzu?() }) {
                    Text(s.pauza ? "▶ Слушать (⌥P)" : "■ Слушаю \(s.istochnik)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(s.pauza ? chernila : .white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(s.pauza ? Color.white.opacity(0.12) : akcent)
                        .cornerRadius(7)
                }.buttonStyle(.plain)
            }
            Text(s.slyshu.isEmpty ? "…" : s.slyshu)
                .font(.system(size: 13)).foregroundColor(karandash).lineLimit(2)
            Divider().background(karandash)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(s.pary.reversed()) { p in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(p.vopros).font(.system(size: 13)).foregroundColor(karandash).lineLimit(3)
                            Text(p.otvet.isEmpty ? "думаю…" : p.otvet)
                                .font(.system(size: s.kegl, weight: .semibold))
                                .foregroundColor(p.gotov ? chernila : chernila.opacity(0.75))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            TextField("вопрос вручную или диктовкой, Enter", text: $s.vvod)
                .textFieldStyle(.plain).font(.system(size: 14)).foregroundColor(chernila)
                .padding(8).background(Color.white.opacity(0.07)).cornerRadius(8)
                .onSubmit { let t = s.vvod.trimmingCharacters(in: .whitespaces); if !t.isEmpty { s.otpravit?(t) }; s.vvod = "" }
            Text("\(s.status) · \(s.claude)").font(.system(size: 10)).foregroundColor(karandash).lineLimit(2)
            Text("⌥P пауза · ⌥M созвон/микрофон · ⌥H спрятать · ⌥= ⌥− шрифт · ⌥R перезапуск Claude")
                .font(.system(size: 10)).foregroundColor(karandash.opacity(0.7))
        }
        .padding(18)
        .frame(minWidth: 380, minHeight: 300)
        .background(fon.opacity(0.95))
        .cornerRadius(14)
    }
}

// MARK: - глобальные клавиши (как в Суфлёре: Carbon, все с ⌥, фокус у презентации)

final class Klavishi {
    static let shared = Klavishi()
    private var dejstviya: [UInt32: () -> Void] = [:]
    private var sled: UInt32 = 1
    private var postavlen = false

    func dobavit(_ kod: Int, _ f: @escaping () -> Void) {
        if !postavlen {
            postavlen = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, ev, _ in
                var h = EventHotKeyID()
                GetEventParameter(ev, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &h)
                let n = h.id
                DispatchQueue.main.async { Klavishi.shared.dejstviya[n]?() }
                return noErr
            }, 1, &spec, nil, nil)
        }
        let id = sled; sled += 1
        dejstviya[id] = f
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(kod), UInt32(optionKey), EventHotKeyID(signature: OSType(0x53555651), id: id),
                            GetApplicationEventTarget(), 0, &ref)
    }
}

// MARK: - приложение

@MainActor
final class Delegat: NSObject, NSApplicationDelegate {
    private let s = Sostoyanie()
    private let mozg = Mozg()
    private let uho = Uho()
    private var panel: Panel!
    private var materialy: URL!
    private var model = "haiku"

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let arg = CommandLine.arguments
        if let i = arg.firstIndex(of: "--model"), i + 1 < arg.count { model = arg[i + 1] }
        let poUmolchaniyu = ProcessInfo.processInfo.environment["SUFLER_MATERIALY"] ?? "\(NSHomeDirectory())/Documents/Суфлёр — материалы доклада.md"
        materialy = URL(fileURLWithPath: arg.dropFirst().first { !$0.hasPrefix("--") && $0 != model } ?? poUmolchaniyu)
        sobratPanel()

        mozg.status = { [weak self] t in self?.s.claude = t; zhurnal("claude: " + t) }
        mozg.delta = { [weak self] id, t in self?.izmenit(id) { $0.otvet += t } }
        mozg.gotovo = { [weak self] id, t in
            guard let self else { return }
            let chisto = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if chisto == "—" || chisto == "-" || chisto.isEmpty {
                self.s.pary.removeAll { $0.id == id }          // это был не вопрос
            } else {
                self.izmenit(id) { $0.otvet = chisto; $0.gotov = true }
                zhurnal("ответ: " + chisto)
            }
        }
        if FileManager.default.fileExists(atPath: materialy.path) {
            mozg.zapustit(materialy: materialy, model: model)
        } else {
            s.claude = "нет файла материалов: \(materialy.lastPathComponent)"
        }

        uho.slyshu = { [weak self] t in self?.s.slyshu = t }
        uho.status = { [weak self] t in self?.s.status = t; zhurnal("слух: " + t) }
        uho.fraza = { [weak self] t in self?.novaya(t) }
        s.otpravit = { [weak self] t in self?.novaya(t) }
        uho.start()

        let k = Klavishi.shared
        s.pereklyuchitPauzu = { [weak self] in guard let self else { return }; self.s.pauza.toggle(); self.uho.pauza = self.s.pauza; zhurnal(self.s.pauza ? "пауза" : "слушаю") }
        k.dobavit(kVK_ANSI_P) { [weak self] in self?.s.pereklyuchitPauzu?() }
        k.dobavit(kVK_ANSI_M) { [weak self] in
            guard let self else { return }
            self.uho.pereklyuchit(); self.s.istochnik = self.uho.istochnik == .sozvon ? "созвон" : "микрофон"
        }
        k.dobavit(kVK_ANSI_H) { [weak self] in
            guard let p = self?.panel else { return }
            if p.isVisible { p.orderOut(nil) } else { p.orderFrontRegardless() }
        }
        k.dobavit(kVK_ANSI_Equal) { [weak self] in self?.s.kegl = min(40, (self?.s.kegl ?? 22) + 2) }
        k.dobavit(kVK_ANSI_Minus) { [weak self] in self?.s.kegl = max(14, (self?.s.kegl ?? 22) - 2) }
        k.dobavit(kVK_ANSI_R) { [weak self] in
            guard let self else { return }
            self.mozg.ostanovit(); self.mozg.zapustit(materialy: self.materialy, model: self.model)
        }
    }

    private func novaya(_ t: String) {
        zhurnal("фраза: " + t)
        let p = Para(vopros: t)
        s.pary.append(p)
        if s.pary.count > 6 { s.pary.removeFirst(s.pary.count - 6) }
        mozg.sprosit(p.id, t)
    }

    private func izmenit(_ id: UUID, _ f: (inout Para) -> Void) {
        guard let i = s.pary.firstIndex(where: { $0.id == id }) else { return }
        f(&s.pary[i])
    }

    private func sobratPanel() {
        let e = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let r = NSRect(x: e.maxX - 460, y: e.minY + 24, width: 440, height: min(560, e.height - 48))
        panel = Panel(contentRect: r, styleMask: [.titled, .fullSizeContentView, .resizable, .nonactivatingPanel],
                      backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        // В демонстрацию экрана панель не попадает; SUFLER_VIDIM=1 снимает это для скриншотов.
        panel.sharingType = ProcessInfo.processInfo.environment["SUFLER_VIDIM"] == "1" ? .readOnly : .none
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { panel.standardWindowButton(b)?.isHidden = true }
        panel.contentView = NSHostingView(rootView: Vid(s: s))
        panel.setFrameAutosaveName("sufler-voprosy")
        panel.orderFrontRegardless()
    }
}

nonisolated(unsafe) var derzhatel: Delegat?
MainActor.assumeIsolated {
    let d = Delegat()
    derzhatel = d
    NSApplication.shared.delegate = d
}
NSApplication.shared.run()
