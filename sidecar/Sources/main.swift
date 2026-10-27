import AppKit
import SwiftUI
import QuartzCore
import Carbon
import UniformTypeIdentifiers

private let accent = NSColor(calibratedRed: 0.12, green: 0.36, blue: 0.85, alpha: 1)

final class InkCanvas: NSView {
    let document: InkDocument
    weak var controller: InkController?
    var current: InkStroke?
    private var erasing = false
    private let backingStore = InkBackingStore()
    private let livePath = InkLivePath()
    private var predictor = InkPredictor()
    /// Drawn past the last input point while the pen moves; cleared when samples stop coming.
    private var predictedTip: NSPoint?
    private var predictedRect = NSRect.null
    private var previousErasePoint: InkPoint?
    private var inkCursor: NSCursor = .crosshair
    private var strokeCursor: NSCursor = .crosshair
    func updateCursor() {
        guard let controller else { return }
        inkCursor = InkCursor.make(tool: controller.tool, color: controller.color.nsColor,
                                   width: controller.lineWidth, eraserRadius: controller.eraserRadius,
                                   eraserMode: controller.eraserMode)
        strokeCursor = InkCursor.make(tool: controller.tool, color: controller.color.nsColor,
                                      width: controller.lineWidth, eraserRadius: controller.eraserRadius,
                                      eraserMode: controller.eraserMode, showTool: false)
        window?.invalidateCursorRects(for: self)
    }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init(frame: NSRect, document: InkDocument, controller: InkController) {
        self.document = document
        self.controller = controller
        super.init(frame: frame)
        setAccessibilityLabel("투명 필기판")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)
        NSGraphicsContext.current?.shouldAntialias = true
        if let image = backingStore.image(strokes: document.strokes, size: bounds.size,
                                          scale: window?.backingScaleFactor ?? 2) {
            NSGraphicsContext.current?.cgContext.draw(image, in: bounds)
        } else {
            for stroke in document.strokes { render(stroke, size: bounds.size) }
        }
        if let stroke = current {
            livePath.update(stroke, size: bounds.size)
            if let predictedTip, let ahead = livePath.path.copy() as? NSBezierPath {
                ahead.line(to: predictedTip)
                render(stroke, size: bounds.size, path: ahead)
            } else {
                render(stroke, size: bounds.size, path: livePath.path)
            }
        }
    }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: current != nil || erasing ? strokeCursor : inkCursor)
    }
    private func position(_ event: NSEvent) -> InkPoint {
        let point = convert(event.locationInWindow, from: nil)
        return InkPoint(x: min(1, max(0, point.x / max(1, bounds.width))),
                        y: min(1, max(0, point.y / max(1, bounds.height))))
    }
    override func mouseDown(with event: NSEvent) {
        guard let controller, controller.acceptingInk else { return }
        controller.focusInkCanvas()
        if controller.dismissQuickTools() { return }
        if controller.tool == .eraser {
            erasing = true
            previousErasePoint = nil
            document.beginErase()
            erase(at: position(event))
        } else {
            current = InkStroke(tool: controller.tool, color: controller.color,
                                width: controller.lineWidth * (controller.tool == .highlighter ? 6 : 1),
                                points: [position(event)])
            setNeedsDisplay(livePath.update(current!, size: bounds.size).intersection(bounds))
            predictor.reset()
            predict(event)
        }
        strokeCursor.set()
    }
    override func mouseDragged(with event: NSEvent) {
        let point = position(event)
        if erasing { erase(at: point); return }
        guard current != nil else { return }
        if current?.tool == .arrow, let first = current?.points.first { current?.points = [first, point] }
        else if let last = current?.points.last {
            let distance = hypot((point.x - last.x) * bounds.width, (point.y - last.y) * bounds.height)
            if distance > 0.5 && current!.points.count < 20000 { current?.points.append(point) }
        }
        let dirty = livePath.update(current!, size: bounds.size)
        if !dirty.isNull { setNeedsDisplay(dirty.intersection(bounds)) }
        predict(event)
    }
    private func predict(_ event: NSEvent) {
        guard let stroke = current, stroke.tool != .arrow, let last = stroke.points.last else { return clearPrediction() }
        let point = convert(event.locationInWindow, from: nil)
        predictor.add(InkPoint(x: point.x, y: point.y), at: event.timestamp)
        let tip = stroke.points.count < 2 ? nil : predictor.predicted().map { NSPoint(x: $0.x, y: $0.y) }
        guard tip != predictedTip else { return }
        setNeedsDisplay(predictedRect)
        predictedTip = tip
        predictedRect = .null
        if let tip {
            let end = NSPoint(x: last.x * bounds.width, y: last.y * bounds.height)
            let padding = stroke.width / 2 + 2
            predictedRect = NSRect(x: min(end.x, tip.x), y: min(end.y, tip.y), width: abs(tip.x - end.x),
                                   height: abs(tip.y - end.y)).insetBy(dx: -padding, dy: -padding).intersection(bounds)
            setNeedsDisplay(predictedRect)
        }
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(clearPrediction), object: nil)
        if tip != nil {
            perform(#selector(clearPrediction), with: nil, afterDelay: InkPredictor.lead * 1.5, inModes: [.common])
        }
    }
    @objc private func clearPrediction() {
        guard predictedTip != nil else { return }
        setNeedsDisplay(predictedRect)
        predictedTip = nil
        predictedRect = .null
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        finishStroke()
        inkCursor.set()
    }
    override func rightMouseDown(with event: NSEvent) { controller?.setDrawing(false) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) { controller?.setDrawing(false) }
        else { super.keyDown(with: event) }
    }
    private func erase(at point: InkPoint) {
        guard let controller else { return }
        let changed = document.erase(at: point, from: previousErasePoint, canvasWidth: bounds.width, canvasHeight: bounds.height,
                                     radius: controller.eraserRadius, mode: controller.eraserMode)
        previousErasePoint = point
        if changed { invalidateInk() }
    }
    func invalidateInk() { backingStore.invalidate(); needsDisplay = true }
    func finishStroke() {
        let hadInput = current != nil || erasing
        clearPrediction()
        if let stroke = current {
            livePath.update(stroke, size: bounds.size)
            if document.add(stroke) {
                backingStore.append(stroke, size: bounds.size, scale: window?.backingScaleFactor ?? 2)
            }
            current = nil
            let padding = stroke.width / 2 + 2
            setNeedsDisplay(livePath.path.bounds.insetBy(dx: -padding, dy: -padding).intersection(bounds))
        }
        if erasing { document.endErase(); erasing = false; previousErasePoint = nil }
        if hadInput { window?.invalidateCursorRects(for: self) }
        controller?.refreshControls()
    }
}

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class InkColorButton: NSButton {
    var inkColor = NSColor.controlAccentColor
    override func draw(_ dirtyRect: NSRect) {
        let circle = NSRect(x: bounds.midX - 11, y: bounds.midY - 11, width: 22, height: 22)
        inkColor.setFill()
        NSBezierPath(ovalIn: circle).fill()
        let edge = NSBezierPath(ovalIn: circle)
        NSColor.black.withAlphaComponent(0.18).setStroke(); edge.lineWidth = 0.6; edge.stroke()
        if state == .on {
            let ring = NSBezierPath(ovalIn: circle.insetBy(dx: -4, dy: -4))
            NSColor.labelColor.setStroke(); ring.lineWidth = 1.5; ring.stroke()
            let check = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .bold))?
                .withSymbolConfiguration(.init(paletteColors: [inkColor.inkIsLight ? .black : .white]))
            check?.draw(in: NSRect(x: bounds.midX - 5, y: bounds.midY - 5, width: 10, height: 10))
        }
    }
}

