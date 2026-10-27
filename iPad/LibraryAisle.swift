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
            LazyHStack(spacing: 44) {
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

private let caseHeight: CGFloat = 500
private let sideWidth: CGFloat = 170
private let frontWidth: CGFloat = 160

/// A bookcase seen from the end of its aisle: the side panel almost facing you with the Mac's name on it, and the
/// front with its books turning away. While approaching, the front turns to face you and the side folds away.
private struct BookcaseEnd: View {
    let item: AisleItem
    let approaching: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 0) {
            side
                .frame(width: sideWidth, height: caseHeight)
                .rotation3DEffect(.degrees(approaching ? 88 : 16), axis: (x: 0, y: 1, z: 0), anchor: .trailing, perspective: 0.45)
            front
                .frame(width: frontWidth, height: caseHeight)
                .rotation3DEffect(.degrees(approaching ? 0 : -66), axis: (x: 0, y: 1, z: 0), anchor: .leading, perspective: 0.45)
        }
        // Edge-on, the side takes almost no room, so the opened front ends up in the middle.
        .offset(x: approaching ? -sideWidth / 2 : 0)
        .frame(width: approaching ? sideWidth + frontWidth : sideWidth + 70, height: caseHeight, alignment: .leading)
        .scaleEffect(approaching ? 1.15 : 1)
        .shadow(color: .black.opacity(scheme == .dark ? 0.55 : 0.25), radius: 24, x: 10, y: 22)
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

    @ViewBuilder private var side: some View {
        switch item {
        case .mac(let bookcase):
            WoodPanel {
                NamePlate(title: bookcase.title, caption: "MAC 서재")
            }
        case .add:
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.primary.opacity(0.45), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .overlay {
                    VStack(spacing: 14) {
                        Image(systemName: "plus").font(.system(size: 34, weight: .light))
                        Text("책장 추가").font(.title3.weight(.semibold))
                        Text("맥 서재 서버\n주소를 넣으면\n책장이 섭니다").font(.footnote).multilineTextAlignment(.center)
                            .foregroundStyle(.primary.opacity(0.65))
                    }
                }
        case .cloud:
            // Material rather than glassCard: Liquid Glass ignores the perspective of rotation3DEffect.
            RoundedRectangle(cornerRadius: 6)
                .fill(.ultraThinMaterial)
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.2)) }
                .overlay {
                    VStack(spacing: 14) {
                        Image(systemName: "lock.fill").font(.system(size: 30, weight: .light))
                        Text("공용\n클라우드 서재").font(.system(.title3, design: .serif).weight(.semibold)).multilineTextAlignment(.center)
                        Text("준비 중").font(.footnote.weight(.medium)).tracking(3).foregroundStyle(.primary.opacity(0.6))
                    }
                }
        }
    }

    @ViewBuilder private var front: some View {
        switch item {
        case .mac(let bookcase):
            BookRows(seed: bookcase.seed)
        case .add:
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(.primary.opacity(0.3), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
        case .cloud:
            // Shelves behind frosted glass, not yet open.
            BookRows(seed: 7)
                .opacity(0.35)
                .overlay { Rectangle().fill(.ultraThinMaterial).overlay { Rectangle().strokeBorder(.primary.opacity(0.15)) } }
        }
    }
}

/// The walnut end panel of a bookcase: a raised panel in a frame, on a darker plinth.
private struct WoodPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.36, green: 0.24, blue: 0.15), Color(red: 0.24, green: 0.15, blue: 0.09)],
                           startPoint: .leading, endPoint: .trailing)
            Canvas { context, size in
                // Long vertical grain.
                for i in 0..<14 {
                    let x = size.width * (0.05 + 0.065 * CGFloat(i))
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addCurve(to: CGPoint(x: x + 3, y: size.height),
                                  control1: CGPoint(x: x + (i.isMultiple(of: 2) ? 5 : -4), y: size.height * 0.35),
                                  control2: CGPoint(x: x - 3, y: size.height * 0.7))
                    context.stroke(path, with: .color(.black.opacity(0.12)), lineWidth: 0.7)
                }
            }
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .black.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing),
                              lineWidth: 2)
                .padding(.horizontal, 16).padding(.top, 22).padding(.bottom, 54)
            VStack {
                Spacer()
                Rectangle().fill(Color(red: 0.16, green: 0.1, blue: 0.06)).frame(height: 34)
            }
            content.padding(.horizontal, 22)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// The brass plate on the end panel that names the bookcase.
