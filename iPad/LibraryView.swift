import SwiftUI
import UniformTypeIdentifiers

// 서재 (library): the Mac server's documents as books on wooden shelves. Opening one hands it to the reader
// (ReviewWebView); importing uploads PDF and Office files from the iPad into the Mac folder's imported/.

/// One document on the shelf, as GET /__pr/api/pages lists it.
struct Book: Decodable, Identifiable, Hashable {
    enum Kind: String, Decodable, CaseIterable {
        case pdf, slides, doc, web

        var shelf: String {
            switch self {
            case .pdf: "PDF"
            case .slides: "슬라이드"
            case .doc: "문서"
            case .web: "웹 페이지"
            }
        }

        var symbol: String {
            switch self {
            case .pdf: "doc.richtext"
            case .slides: "rectangle.on.rectangle"
            case .doc: "doc.text"
            case .web: "globe"
            }
        }

        /// Width over height of the cover; slides lie on their side.
        var aspect: CGFloat { self == .slides ? 4 / 3 : 3 / 4 }
    }

    let path: String
    let title: String
    let source: String?
    let kind: Kind
    let cover: String?
    let pageCount: Int?
    let strokes: Int
    var id: String { path }

    /// The page's <title>, or the file name without its extension.
    var name: String {
        let file = ((source ?? path) as NSString).lastPathComponent
        return title.isEmpty || title == file ? (file as NSString).deletingPathExtension : title
    }
}

/// A document the server is still turning into a book, or failed to (GET /__pr/api/conversions).
struct PendingBook: Decodable, Identifiable {
    let source: String
    let status: String
    let error: String?
    var id: String { source }
    var kind: Book.Kind {
        switch (source as NSString).pathExtension.lowercased() {
        case "pdf": .pdf
        case "pptx", "ppt", "key": .slides
        default: .doc
        }
    }
}

/// The server address saved in the app, split into its origin and token (…/?t=<token>).
struct LibraryServer {
    let origin: URL
    let token: String

    init?(_ address: String) {
        guard var parts = URLComponents(string: address), parts.host != nil,
              let token = parts.queryItems?.first(where: { $0.name == "t" })?.value, !token.isEmpty else { return nil }
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        guard let origin = parts.url else { return nil }
        self.origin = origin
        self.token = token
    }

    func request(_ path: String, query: [URLQueryItem] = []) -> URLRequest {
        var parts = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        parts.path = "/" + path
        if !query.isEmpty { parts.queryItems = query }
        var request = URLRequest(url: parts.url!, timeoutInterval: 10)
        request.setValue(token, forHTTPHeaderField: "X-PR-Token")
        return request
    }

    /// The reader opens the page with the token once so the web view keeps it as a cookie.
    func pageURL(_ book: Book) -> URL {
        request(book.path, query: [URLQueryItem(name: "t", value: token)]).url!
    }
}

@MainActor final class LibraryClient: ObservableObject {
    @Published private(set) var books: [Book] = []
    @Published private(set) var pending: [PendingBook] = []
    @Published private(set) var loaded = false
    @Published private(set) var unreachable = false
    @Published private(set) var root = ""
    @Published private(set) var uploads = 0
    @Published var notice: String?
    let server: LibraryServer

    init(server: LibraryServer) { self.server = server }

