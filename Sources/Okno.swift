import AppKit
import SwiftUI

/// Панель поверх презентации. Фокус не забирает, поэтому пробел уходит в колоду,
/// и в захват экрана не попадает, так что зритель суфлёра не видит.
final class Panel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

enum Cvet {
    static let paper   = Color(red: 0.055, green: 0.07, blue: 0.082)
    static let ink     = Color(red: 0.93, green: 0.945, blue: 0.925)
    static let pencil  = Color(red: 0.55, green: 0.585, blue: 0.615)
    static let fuchsia = Color(red: 1.00, green: 0.373, blue: 0.659)
    static let ultra   = Color(red: 0.498, green: 0.627, blue: 1.00)
}

/// Состояние, которое видит вид.
@MainActor
final class Model: ObservableObject {
    @Published var skript = Skript()
    @Published var blok = 0
    @Published var slovo = 0
    @Published var proshlyj = -1
    @Published var status = "пауза"
    @Published var rezhim = ""
    @Published var slushaet = false
    @Published var tishina = false
    @Published var poteryan = false
    @Published var kegl: CGFloat = 21
    @Published var neprozrachnost: Double = 0.96
    @Published var skvoznoj = false
    @Published var proshlo: TimeInterval = 0
    @Published var slyshu = ""          // что распознаватель услышал последним
    @Published var prokrutka = 0        // счётчик просьб вернуть ленту на место

    var perejtiNaToken: ((Int) -> Void)?
    var perejtiNaBlok: ((Int) -> Void)?
    var zakryt: (() -> Void)?
    var spryatat: (() -> Void)?

    /// Клики и «пробел», до которых мы дочитали, но ещё не пошли дальше.
    var zhdut: [Blok] {
        skript.bloki.filter { b in
            (b.rod == .klik || b.rod == .probel) && b.id > proshlyj && b.id < blok
        }
    }
    var zagolovok: Blok? {
        skript.bloki.prefix(while: { $0.id <= blok }).last(where: { $0.rod == .zagolovok })
    }
    var nomerSlajda: Int { skript.slajd(dlyaBloka: blok) }
    var planDoSjuda: Int { skript.planMinut(doBloka: blok) }
}

// MARK: - раскладка словами

/// Слова кладутся строками с переносом. Нужна, чтобы каждое слово ловило клик.
struct Potok: Layout {
    var poGorizontali: CGFloat = 6
    var poVertikali: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let shirina = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, vysotaStroki: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > shirina, x > 0 { x = 0; y += vysotaStroki + poVertikali; vysotaStroki = 0 }
            x += sz.width + poGorizontali
            vysotaStroki = max(vysotaStroki, sz.height)
        }
        return CGSize(width: shirina, height: y + vysotaStroki)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0, vysotaStroki: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.width, x > 0 { x = 0; y += vysotaStroki + poVertikali; vysotaStroki = 0 }
            s.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(sz))
            x += sz.width + poGorizontali
            vysotaStroki = max(vysotaStroki, sz.height)
        }
    }
}

// MARK: - вид