private struct NamePlate: View {
    let title: String
    let caption: String

    var body: some View {
        VStack(spacing: 6) {
            Text(caption).font(.system(size: 10, weight: .semibold)).tracking(2.5).opacity(0.75)
            Text(title).font(.system(size: 17, weight: .semibold, design: .serif))
                .multilineTextAlignment(.center).lineLimit(3).minimumScaleFactor(0.7)
        }
        .foregroundStyle(Color(red: 0.24, green: 0.16, blue: 0.06))
        .padding(.horizontal, 12).padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [Color(red: 0.93, green: 0.8, blue: 0.5), Color(red: 0.72, green: 0.56, blue: 0.27)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 4)
        )
        .shadow(color: .black.opacity(0.4), radius: 2, y: 2)
        .offset(y: -60)
    }
}

/// The front of a bookcase: five shelves of cloth-bound spines.
private struct BookRows: View {
    let seed: Int
    private static let cloth: [Color] = [
        Color(red: 0.13, green: 0.2, blue: 0.36), Color(red: 0.45, green: 0.14, blue: 0.13), Color(red: 0.15, green: 0.3, blue: 0.22),
        Color(red: 0.62, green: 0.45, blue: 0.2), Color(red: 0.3, green: 0.32, blue: 0.36), Color(red: 0.34, green: 0.18, blue: 0.32),
        Color(red: 0.12, green: 0.33, blue: 0.36), Color(red: 0.7, green: 0.62, blue: 0.48),
    ]

    var body: some View {
        Canvas { context, size in
            var state = UInt64(truncatingIfNeeded: seed &* 2_654_435_761 &+ 1)
            func next() -> CGFloat {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return CGFloat(state >> 33) / CGFloat(UInt32.max >> 1)
            }
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.12, green: 0.08, blue: 0.05)))
            let rows = 5
            let plinth: CGFloat = 34
            let rowHeight = (size.height - plinth - 14) / CGFloat(rows)
            for row in 0..<rows {
                let floor = 14 + rowHeight * CGFloat(row + 1)
                var x: CGFloat = 6
                while x < size.width - 10 {
                    let width = 7 + next() * 9
                    let height = rowHeight * (0.62 + next() * 0.3)
                    if next() < 0.06 { x += width; continue } // a gap where a book is out
                    let rect = CGRect(x: x, y: floor - height, width: min(width, size.width - 6 - x), height: height)
                    let color = Self.cloth[Int(next() * CGFloat(Self.cloth.count)) % Self.cloth.count]
                    context.fill(Path(rect), with: .color(color))
                    context.fill(Path(CGRect(x: rect.minX, y: rect.minY + height * 0.18, width: rect.width, height: 2)),
                                 with: .color(Color(red: 0.86, green: 0.72, blue: 0.42).opacity(0.7)))
                    x += width + 1
                }
                context.fill(Path(CGRect(x: 0, y: floor, width: size.width, height: 6)), with: .color(Color(red: 0.3, green: 0.2, blue: 0.12)))
            }
            context.fill(Path(CGRect(x: 0, y: size.height - plinth, width: size.width, height: plinth)),
                         with: .color(Color(red: 0.16, green: 0.1, blue: 0.06)))
            // Light falls off toward the back of the aisle.
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .linearGradient(Gradient(colors: [.clear, .black.opacity(0.45)]),
                                               startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}