    /// Keeps the shelves current while the library is on screen.
    func watch() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(3))
        }
    }

    func refresh() async {
        do {
            async let pages: [Book] = fetch("__pr/api/pages")
            async let pending: [PendingBook] = fetch("__pr/api/conversions")
            (books, self.pending) = try await (pages, pending)
            if root.isEmpty, let info: [String: String] = try? await fetch("__pr/api/info") { root = info["root"] ?? "" }
            unreachable = false
        } catch {
            unreachable = true
        }
        loaded = true
    }

    private func fetch<T: Decodable>(_ path: String) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: server.request(path))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Uploads each file into the Mac folder's imported/; PDFs and Office files then appear as books being bound.
    func importFiles(_ urls: [URL]) async {
        var placed: [String] = []
        var failed: [String] = []
        for url in urls {
            uploads += 1
            defer { uploads -= 1 }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var request = server.request("__pr/api/import", query: [URLQueryItem(name: "name", value: url.lastPathComponent)])
            request.httpMethod = "POST"
            request.timeoutInterval = 300
            let ok = (try? await URLSession.shared.upload(for: request, fromFile: url))
                .map { ($0.1 as? HTTPURLResponse)?.statusCode == 200 } ?? false
            if ok { placed.append(url.deletingPathExtension().lastPathComponent) } else { failed.append(url.lastPathComponent) }
        }
        if !failed.isEmpty {
            notice = "가져오지 못했습니다: \(failed.joined(separator: ", "))"
        } else if placed.count == 1 {
            notice = "‘\(placed[0])’을 서재에 꽂았습니다."
        } else if !placed.isEmpty {
            notice = "\(placed.count)권을 서재에 꽂았습니다."
        }
        await refresh()
    }
}

/// Recently opened books, newest first, kept on this iPad as newline-separated paths.
private enum ReadingHistory {
    static let key = "libraryRecent"

    static func paths(_ stored: String) -> [String] { stored.split(separator: "\n").map(String.init) }

    static func opened(_ path: String, in stored: String) -> String {
        ([path] + paths(stored).filter { $0 != path }).prefix(20).joined(separator: "\n")
    }
}

struct LibraryView: View {
    @StateObject private var client: LibraryClient
    /// The bookcase's name, from its Mac.
    let title: String
    var open: (Book) -> Void
    var changeServer: () -> Void
    var leave: () -> Void
    @State private var query = ""
    @State private var importing = false
    @State private var settings = false
    @AppStorage(ReadingHistory.key) private var recentStored = ""

    init(server: LibraryServer, title: String, open: @escaping (Book) -> Void, changeServer: @escaping () -> Void, leave: @escaping () -> Void) {
        _client = StateObject(wrappedValue: LibraryClient(server: server))
        self.title = title
        self.open = open
        self.changeServer = changeServer
        self.leave = leave
    }

    private var shown: [Book] {
        let words = query.trimmingCharacters(in: .whitespaces)
        return words.isEmpty ? client.books : client.books.filter { $0.name.localizedCaseInsensitiveContains(words) }
    }

