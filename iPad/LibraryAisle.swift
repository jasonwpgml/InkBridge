import SwiftUI

// 서재 aisle: one bookcase per Mac running the library server, standing side-on like the stacks of a library, plus
// the shared cloud library, locked until there is a server for it. Swiping walks along the aisle, which repeats in
// the same order; tapping a bookcase turns its front toward you and opens its shelves (LibraryView).

/// A Mac's library server saved on the iPad.
struct Bookcase: Codable, Identifiable, Hashable {
    var id = UUID()
    var address: String
    /// The name the Mac reports (`GET /__pr/api/info`); `custom` overrides it.
    var deviceName: String?
    var custom: String?

    var title: String { custom ?? deviceName ?? URL(string: address)?.host() ?? "맥" }

    /// Picks the colors of the books seen on its front, the same on every launch.
    var seed: Int { Int(id.uuid.0) << 8 | Int(id.uuid.1) }
}

/// The saved bookcases, kept as JSON in user defaults.
enum Bookcases {
    static let key = "bookcases"

    static func decode(_ stored: String) -> [Bookcase] {
        (try? JSONDecoder().decode([Bookcase].self, from: Data(stored.utf8))) ?? []
    }

    static func encode(_ list: [Bookcase]) -> String {
        (try? JSONEncoder().encode(list)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    /// The Mac's own name, or nil when its server cannot be reached.
    static func deviceName(_ address: String) async -> String? {
        guard let server = LibraryServer(address) else { return nil }
        var request = server.request("__pr/api/info")
        request.timeoutInterval = 4
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let info = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }
        return info["name"]
    }
}

private enum AisleItem: Hashable {
    case mac(Bookcase)
    /// Stands in the aisle while no Mac is saved.
    case add
    case cloud
}

struct LibraryAisle: View {
    let bookcases: [Bookcase]
    /// The bookcase whose shelves are open; nil while walking the aisle.
    let opened: Bookcase?
    var open: (Bookcase) -> Void
    var add: () -> Void
    var changeAddress: (Bookcase) -> Void
    var rename: (Bookcase, String?) -> Void
    var remove: (Bookcase) -> Void
    /// Returns to the home screen.
    var leave: () -> Void

    /// How many times the aisle repeats each way; far enough that nobody reaches the end.
    private static let laps = 200
    @State private var position: Int?
    @State private var approaching: Int?
    @State private var settings = false
    @State private var notice: String?
    @State private var renaming: Bookcase?
    @State private var newName = ""
    @State private var removing: Bookcase?

