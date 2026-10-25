import Foundation

/// Род блока суфлёра. Речь читается вслух, остальное показывается глазам.
enum Rod {
    case zagolovok   // ## 03 · Прямая, установка · 1 шаг · 2 мин
    case rech        // абзац, который говорится вслух
    case klik        // **Клик 1** — появляется карточка
    case probel      // **Пробел.**
    case remarka     // *(ждём ответ)* и курсивные пометки
    case formula     // выкладка с отступом в четыре пробела
}

struct Token {
    let tekst: String      // как в файле
    let klyuch: String     // нормализованный вид для сравнения
    let opora: Bool        // по опорным словам матчер двигает курсор
    let redkoe: Bool       // длинное слово, по нему разрешён дальний прыжок
    let konecFrazy: Bool   // на этом слове предложение кончается
    let blok: Int
}

struct Blok: Identifiable {
    let id: Int
    let rod: Rod
    let tekst: String
    let meta: String?      // «Слайд 03 · 1 шаг · 2 мин» у заголовка
    var minuty: Int = 0    // сколько минут отведено слайду
    var tokeny: [Int] = [] // индексы в общем массиве токенов
}

/// Разобранный суфлёр: блоки для показа и сквозной поток слов для матчера.
struct Skript {
    var bloki: [Blok] = []
    var tokeny: [Token] = []
    var imya: String = ""

    var pervyjRechevojBlok: Int {
        bloki.first(where: { $0.rod == .rech })?.id ?? 0
    }

    var vsegoSlajdov: Int { bloki.filter { $0.rod == .zagolovok }.count }

    /// Номер слайда по номеру блока, считая с единицы.
    func slajd(dlyaBloka blok: Int) -> Int {
        bloki.prefix(blok + 1).reduce(0) { $0 + ($1.rod == .zagolovok ? 1 : 0) }
    }

    /// Сколько минут по плану уходит до конца текущего слайда.
    func planMinut(doBloka blok: Int) -> Int {
        bloki.prefix(blok + 1).reduce(0) { $0 + $1.minuty }
    }
    var planVsego: Int { bloki.reduce(0) { $0 + $1.minuty } }
}

enum Razbor {

    /// Слова приводятся к общему виду: строчные буквы, «ё» как «е», без знаков.
    static func klyuch(_ s: String) -> String {
        var out = ""
        for ch in s.lowercased() {
            if ch == "ё" { out.append("е"); continue }
            if ch.isLetter || ch.isNumber { out.append(ch) }
        }
        return out
    }

    /// Опорное слово держит позицию курсора. Числа и короткие частицы опорой не служат,
    /// так как распознаватель отдаёт их то цифрой, то словом.
    static func opornoe(_ k: String) -> Bool {
        guard k.count >= 4 else { return false }
        return k.allSatisfy { $0.isLetter }
    }

    /// Слова короче семи букв встречаются в тексте по многу раз, поэтому дальний
    /// прыжок по одному такому слову увёл бы суфлёр не туда.
    static func redkoe(_ k: String) -> Bool {
        k.count >= 8 && k.allSatisfy { $0.isLetter }
    }

    static func konecFrazy(_ s: String) -> Bool {
        guard let last = s.last(where: { !$0.isWhitespace }) else { return false }
        return ".!?".contains(last) || s.hasSuffix(".»") || s.hasSuffix("?»")
    }