    private var recent: [Book] {
        let byPath = Dictionary(shown.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        return ReadingHistory.paths(recentStored).compactMap { byPath[$0] }
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 40) {
                    if !client.loaded {
                        ProgressView("서재를 여는 중").tint(.primary).frame(maxWidth: .infinity).padding(.top, 120)
                    } else if client.unreachable && client.books.isEmpty {
                        unreachable
                    } else if client.books.isEmpty && client.pending.isEmpty {
                        empty
                    } else {
                        if query.isEmpty, let last = recent.first { ContinueCard(book: last, server: client.server) { read(last) } }
                        if recent.count > 1 { shelf("최근 펼친 책", books: Array(recent.dropFirst().prefix(12)), width: geo.size.width) }
                        ForEach(Book.Kind.allCases, id: \.self) { kind in
                            let books = shown.filter { $0.kind == kind }
                            let pending = query.isEmpty ? client.pending.filter { $0.kind == kind } : []
                            if !books.isEmpty || !pending.isEmpty {
                                shelf(kind.shelf, books: books, pending: pending, width: geo.size.width)
                            }
                        }
                        if shown.isEmpty {
                            Text("‘\(query)’와 맞는 책이 없습니다.").foregroundStyle(.primary.opacity(0.7)).padding(.horizontal, 32)
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 48)
            }
            .scrollIndicators(.hidden)
            .safeAreaInset(edge: .top) { header }
        }
        .foregroundStyle(.primary)
        .background { InkBackdrop() }
        .task { await client.watch() }
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.importable, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await client.importFiles(urls) } }
        }
        .overlay(alignment: .bottom) { noticeBanner }
        .sheet(isPresented: $settings) { SettingsView() }
    }

    private func read(_ book: Book) {
        recentStored = ReadingHistory.opened(book.path, in: recentStored)
        open(book)
    }

    private func shelf(_ title: String, books: [Book], pending: [PendingBook] = [], width: CGFloat) -> some View {
        Shelf(title: title, books: books, pending: pending, server: client.server, width: width, open: read)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Button(action: leave) { Image(systemName: "chevron.left").font(.title3.weight(.semibold)).frame(width: 48, height: 48) }
                .glassCard(Circle())
                .accessibilityLabel("책장 사이로")
            Text(title).font(.largeTitle.bold()).lineLimit(1).minimumScaleFactor(0.6)
            if client.uploads > 0 {
                ProgressView().tint(.primary)
                Text("가져오는 중").font(.subheadline).foregroundStyle(.primary.opacity(0.75))
            } else if client.unreachable && client.loaded && !client.books.isEmpty {
                Label("맥 연결 끊김", systemImage: "wifi.exclamationmark").font(.subheadline).foregroundStyle(.orange)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.primary.opacity(0.6))
                TextField("책 찾기", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled()
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.primary.opacity(0.6)) }
                        .accessibilityLabel("검색어 지우기")
                }
            }
            .padding(.horizontal, 16).frame(width: 240, height: 48)
            .glassCard(Capsule())
            Button { importing = true } label: {
                Label("가져오기", systemImage: "plus").font(.headline).padding(.horizontal, 20).frame(height: 48)
            }
            .glassCard(Capsule())
            Menu {
                Button { Task { await client.refresh() } } label: { Label("새로고침", systemImage: "arrow.clockwise") }
                Button(action: changeServer) { Label("서버 주소 바꾸기", systemImage: "server.rack") }
                Button { settings = true } label: { Label("설정", systemImage: "gearshape") }
                if !client.root.isEmpty { Section("맥 폴더: \(client.root)") {} }
            } label: { Image(systemName: "ellipsis").font(.title3).frame(width: 48, height: 48) }
                .glassCard(Circle())
                .accessibilityLabel("서재 더보기")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 32)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

    // MARK: States

    private var empty: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "books.vertical").font(.system(size: 44, weight: .light))
            Text("서재가 비어 있습니다").font(.title2.bold())
            Text("iPad의 PDF·PowerPoint·Word 파일을 가져오거나, 맥 폴더\(client.root.isEmpty ? "" : "(\(client.root))")에 문서를 넣으면 책장에 꽂힙니다.")
                .foregroundStyle(.primary.opacity(0.75))
            Button { importing = true } label: {
                Label("문서 가져오기", systemImage: "plus").font(.headline).padding(.horizontal, 22).frame(height: 48)
            }
            .buttonStyle(.plain)
            .glassCard(Capsule())
        }
        .padding(32)
        .frame(maxWidth: 560, alignment: .leading)
        .glassCard(RoundedRectangle(cornerRadius: 32))
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private var unreachable: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                Image(systemName: "wifi.exclamationmark").font(.system(size: 40, weight: .light))
                Spacer()
                ConnectionHelpButton(host: client.server.origin.host).foregroundStyle(.primary)
            }
            Text("맥 서버에 연결할 수 없습니다").font(.title2.bold())
            Text("맥에서 서재 서버가 켜져 있고 같은 Wi-Fi인지 확인해 주세요.\n\(client.server.origin.host ?? "")")
                .foregroundStyle(.primary.opacity(0.75))
            HStack(spacing: 12) {
                Button { Task { await client.refresh() } } label: { Text("다시 시도").font(.headline).padding(.horizontal, 22).frame(height: 48) }
                    .glassCard(Capsule())
                Button(action: changeServer) { Text("서버 주소 바꾸기").padding(.horizontal, 22).frame(height: 48) }
                    .glassCard(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(32)
        .frame(maxWidth: 560, alignment: .leading)
        .glassCard(RoundedRectangle(cornerRadius: 32))
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    @ViewBuilder private var noticeBanner: some View {
        if let notice = client.notice {
            Text(notice).font(.subheadline.weight(.medium)).padding(.horizontal, 22).padding(.vertical, 14)
                .glassCard(Capsule())
                .padding(.bottom, 32)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: notice) {
                    try? await Task.sleep(for: .seconds(3))
                    withAnimation { client.notice = nil }
                }
        }
    }

    /// Documents the server turns into page images; HTML is not imported because its scripts would run beside the API.
    static let importable: [UTType] = [.pdf, .rtf]
        + ["pptx", "ppt", "key", "docx", "doc", "odt", "pages"].compactMap { UTType(filenameExtension: $0) }
}