    private var items: [AisleItem] { (bookcases.isEmpty ? [.add] : bookcases.map(AisleItem.mac)) + [.cloud] }

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 0)
            aisle
            Spacer(minLength: 0)
            Text("옆으로 밀면 다른 책장 · 책장을 누르면 펼쳐집니다")
                .font(.footnote).foregroundStyle(.primary.opacity(0.55))
                .padding(.bottom, 28)
        }
        .foregroundStyle(.primary)
        .background { InkBackdrop() }
        .overlay(alignment: .bottom) {
            if let notice {
                Text(notice).font(.callout).multilineTextAlignment(.center)
                    .padding(.horizontal, 22).padding(.vertical, 14)
                    .glassCard(Capsule(), interactive: false)
                    .padding(.bottom, 64)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $settings) { SettingsView() }
        .alert("책장 이름", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("이름", text: $newName)
            Button("저장") { if let renaming { rename(renaming, newName.trimmingCharacters(in: .whitespaces)) } }
            Button("맥 이름으로") { if let renaming { rename(renaming, nil) } }
            Button("취소", role: .cancel) {}
        }
        .confirmationDialog("이 책장을 서재에서 뺄까요?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("책장 빼기", role: .destructive) { if let removing { remove(removing) } }
        } message: {
            Text("맥의 문서와 필기는 그대로 남고, 주소를 다시 넣으면 돌아옵니다.")
        }
        // Coming back from the shelves, the bookcase turns back into the aisle.
        .onChange(of: opened) { _, now in
            if now == nil { withAnimation(.smooth(duration: 0.45)) { approaching = nil } }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button(action: leave) { Image(systemName: "house").font(.title3).frame(width: 48, height: 48) }
                .glassCard(Circle())
                .accessibilityLabel("처음 화면으로")
            Text("서재").font(.largeTitle.bold())
            Spacer(minLength: 12)
            Button(action: add) {
                Label("책장 추가", systemImage: "plus").font(.headline).padding(.horizontal, 20).frame(height: 48)
            }
            .glassCard(Capsule())
            Button { settings = true } label: { Image(systemName: "gearshape").font(.title3).frame(width: 48, height: 48) }
                .glassCard(Circle())
                .accessibilityLabel("설정")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 32)
        .padding(.top, 12)
    }

    private var aisle: some View {
        let count = items.count
        return ScrollView(.horizontal) {
            LazyHStack(spacing: 14) {
                ForEach(0..<(count * Self.laps), id: \.self) { index in
                    let item = items[index % count]
                    BookcaseEnd(item: item, approaching: approaching == index)
                        .zIndex(approaching == index ? 1 : 0)
                        .opacity(approaching == nil || approaching == index ? 1 : 0)
                        .contentShape(Rectangle())
                        .onTapGesture { tap(item, at: index) }
                        .contextMenu { menu(for: item) }
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 80)
            .frame(height: 620)
        }
        .scrollPosition(id: $position, anchor: .center)
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .scrollDisabled(approaching != nil)
        .onAppear { if position == nil { position = count * Self.laps / 2 } }
        .onChange(of: count) { _, now in position = now * Self.laps / 2 }
    }

    @ViewBuilder private func menu(for item: AisleItem) -> some View {
        if case .mac(let bookcase) = item {
            Button { newName = bookcase.title; renaming = bookcase } label: { Label("이름 바꾸기", systemImage: "pencil") }
            Button { changeAddress(bookcase) } label: { Label("서버 주소 바꾸기", systemImage: "server.rack") }
            Button(role: .destructive) { removing = bookcase } label: { Label("책장 빼기", systemImage: "minus.circle") }
        }
    }

    private func tap(_ item: AisleItem, at index: Int) {
        switch item {
        case .add:
            add()
        case .cloud:
            withAnimation(.snappy) { notice = "공용 클라우드 서재는 아직 열리지 않았습니다.\n서재 서버가 생기면 여기서 여러 기기가 함께 쓰는 책장을 엽니다." }
            Task {
                try? await Task.sleep(for: .seconds(3.5))
                withAnimation(.snappy) { notice = nil }
            }
        case .mac(let bookcase):
            withAnimation(.smooth(duration: 0.5)) {
                position = index
                approaching = index
            }
            Task {
                try? await Task.sleep(for: .milliseconds(420))
                open(bookcase)
            }
        }
    }
}

// MARK: - Bookcase drawing

private let caseHeight: CGFloat = 520
/// The end panel is as deep as the shelves; the front with the books runs long, like the stacks of a library.
private let endWidth: CGFloat = 86
private let frontLength: CGFloat = 380
private let walnut = Color(red: 0.33, green: 0.21, blue: 0.13)
private let walnutDark = Color(red: 0.17, green: 0.1, blue: 0.06)

