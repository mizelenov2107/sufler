import Foundation

/// Матчер ведёт курсор по словам суфлёра вслед за речью.
/// Совпадение считается по началу слова, так что падеж и число роли не играют,
/// а пропуск слов и целых фраз матчер догоняет сам.
final class Matcher {

    private(set) var kursor: Int = 0          // индекс следующего ожидаемого токена
    private(set) var poteryan = false         // речь не ложится на текст
    private var promahi: Int = 0
    private var bufer: [String] = []          // последние услышанные опорные слова
    private var skript: Skript

    private let okno = 34                     // обычный поиск вперёд, слов
    private let dalnee = 700                  // поиск при потере места
    private let nazad = 90                    // насколько разрешено вернуться

    init(skript: Skript) { self.skript = skript }

    func zanovo(skript: Skript) {
        self.skript = skript
        kursor = 0; promahi = 0; bufer = []; poteryan = false
    }

    func postavit(na blok: Int) {
        if let t = skript.bloki[safe: blok]?.tokeny.first { kursor = t }
        else if blok >= skript.bloki.count { kursor = skript.tokeny.count }
        promahi = 0; bufer = []; poteryan = false
    }

    func postavit(naToken i: Int) {
        kursor = max(0, min(i, skript.tokeny.count))
        promahi = 0; bufer = []; poteryan = false
    }

    /// Блок, который сейчас читается, и слово внутри него.
    var mesto: (blok: Int, tokenVBloke: Int) {
        guard kursor < skript.tokeny.count else { return (skript.bloki.count - 1, 0) }
        let t = skript.tokeny[kursor]
        let vnutri = skript.bloki[t.blok].tokeny.firstIndex(of: kursor) ?? 0
        return (t.blok, vnutri)
    }

    /// Последний уже произнесённый речевой блок.
    var proshlyjRechevoj: Int {
        guard kursor > 0 else { return -1 }
        return skript.tokeny[kursor - 1].blok
    }

    // MARK: сравнение

    private func sovpalo(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let n = min(a.count, b.count)
        if n >= 5 { return a.prefix(5) == b.prefix(5) }
        if n == 4 { return a.prefix(4) == b.prefix(4) }
        return false
    }

    private func iskat(_ slovo: String, ot: Int, do konec: Int) -> Int? {
        var i = max(0, ot)
        let stop = min(konec, skript.tokeny.count)
        while i < stop {
            let t = skript.tokeny[i]
            if t.opora && sovpalo(t.klyuch, slovo) { return i }
            i += 1
        }
        return nil
    }

    /// Место, где две подряд услышанные опоры ложатся на две подряд опоры текста.
    /// По одному слову прыгаем только если слово длинное и в тексте редкое.
    private func vosstanovit(_ slovo: String) -> Int? {
        let ot = max(0, kursor - nazad)
        let do_ = min(skript.tokeny.count, kursor + dalnee)

        if bufer.count >= 2 {
            let a = bufer[bufer.count - 2], b = bufer[bufer.count - 1]
            var i = ot
            while i < do_ {
                let t = skript.tokeny[i]
                guard t.opora, sovpalo(t.klyuch, a) else { i += 1; continue }
                var j = i + 1
                while j < do_ && !skript.tokeny[j].opora { j += 1 }
                if j < do_ && sovpalo(skript.tokeny[j].klyuch, b) { return j + 1 }
                i += 1
            }
        }

        if Razbor.redkoe(slovo) {
            var najdeno: Int? = nil, skolko = 0
            var i = ot
            while i < do_ {
                let t = skript.tokeny[i]
                if t.redkoe && sovpalo(t.klyuch, slovo) { skolko += 1; if najdeno == nil { najdeno = i } }
                i += 1
            }
            if skolko == 1, let n = najdeno { return n + 1 }
        }
        return nil
    }

    /// Возвращает true, если курсор сдвинулся.
    @discardableResult
    func uslyshano(_ slova: [String]) -> Bool {
        var dvinulsya = false
        for slovo in slova {
            let k = Razbor.klyuch(slovo)
            guard Razbor.opornoe(k) else { continue }
            bufer.append(k)
            if bufer.count > 6 { bufer.removeFirst() }

            // Ближайшее совпадение впереди: так пропущенные слова и целые обороты
            // проглатываются одним движением.
            if let i = iskat(k, ot: kursor, do: kursor + okno) {
                kursor = i + 1; promahi = 0; poteryan = false; dvinulsya = true
                continue
            }
            promahi += 1
            if promahi >= 2, let i = vosstanovit(k) {
                kursor = i; promahi = 0; poteryan = false; dvinulsya = true
                continue
            }
            if promahi >= 6 { poteryan = true }
        }
        return dvinulsya
    }

    // MARK: ручные шаги

    /// Курсор встаёт на начало соседнего речевого блока.
    func shagBlok(vpered: Bool) {
        let sejchas = mesto.blok
        let poryadok = vpered ? Array((sejchas + 1)..<skript.bloki.count)
                              : Array(0..<sejchas).reversed()
        for i in poryadok where skript.bloki[i].rod == .rech { postavit(na: i); return }
        if vpered { postavit(naToken: skript.tokeny.count) }
    }

    /// Курсор перескакивает через предложение. Так пропускается кусок, который
    /// по ходу занятия говорить не хочется.
    func shagFraza(vpered: Bool) {
        if vpered {
            var i = kursor
            while i < skript.tokeny.count && !skript.tokeny[i].konecFrazy { i += 1 }
            postavit(naToken: min(i + 1, skript.tokeny.count))
        } else {
            var i = kursor - 2
            while i > 0 && !skript.tokeny[i].konecFrazy { i -= 1 }
            var j = i - 1
            while j > 0 && !skript.tokeny[j].konecFrazy { j -= 1 }
            postavit(naToken: max(0, j > 0 ? j + 1 : 0))
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