// MARK: Shelves and books

private let coverHeight: CGFloat = 196
/// Room above the tallest cover for the page block, which rises toward the back of the shelf.
private let standHeight: CGFloat = coverHeight + 10

/// A row of books standing on a wooden shelf, scrolling sideways.
private struct Shelf: View {
    let title: String
    let books: [Book]
    var pending: [PendingBook] = []
    let server: LibraryServer
    let width: CGFloat
    let open: (Book) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title).font(.title2.weight(.semibold))
                Text("\(books.count)권").font(.subheadline).foregroundStyle(.primary.opacity(0.6))
            }
            .padding(.horizontal, 32)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 22) {
                    ForEach(books) { book in
                        Button { open(book) } label: { BookItem(book: book, server: server) }
                            .buttonStyle(BookPress())
                            .hoverEffect(.lift)
                    }
                    ForEach(pending) { BindingItem(book: $0) }
                }
                .padding(.horizontal, 40)
                .padding(.top, 6)
                .frame(minWidth: width, alignment: .leading)
                .background(alignment: .topLeading) {
                    // Books stand toward the front of the plank's top.
                    ShelfPlank().padding(.horizontal, 20).offset(y: 6 + standHeight - 12)
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}

/// A walnut plank seen from a little above: the top the books stand on, then its front edge.
private struct ShelfPlank: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [Color(red: 0.2, green: 0.13, blue: 0.08), Color(red: 0.36, green: 0.24, blue: 0.15)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 16)
            Rectangle().fill(.white.opacity(0.22)).frame(height: 1)
            LinearGradient(colors: [Color(red: 0.3, green: 0.2, blue: 0.12), Color(red: 0.19, green: 0.12, blue: 0.07)],
                           startPoint: .top, endPoint: .bottom)
                .overlay { WoodGrain().stroke(.black.opacity(0.18), lineWidth: 0.6) }
                .frame(height: 17)
        }
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.25), radius: 14, y: 12)
    }
}

private struct WoodGrain: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for (i, y) in [0.3, 0.55, 0.78].enumerated() {
            let base = rect.minY + rect.height * y
            path.move(to: CGPoint(x: rect.minX, y: base))
            var x = rect.minX
            while x < rect.maxX {
                let next = min(x + 140 + CGFloat(i) * 37, rect.maxX)
                path.addQuadCurve(to: CGPoint(x: next, y: base), control: CGPoint(x: (x + next) / 2, y: base + (i.isMultiple(of: 2) ? 1.4 : -1.4)))
                x = next
            }
        }
        return path
    }
}

private struct BookItem: View {
    let book: Book
    let server: LibraryServer