/// A long bookcase seen from the end of its aisle at an angle: the narrow end panel with the Mac's name on a range
/// card, and the front full of books running away from you. While approaching, the front turns to face you.
private struct BookcaseEnd: View {
    let item: AisleItem
    let approaching: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 0) {
            end
                .frame(width: endWidth, height: caseHeight)
                .rotation3DEffect(.degrees(approaching ? -88 : -30), axis: (x: 0, y: 1, z: 0), anchor: .trailing, perspective: 0.5)
            front
                .frame(width: frontLength, height: caseHeight)
                .rotation3DEffect(.degrees(approaching ? 0 : 55), axis: (x: 0, y: 1, z: 0), anchor: .leading, perspective: 0.5)
        }
        // Edge-on, the end panel takes almost no room, so the turned front ends up in the middle.
        .offset(x: approaching ? -endWidth / 2 : 0)
        .frame(width: approaching ? endWidth + frontLength : 250, height: caseHeight, alignment: .leading)
        .scaleEffect(approaching ? 1.1 : 1)
        .shadow(color: .black.opacity(scheme == .dark ? 0.55 : 0.25), radius: 20, x: 14, y: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
    }

    private var label: String {
        switch item {
        case .mac(let bookcase): "\(bookcase.title) 책장"
        case .add: "책장 추가"
        case .cloud: "공용 클라우드 서재, 준비 중"
        }
    }

    @ViewBuilder private var end: some View {
        switch item {
        case .mac(let bookcase):
            EndPanel { RangeCard(caption: "MAC", title: bookcase.title) }
        case .add:
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(.primary.opacity(0.45), style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                .overlay { Image(systemName: "plus").font(.system(size: 26, weight: .light)) }
        case .cloud:
            EndPanel { EmptyView() }
                .overlay { DustSheet(seed: 3, folds: 2) }
                .overlay(alignment: .top) { SheetTag().padding(.top, caseHeight * 0.18) }
        }
    }

    @ViewBuilder private var front: some View {
        switch item {
        case .mac(let bookcase):
            Stack(seed: bookcase.seed, header: bookcase.title)
        case .add:
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(.primary.opacity(0.3), style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                .overlay {
                    VStack(spacing: 8) {
                        Text("책장 추가").font(.title3.weight(.semibold))
                        Text("맥 서재 서버 주소를 넣으면\n여기에 책장이 섭니다").font(.footnote).multilineTextAlignment(.center)
                            .foregroundStyle(.primary.opacity(0.65))
                    }
                }
        case .cloud:
            // Not open yet: a dust sheet is thrown over the shelves.
            Stack(seed: 7, header: "공용 클라우드 서재")
                .overlay { DustSheet(seed: 7, folds: 7) }
                .overlay { LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .leading, endPoint: .trailing) }
        }
    }
}

/// A linen dust sheet thrown over a bookcase that is not open yet: soft folds hanging from the top, a wavy hem just
/// above the plinth.
private struct DustSheet: View {
    let seed: Int
    let folds: Int
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { context, size in
            var random = SeededRandom(seed)
            let hem = size.height - 24
            let wave = (0...folds * 2).map { _ in random.next() * 9 - 3 }
            func hemY(_ x: CGFloat) -> CGFloat {
                let t = x / size.width * CGFloat(folds * 2)
                let i = min(Int(t), folds * 2 - 1), f = t - CGFloat(i)
                return hem + wave[i] + (wave[i + 1] - wave[i]) * (1 - cos(f * .pi)) / 2
            }
            var sheet = Path()
            sheet.move(to: .zero)
            sheet.addLine(to: CGPoint(x: size.width, y: 0))
            for step in stride(from: size.width, through: 0, by: -4) { sheet.addLine(to: CGPoint(x: step, y: hemY(step))) }
            sheet.closeSubpath()

            let light = scheme == .dark ? 0.78 : 1.0
            context.fill(sheet, with: .linearGradient(
                Gradient(colors: [Color(red: 0.93 * light, green: 0.9 * light, blue: 0.83 * light),
                                  Color(red: 0.8 * light, green: 0.76 * light, blue: 0.68 * light)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.clip(to: sheet)
            // Folds fan out from where the sheet rests on the top board.
            let pitch = size.width / CGFloat(folds)
            for i in 0..<folds {
                let top = pitch * (CGFloat(i) + 0.5) + (random.next() - 0.5) * pitch * 0.3
                let bottom = top + (random.next() - 0.5) * pitch * 0.5
                let topWidth = pitch * 0.25, bottomWidth = pitch * (0.7 + random.next() * 0.3)
                var fold = Path()
                fold.move(to: CGPoint(x: top - topWidth / 2, y: 0))
                fold.addLine(to: CGPoint(x: top + topWidth / 2, y: 0))
                fold.addLine(to: CGPoint(x: bottom + bottomWidth / 2, y: size.height))
                fold.addLine(to: CGPoint(x: bottom - bottomWidth / 2, y: size.height))
                fold.closeSubpath()
                context.fill(fold, with: .linearGradient(
                    Gradient(colors: [.white.opacity(0.3), .clear, .black.opacity(0.2), .clear]),
                    startPoint: CGPoint(x: bottom - bottomWidth / 2, y: 0), endPoint: CGPoint(x: bottom + bottomWidth / 2, y: 0)))
            }
            // Where the cloth bends over the top board.
            context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: 14)),
                         with: .linearGradient(Gradient(colors: [.black.opacity(0.18), .clear]), startPoint: .zero, endPoint: CGPoint(x: 0, y: 14)))
            var edge = Path()
            edge.move(to: CGPoint(x: 0, y: hemY(0)))
            for step in stride(from: 4, through: size.width, by: 4) { edge.addLine(to: CGPoint(x: step, y: hemY(step))) }
            context.stroke(edge, with: .color(.black.opacity(0.3)), lineWidth: 2)
        }
    }
}