    static func chistyj(_ s: String) -> String {
        var t = s
        for para in ["**", "__", "`"] { t = t.replacingOccurrences(of: para, with: "") }
        if t.hasPrefix("*") && t.hasSuffix("*") && t.count > 2 {
            t = String(t.dropFirst().dropLast())
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    static func razobrat(fajl: URL) throws -> Skript {
        let syroj = try String(contentsOf: fajl, encoding: .utf8)
        return razobrat(tekst: syroj, imya: fajl.deletingPathExtension().lastPathComponent)
    }

    /// Текст без единого заголовка `## NN · тема · N мин` ведётся целиком: так суфлёр
    /// берёт речь, которую просто вставили в окно, а не собрали заметкой в ваулте.
    static func razobrat(tekst syroj: String, imya: String) -> Skript {
        var sk = Skript()
        sk.imya = imya
        let razmechen = syroj.components(separatedBy: .newlines).contains {
            zagolovokSlajda($0.trimmingCharacters(in: .whitespaces)) != nil
        }

        var nachalos = !razmechen
        var abzac: [String] = []
        var vykladka: [String] = []

        func dobavit(_ rod: Rod, _ tekst: String, meta: String? = nil) {
            let t = tekst.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            var b = Blok(id: sk.bloki.count, rod: rod, tekst: t, meta: meta)
            if rod == .zagolovok, let meta { b.minuty = minutyIz(meta) }
            if rod == .rech {
                for slovo in t.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
                    let k = klyuch(String(slovo))
                    guard !k.isEmpty else { continue }
                    b.tokeny.append(sk.tokeny.count)
                    sk.tokeny.append(Token(tekst: String(slovo), klyuch: k,
                                           opora: opornoe(k), redkoe: redkoe(k),
                                           konecFrazy: konecFrazy(String(slovo)), blok: b.id))
                }
            }
            sk.bloki.append(b)
        }

        func zakryt() {
            if !abzac.isEmpty { dobavit(.rech, abzac.joined(separator: " ")); abzac = [] }
            if !vykladka.isEmpty { dobavit(.formula, vykladka.joined(separator: "\n")); vykladka = [] }
        }

        for stroka in syroj.components(separatedBy: .newlines) {
            let s = stroka.trimmingCharacters(in: .whitespaces)

            // Ведение начинается с первого слайда и кончается служебным хвостом.
            if let zag = zagolovokSlajda(s) {
                nachalos = true
                zakryt()
                dobavit(.zagolovok, zag.0, meta: zag.1)
                continue
            }
            if !nachalos { continue }
            if s.hasPrefix("#") {
                // В размеченной заметке «## Если время поджимает» закрывает ведение,
                // во вставленном тексте строка с решёткой служит простым заголовком.
                if razmechen { break }
                zakryt()
                dobavit(.zagolovok, s.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces))
                continue
            }

            if s.isEmpty { zakryt(); continue }
            if s == "---" { zakryt(); continue }
            if s.hasPrefix("|") { continue }

            if stroka.hasPrefix("    ") || stroka.hasPrefix("\t") {
                if !abzac.isEmpty { dobavit(.rech, abzac.joined(separator: " ")); abzac = [] }
                vykladka.append(chistyj(s)); continue
            }
            if !vykladka.isEmpty { dobavit(.formula, vykladka.joined(separator: "\n")); vykladka = [] }

            if s.hasPrefix("**Клик") || s.hasPrefix("**Пробел") {
                zakryt()
                dobavit(s.hasPrefix("**Клик") ? .klik : .probel, chistyj(s))
                continue
            }
            if s.hasPrefix("*") && s.hasSuffix("*") && !s.hasPrefix("**") {
                zakryt(); dobavit(.remarka, chistyj(s)); continue
            }
            abzac.append(chistyj(s))
        }
        zakryt()
        return sk
    }

    /// «Слайд 03 · 1 шаг · 2 мин» → 2.
    static func minutyIz(_ meta: String) -> Int {
        guard let r = meta.range(of: #"(\d+)\s*мин"#, options: .regularExpression) else { return 0 }
        let cifry = meta[r].filter { $0.isNumber }
        return Int(cifry) ?? 0
    }

    /// «## 03 · Прямая, установка · 1 шаг · 2 мин» → заголовок и хвост с метой.
    private static func zagolovokSlajda(_ s: String) -> (String, String)? {
        guard s.hasPrefix("## ") else { return nil }
        let telo = String(s.dropFirst(3))
        let chasti = telo.components(separatedBy: " · ")
        guard chasti.count >= 2, Int(chasti[0].trimmingCharacters(in: .whitespaces)) != nil
        else { return nil }
        let nomer = chasti[0].trimmingCharacters(in: .whitespaces)
        let imya = chasti[1].trimmingCharacters(in: .whitespaces)
        let hvost = chasti.count > 2 ? chasti[2...].joined(separator: " · ") : ""
        return (imya, hvost.isEmpty ? "Слайд \(nomer)" : "Слайд \(nomer) · \(hvost)")
    }
}