    var body: some View {
        let width = coverHeight * book.kind.aspect + book.thickness
        VStack(alignment: .leading, spacing: 6) {
            BookCover(book: book, server: server, height: coverHeight * book.heightScale)
                .frame(height: standHeight, alignment: .bottom)
                .padding(.bottom, 34)
            Text(book.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(caption).font(.caption).foregroundStyle(.primary.opacity(0.62))
        }
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var caption: String {
        let ink = book.strokes > 0 ? "필기 \(book.strokes)" : "새 책"
        return book.pageCount.map { "\(ink) · \($0)쪽" } ?? ink
    }
}

private extension Book {
    /// Stable per book, so its cloth and height don't change between refreshes.
    var seed: UInt32 { path.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value } }

    /// Real shelves are uneven: covers stand between 88% and 100% of the tallest.
    var heightScale: CGFloat { 0.88 + CGFloat(seed % 13) / 100 }

    /// Depth of the page block, growing with the page count.
    var thickness: CGFloat { pageCount.map { min(18, 4 + CGFloat($0).squareRoot() * 1.3) } ?? 6 }
}

/// Book cloth for covers the server has no page image for, with the stamping that reads on it.
private struct Cloth {
    let color: Color
    let stamp: Color

    private static let gold = Color(red: 0.88, green: 0.75, blue: 0.47)
    private static let blind = Color(red: 0.1, green: 0.08, blue: 0.06).opacity(0.8)
    static let all = [
        Cloth(color: Color(red: 0.13, green: 0.19, blue: 0.33), stamp: gold),   // navy
        Cloth(color: Color(red: 0.42, green: 0.12, blue: 0.13), stamp: gold),   // oxblood
        Cloth(color: Color(red: 0.14, green: 0.29, blue: 0.22), stamp: gold),   // forest
        Cloth(color: Color(red: 0.2, green: 0.2, blue: 0.22), stamp: gold),     // charcoal
        Cloth(color: Color(red: 0.1, green: 0.31, blue: 0.34), stamp: gold),    // teal
        Cloth(color: Color(red: 0.31, green: 0.17, blue: 0.3), stamp: gold),    // plum
        Cloth(color: Color(red: 0.64, green: 0.48, blue: 0.2), stamp: blind),   // ochre
        Cloth(color: Color(red: 0.69, green: 0.6, blue: 0.46), stamp: blind),   // kraft
    ]
}

/// A hardcover seen slightly from the right: the cover, and the page block's fore-edge behind it.
/// The cover is the first page when the server rendered one, otherwise stamped cloth.
struct BookCover: View {
    let book: Book
    let server: LibraryServer
    let height: CGFloat

    var body: some View {
        let width = height * book.kind.aspect
        let depth = book.thickness
        let rise = depth * 0.45
        let cloth = Cloth.all[Int(book.seed % UInt32(Cloth.all.count))]
        let board = book.cover == nil ? cloth.color : Color(white: 0.9)
        ZStack(alignment: .bottomLeading) {
            ForeEdge(board: board, rise: rise)
                .frame(width: depth, height: height + rise)
                .offset(x: width)
            face(cloth: cloth)
                .frame(width: width, height: height)
        }
        .frame(width: width + depth, height: height + rise, alignment: .bottomLeading)
        .background(alignment: .bottom) {
            // Contact shadow on the shelf.
            Ellipse().fill(.black.opacity(0.7)).frame(height: 10).blur(radius: 4).offset(y: 4)
        }
        .shadow(color: .black.opacity(0.35), radius: 9, x: 7, y: 0)
        .overlay(alignment: .bottomLeading) {
            if book.strokes > 0 {
                Ribbon().fill(LinearGradient(colors: [Color(red: 0.78, green: 0.2, blue: 0.2), Color(red: 0.55, green: 0.1, blue: 0.12)],
                                             startPoint: .top, endPoint: .bottom))
                    .frame(width: 11, height: 24)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
                    .offset(x: width * 0.66, y: 20)
            }
        }
    }

