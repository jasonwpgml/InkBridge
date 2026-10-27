import SwiftUI
import UniformTypeIdentifiers

// 서재 (library): the Mac server's documents as books on glass shelves. Opening one hands it to the reader
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
    var open: (Book) -> Void
    var changeServer: () -> Void
    var leave: () -> Void
    @State private var query = ""
    @State private var importing = false
    @AppStorage(ReadingHistory.key) private var recentStored = ""

    init(server: LibraryServer, open: @escaping (Book) -> Void, changeServer: @escaping () -> Void, leave: @escaping () -> Void) {
        _client = StateObject(wrappedValue: LibraryClient(server: server))
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
                        ProgressView("서재를 여는 중").tint(.white).frame(maxWidth: .infinity).padding(.top, 120)
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
                            Text("‘\(query)’와 맞는 책이 없습니다.").foregroundStyle(.white.opacity(0.7)).padding(.horizontal, 32)
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 48)
            }
            .scrollIndicators(.hidden)
            .safeAreaInset(edge: .top) { header }
        }
        .foregroundStyle(.white)
        .background { InkBackdrop() }
        .preferredColorScheme(.dark)
        .task { await client.watch() }
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.importable, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await client.importFiles(urls) } }
        }
        .overlay(alignment: .bottom) { noticeBanner }
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
            Button(action: leave) { Image(systemName: "house").font(.title3).frame(width: 48, height: 48) }
                .glassCard(Circle())
                .accessibilityLabel("처음 화면으로")
            Text("서재").font(.largeTitle.bold())
            if client.uploads > 0 {
                ProgressView().tint(.white)
                Text("가져오는 중").font(.subheadline).foregroundStyle(.white.opacity(0.75))
            } else if client.unreachable && client.loaded && !client.books.isEmpty {
                Label("맥 연결 끊김", systemImage: "wifi.exclamationmark").font(.subheadline).foregroundStyle(.orange)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.6))
                TextField("책 찾기", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled()
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.6)) }
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
                .foregroundStyle(.white.opacity(0.75))
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
            Image(systemName: "wifi.exclamationmark").font(.system(size: 40, weight: .light))
            Text("맥 서버에 연결할 수 없습니다").font(.title2.bold())
            Text("맥에서 서재 서버가 켜져 있고 같은 Wi-Fi인지 확인해 주세요.\n\(client.server.origin.host ?? "")")
                .foregroundStyle(.white.opacity(0.75))
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

/// A row of books standing on a glass ledge, scrolling sideways.
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
                Text("\(books.count)권").font(.subheadline).foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 32)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 26) {
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
                    // The ledge the covers stand on, under their bottom edge and above the titles.
                    RoundedRectangle(cornerRadius: 7)
                        .fill(.white.opacity(0.06))
                        .frame(height: 16)
                        .glassCard(RoundedRectangle(cornerRadius: 7))
                        .shadow(color: .black.opacity(0.35), radius: 12, y: 10)
                        .padding(.horizontal, 20)
                        .offset(y: 6 + coverHeight - 3)
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}

private struct BookItem: View {
    let book: Book
    let server: LibraryServer

    var body: some View {
        let width = coverHeight * book.kind.aspect
        VStack(alignment: .leading, spacing: 6) {
            BookCover(book: book, server: server, height: coverHeight)
                .padding(.bottom, 22)
            Text(book.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(caption).font(.caption).foregroundStyle(.white.opacity(0.62))
        }
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var caption: String {
        let ink = book.strokes > 0 ? "필기 \(book.strokes)" : "새 책"
        return book.pageCount.map { "\(ink) · \($0)쪽" } ?? ink
    }
}

/// A cover: the first page when the server rendered one, otherwise a cloth binding with the title.
struct BookCover: View {
    let book: Book
    let server: LibraryServer
    let height: CGFloat

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 3, bottomTrailingRadius: 9, topTrailingRadius: 9)
        ZStack(alignment: .topLeading) {
            if let cover = book.cover {
                CoverImage(request: server.request(cover)) { cloth }
            } else {
                cloth
            }
            // Spine: a darker strip and a crease along the binding edge.
            HStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.38), .black.opacity(0.08)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 12)
                Rectangle().fill(.white.opacity(0.22)).frame(width: 1)
                Spacer()
            }
            if book.strokes > 0 {
                Ribbon().fill(Color(red: 0.92, green: 0.33, blue: 0.3))
                    .frame(width: 16, height: 30)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
                    .padding(.trailing, 14)
            }
        }
        .frame(width: height * book.kind.aspect, height: height)
        .clipShape(shape)
        .overlay(shape.stroke(.white.opacity(0.14)))
        .shadow(color: .black.opacity(0.45), radius: 10, x: 4, y: 8)
    }

    private var cloth: some View {
        let hue = Double(book.path.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value } % 360) / 360
        return ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(hue: hue, saturation: 0.45, brightness: 0.62), Color(hue: hue, saturation: 0.55, brightness: 0.34)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: 0) {
                Rectangle().fill(.white.opacity(0.5)).frame(width: 28, height: 1.5).padding(.bottom, 12)
                Text(book.name).font(.system(size: height * 0.085, weight: .semibold, design: .serif))
                    .foregroundStyle(.white).lineLimit(5).minimumScaleFactor(0.7)
                Spacer()
                Image(systemName: book.kind.symbol).font(.system(size: height * 0.08)).foregroundStyle(.white.opacity(0.6))
            }
            .padding(.leading, 24).padding(.trailing, 14).padding(.vertical, 18)
        }
    }
}

private struct Ribbon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - rect.width * 0.45))
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
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.04))
                RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                VStack(spacing: 10) {
                    if failed { Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(.orange) }
                    else { ProgressView().tint(.white) }
                    Text(failed ? "만들지 못함" : "책으로 만드는 중").font(.caption.weight(.medium))
                }
            }
            .frame(width: coverHeight * book.kind.aspect, height: coverHeight)
            .padding(.bottom, 22)
            Text(((book.source as NSString).lastPathComponent as NSString).deletingPathExtension)
                .font(.subheadline.weight(.semibold)).lineLimit(2)
            Text(failed ? (book.error ?? "변환 실패") : "맥에서 변환 중").font(.caption).foregroundStyle(.white.opacity(0.62)).lineLimit(2)
        }
        .frame(width: coverHeight * book.kind.aspect, alignment: .leading)
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
                    Text("이어서 쓰기").font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.65))
                    Text(book.name).font(.system(.largeTitle, design: .serif).weight(.semibold)).lineLimit(2)
                    Label(details, systemImage: book.kind.symbol).font(.callout).foregroundStyle(.white.opacity(0.72))
                    Label("펼치기", systemImage: "book").font(.headline)
                        .padding(.horizontal, 22).frame(height: 46)
                        .background(.white.opacity(0.16), in: Capsule())
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
