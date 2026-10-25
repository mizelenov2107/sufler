import Foundation
import Speech
import AVFoundation

/// Слух: микрофон и распознавание речи. Наружу отдаёт только новые слова.
@MainActor
final class Sluh: NSObject {

    enum Rezhim: String {
        case naUstrojstve = "на устройстве"
        case cherezSet = "через сеть"
        case net = "нет"
    }

    var novyeSlova: (([String]) -> Void)?
    var sostoyanie: ((String) -> Void)?
    var uslyshal: ((String) -> Void)?          // сырой текст для строки контроля

    private let raspoznavatel = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))
    private var zapros: SFSpeechAudioBufferRecognitionRequest?
    private var zadacha: SFSpeechRecognitionTask?
    private let dvizhok = AVAudioEngine()
    private var otdano = 0                     // слов текущей задачи уже отдано матчеру
    private var perezapusk: Timer?
    private var puskDo = Date.distantPast      // когда задача была запущена
    private var naUstrojstve = true            // первая попытка идёт без сети
    private(set) var rabotaet = false
    private(set) var rezhim: Rezhim = .net

    /// Разрешения спрашиваются один раз, дальше система помнит ответ.
    func sprosit(_ gotovo: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard status == .authorized else {
                    self.sostoyanie?("нет доступа к распознаванию речи")
                    gotovo(false); return
                }
                AVCaptureDevice.requestAccess(for: .audio) { mozhno in
                    Task { @MainActor in
                        if !mozhno { self.sostoyanie?("нет доступа к микрофону") }
                        gotovo(mozhno)
                    }
                }
            }
        }
    }

    func puskat() {
        guard !rabotaet else { return }
        guard let r = raspoznavatel, r.isAvailable else {
            sostoyanie?("распознавание недоступно"); return
        }
        rabotaet = true
        do { try zapustit() } catch {
            rabotaet = false
            sostoyanie?("микрофон не открылся")
            return
        }
        // Задача копит контекст и со временем ползёт, поэтому раз в минуту начинаем заново.
        perezapusk = Timer.scheduledTimer(withTimeInterval: 55, repeats: true) { _ in
            Task { @MainActor in self.osvezhit() }
        }
    }

    func stopnut() {
        perezapusk?.invalidate(); perezapusk = nil
        rabotaet = false
        snyat()
        rezhim = .net
    }

    private func osvezhit() {
        guard rabotaet else { return }
        snyat()
        try? zapustit()
    }

    private func snyat() {
        if dvizhok.isRunning { dvizhok.stop() }
        dvizhok.inputNode.removeTap(onBus: 0)
        zapros?.endAudio()
        zadacha?.finish()
        zapros = nil; zadacha = nil; otdano = 0
    }

    private func zapustit() throws {
        guard let r = raspoznavatel else { return }
        let z = SFSpeechAudioBufferRecognitionRequest()
        z.shouldReportPartialResults = true
        z.taskHint = .dictation
        // Русская модель на устройстве стоит не у всех, поэтому при первой же ошибке
        // уходим на серверное распознавание и больше на устройство не возвращаемся.
        if naUstrojstve && r.supportsOnDeviceRecognition {
            z.requiresOnDeviceRecognition = true
            rezhim = .naUstrojstve
        } else {
            rezhim = .cherezSet
        }
        zapros = z
        puskDo = Date()

        let vhod = dvizhok.inputNode
        let format = vhod.inputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw Oshibka.netVhoda }
        vhod.removeTap(onBus: 0)
        vhod.installTap(onBus: 0, bufferSize: 4096, format: format) { bufer, _ in
            z.append(bufer)
        }
        dvizhok.prepare()
        try dvizhok.start()

        zadacha = r.recognitionTask(with: z) { [weak self] rezultat, oshibka in
            Task { @MainActor in
                guard let self, self.rabotaet else { return }
                if let rezultat { self.prinyat(rezultat) }
                if oshibka != nil || (rezultat?.isFinal ?? false) {
                    self.spotknulis(oshibka)
                }
            }
        }
    }

    enum Oshibka: Error { case netVhoda }

    /// Хвост распознанного отдаётся матчеру один раз и сразу, без придержки:
    /// суфлёр не должен отставать. Недослышанное слово матчер узнаёт по началу,
    /// а правку хвоста пропускает, так как этот номер уже отдан.
    private func prinyat(_ rezultat: SFSpeechRecognitionResult) {
        let stroka = rezultat.bestTranscription.formattedString
        let slova = stroka.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        uslyshal?(stroka)

        if slova.count < otdano { otdano = slova.count }        // распознаватель переписал хвост
        guard slova.count > otdano else { return }
        let svezhie = Array(slova[otdano...])
        otdano = slova.count
        novyeSlova?(svezhie)
    }

    /// Задача кончилась. Если она умерла сразу после старта, то модель на устройстве
    /// не отвечает, и вторую попытку делаем через сеть.
    private func spotknulis(_ oshibka: Error?) {
        let bystro = Date().timeIntervalSince(puskDo) < 3
        if bystro && oshibka != nil && rezhim == .naUstrojstve {
            naUstrojstve = false
            sostoyanie?("модель на устройстве не ответила, идём через сеть")
        }
        snyat()
        let pauza = bystro ? 1.0 : 0.15
        DispatchQueue.main.asyncAfter(deadline: .now() + pauza) { [weak self] in
            Task { @MainActor in
                guard let self, self.rabotaet else { return }
                do { try self.zapustit() } catch { self.sostoyanie?("микрофон не открылся") }
            }
        }
    }
}
