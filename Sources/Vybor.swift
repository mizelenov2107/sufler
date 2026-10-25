import AppKit
import SwiftUI

/// Одна заметка суфлёра, найденная в ваулте.
struct Urok: Identifiable, Hashable {
    let id: String
    let fajl: URL
    let imya: String        // «Функции, сдвиги и производная»
    let papka: String       // папка занятия, чтобы отличать колоду от подборки
    let izmenen: Date
    let razdelov: Int
    let minut: Int
}

/// Поиск заметок суфлёра. Заметкой считается файл, чьё имя начинается со слова
/// «Суфлёр»: так названы все заметки ведения и в презентациях, и в банке задач.
enum Poisk {

    /// Путь к ваулту берётся из SUFLER_VAULT, иначе стоит обычное место Obsidian.
    static let vault: URL = {
        if let svoj = ProcessInfo.processInfo.environment["SUFLER_VAULT"], !svoj.isEmpty {
            return URL(fileURLWithPath: (svoj as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Obsidian Vault")
    }()

    /// SUFLER_PAPKA сужает поиск до одной папки ваулта: на большом ваулте так быстрее.
    static func najti() -> [Urok] {
        let vetka = ProcessInfo.processInfo.environment["SUFLER_PAPKA"] ?? ""
        var najdeno = vetka.isEmpty ? [] : skanirovat(vault.appendingPathComponent(vetka))
        if najdeno.isEmpty { najdeno = skanirovat(vault) }
        return najdeno.sorted { $0.izmenen > $1.izmenen }
    }

    private static func skanirovat(_ koren: URL) -> [Urok] {
        let fm = FileManager.default
        guard let obhod = fm.enumerator(at: koren,
                                        includingPropertiesForKeys: [.contentModificationDateKey],
                                        options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }

        var out: [Urok] = []
        for sluchaj in obhod {
            guard let u = sluchaj as? URL, u.pathExtension == "md" else { continue }
            let imyaFajla = u.deletingPathExtension().lastPathComponent
            guard imyaFajla.hasPrefix("Суфлёр") || imyaFajla.hasPrefix("Суфлер") else { continue }
            guard let sk = try? Razbor.razobrat(fajl: u), sk.vsegoSlajdov > 0 else { continue }

            let data = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            out.append(Urok(id: u.path, fajl: u,
                            imya: korotkoeImya(imyaFajla),
                            papka: u.deletingLastPathComponent().lastPathComponent,
                            izmenen: data,
                            razdelov: sk.vsegoSlajdov,
                            minut: sk.planVsego))
        }
        return out
    }

    /// «Суфлёр — Функции, сдвиги и производная» → «Функции, сдвиги и производная».
    private static func korotkoeImya(_ s: String) -> String {
        for razdelitel in [" — ", " – ", " - ", "—", "-"] {
            if let r = s.range(of: razdelitel) {
                let hvost = String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !hvost.isEmpty { return hvost }
            }
        }
        return s
    }
}

// MARK: - окно выбора

struct VidVybora: View {
    let uroki: [Urok]
    var vybran: (URL) -> Void
    var drugojFajl: () -> Void
    var obnovit: () -> Void
    var vstavka: () -> Void

    @State private var zapros = ""

    private var vidimye: [Urok] {
        let z = zapros.trimmingCharacters(in: .whitespaces).lowercased()
        guard !z.isEmpty else { return uroki }
        return uroki.filter {
            $0.imya.lowercased().contains(z) || $0.papka.lowercased().contains(z)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "text.bubble")
                Text("Какой урок ведём").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("Обновить", action: obnovit)
                Button("Другой файл…", action: drugojFajl)
                Button("Вставить текст…", action: vstavka)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)

            TextField("Поиск по теме или папке", text: $zapros)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 18).padding(.bottom, 10)

            Divider()

            if vidimye.isEmpty {
                VStack(spacing: 8) {
                    Text("Заметок суфлёра не нашлось")
                        .font(.system(size: 14, weight: .medium))
                    Text("Файл должен лежать в ваулте и называться со слова «Суфлёр»")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(vidimye) { u in
                            Stroka(urok: u) { vybran(u.fajl) }
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 640, minHeight: 460)
    }
}

private struct Stroka: View {
    let urok: Urok
    var nazhali: () -> Void
    @State private var podsvetka = false

    private static let daty: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM"
        return f
    }()

    var body: some View {
        Button(action: nazhali) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(urok.imya).font(.system(size: 15, weight: .medium))
                    Text(urok.papka).font(.system(size: 12)).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(urok.razdelov) разделов · \(urok.minut) мин")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Text(Self.daty.string(from: urok.izmenen))
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 11)
            .contentShape(Rectangle())
            .background(podsvetka ? Color.accentColor.opacity(0.12) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { podsvetka = $0 }
    }
}

// MARK: - вставка текста

/// Речь, которую просто вставили в окно. Разметка не нужна: абзац становится
/// абзацем, строка с отступом — выкладкой, строка с решёткой — заголовком.
struct VidVstavki: View {
    @State var tekst: String
    var vesti: (String) -> Void
    var nazad: () -> Void

    private var slov: Int {
        tekst.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
    }
    /// Речь на занятии идёт примерно по 110 слов в минуту.
    private var minut: Int { max(1, Int((Double(slov) / 110).rounded())) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "text.append")
                Text("Вставь текст занятия").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("К списку уроков", action: nazad)
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 10)

            TextEditor(text: $tekst)
                .font(.system(size: 14))
                .padding(.horizontal, 14)
                .overlay(alignment: .topLeading) {
                    if tekst.isEmpty {
                        Text("Сюда вставляется речь как есть. Пустая строка делит абзацы, строка с решёткой становится заголовком, а строка с отступом в четыре пробела — выкладкой.")
                            .font(.system(size: 13)).foregroundStyle(.tertiary)
                            .padding(.horizontal, 19).padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }

            Divider()
            HStack(spacing: 12) {
                Text(slov == 0 ? "пусто" : "\(slov) слов · примерно \(minut) мин речи")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("Очистить") { tekst = "" }
                    .disabled(tekst.isEmpty)
                Button("Вести") { vesti(tekst) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(tekst.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(minWidth: 640, minHeight: 460)
    }
}