final class PassivePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class ToolPalettePanel: NSPanel {
    var onDismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) { onDismiss?() }
        else { super.keyDown(with: event) }
    }
}

final class PracticeView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 12
        let text = "화면 위에 바로 쓰기\n\n1. 도구 막대에서 ‘필기 시작’을 누르세요.\n2. 이 문장에 밑줄을 긋거나 화살표를 그려 보세요.\n3. ‘조작으로’로 바꾼 뒤 아래 버튼을 눌러 보세요.\n\n아이패드에서는 Sidecar로 맥 화면을 미러링한 뒤\nApple Pencil로 같은 동작을 하면 됩니다."
        text.draw(in: NSRect(x: 46, y: 125, width: bounds.width - 92, height: bounds.height - 165),
                  withAttributes: [.font: NSFont.systemFont(ofSize: 21), .foregroundColor: NSColor.labelColor,
                                   .paragraphStyle: paragraph])
    }
}

final class InkController: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    var tool: InkTool = .pen
    private var inkSettings: InkToolSettings = UserDefaults.standard.data(forKey: "inkToolSettings")
        .flatMap { try? JSONDecoder().decode(InkToolSettings.self, from: $0) } ?? InkToolSettings() {
        didSet {
            if let data = try? JSONEncoder().encode(inkSettings) { UserDefaults.standard.set(data, forKey: "inkToolSettings") }
        }
    }
    private var inkTool: InkTool { tool == .eraser ? lastInkTool : tool }
    var color: InkColor {
        get { inkSettings[inkTool].color }
        set { inkSettings[inkTool].color = newValue }
    }
    var lineWidth: Double {
        get { inkSettings[inkTool].width }
        set { inkSettings[inkTool].width = newValue }
    }
    var eraserMode = EraserMode(rawValue: UserDefaults.standard.integer(forKey: "eraserMode")) ?? .stroke
    private var eraserSizeIndex = 1
    var eraserRadius: Double { [8, 14, 24][eraserSizeIndex] }
    private var drawing = false
    private var temporaryControl = false
    private var showingDialog = false
    var acceptingInk: Bool { drawing && !temporaryControl && !showingDialog }
    private var documents: [CGDirectDisplayID: InkDocument] = [:]
    private var selectedDisplay: CGDirectDisplayID?
    private var followsDefaultScreen = true
    private var overlay: OverlayPanel?
    private var canvas: InkCanvas?
    private var toolbar: OverlayPanel!
    private var modeButton: NSButton!
    private var collapseButton: NSButton!
    private var backgroundButton: NSButton!
    private var opaqueTools = UserDefaults.standard.bool(forKey: "opaqueTools")
    private var toolbarRoot: NSStackView!
    private var contextWidthConstraint: NSLayoutConstraint!
    private var toolbarAnimating = false
    private var detailRows: [NSView] = []
    private var toolbarCollapsed = UserDefaults.standard.bool(forKey: "toolbarCollapsed")
    private var lastInkTool: InkTool = .pen
    private var undoButton: NSButton!
    private var redoButton: NSButton!
    private var toolControl: NSSegmentedControl!
    private var toolButtons: [InkToolButton] = []
    private var stylePopover: NSPopover?
    private var stylePreview: InkStylePreview?
    private var styleValue: NSTextField?
    private var styleColors: [NSButton] = []
    private var styleButton: NSButton!
    private var sizeControl: NSSegmentedControl!
    private var colorRow: NSStackView!
    private var eraserModeControl: NSSegmentedControl!
    private var statusLabel: NSTextField!
    private var paletteButtons: [NSButton] = []
    private var statusItem: NSStatusItem!
    private var practiceWindow: NSWindow?
    private var practiceClicks = 0
    private var modifierTimer: Timer?
    private var pencilEventMonitor: Any?
    private let pencilDiagnostics = PencilDiagnostics()
    private var quickTools: ToolPalettePanel?
    private var hotKeys: [EventHotKeyRef] = []
    private var hotKeyHandler: EventHandlerRef?
    private var failedHotKeys = false
    private let palette: [(String, InkColor)] = [
        ("파랑", InkColor(red: 0.12, green: 0.36, blue: 0.85)),
        ("빨강", InkColor(red: 0.88, green: 0.16, blue: 0.23)),
        ("초록", InkColor(red: 0.1, green: 0.57, blue: 0.32)),
        ("노랑", InkColor(red: 0.98, green: 0.77, blue: 0.12)),
        ("검정", InkColor(red: 0.08, green: 0.09, blue: 0.12)),
        ("흰색", InkColor(red: 1, green: 1, blue: 1)),
        ("보라", InkColor(red: 0.58, green: 0.39, blue: 0.85)),
        ("분홍", InkColor(red: 0.89, green: 0.5, blue: 0.65)),
        ("주황", InkColor(red: 0.92, green: 0.56, blue: 0.24)),
        ("하늘", InkColor(red: 0.32, green: 0.73, blue: 0.83)),
        ("연두", InkColor(red: 0.64, green: 0.78, blue: 0.4)),
        ("회색", InkColor(red: 0.52, green: 0.54, blue: 0.59))
    ]
    private var screens: [NSScreen] { NSScreen.screens }
    private func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
    }
    private var selectedScreen: NSScreen? { screens.first { displayID($0) == selectedDisplay } }
    private var document: InkDocument? { selectedDisplay.flatMap { documents[$0] } }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenus()
        buildToolbar()
        registerHotKeys()
        pencilEventMonitor = NSEvent.addLocalMonitorForEvents(matching: PencilDiagnostics.eventMask) { [weak self] event in
            guard let self else { return event }
            self.pencilDiagnostics.record(event)
            guard event.type == .changeMode, self.acceptingInk else { return event }
            self.pencilDoubleTap()
            return nil
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                    name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceChanged),
                    name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        screensChanged()
        modifierTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self else { return }
            // F18 and navigation keys also set .function; only Fn should suspend ink.
            let held = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Function))
            if self.temporaryControl != held {
                self.canvas?.finishStroke()
                self.temporaryControl = held
                self.updateInput()
                self.refreshControls()
                if !held && self.drawing { self.focusInkCanvas() }
            }
        }
        resizeToolbar()
        showToolbar()
    }
    private func buildMenus() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let menu = NSMenu()
        let items: [(String, Selector, String)] = [
            ("도구 막대 보기", #selector(showToolbar), "0"),
            ("필기 연습장", #selector(showPractice), ""),
            ("빠른 도구", #selector(showQuickTools), ""),
            ("Pencil 입력 진단", #selector(showPencilDiagnostics), ""),
            ("최근 진단 결과", #selector(showDiagnosticResult), ""),
            ("사용 방법", #selector(showHelp), "?"),
            ("InkBridge 종료", #selector(quit), "q")
        ]
        for (title, action, key) in items {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self; menu.addItem(item)
        }
        appItem.submenu = menu; main.addItem(appItem); NSApp.mainMenu = main
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "pencil.tip.crop.circle", accessibilityDescription: "InkBridge")
        let statusMenu = NSMenu()
        for (title, action) in [("필기 / 조작 전환  ⌥⌘D", #selector(toggleDrawing)),
                                ("도구 막대 보기", #selector(showToolbar)),
                                ("빠른 도구", #selector(showQuickTools)),
                                ("Pencil 입력 진단", #selector(showPencilDiagnostics)),
                                ("전체 지우기", #selector(clearDrawing)), ("종료", #selector(quit))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; statusMenu.addItem(item)
        }
        statusItem.menu = statusMenu
    }
    private func button(_ title: String, _ action: Selector, symbol: String? = nil) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.font = .systemFont(ofSize: 13, weight: .medium)
        if let symbol { button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); button.imagePosition = .imageLeading }
        button.setAccessibilityLabel(title)
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return button
    }
    private func iconButton(_ label: String, _ action: Selector, symbol: String) -> NSButton {
        let b = button(label, action, symbol: symbol)
        b.imagePosition = .imageOnly
        b.isBordered = false
        b.toolTip = label
        b.widthAnchor.constraint(equalToConstant: 44).isActive = true
        return b
    }
    private func buildToolbar() {
        toolbar = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 166),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        toolbar.title = "InkBridge · 화면 필기 (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "개발"))"
        toolbar.isMovableByWindowBackground = true
        toolbar.hidesOnDeactivate = false
        toolbar.isFloatingPanel = true
        toolbar.becomesKeyOnlyIfNeeded = true
        toolbar.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        toolbar.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        toolbar.appearance = NSAppearance(named: .aqua)
        toolbar.backgroundColor = .clear
        toolbar.isOpaque = false
        toolbar.hasShadow = false
        let content = GlassGrooveView()
        content.wantsLayer = true
        toolbar.contentView = toolSurface(content: content, cornerRadius: 26)
        let root = NSStackView()
        toolbarRoot = root
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor), root.bottomAnchor.constraint(equalTo: content.bottomAnchor)])

        let top = NSStackView(); top.spacing = 8
        modeButton = button("필기 시작", #selector(toggleDrawing), symbol: "pencil.tip")
        modeButton.widthAnchor.constraint(equalToConstant: 100).isActive = true
        top.addArrangedSubview(modeButton)
        let toolImages = ["pencil.tip", "highlighter", "arrow.up.right", "eraser.fill"].map {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)!
        }
        toolControl = NSSegmentedControl(images: toolImages, trackingMode: .selectOne,
                                         target: self, action: #selector(pickTool))
        toolControl.controlSize = .large; toolControl.selectedSegment = 0
        toolControl.setAccessibilityLabel("필기 도구")
        for (index, name) in ["펜", "형광펜", "화살표", "지우개"].enumerated() {
            toolControl.setToolTip(name, forSegment: index)
            toolControl.setWidth(32, forSegment: index)
            toolImages[index].accessibilityDescription = name
        }
        let tools = NSStackView(); tools.spacing = 4
        for (index, entry) in [("펜", "pencil.tip"), ("형광펜", "highlighter"),
                               ("화살표", "arrow.up.right"), ("지우개", "eraser")].enumerated() {
            let b = InkToolButton(title: entry.0, target: self, action: #selector(selectToolbarTool))
            b.symbol = entry.1; b.tag = index; b.isBordered = false
            b.setButtonType(.toggle)
            b.setAccessibilityLabel(entry.0)
            b.toolTip = index == 3 ? "지우개 · 부분 또는 획 단위" : entry.0 + " · 선택한 도구를 다시 누르면 설정"
            b.widthAnchor.constraint(equalToConstant: 54).isActive = true
            b.heightAnchor.constraint(equalToConstant: 54).isActive = true
            tools.addArrangedSubview(b); toolButtons.append(b)
        }
        top.addArrangedSubview(tools); detailRows.append(tools)
        let topSpacer = NSView(); topSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        top.addArrangedSubview(topSpacer)
        undoButton = iconButton("실행 취소", #selector(undoDrawing), symbol: "arrow.uturn.backward")
        redoButton = iconButton("다시 실행", #selector(redoDrawing), symbol: "arrow.uturn.forward")
        for item in [undoButton!, redoButton!] { top.addArrangedSubview(item); detailRows.append(item) }
        let more = iconButton("더보기 · 저장 및 화면", #selector(showMore), symbol: "ellipsis")
        top.addArrangedSubview(more); detailRows.append(more)
        backgroundButton = iconButton("불투명 모드", #selector(toggleToolBackground), symbol: "circle.lefthalf.filled")
        top.addArrangedSubview(backgroundButton)
        updateBackgroundButton()
        collapseButton = iconButton("도구 막대 접기", #selector(toggleToolbar), symbol: "chevron.up")
        top.addArrangedSubview(collapseButton)
        root.addArrangedSubview(top)
        top.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -28).isActive = true

        let context = NSStackView(); context.spacing = 10
        colorRow = NSStackView(); colorRow.spacing = 0
        for (index, entry) in palette.prefix(6).enumerated() {
            let b = InkColorButton(title: "", target: self, action: #selector(pickColor))
            b.setButtonType(.toggle)
            b.inkColor = entry.1.nsColor
            b.tag = index; b.isBordered = false
            b.setAccessibilityLabel(entry.0); b.toolTip = entry.0
            b.widthAnchor.constraint(equalToConstant: 44).isActive = true
            b.heightAnchor.constraint(equalToConstant: 44).isActive = true
            paletteButtons.append(b); colorRow.addArrangedSubview(b)
        }
        context.addArrangedSubview(colorRow)
        eraserModeControl = NSSegmentedControl(labels: ["부분 지우기", "획 지우기"], trackingMode: .selectOne,
                                               target: self, action: #selector(pickEraserMode))
        eraserModeControl.controlSize = .large
        eraserModeControl.selectedSegmentBezelColor = .systemPink
        eraserModeControl.setAccessibilityLabel("지우개 방식")
        eraserModeControl.isHidden = true
        context.addArrangedSubview(eraserModeControl)
        sizeControl = NSSegmentedControl(images: [2.0, 4, 7].map { sizeIcon($0) }, trackingMode: .selectOne,
                                         target: self, action: #selector(pickSize))
        sizeControl.controlSize = .large
        for index in 0..<3 { sizeControl.setWidth(40, forSegment: index) }
        sizeControl.heightAnchor.constraint(equalToConstant: 44).isActive = true
        sizeControl.setAccessibilityLabel("굵기 또는 지우개 크기")
        context.addArrangedSubview(sizeControl)
        styleButton = button("4 pt", #selector(showStyleSettings), symbol: "slider.horizontal.3")
        styleButton.widthAnchor.constraint(equalToConstant: 85).isActive = true
        context.addArrangedSubview(styleButton)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        context.addArrangedSubview(spacer)
        context.addArrangedSubview(iconButton("원형 도구 열기", #selector(showQuickTools), symbol: "circle.grid.2x2"))
        root.addArrangedSubview(context); detailRows.append(context)
        contextWidthConstraint = context.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -28)
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        statusLabel.textColor = .labelColor
        root.addArrangedSubview(statusLabel); detailRows.append(statusLabel)
    }
    private func toolSurface(content: NSView, cornerRadius: CGFloat) -> NSView {
        content.removeFromSuperview()
        if #available(macOS 26.0, *), !opaqueTools {
            content.translatesAutoresizingMaskIntoConstraints = true
            let glass = WaterGlassView()
            glass.style = .clear
            glass.cornerRadius = cornerRadius
            glass.contentView = content
            return glass
        }
        let glass = NSVisualEffectView()
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = cornerRadius
        glass.layer?.masksToBounds = true
        glass.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            content.topAnchor.constraint(equalTo: glass.topAnchor),
            content.bottomAnchor.constraint(equalTo: glass.bottomAnchor)
        ])
        return glass
    }
    private func updateBackgroundButton() {
        let label = opaqueTools ? "불투명 모드 끄기" : "불투명 모드 켜기"
        backgroundButton.setAccessibilityLabel(label)
        backgroundButton.toolTip = label + " · 도구 배경 흐림"
        backgroundButton.contentTintColor = opaqueTools ? accent : .labelColor
        backgroundButton.state = opaqueTools ? .on : .off
    }
    @objc private func toggleToolBackground() {
        opaqueTools.toggle()
        UserDefaults.standard.set(opaqueTools, forKey: "opaqueTools")
        dismissQuickTools()
        let content = toolbarRoot.superview!
        toolbar.contentView = toolSurface(content: content, cornerRadius: 26)
        updateBackgroundButton()
        resizeToolbar()
        if drawing { focusInkCanvas() }
    }
    private func sizeIcon(_ diameter: Double, eraser: Bool = false) -> NSImage {
        NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            NSColor.labelColor.setFill()
            if eraser {
                NSBezierPath(ovalIn: NSRect(x: 10 - diameter / 2, y: 10 - diameter / 2,
                                            width: diameter, height: diameter)).fill()
            } else {
                NSBezierPath(roundedRect: NSRect(x: 1, y: 10 - diameter / 2, width: 18, height: diameter),
                             xRadius: diameter / 2, yRadius: diameter / 2).fill()
            }
            return true
        }
    }
    @objc private func showMore(_ sender: NSButton) {
        let menu = NSMenu()
        for (title, action) in [("필기 저장…", #selector(saveDrawing)), ("필기 열기…", #selector(loadDrawing)),
                                ("PNG 내보내기…", #selector(exportPNG)), ("모두 지우기", #selector(clearDrawing))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let displayMenu = NSMenu()
        for screen in screens {
            let item = NSMenuItem(title: screen.localizedName, action: #selector(pickScreen(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = NSNumber(value: displayID(screen))
            item.state = displayID(screen) == selectedDisplay ? .on : .off
            displayMenu.addItem(item)
        }
        let displays = NSMenuItem(title: "필기할 화면", action: nil, keyEquivalent: "")
        displays.submenu = displayMenu; menu.addItem(displays)
        for (title, action) in [("필기 연습장", #selector(showPractice)), ("사용 방법", #selector(showHelp)),
                                ("종료", #selector(quit))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
        if drawing { focusInkCanvas() }
    }
    private func resizeToolbar(animated: Bool = false) {
        let topLeft = NSPoint(x: toolbar.frame.minX, y: toolbar.frame.maxY)
        contextWidthConstraint.isActive = !toolbarCollapsed
        for view in detailRows { view.isHidden = toolbarCollapsed }
        let label = toolbarCollapsed ? "도구 막대 펼치기" : "도구 막대 접기"
        collapseButton.image = NSImage(systemSymbolName: toolbarCollapsed ? "chevron.down" : "chevron.up", accessibilityDescription: nil)
        collapseButton.setAccessibilityLabel(label); collapseButton.toolTip = label
        toolbarRoot.layoutSubtreeIfNeeded()
        let fitting = toolbarRoot.fittingSize
        let size = NSSize(width: max(toolbarCollapsed ? 252 : 570, fitting.width), height: fitting.height)
        let area = (toolbar.screen ?? selectedScreen)?.visibleFrame ?? toolbar.frame
        let origin = NSPoint(x: min(max(topLeft.x, area.minX), max(area.minX, area.maxX - size.width)),
                             y: max(area.minY, min(topLeft.y, area.maxY) - size.height))
        let target = NSRect(origin: origin, size: size)
        guard animated else {
            toolbar.setFrame(target, display: true)
            for view in detailRows { view.alphaValue = 1 }
            collapseButton.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            toolbar.animator().setFrame(target, display: true)
        } completionHandler: { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                self.collapseButton.animator().alphaValue = 1
                for view in self.detailRows { view.animator().alphaValue = 1 }
            } completionHandler: { [weak self] in self?.toolbarAnimating = false }
        }
    }
    @objc private func toggleToolbar() {
        guard !toolbarAnimating else { return }
        canvas?.finishStroke()
        toolbarCollapsed.toggle()
        UserDefaults.standard.set(toolbarCollapsed, forKey: "toolbarCollapsed")
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            resizeToolbar()
        } else {
            toolbarAnimating = true
            if toolbarCollapsed {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.1
                    collapseButton.animator().alphaValue = 0
                    for view in detailRows { view.animator().alphaValue = 0 }
                } completionHandler: { [weak self] in self?.resizeToolbar(animated: true) }
            } else {
                collapseButton.alphaValue = 0
                for view in detailRows { view.alphaValue = 0 }
                resizeToolbar(animated: true)
            }
        }
        if drawing { focusInkCanvas() }
        toolbar.orderFrontRegardless()
    }
    @objc private func screensChanged() {
        canvas?.finishStroke()
        if selectedScreen == nil { followsDefaultScreen = true }
        if followsDefaultScreen {
            let sidecar = screens.first { $0.localizedName.localizedCaseInsensitiveContains("Sidecar") }
            let builtin = screens.first { CGDisplayIsBuiltin(displayID($0)) != 0 }
            selectedDisplay = (sidecar ?? builtin ?? screens.first).map(displayID)
        }
        rebuildOverlay()
        placeToolbar()
    }
    private func rebuildOverlay() {
        dismissQuickTools()
        overlay?.orderOut(nil)
        overlay?.contentView = nil
        overlay?.close()
        guard let screen = selectedScreen else { canvas = nil; overlay = nil; return }
        let id = displayID(screen)
        if documents[id] == nil { documents[id] = InkDocument() }
        let panel = OverlayPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.title = "InkBridge 투명 필기판"
        let view = InkCanvas(frame: NSRect(origin: .zero, size: screen.frame.size), document: documents[id]!, controller: self)
        view.autoresizingMask = [.width, .height]
        if #available(macOS 14.5, *) {
            let host = NSHostingView(rootView: PencilCanvas(canvas: view,
                recordPhase: { [weak self, weak view] phase in
                    guard let self, let view, self.canvas === view else { return }
                    self.pencilDiagnostics.recordGesture("SwiftUI 스퀴즈 \(phase)")
                }, squeezed: { [weak self, weak view] location in
                    guard let self, let view, self.canvas === view else { return }
                    self.pencilSqueeze(at: location)
                }))
            host.sizingOptions = []
            panel.contentView = host
        } else { panel.contentView = view }
        overlay = panel; canvas = view
        updateInput(); panel.orderFrontRegardless(); toolbar.orderFrontRegardless()
        if drawing { focusInkCanvas() }
        refreshControls()
    }
    private func placeToolbar() {
        guard let screen = selectedScreen else { return }
        let area = screen.visibleFrame
        toolbar.setFrameOrigin(NSPoint(x: area.midX - toolbar.frame.width / 2, y: area.maxY - toolbar.frame.height - 14))
    }
    @objc private func spaceChanged() { overlay?.orderFrontRegardless(); toolbar.orderFrontRegardless() }
    @objc private func pickScreen(_ sender: NSMenuItem) {
        followsDefaultScreen = false
        canvas?.finishStroke()
        selectedDisplay = (sender.representedObject as? NSNumber)?.uint32Value
        rebuildOverlay(); placeToolbar()
    }
    @objc private func pickTool() {
        canvas?.finishStroke()
        tool = [InkTool.pen, .highlighter, .arrow, .eraser][toolControl.selectedSegment]
        if tool != .eraser { lastInkTool = tool }
        setDrawing(true)
    }
    @objc private func selectToolbarTool(_ sender: NSButton) {
        if drawing, sender.tag == toolControl.selectedSegment, tool != .eraser {
            showStyleSettings(sender)
        } else {
            toolControl.selectedSegment = sender.tag
            pickTool()
        }
    }

    @objc private func showStyleSettings(_ sender: NSButton) {
        guard tool != .eraser else { return }
        if stylePopover?.isShown == true { stylePopover?.close(); return }
        beginDialog()
        let root = NSStackView()
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        let header = NSStackView(); header.spacing = 8
        let title = NSTextField(labelWithString: ["펜", "형광펜", "화살표"][toolControl.selectedSegment])
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        header.addArrangedSubview(title)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        header.addArrangedSubview(spacer)
        header.addArrangedSubview(iconButton("설정 닫기", #selector(closeStyleSettings), symbol: "xmark"))
        root.addArrangedSubview(header)
        header.widthAnchor.constraint(equalToConstant: 264).isActive = true
        let preview = InkStylePreview()
        preview.widthAnchor.constraint(equalToConstant: 264).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 70).isActive = true
        root.addArrangedSubview(preview); stylePreview = preview
        let widthRow = NSStackView(); widthRow.spacing = 12
        widthRow.addArrangedSubview(NSTextField(labelWithString: "굵기"))
        let value = NSTextField(labelWithString: "")
        value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        widthRow.addArrangedSubview(value); styleValue = value
        root.addArrangedSubview(widthRow)
        let slider = NSSlider(value: lineWidth, minValue: 1, maxValue: 8, target: self, action: #selector(adjustFineWidth))
        slider.isContinuous = true
        slider.setAccessibilityLabel("필기 굵기")
        slider.widthAnchor.constraint(equalToConstant: 264).isActive = true
        slider.heightAnchor.constraint(equalToConstant: 32).isActive = true
        root.addArrangedSubview(slider)
        root.addArrangedSubview(NSTextField(labelWithString: "색상"))
        styleColors = []
        for row in 0..<2 {
            let colors = NSStackView(); colors.spacing = 0
            for index in (row * 6)..<(row * 6 + 6) {
                let b = InkColorButton(title: "", target: self, action: #selector(pickColor))
                b.setButtonType(.toggle)
                b.inkColor = palette[index].1.nsColor; b.tag = index; b.isBordered = false
                b.setAccessibilityLabel(palette[index].0); b.toolTip = palette[index].0
                b.widthAnchor.constraint(equalToConstant: 44).isActive = true
                b.heightAnchor.constraint(equalToConstant: 44).isActive = true
                colors.addArrangedSubview(b); styleColors.append(b)
            }
            root.addArrangedSubview(colors)
        }
        let content = NSViewController(); content.view = root
        let popover = NSPopover()
        popover.contentViewController = content
        popover.behavior = .transient; popover.delegate = self
        popover.contentSize = NSSize(width: 296, height: root.fittingSize.height)
        stylePopover = popover
        refreshControls()
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    @objc private func closeStyleSettings() { stylePopover?.close() }

    @objc private func adjustFineWidth(_ sender: NSSlider) {
        lineWidth = (sender.doubleValue * 2).rounded() / 2
        canvas?.updateCursor(); refreshControls()
    }

    func popoverDidClose(_ notification: Notification) {
        stylePopover = nil; stylePreview = nil; styleValue = nil; styleColors = []
        endDialog()
    }
    func pencilDoubleTap() {
        guard drawing, !showingDialog else { return }
        canvas?.finishStroke()
        tool = tool == .eraser ? lastInkTool : .eraser
        toolControl.selectedSegment = [InkTool.pen, .highlighter, .arrow, .eraser].firstIndex(of: tool)!
        updateInput(); refreshControls()
    }
    func pencilSqueeze(at location: CGPoint?) {
        guard acceptingInk else { return }
        if dismissQuickTools() {
            focusInkCanvas()
            return
        }
        refreshControls()
        let point = location.flatMap { location -> NSPoint? in
            guard let overlay, let host = overlay.contentView else { return nil }
            return overlay.convertPoint(toScreen: host.convert(location, to: nil))
        } ?? NSEvent.mouseLocation
        presentQuickTools(around: point)
    }
    @objc private func showQuickTools() {
        setDrawing(true)
        presentQuickTools(around: NSEvent.mouseLocation)
    }
    @discardableResult func dismissQuickTools() -> Bool {
        guard let quickTools, quickTools.isVisible else { return false }
        quickTools.orderOut(nil)
        quickTools.contentView = nil
        quickTools.close()
        self.quickTools = nil
        return true
    }
    private func presentQuickTools(around point: NSPoint) {
        canvas?.finishStroke()
        if let quickTools, quickTools.isVisible {
            quickTools.orderFrontRegardless()
            return
        }
        let diameter: CGFloat = 236
        let area = selectedScreen?.visibleFrame ?? toolbar.frame
        let origin = NSPoint(x: min(max(point.x - diameter / 2, area.minX + 8), area.maxX - diameter - 8),
                             y: min(max(point.y - diameter / 2, area.minY + 8), area.maxY - diameter - 8))
        let panel = ToolPalettePanel(contentRect: NSRect(origin: origin, size: NSSize(width: diameter, height: diameter)),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "InkBridge 원형 도구"
        panel.isReleasedWhenClosed = false
        panel.onDismiss = { [weak self] in self?.dismissQuickTools(); self?.focusInkCanvas() }
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .aqua)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let content = NSView(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        content.wantsLayer = true
        panel.contentView = toolSurface(content: content, cornerRadius: diameter / 2)
        let entries = [("펜", "pencil.tip", 0), ("형광펜", "highlighter", 1),
                       ("화살표", "arrow.up.right", 2), ("지우개", "eraser.fill", 3),
                       ("파랑", "circle.fill", 10), ("빨강", "circle.fill", 11),
                       ("실행 취소", "arrow.uturn.backward", 12), ("닫기", "xmark", 13)]
        for (index, entry) in entries.enumerated() {
            let angle = CGFloat.pi / 2 - CGFloat(index) * .pi / 4
            let b = NSButton(frame: NSRect(x: diameter / 2 + cos(angle) * 82 - 23,
                                          y: diameter / 2 + sin(angle) * 82 - 23, width: 46, height: 46))
            b.title = ""; b.image = NSImage(systemSymbolName: entry.1, accessibilityDescription: entry.0)
            b.imagePosition = .imageOnly; b.isBordered = false
            b.target = self; b.action = #selector(pickQuickTool); b.tag = entry.2
            b.setAccessibilityLabel(entry.0); b.toolTip = entry.0
            b.wantsLayer = true
            b.layer?.cornerRadius = 23
            let selected = entry.2 == toolControl.selectedSegment
            b.layer?.backgroundColor = (selected ? (tool == .eraser ? NSColor.systemPink : accent).withAlphaComponent(0.9)
                                                        : NSColor.clear).cgColor
            b.contentTintColor = selected ? .white : (entry.2 == 10 ? accent : (entry.2 == 11 ? .systemRed : .black))
            content.addSubview(b)
        }
        let caption = NSTextField(labelWithString: ["펜", "형광펜", "화살표", "지우개"][toolControl.selectedSegment])
        caption.font = .systemFont(ofSize: 13, weight: .semibold)
        caption.textColor = tool == .eraser ? .systemPink : .labelColor
        caption.alignment = .center
        caption.frame = NSRect(x: 70, y: 108, width: 96, height: 20)
        content.addSubview(caption)
        quickTools = panel
        // Keep the PencilCanvas key so the next squeeze reaches its SwiftUI handler.
        focusInkCanvas()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
            panel.animator().alphaValue = 1
        }
    }
    @objc private func pickQuickTool(_ sender: NSButton) {
        dismissQuickTools()
        switch sender.tag {
        case 0...3: toolControl.selectedSegment = sender.tag; pickTool()
        case 10, 11:
            canvas?.finishStroke()
            if tool == .eraser { tool = lastInkTool }
            color = palette[sender.tag - 10].1; canvas?.updateCursor(); refreshControls()
        case 12: undoDrawing()
        default: break
        }
        focusInkCanvas()
    }
    @objc private func pickColor(_ sender: NSButton) {
        canvas?.finishStroke()
        if tool == .eraser { tool = lastInkTool }
        color = palette[sender.tag].1; canvas?.updateCursor(); refreshControls()
        if drawing, !showingDialog { focusInkCanvas() }
    }
    @objc private func pickSize() {
        let selection = sizeControl.selectedSegment
        canvas?.finishStroke()
        if tool == .eraser { eraserSizeIndex = selection }
        else { lineWidth = [2, 4, 7][selection] }
        canvas?.updateCursor(); refreshControls()
        if drawing { focusInkCanvas() }
    }
    @objc private func pickEraserMode() {
        let selection = eraserModeControl.selectedSegment
        canvas?.finishStroke()
        eraserMode = EraserMode(rawValue: selection)!
        UserDefaults.standard.set(eraserMode.rawValue, forKey: "eraserMode")
        canvas?.updateCursor(); refreshControls()
        if drawing { focusInkCanvas() }
    }
    @objc private func toggleDrawing() { setDrawing(!drawing) }
    func setDrawing(_ value: Bool) {
        canvas?.finishStroke(); if !value { dismissQuickTools() }; drawing = value; updateInput(); refreshControls()
        if value {
            focusInkCanvas()
        } else {
            toolbar.makeKeyAndOrderFront(nil)
        }
    }
    func focusInkCanvas() {
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        overlay?.makeKeyAndOrderFront(nil)
        overlay?.makeFirstResponder(canvas)
        toolbar.orderFrontRegardless()
    }
    private func updateInput() {
        overlay?.ignoresMouseEvents = !acceptingInk
        canvas?.updateCursor()
    }
    func refreshControls() {
        guard modeButton != nil else { return }
        modeButton.title = drawing ? (tool == .eraser ? "지우개" : "조작으로") : "필기 시작"
        modeButton.image = NSImage(systemSymbolName: drawing && tool == .eraser ? "eraser.fill" : "pencil.tip", accessibilityDescription: nil)
        modeButton.contentTintColor = drawing ? (tool == .eraser ? .systemPink : accent) : .labelColor
        let eraser = tool == .eraser
        colorRow.isHidden = eraser
        eraserModeControl.isHidden = !eraser
        eraserModeControl.selectedSegment = eraserMode.rawValue
        sizeControl.selectedSegmentBezelColor = eraser ? .systemPink : accent
        let actualWidth = eraser ? eraserRadius * 2 : lineWidth * (tool == .highlighter ? 6 : 1)
        styleButton.title = "\(actualWidth.formatted()) pt"
        styleButton.isEnabled = !eraser
        styleButton.setAccessibilityLabel(eraser ? "지우개 범위 \(actualWidth.formatted())포인트" : "굵기 \(actualWidth.formatted())포인트 · 색상과 굵기 설정")
        sizeControl.selectedSegment = eraser ? eraserSizeIndex : ([2.0, 4, 7].firstIndex(of: lineWidth) ?? -1)
        for index in 0..<3 {
            sizeControl.setImage(sizeIcon(eraser ? [6.0, 10, 15][index] : [2.0, 4, 7][index], eraser: eraser), forSegment: index)
            let value = Int(eraser ? [16.0, 28, 48][index] : [2.0, 4, 7][index] * (tool == .highlighter ? 6 : 1))
            sizeControl.setToolTip("\(value) pt", forSegment: index)
        }
        toolControl.selectedSegmentBezelColor = tool == .eraser ? .systemPink : accent
        toolControl.selectedSegment = [InkTool.pen, .highlighter, .arrow, .eraser].firstIndex(of: tool)!
        for (index, button) in toolButtons.enumerated() {
            button.state = index == toolControl.selectedSegment ? .on : .off
            button.inkTint = eraser ? .systemPink : color.nsColor
            button.needsDisplay = true
        }
        stylePreview?.inkColor = color.nsColor
        stylePreview?.lineWidth = actualWidth
        stylePreview?.highlighter = tool == .highlighter
        stylePreview?.needsDisplay = true
        styleValue?.stringValue = "\(actualWidth.formatted()) pt"
        modeButton.setAccessibilityLabel(drawing ? "조작으로 전환" : "필기 시작")
        undoButton.isEnabled = document?.canUndo ?? false; redoButton.isEnabled = document?.canRedo ?? false
        let selectedColor = palette.firstIndex { $0.1 == color }
        for (slot, b) in paletteButtons.enumerated() {
            var index = slot
            if slot == 5, let selectedColor, selectedColor >= 6 { index = selectedColor }
            b.tag = index
            (b as? InkColorButton)?.inkColor = palette[index].1.nsColor
            b.setAccessibilityLabel(palette[index].0); b.toolTip = palette[index].0
            b.state = palette[index].1 == color ? .on : .off
            b.needsDisplay = true
        }
        for (index, b) in styleColors.enumerated() {
            b.state = palette[index].1 == color ? .on : .off
            b.needsDisplay = true
        }
        let state = drawing ? (temporaryControl ? "Fn을 놓으면 필기로 복귀" : "필기 중") : "화면 조작 중"
        let display = selectedScreen?.localizedName.localizedCaseInsensitiveContains("Sidecar") == true ? "iPad" : "Mac"
        let toolName = ["펜", "형광펜", "화살표", eraserMode == .partial ? "부분 지우개" : "획 지우개"][toolControl.selectedSegment]
        statusLabel.stringValue = "InkBridge · \(display) · \(state) · \(toolName) · \(document?.strokes.count ?? 0)획\(failedHotKeys ? " · 단축키 충돌" : "")"
        statusLabel.toolTip = "⌥⌘D로 필기 전환 · Fn을 누르면 잠깐 화면 조작"
    }
    @objc private func undoDrawing() { canvas?.finishStroke(); document?.undo(); canvas?.invalidateInk(); refreshControls() }
    @objc private func redoDrawing() { canvas?.finishStroke(); document?.redo(); canvas?.invalidateInk(); refreshControls() }
    @objc private func clearDrawing() { canvas?.finishStroke(); document?.clear(); canvas?.invalidateInk(); refreshControls() }
    @objc private func showToolbar() {
        placeToolbar()
        if drawing { focusInkCanvas() }
        else { toolbar.makeKeyAndOrderFront(nil) }
        toolbar.orderFrontRegardless()
    }
    private func beginDialog() { canvas?.finishStroke(); showingDialog = true; updateInput(); NSApp.activate(ignoringOtherApps: true) }
    private func endDialog() {
        showingDialog = false; updateInput()
        if drawing { focusInkCanvas() }
        else { toolbar.makeKeyAndOrderFront(nil) }
        toolbar.orderFrontRegardless()
    }
    @objc private func saveDrawing() {
        guard let document else { return }
        beginDialog(); defer { endDialog() }
        let panel = NSSavePanel(); panel.title = "편집 가능한 필기 저장"
        panel.nameFieldStringValue = "강의 필기"
        panel.allowedContentTypes = [UTType(filenameExtension: "inkbridge") ?? .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try document.encoded().write(to: url, options: .atomic) }
        catch { showError(error) }
    }
    @objc private func loadDrawing() {
        guard let document else { return }
        beginDialog(); defer { endDialog() }
        if !document.strokes.isEmpty {
            let alert = NSAlert(); alert.messageText = "현재 화면의 필기를 바꿀까요?"
            alert.informativeText = "필요한 필기는 먼저 저장하세요. 불러온 문서로 현재 필기를 교체합니다."
            alert.addButton(withTitle: "불러오기"); alert.addButton(withTitle: "취소")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "inkbridge") ?? .json, .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let count = attributes[.size] as? NSNumber, count.intValue > 16 * 1024 * 1024 {
                throw NSError(domain: "InkBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "필기 파일은 16MB 이하여야 합니다."])
            }
            let strokes = try InkDocument.decode(Data(contentsOf: url))
            document.replace(with: strokes); canvas?.invalidateInk(); refreshControls()
        } catch { showError(error) }
    }
    @objc private func exportPNG() {
        guard let canvas else { return }
        beginDialog(); defer { endDialog() }
        let panel = NSSavePanel(); panel.title = "배경 없이 필기만 PNG로 저장"
        panel.nameFieldStringValue = "필기 레이어.png"; panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { return }
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        do { try data.write(to: url, options: .atomic) } catch { showError(error) }
    }
    private func showError(_ error: Error) { let alert = NSAlert(error: error); alert.runModal() }
    @objc private func showPractice() {
        setDrawing(false)
        if practiceWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 500),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "InkBridge 연습장"; window.isReleasedWhenClosed = false
            let view = PracticeView(frame: NSRect(x: 0, y: 0, width: 780, height: 500))
            let b = button("클릭 테스트 · \(practiceClicks)", #selector(testClick))
            b.frame = NSRect(x: 46, y: 45, width: 200, height: 40)
            view.addSubview(b); window.contentView = view; practiceWindow = window
        }
        if let area = selectedScreen?.visibleFrame {
            practiceWindow?.setFrameOrigin(NSPoint(x: area.midX - 390, y: area.midY - 285))
        }
        NSApp.activate(ignoringOtherApps: true); practiceWindow?.makeKeyAndOrderFront(nil)
        toolbar.orderFrontRegardless()
    }
    @objc private func testClick(_ sender: NSButton) { practiceClicks += 1; sender.title = "클릭 테스트 · \(practiceClicks)" }
    @objc private func showPencilDiagnostics() {
        setDrawing(true)
        pencilDiagnostics.start(below: toolbar.frame) { [weak self] in
            guard let self else { return "앱 종료" }
            let focus = NSApp.keyWindow === self.overlay ? "필기판" : "다른 창/없음"
            let glass: String
            if #available(macOS 26.0, *), let view = self.toolbar.contentView as? WaterGlassView {
                glass = view.tuningApplied ? "맑은 유리 조정 적용" : "기본 유리 효과"
            } else { glass = "기본 유리 효과" }
            return "앱 활성: \(NSApp.isActive ? "예" : "아니오") · 키 창: \(focus)\n필기 입력: \(self.acceptingInk ? "허용" : "중지") · Fn: \(self.temporaryControl ? "눌림" : "해제")\n유리: \(glass) · 투명도 줄이기: \(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? "켜짐" : "꺼짐")"
        }
        focusInkCanvas()
    }
    @objc private func showDiagnosticResult() {
        beginDialog(); defer { endDialog() }
        let alert = NSAlert()
        alert.messageText = "최근 Pencil 입력 진단"
        alert.informativeText = pencilDiagnostics.summary
        alert.runModal()
    }
    @objc private func showHelp() {
        beginDialog(); defer { endDialog() }
        let alert = NSAlert(); alert.messageText = "InkBridge 사용 방법"
        alert.informativeText = "맥 화면 위에 필기하는 개인용 앱입니다.\n\n아이패드: Sidecar로 ‘맥 내장 디스플레이 미러링’을 선택하고 Apple Pencil로 쓰세요. 아이패드에서 맥으로 AirPlay를 추가 연결할 필요는 없습니다.\n\n• 필기/조작 전환: ⌥⌘D 또는 도구 막대 버튼\n• 잠깐 웹페이지 조작: Fn을 누른 상태로 클릭·스크롤\n• 도구 막대 오른쪽 화살표: 접기 / 펼치기\n• Pencil 더블탭: 현재 필기 도구 ↔ 선택한 지우개 (Sidecar 설정에서 더블탭을 켠 경우)\n• Pencil Pro 스퀴즈: 원형 도구 열기 / 다시 누르면 닫기 (macOS 14.5 이상)\n• 제스처가 안 되면 메뉴의 ‘Pencil 입력 진단’을 실행하세요.\n• 지우개를 선택하면 부분/획 지우기와 범위 선택이 나타납니다.\n• 불투명 모드: 반원 버튼으로 도구 배경 흐림 전환\n• 저장·열기·PNG·화면 선택: 도구 막대의 더보기(…)\n• 취소/다시: ⌥⌘Z / ⌥⇧⌘Z\n• 전체 지우기: ⌥⌘⌫ (실행 취소 가능)\n• 필기 중 마우스 오른쪽 버튼: 조작으로 전환\n\n‘필기 저장’은 편집 가능한 .inkbridge 파일, ‘투명 PNG’는 필기만 저장합니다. 화면과 필기를 함께 남기려면 macOS의 ⌘⇧3 또는 ⌘⇧4를 쓰세요.\n\n필기는 화면 위치에 고정됩니다. 스크롤한 문장을 따라가지는 않습니다. Zoom 등에서는 창 하나 대신 전체 화면/영역을 공유하세요.\n\n앱은 디스플레이 설정을 바꾸지 않습니다. 실제 Pencil 지연·전체 화면 앱 호환성은 사용 환경에서 확인해 주세요."
        alert.addButton(withTitle: "확인"); alert.runModal()
    }
    private func registerHotKeys() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            if result == noErr {
                let controller = Unmanaged<InkController>.fromOpaque(userData).takeUnretainedValue()
                controller.handleHotKey(id.id)
            }
            return noErr
        }, 1, &event, pointer, &hotKeyHandler)
        guard result == noErr else { failedHotKeys = true; return }
        for (id, key, modifiers) in [(1, kVK_ANSI_D, cmdKey | optionKey),
                                      (2, kVK_Delete, cmdKey | optionKey),
                                      (3, kVK_ANSI_Z, cmdKey | optionKey),
                                      (4, kVK_ANSI_Z, cmdKey | optionKey | shiftKey)] {
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(UInt32(key), UInt32(modifiers), EventHotKeyID(signature: 0x494E4B42, id: UInt32(id)),
                                             GetApplicationEventTarget(), 0, &ref)
            if result == noErr, let ref { hotKeys.append(ref) } else { failedHotKeys = true }
        }
    }
    private func handleHotKey(_ id: UInt32) {
        guard !showingDialog else { return }
        switch id { case 1: toggleDrawing(); case 2: clearDrawing(); case 3: undoDrawing(); case 4: redoDrawing(); default: break }
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        canvas?.finishStroke()
        guard documents.values.contains(where: { !$0.strokes.isEmpty }) else { return .terminateNow }
        beginDialog(); defer { endDialog() }
        let alert = NSAlert(); alert.messageText = "필기를 저장하셨나요?"
        alert.informativeText = "저장하지 않은 필기는 앱을 종료하면 사라집니다."
        alert.addButton(withTitle: "돌아가기"); alert.addButton(withTitle: "종료")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) {
        modifierTimer?.invalidate()
        if let monitor = pencilEventMonitor { NSEvent.removeMonitor(monitor) }
        for ref in hotKeys { UnregisterEventHotKey(ref) }
        if let handler = hotKeyHandler { RemoveEventHandler(handler) }
    }
}

let application = NSApplication.shared
let controller = InkController()
application.setActivationPolicy(.regular)
application.delegate = controller
application.run()