    private func face(cloth: Cloth) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 1.5, bottomLeadingRadius: 1.5, bottomTrailingRadius: 3, topTrailingRadius: 3)
        return ZStack(alignment: .topLeading) {
            if let cover = book.cover {
                CoverImage(request: server.request(cover)) { stamped(cloth) }
                // Laminate catching the light.
                LinearGradient(stops: [.init(color: .white.opacity(0), location: 0.35), .init(color: .white.opacity(0.18), location: 0.5),
                                       .init(color: .white.opacity(0), location: 0.62)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                // Quarter binding: cloth over the spine, the printed page on the boards.
                ZStack { cloth.color; ClothWeave().stroke(.black.opacity(0.07), lineWidth: 0.5) }
                    .frame(width: max(14, height * book.kind.aspect * 0.08))
                    .shadow(color: .black.opacity(0.4), radius: 1, x: 1)
            } else {
                stamped(cloth)
            }
            // Where the board bends round the spine: shadowed wrap, then the hinge groove.
            HStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.45), .black.opacity(0.12)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 9)
                Rectangle().fill(.black.opacity(0.35)).frame(width: 1.5)
                Rectangle().fill(.white.opacity(0.18)).frame(width: 1)
                Spacer()
            }
            LinearGradient(colors: [.white.opacity(0.1), .clear, .black.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.75))
    }

    private func stamped(_ cloth: Cloth) -> some View {
        ZStack {
            cloth.color
            ClothWeave().stroke(.black.opacity(0.07), lineWidth: 0.5)
            VStack(spacing: 0) {
                rules(cloth.stamp)
                Spacer(minLength: 0)
                Text(book.name).font(.system(size: height * 0.082, weight: .semibold, design: .serif))
                    .multilineTextAlignment(.center).lineLimit(5).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                Text(book.kind.shelf).font(.system(size: height * 0.045, weight: .medium, design: .serif)).tracking(2)
                    .padding(.bottom, 8)
                rules(cloth.stamp)
            }
            .foregroundStyle(cloth.stamp)
            .shadow(color: .black.opacity(0.35), radius: 0, x: 0, y: -0.5)
            .padding(.leading, 22).padding(.trailing, 12).padding(.vertical, height * 0.08)
        }
    }

    private func rules(_ color: Color) -> some View {
        VStack(spacing: 2.5) {
            Rectangle().frame(height: 1.2)
            Rectangle().frame(height: 0.5)
        }
        .foregroundStyle(color.opacity(0.85))
    }
}

/// Fine crossed threads of book cloth.
private struct ClothWeave: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        var y = rect.minY
        while y < rect.maxY { path.move(to: CGPoint(x: rect.minX, y: y)); path.addLine(to: CGPoint(x: rect.maxX, y: y)); y += 1.6 }
        var x = rect.minX
        while x < rect.maxX { path.move(to: CGPoint(x: x, y: rect.minY)); path.addLine(to: CGPoint(x: x, y: rect.maxY)); x += 2.2 }
        return path
    }
}

/// The pages' edges between the two boards, receding up and to the right.
private struct ForeEdge: View {
    let board: Color
    let rise: CGFloat

    var body: some View {
        Canvas { context, size in
            let depth = size.width
            let height = size.height - rise
            // y of the top edge at x; the bottom is `height` below it.
            func top(_ x: CGFloat) -> CGFloat { rise * (1 - x / depth) }
            func band(_ from: CGFloat, _ to: CGFloat, inset: CGFloat) -> Path {
                Path { path in
                    path.move(to: CGPoint(x: from, y: top(from) + inset))
                    path.addLine(to: CGPoint(x: to, y: top(to) + inset))
                    path.addLine(to: CGPoint(x: to, y: top(to) + height - inset))
                    path.addLine(to: CGPoint(x: from, y: top(from) + height - inset))
                    path.closeSubpath()
                }
            }
            context.fill(band(0, depth, inset: 0), with: .color(board))
            context.fill(band(0, depth, inset: 0), with: .color(.black.opacity(0.3)))
            let boardWidth = min(1.6, depth * 0.15)
            let pages = band(boardWidth, depth - boardWidth, inset: 1.5)
            context.fill(pages, with: .linearGradient(Gradient(colors: [Color(red: 0.93, green: 0.9, blue: 0.83), Color(red: 0.72, green: 0.68, blue: 0.6)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: depth, y: 0)))
            var x = boardWidth + 0.8
            var line = 0
            while x < depth - boardWidth {
                var edge = Path()
                edge.move(to: CGPoint(x: x, y: top(x) + 1.5))
                edge.addLine(to: CGPoint(x: x, y: top(x) + height - 1.5))
                context.stroke(edge, with: .color(.black.opacity(line % 3 == 0 ? 0.14 : 0.06)), lineWidth: 0.4)
                x += 0.9
                line += 1
            }
        }
    }
}

/// The tail of a ribbon bookmark hanging out under the pages: the book has notes in it.
private struct Ribbon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - rect.width * 0.5))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// A book still at the bindery: the server is converting its source file.
private struct BindingItem: View {
    let book: PendingBook