/// A paper tag tied to the dust sheet: the cloud library is not open yet.
private struct SheetTag: View {
    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color(red: 0.55, green: 0.45, blue: 0.32)).frame(width: 1, height: 22)
            VStack(spacing: 5) {
                Circle().strokeBorder(.black.opacity(0.35), lineWidth: 1).frame(width: 6, height: 6)
                Image(systemName: "lock.fill").font(.system(size: 13))
                Text("공용\n클라우드").font(.system(size: 11, weight: .semibold, design: .serif)).multilineTextAlignment(.center)
                Text("준비 중").font(.system(size: 9, weight: .medium)).opacity(0.6)
            }
            .foregroundStyle(Color(red: 0.2, green: 0.15, blue: 0.1))
            .padding(.horizontal, 7).padding(.vertical, 7)
            .background(Color(red: 0.86, green: 0.76, blue: 0.56), in: TagShape())
            .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1.5)
        }
        .rotationEffect(.degrees(-5), anchor: .top)
    }
}

/// A luggage tag: a rectangle with its top corners clipped.
private struct TagShape: Shape {
    func path(in rect: CGRect) -> Path {
        let cut = min(rect.width, rect.height) * 0.22
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + cut, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + cut))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + cut))
        path.closeSubpath()
        return path
    }
}

/// The same made-up books and folds every time a bookcase is drawn.
private struct SeededRandom {
    private var state: UInt64
    init(_ seed: Int) { state = UInt64(truncatingIfNeeded: seed &* 2_654_435_761 &+ 1) }
    mutating func next() -> CGFloat {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return CGFloat(state >> 33) / CGFloat(UInt32.max >> 1)
    }
}

/// The narrow walnut end of a bookcase: top cap, plinth and the range card that names it.
private struct EndPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [walnut, Color(red: 0.26, green: 0.16, blue: 0.1)], startPoint: .leading, endPoint: .trailing)
            Canvas { context, size in
                for i in 0..<6 {
                    let x = size.width * (0.12 + 0.15 * CGFloat(i))
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addCurve(to: CGPoint(x: x + 2, y: size.height),
                                  control1: CGPoint(x: x + (i.isMultiple(of: 2) ? 4 : -3), y: size.height * 0.4),
                                  control2: CGPoint(x: x - 2, y: size.height * 0.75))
                    context.stroke(path, with: .color(.black.opacity(0.13)), lineWidth: 0.7)
                }
            }
            VStack(spacing: 0) {
                Rectangle().fill(walnutDark).frame(height: 16)
                Spacer()
                Rectangle().fill(walnutDark).frame(height: 34)
            }
            content.padding(.horizontal, 10).padding(.top, caseHeight * 0.2)
        }
    }
}

/// The card on the end of a library range, in a brass holder.
private struct RangeCard: View {
    let caption: String
    let title: String