struct Vid: View {
    @ObservedObject var m: Model
    @State private var pulsiruet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            shapka
            Divider().overlay(Cvet.pencil.opacity(0.25))
            lenta
            Divider().overlay(Cvet.pencil.opacity(0.25))
            podval
        }
        .background(Cvet.paper.opacity(m.neprozrachnost))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Cvet.pencil.opacity(0.35), lineWidth: 1)
        )
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulsiruet = true
            }
        }
    }

    // MARK: шапка

    private var shapka: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(m.slushaet ? (m.tishina ? Cvet.ultra : Cvet.fuchsia) : Cvet.pencil)
                .frame(width: 9, height: 9)
            Text(m.status.uppercased())
                .font(.system(size: 11, weight: .semibold)).tracking(1.1)
                .foregroundStyle(Cvet.ink.opacity(0.85))
            if !m.rezhim.isEmpty {
                Text(m.rezhim).font(.system(size: 11)).foregroundStyle(Cvet.pencil)
            }
            if m.poteryan {
                Text("не нахожу место").font(.system(size: 11)).foregroundStyle(Cvet.ultra)
            }
            Spacer()
            if m.skvoznoj {
                Text("КЛИКИ СКВОЗЬ").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Cvet.ultra)
            }
            Text(m.zagolovok?.tekst ?? "")
                .font(.system(size: 11)).foregroundStyle(Cvet.pencil).lineLimit(1)
            knopka("chevron.down", "спрятать панель, ⌥H") { m.spryatat?() }
            knopka("xmark", "закрыть суфлёр, ⌥Q") { m.zakryt?() }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func knopka(_ znak: String, _ podskazka: String,
                        _ dejstvie: @escaping () -> Void) -> some View {
        Image(systemName: znak)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Cvet.pencil)
            .frame(width: 20, height: 20)
            .background(Cvet.ink.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
            .onTapGesture(perform: dejstvie)
            .help(podskazka)
    }

    // MARK: лента

    private var lenta: some View {
        ScrollViewReader { ssylka in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(m.skript.bloki) { b in
                        blokVid(b).id(b.id)
                    }
                    Color.clear.frame(height: 360)
                }
                .padding(.horizontal, 18).padding(.top, 14)
            }
            .onChange(of: m.prokrutka) { _, _ in
                let cel = m.zhdut.first?.id ?? m.blok
                withAnimation(.easeOut(duration: 0.28)) {
                    ssylka.scrollTo(cel, anchor: UnitPoint(x: 0, y: 0.3))
                }
            }
            .onAppear {
                // Первая раскладка ленты приходит позже появления вида,
                // поэтому на место её ставим следующим ходом.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    ssylka.scrollTo(m.zhdut.first?.id ?? m.blok, anchor: UnitPoint(x: 0, y: 0.3))
                }
            }
        }
    }

    @ViewBuilder
    private func blokVid(_ b: Blok) -> some View {
        switch b.rod {
        case .zagolovok:
            VStack(alignment: .leading, spacing: 3) {
                if let meta = b.meta {
                    Text(meta.uppercased()).font(.system(size: 10, weight: .semibold))
                        .tracking(1.2).foregroundStyle(Cvet.pencil)
                }
                Text(b.tekst).font(.system(size: m.kegl + 3, weight: .bold))
                    .foregroundStyle(Cvet.ink.opacity(b.id <= m.blok ? 0.95 : 0.5))
            }
            .padding(.top, 10)
            .contentShape(Rectangle())
            .onTapGesture { m.perejtiNaBlok?(b.id) }

        case .klik, .probel:
            let zhdet = m.zhdut.contains(where: { $0.id == b.id })
            let cvet = b.rod == .klik ? Cvet.fuchsia : Cvet.ultra
            HStack(alignment: .top, spacing: 10) {
                Text(b.rod == .klik ? "▸" : "␣")
                    .font(.system(size: m.kegl, weight: .bold)).foregroundStyle(cvet)
                Text(b.tekst)
                    .font(.system(size: m.kegl, weight: zhdet ? .semibold : .regular))
                    .foregroundStyle(cvet.opacity(zhdet ? 1 : (b.id < m.blok ? 0.4 : 0.62)))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 9).padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cvet.opacity(zhdet ? 0.18 : 0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(cvet.opacity(zhdet ? (pulsiruet ? 1 : 0.35) : 0.2),
                            lineWidth: zhdet ? 2 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))

        case .remarka:
            Text(b.tekst)
                .font(.system(size: m.kegl - 2).italic())
                .foregroundStyle(Cvet.ultra.opacity(b.id <= m.blok ? 0.85 : 0.45))
                .fixedSize(horizontal: false, vertical: true)

        case .formula:
            Text(b.tekst)
                .font(.system(size: m.kegl, weight: .medium, design: .monospaced))
                .foregroundStyle(Cvet.ink.opacity(b.id <= m.blok ? 0.9 : 0.45))
                .padding(.vertical, 8).padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Cvet.ink.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))

        case .rech:
            if b.id == m.blok { tekushchij(b) } else { dalnij(b) }
        }
    }

    /// Текущий абзац разложен по словам: клик по слову переносит суфлёр туда.
    private func tekushchij(_ b: Blok) -> some View {
        Potok(poVertikali: 7).callAsFunction {
            ForEach(Array(b.tokeny.enumerated()), id: \.offset) { i, gi in
                Text(m.skript.tokeny[gi].tekst)
                    .font(.system(size: m.kegl, weight: i == m.slovo ? .semibold : .medium))
                    .foregroundStyle(i < m.slovo ? Cvet.ink.opacity(0.32)
                                     : (i == m.slovo ? Cvet.fuchsia : Cvet.ink))
                    .contentShape(Rectangle())
                    .onTapGesture { m.perejtiNaToken?(gi) }
            }
        }
    }

    /// Остальные абзацы одним куском, клик ставит суфлёр на их начало.
    private func dalnij(_ b: Blok) -> some View {
        Text(b.tekst)
            .font(.system(size: m.kegl))
            .lineSpacing(6)
            .foregroundStyle(Cvet.ink.opacity(b.id < m.blok ? 0.3 : 0.55))
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
            .onTapGesture { m.perejtiNaBlok?(b.id) }
    }

    // MARK: подвал

    private var podval: some View {
        VStack(alignment: .leading, spacing: 7) {
            rejka
            if !m.slyshu.isEmpty {
                Text(m.slyshu)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Cvet.ultra.opacity(0.75))
                    .lineLimit(1).truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                Text("слайд \(m.nomerSlajda)/\(m.skript.vsegoSlajdov)")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Cvet.ink.opacity(0.8))
                Text(chasy).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(otstavanie > 180 ? Cvet.fuchsia : Cvet.pencil)
                Spacer()
                Text("⌥␣ пауза · ⌥→ фраза · ⌥⇧→ абзац · ⌥H спрятать · ⌥Q закрыть")
                    .font(.system(size: 10)).foregroundStyle(Cvet.pencil.opacity(0.75))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    private var rejka: some View {
        GeometryReader { g in
            let zagolovki = m.skript.bloki.filter { $0.rod == .zagolovok }
            let vsego = max(1, zagolovki.count)
            HStack(spacing: 2) {
                ForEach(Array(zagolovki.enumerated()), id: \.element.id) { i, z in
                    Rectangle()
                        .fill(i < m.nomerSlajda ? Cvet.fuchsia.opacity(i == m.nomerSlajda - 1 ? 1 : 0.5)
                                                : Cvet.pencil.opacity(0.28))
                        .frame(width: max(2, (g.size.width - CGFloat(vsego - 1) * 2) / CGFloat(vsego)),
                               height: i == m.nomerSlajda - 1 ? 5 : 3)
                        .clipShape(Capsule())
                        .onTapGesture { m.perejtiNaBlok?(z.id) }
                }
            }
            .frame(height: 6, alignment: .center)
        }
        .frame(height: 6)
    }

    private var otstavanie: TimeInterval {
        m.proshlo - Double(m.planDoSjuda) * 60
    }

    private var chasy: String {
        let s = Int(m.proshlo)
        let plan = m.planDoSjuda
        let znak = otstavanie >= 0 ? "+" : "−"
        let raznica = Int(abs(otstavanie) / 60)
        return String(format: "%02d:%02d · план %d · %@%d", s / 60, s % 60, plan, znak, raznica)
    }
}