    var body: some View {
        let failed = book.status == "failed"
        let width = coverHeight * book.kind.aspect
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 3).fill(.primary.opacity(0.04))
                RoundedRectangle(cornerRadius: 3).strokeBorder(.primary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                VStack(spacing: 10) {
                    if failed { Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(.orange) }
                    else { ProgressView().tint(.primary) }
                    Text(failed ? "만들지 못함" : "책으로 만드는 중").font(.caption.weight(.medium))
                }
            }
            .frame(width: width, height: coverHeight * 0.94)
            .frame(height: standHeight, alignment: .bottom)
            .padding(.bottom, 34)
            Text(((book.source as NSString).lastPathComponent as NSString).deletingPathExtension)
                .font(.subheadline.weight(.semibold)).lineLimit(2)
            Text(failed ? (book.error ?? "변환 실패") : "맥에서 변환 중").font(.caption).foregroundStyle(.primary.opacity(0.62)).lineLimit(2)
        }
        .frame(width: width, alignment: .leading)
    }
}

/// The last book opened, set out on the front table.
private struct ContinueCard: View {
    let book: Book
    let server: LibraryServer
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .center, spacing: 28) {
                BookCover(book: book, server: server, height: 220)
                VStack(alignment: .leading, spacing: 10) {
                    Text("이어서 쓰기").font(.subheadline.weight(.semibold)).foregroundStyle(.primary.opacity(0.65))
                    Text(book.name).font(.system(.largeTitle, design: .serif).weight(.semibold)).lineLimit(2)
                    Label(details, systemImage: book.kind.symbol).font(.callout).foregroundStyle(.primary.opacity(0.72))
                    Label("펼치기", systemImage: "book").font(.headline)
                        .padding(.horizontal, 22).frame(height: 46)
                        .background(.primary.opacity(0.16), in: Capsule())
                        .padding(.top, 10)
                }
                Spacer(minLength: 0)
            }
            .padding(28)
            .contentShape(RoundedRectangle(cornerRadius: 36))
        }
        .buttonStyle(.plain)
        .glassCard(RoundedRectangle(cornerRadius: 36))
        .padding(.horizontal, 32)
    }

    private var details: String {
        var parts = [book.kind.shelf]
        if let pages = book.pageCount { parts.append("\(pages)쪽") }
        parts.append(book.strokes > 0 ? "필기 \(book.strokes)" : "아직 필기 없음")
        return parts.joined(separator: " · ")
    }
}

/// Lifts a book slightly off the shelf while it is pressed.
private struct BookPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 1.04 : 1)
            .offset(y: configuration.isPressed ? -8 : 0)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

private let coverCache: NSCache<NSURL, UIImage> = {
    let cache = NSCache<NSURL, UIImage>()
    cache.countLimit = 120
    return cache
}()

/// Loads a cover page through the server token and keeps a small copy in memory.
private struct CoverImage<Placeholder: View>: View {
    let request: URLRequest
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() } else { placeholder() }
        }
        .task(id: request.url) {
            guard let url = request.url as NSURL? else { return }
            if let cached = coverCache.object(forKey: url) { image = cached; return }
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let small = await UIImage(data: data)?.byPreparingThumbnail(ofSize: CGSize(width: 480, height: 640)) else { return }
            coverCache.setObject(small, forKey: url)
            image = small
        }
    }
}