    var body: some View {
        VStack(spacing: 4) {
            Text(caption).font(.system(size: 9, weight: .bold)).tracking(2).opacity(0.6)
            Text(title).font(.system(size: 13, weight: .semibold, design: .serif))
                .multilineTextAlignment(.center).lineLimit(4).minimumScaleFactor(0.6)
        }
        .foregroundStyle(Color(red: 0.16, green: 0.12, blue: 0.08))
        .padding(.horizontal, 6).padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Color(red: 0.96, green: 0.93, blue: 0.85), in: RoundedRectangle(cornerRadius: 2))
        .padding(3)
        .background(
            LinearGradient(colors: [Color(red: 0.9, green: 0.76, blue: 0.45), Color(red: 0.62, green: 0.47, blue: 0.22)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 3)
        )
        .shadow(color: .black.opacity(0.4), radius: 1.5, y: 1.5)
    }
}

/// The front of a long bookcase: a top board with its name, six shelves of cloth-bound books in three bays, a plinth.
private struct Stack: View {
    let seed: Int
    let header: String
    private static let cloth: [Color] = [
        Color(red: 0.13, green: 0.2, blue: 0.36), Color(red: 0.45, green: 0.14, blue: 0.13), Color(red: 0.15, green: 0.3, blue: 0.22),
        Color(red: 0.62, green: 0.45, blue: 0.2), Color(red: 0.3, green: 0.32, blue: 0.36), Color(red: 0.34, green: 0.18, blue: 0.32),
        Color(red: 0.12, green: 0.33, blue: 0.36), Color(red: 0.7, green: 0.62, blue: 0.48),
    ]

    var body: some View {
        Canvas { context, size in
            var random = SeededRandom(seed)
            func next() -> CGFloat { random.next() }
            let cap: CGFloat = 26, plinth: CGFloat = 34, post: CGFloat = 8
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.1, green: 0.065, blue: 0.04)))
            let rows = 6
            let rowHeight = (size.height - cap - plinth) / CGFloat(rows)
            let bays = 3
            let bayWidth = (size.width - post * CGFloat(bays + 1)) / CGFloat(bays)
            for bay in 0..<bays {
                let left = post + CGFloat(bay) * (bayWidth + post)
                for row in 0..<rows {
                    let floor = cap + rowHeight * CGFloat(row + 1) - 5
                    var x = left + 2
                    while x < left + bayWidth - 4 {
                        let width = 6 + next() * 8
                        let height = rowHeight * (0.6 + next() * 0.3)
                        if next() < 0.05 { x += width; continue } // a gap where a book is out
                        let rect = CGRect(x: x, y: floor - height, width: min(width, left + bayWidth - 2 - x), height: height)
                        context.fill(Path(rect), with: .color(Self.cloth[Int(next() * CGFloat(Self.cloth.count)) % Self.cloth.count]))
                        context.fill(Path(CGRect(x: rect.minX, y: rect.minY + height * 0.16, width: rect.width, height: 1.6)),
                                     with: .color(Color(red: 0.86, green: 0.72, blue: 0.42).opacity(0.7)))
                        x += width + 0.8
                    }
                    context.fill(Path(CGRect(x: left, y: floor, width: bayWidth, height: 5)), with: .color(walnut))
                }
            }
            for i in 0...bays {
                context.fill(Path(CGRect(x: CGFloat(i) * (bayWidth + post), y: 0, width: post, height: size.height)), with: .color(walnut))
            }
            context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: cap)), with: .color(walnutDark))
            context.fill(Path(CGRect(x: 0, y: size.height - plinth, width: size.width, height: plinth)), with: .color(walnutDark))
            context.draw(Text(header).font(.system(size: 13, weight: .semibold, design: .serif)).foregroundStyle(Color(red: 0.88, green: 0.74, blue: 0.45)),
                         at: CGPoint(x: size.width / 2, y: cap / 2))
            // Light falls off toward the back of the aisle.
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .linearGradient(Gradient(colors: [.clear, .black.opacity(0.5)]),
                                               startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
        }
    }
}
