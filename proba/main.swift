import Foundation

let put = CommandLine.arguments[1]
let sk = try Razbor.razobrat(fajl: URL(fileURLWithPath: put))
print("блоков \(sk.bloki.count), слов \(sk.tokeny.count), слайдов \(sk.vsegoSlajdov), план \(sk.planVsego) мин")

func proba(_ imya: String, _ nachalo: Int, _ frazy: [[String]]) {
    let m = Matcher(skript: sk)
    m.postavit(na: nachalo)
    for f in frazy { m.uslyshano(f) }
    let mesto = m.mesto
    let tekst = sk.bloki[mesto.blok].tekst
    print("\(imya): блок \(mesto.blok), слово \(mesto.tokenVBloke) → «\(String(tekst.prefix(52)))…»")
}

proba("по тексту", sk.pervyjRechevojBlok, [
    ["сегодня","занятие","целиком","про","функции"],
    ["прямая","парабола","гипербола","сдвиги","графика","и","производная"]])

proba("с середины фразы", sk.pervyjRechevojBlok, [["прямая","парабола","гипербола"]])

proba("пропустил половину абзаца", sk.pervyjRechevojBlok, [
    ["сегодня","занятие","целиком","про","функции"],
    ["скажу","сразу","почему","мы","начинаем","с","математики"]])

proba("пропустил целый абзац", sk.pervyjRechevojBlok, [
    ["сегодня","занятие","про","функции"],
    ["все","пять","сюжетов","сегодня","мы","разбираем","на","чистых","числах"]])

proba("пересказал своими словами", sk.pervyjRechevojBlok, [
    ["сегодня","занятие","целиком","про","функции"],
    ["ну","в","общем","короче","говоря","давай","посмотрим","что","тут","у","нас"],
    ["вот","наш","маршрут","пять","инструментов"]])

proba("прыжок на четвёртый слайд", sk.pervyjRechevojBlok, [
    ["наклон","показывает","на","сколько","изменится","игрек"]])

// шаги руками
let m = Matcher(skript: sk)
m.postavit(na: sk.pervyjRechevojBlok)
m.shagFraza(vpered: true)
print("после ⌥→: слово \(m.mesto.tokenVBloke) блока \(m.mesto.blok)")
m.shagFraza(vpered: true)
print("ещё раз: слово \(m.mesto.tokenVBloke) блока \(m.mesto.blok)")
m.shagBlok(vpered: true)
print("после ⌥⇧→: блок \(m.mesto.blok)")
