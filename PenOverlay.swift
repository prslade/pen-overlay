// PenOverlay: draw on top of everything with a pen tablet while screen recording.
//
// Hold the chord (default Control+Option) and draw with the pen. Everything stays up while you keep
// drawing, and after you pause it all holds for a moment, then fades together. With the chord released the overlay is fully click-through, so the pen and mouse behave
// normally. In Wacom Tablet Properties, map an ExpressKey to "Modifier..." with Control+Option so
// it holds the chord while pressed.
//
// Env: PENOVERLAY_CHORD (e.g. "ctrl+opt", "cmd+shift"), PENOVERLAY_HOLD, PENOVERLAY_FADE (seconds),
//      PENOVERLAY_WIDTH (points), PENOVERLAY_OPACITY (0 to 1).
// Flags: --log-events (print what the pen reports), --selftest (render and fade checks, then exit).

import AppKit
import QuartzCore

let environment = ProcessInfo.processInfo.environment
func tunable(_ key: String, _ fallback: Double) -> Double { environment[key].flatMap(Double.init) ?? fallback }
let holdSeconds = tunable("PENOVERLAY_HOLD", 1.5)   // a finished stroke stays fully visible this long
let fadeSeconds = tunable("PENOVERLAY_FADE", 0.8)   // then fades out over this long
let baseWidth = CGFloat(tunable("PENOVERLAY_WIDTH", 3.5))
let strokeOpacity = CGFloat(tunable("PENOVERLAY_OPACITY", 0.85))   // 1 = solid
let logEvents = CommandLine.arguments.contains("--log-events")

// MARK: - Chord

struct Chord {
    static let mask: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift, .maskSecondaryFn]
    let flags: CGEventFlags
    let label: String

    init(_ spec: String) {
        var flags: CGEventFlags = []
        var names: [String] = []
        for token in spec.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch token {
            case "ctrl", "control": flags.insert(.maskControl); names.append("⌃")
            case "opt", "option", "alt": flags.insert(.maskAlternate); names.append("⌥")
            case "cmd", "command": flags.insert(.maskCommand); names.append("⌘")
            case "shift": flags.insert(.maskShift); names.append("⇧")
            case "fn": flags.insert(.maskSecondaryFn); names.append("fn")
            default: break
            }
        }
        if flags.isEmpty { flags = [.maskControl, .maskAlternate]; names = ["⌃", "⌥"] }
        self.flags = flags
        self.label = names.joined()
    }

    /// True while exactly these modifiers are down. Reads global key state, so it needs no permission.
    var isHeld: Bool { CGEventSource.flagsState(.combinedSessionState).intersection(Chord.mask) == flags }
}

// MARK: - Strokes

/// Strokes drawn without a long pause share a session: they stay up together and fade together, so
/// drawing again resets the timeout for everything on screen, even ink that has started to fade.
final class Session {
    var lastActivity: CFTimeInterval
    var penDown = false

    init(at t: CFTimeInterval) { lastActivity = t }

    /// Fully opaque while the pen is down and for holdSeconds after the last activity, then fades linearly.
    func alpha(at t: CFTimeInterval) -> CGFloat {
        if penDown { return 1 }
        let age = t - lastActivity
        if age <= holdSeconds { return 1 }
        return max(0, 1 - CGFloat((age - holdSeconds) / fadeSeconds))
    }
}

final class Stroke {
    var points: [CGPoint] = []
    var widths: [CGFloat] = []
    var bounds = CGRect.null
    let color: NSColor
    let session: Session

    init(color: NSColor, session: Session) {
        self.color = color
        self.session = session
    }

    func append(_ p: CGPoint, _ width: CGFloat) {
        if let last = points.last, hypot(p.x - last.x, p.y - last.y) < 1 { return }
        points.append(p)
        widths.append(width)
        bounds = bounds.union(CGRect(x: p.x - width, y: p.y - width, width: width * 2, height: width * 2))
    }

    func alpha(at t: CFTimeInterval) -> CGFloat { session.alpha(at: t) }

    /// The stroke as short straight pieces along a curve through the midpoints of consecutive samples,
    /// with the samples as control points. That rounds corners and jitter, yet the line still ends on
    /// the pen tip, so there is no lag. Width eases between samples instead of stepping.
    func segments() -> [(from: CGPoint, to: CGPoint, width: CGFloat)] {
        let n = points.count
        guard n >= 2 else { return [] }
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        var out = [(from: CGPoint, to: CGPoint, width: CGFloat)]()
        out.append((points[0], mid(points[0], points[1]), widths[0]))
        for i in 1..<(n - 1) {
            let a = mid(points[i - 1], points[i]), b = mid(points[i], points[i + 1]), c = points[i]
            let w0 = (widths[i - 1] + widths[i]) / 2, w1 = (widths[i] + widths[i + 1]) / 2
            let steps = max(1, min(12, Int((hypot(b.x - a.x, b.y - a.y) / 1.5).rounded(.up))))
            var prev = a
            for s in 1...steps {
                let t = CGFloat(s) / CGFloat(steps), u = 1 - t
                let p = CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x,
                                y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
                out.append((prev, p, w0 + (w1 - w0) * ((CGFloat(s) - 0.5) / CGFloat(steps))))
                prev = p
            }
        }
        out.append((mid(points[n - 2], points[n - 1]), points[n - 1], widths[n - 1]))
        return out
    }
}

// MARK: - View

final class OverlayView: NSView {
    var strokes: [Stroke] = []
    var current: Stroke?
    private var session: Session?
    var color: NSColor
    var capturing = false
    var now: () -> CFTimeInterval = { CACurrentMediaTime() }
    private var timer: Timer?
    private var lastRegion = CGRect.null
    private var eraserActive = false

    init(frame: NSRect, color: NSColor) {
        self.color = color
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setCapturing(_ on: Bool) {
        capturing = on
        if !on { endStroke() }
        needsDisplay = true
    }

    func clear() {
        strokes.removeAll()
        current = nil
        session = nil
        invalidate()
    }

    // MARK: Input

    override func mouseDown(with event: NSEvent) {
        guard capturing else { return }
        if eraserActive { clear(); return }   // the pen's eraser end wipes everything
        beginStroke()
        add(event)
    }

    override func mouseDragged(with event: NSEvent) {
        if current != nil { add(event) }
    }

    override func mouseUp(with event: NSEvent) { endStroke() }

    override func tabletProximity(with event: NSEvent) {
        eraserActive = event.isEnteringProximity && event.pointingDeviceType == .eraser
    }

    private func add(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let isTablet = event.subtype == .tabletPoint
        let pressure = isTablet ? CGFloat(max(0.05, min(1, event.pressure))) : 1
        let width = isTablet ? baseWidth * (0.3 + 0.9 * pressure) : baseWidth
        extend(to: point, width: width)
        if logEvents {
            print("event type=\(event.type.rawValue) subtype=\(event.subtype.rawValue) pressure=\(event.pressure) x=\(Int(point.x)) y=\(Int(point.y))")
        }
    }

    /// Starts a stroke. It joins the current session and restarts its timeout as long as any of its ink
    /// is still visible, so ink that is mid-fade snaps back to solid. Once everything has faded, it
    /// starts a fresh session.
    func beginStroke() {
        let t = now()
        let s: Session
        if let existing = session, existing.alpha(at: t) > 0 {
            s = existing
        } else {
            s = Session(at: t)
            session = s
        }
        s.penDown = true
        s.lastActivity = t
        let stroke = Stroke(color: color, session: s)
        strokes.append(stroke)
        current = stroke
        startTimer()
    }

    func extend(to point: CGPoint, width: CGFloat) {
        current?.append(point, width)
        session?.lastActivity = now()
        invalidate()
    }

    func endStroke() {
        session?.penDown = false
        session?.lastActivity = now()
        current = nil
    }

    // MARK: Animation

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func tick() {
        let t = now()
        strokes.removeAll { $0.alpha(at: t) <= 0 }
        invalidate()
        if strokes.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Redraw only where strokes are now or were last frame; a full-screen redraw at 60 fps is wasteful.
    private func invalidate() {
        var region = CGRect.null
        for s in strokes { region = region.union(s.bounds) }
        let dirty = region.union(lastRegion)
        lastRegion = region
        if !dirty.isNull { setNeedsDisplay(dirty.insetBy(dx: -16, dy: -16)) }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if capturing {
            // Fully clear pixels let clicks fall through; a 1% tint makes the panel catch the pen.
            ctx.setFillColor(NSColor(white: 0, alpha: 0.01).cgColor)
            ctx.fill(dirtyRect)
        }
        let t = now()
        for stroke in strokes {
            let alpha = stroke.alpha(at: t)
            guard alpha > 0, !stroke.points.isEmpty, stroke.bounds.intersects(dirtyRect) else { continue }
            ctx.saveGState()
            ctx.setAlpha(alpha * strokeOpacity)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)   // fade the whole stroke as one, no joint darkening
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setStrokeColor(stroke.color.cgColor)
            ctx.setFillColor(stroke.color.cgColor)
            if stroke.points.count == 1 {   // a tap is a dot
                let p = stroke.points[0], w = stroke.widths[0]
                ctx.fillEllipse(in: CGRect(x: p.x - w / 2, y: p.y - w / 2, width: w, height: w))
            }
            for piece in stroke.segments() {
                ctx.setLineWidth(piece.width)
                ctx.move(to: piece.from)
                ctx.addLine(to: piece.to)
                ctx.strokePath()
            }
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
    }
}

// MARK: - Panel

/// Floats above everything (including full-screen apps) and never takes focus from the app being recorded.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

func makePanel(for screen: NSScreen, color: NSColor) -> (OverlayPanel, OverlayView) {
    let panel = OverlayPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
    panel.level = .screenSaver
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size), color: color)
    panel.contentView = view
    panel.setFrame(screen.frame, display: true)
    panel.orderFrontRegardless()
    return (panel, view)
}

// MARK: - App

let palette: [(name: String, color: NSColor)] = [
    ("Red", NSColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1)),
    ("Yellow", NSColor(srgbRed: 1.00, green: 0.80, blue: 0.00, alpha: 1)),
    ("Green", NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1)),
    ("Blue", NSColor(srgbRed: 0.04, green: 0.52, blue: 1.00, alpha: 1)),
    ("Pink", NSColor(srgbRed: 1.00, green: 0.18, blue: 0.57, alpha: 1)),
]

final class AppDelegate: NSObject, NSApplicationDelegate {
    let chord = Chord(environment["PENOVERLAY_CHORD"] ?? "ctrl+opt")
    var panels: [(panel: OverlayPanel, view: OverlayView)] = []
    var statusItem: NSStatusItem!
    var colorIndex = UserDefaults.standard.integer(forKey: "colorIndex")
    var active = false
    var paused = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !palette.indices.contains(colorIndex) { colorIndex = 0 }
        buildPanels()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        rebuildMenu()
        updateIcon()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let poll = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.pollChord() }
        RunLoop.main.add(poll, forMode: .common)
    }

    func buildPanels() {
        panels.forEach { $0.panel.close() }
        panels = NSScreen.screens.map { makePanel(for: $0, color: palette[colorIndex].color) }
    }

    @objc func screensChanged() {
        buildPanels()
        setActive(false)
    }

    func pollChord() {
        let held = !paused && chord.isHeld
        if held != active { setActive(held) }
    }

    func setActive(_ on: Bool) {
        active = on
        for (panel, view) in panels {
            panel.ignoresMouseEvents = !on
            view.setCapturing(on)
        }
        updateIcon()
    }

    func updateIcon() {
        let symbol = active ? "pencil.tip.crop.circle.fill" : (paused ? "pencil.slash" : "pencil.tip")
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Pen overlay") {
            statusItem.button?.image = image
            statusItem.button?.title = ""
        } else {
            statusItem.button?.title = active ? "✎●" : "✎"
        }
    }

    func rebuildMenu() {
        let menu = NSMenu()
        let hint = NSMenuItem(title: "Hold \(chord.label) and draw with the pen", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())
        let colors = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (i, entry) in palette.enumerated() {
            let item = NSMenuItem(title: entry.name, action: #selector(pickColor(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = i == colorIndex ? .on : .off
            sub.addItem(item)
        }
        colors.submenu = sub
        menu.addItem(colors)
        let clear = NSMenuItem(title: "Clear", action: #selector(clearAll), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
        let pause = NSMenuItem(title: paused ? "Resume" : "Pause (pen acts as a normal cursor)",
                               action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc func pickColor(_ sender: NSMenuItem) {
        colorIndex = sender.tag
        UserDefaults.standard.set(colorIndex, forKey: "colorIndex")
        panels.forEach { $0.view.color = palette[colorIndex].color }
        rebuildMenu()
    }

    @objc func clearAll() { panels.forEach { $0.view.clear() } }
    @objc func togglePause() {
        paused.toggle()
        if paused { setActive(false) }
        updateIcon()
        rebuildMenu()
    }
}

// MARK: - Self test

/// Renders a stroke offscreen and checks hold, fade, removal and the click-catching tint. No display needed.
func selfTest() -> Never {
    _ = NSApplication.shared
    var clock: CFTimeInterval = 100
    let view = OverlayView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), color: .red)
    view.now = { clock }
    let stroke = Stroke(color: .red, session: Session(at: clock))
    for i in 0..<40 { stroke.append(CGPoint(x: 40 + CGFloat(i) * 8, y: 100), 10) }
    view.strokes = [stroke]

    func alpha(of v: OverlayView, atX x: CGFloat, y: CGFloat) -> CGFloat {
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return -1 }
        v.cacheDisplay(in: v.bounds, to: rep)
        let px = Int(CGFloat(rep.pixelsWide) * x / v.bounds.width)
        let py = Int(CGFloat(rep.pixelsHigh) * (1 - y / v.bounds.height))
        return rep.colorAt(x: px, y: py)?.alphaComponent ?? -1
    }
    func alpha(atX x: CGFloat, y: CGFloat) -> CGFloat { alpha(of: view, atX: x, y: y) }

    var failures = 0
    func check(_ name: String, _ ok: Bool, _ detail: String) {
        print("\(ok ? "PASS" : "FAIL")  \(name)  (\(detail))")
        if !ok { failures += 1 }
    }

    let held = alpha(atX: 200, y: 100)
    check("stroke at full strength while held", abs(held - strokeOpacity) < 0.03, "alpha \(held), expected \(strokeOpacity)")
    clock += holdSeconds + fadeSeconds / 2
    let half = alpha(atX: 200, y: 100)
    check("stroke half faded midway", abs(half - strokeOpacity / 2) < 0.05, "alpha \(half), expected \(strokeOpacity / 2)")
    clock += fadeSeconds
    let gone = alpha(atX: 200, y: 100)
    check("stroke gone after fade", gone == 0, "alpha \(gone)")
    view.tick()
    check("faded stroke removed", view.strokes.isEmpty, "\(view.strokes.count) left")
    let idle = alpha(atX: 10, y: 10)
    check("idle overlay fully clear", idle == 0, "alpha \(idle)")
    view.capturing = true
    view.needsDisplay = true
    let tint = alpha(atX: 10, y: 10)
    check("capturing overlay has click-catching tint", tint > 0.005 && tint < 0.03, "alpha \(tint)")

    // A right-angle corner with wide spacing: a sharp polyline would cover the corner point, the
    // smoothed curve cuts inside it and still ends on the last sample.
    let cornerView = OverlayView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), color: .red)
    cornerView.now = { 100 }
    let bend = Stroke(color: .red, session: Session(at: 100))
    for p in [CGPoint(x: 140, y: 100), CGPoint(x: 200, y: 100), CGPoint(x: 200, y: 160)] { bend.append(p, 10) }
    cornerView.strokes = [bend]
    let corner = alpha(of: cornerView, atX: 200, y: 100)
    check("corner is rounded off", corner < 0.1, "alpha \(corner) at the sample point")
    let onCurve = alpha(of: cornerView, atX: 195, y: 105)
    check("curve passes inside the corner", abs(onCurve - strokeOpacity) < 0.03, "alpha \(onCurve)")
    let tip = alpha(of: cornerView, atX: 200, y: 158)
    check("stroke still reaches the pen tip", tip > 0.5, "alpha \(tip)")

    // Drawing again resets the timeout for everything on screen; ink already fading is never revived.
    var t: CFTimeInterval = 500
    let sessionView = OverlayView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), color: .red)
    sessionView.now = { t }
    func scribble() {
        sessionView.beginStroke()
        sessionView.extend(to: CGPoint(x: 50, y: 50), width: 6)
        sessionView.extend(to: CGPoint(x: 90, y: 70), width: 6)
        sessionView.endStroke()
    }
    scribble()                                   // first stroke ends at t = 500
    t = 500 + holdSeconds * 0.9
    scribble()                                   // second stroke, still inside the hold
    let secondEnded = t
    t = secondEnded + holdSeconds * 0.9           // 2.7 s after the first stroke, 1.35 s after the second
    let early = sessionView.strokes[0].alpha(at: t), late = sessionView.strokes[1].alpha(at: t)
    check("earlier stroke stays up while you keep drawing", early == 1 && late == 1, "alphas \(early), \(late)")
    t = secondEnded + holdSeconds + fadeSeconds / 2
    let fadeA = sessionView.strokes[0].alpha(at: t), fadeB = sessionView.strokes[1].alpha(at: t)
    check("all strokes fade together", abs(fadeA - 0.5) < 0.01 && fadeA == fadeB, "alphas \(fadeA), \(fadeB)")
    sessionView.beginStroke()                    // start drawing mid-fade: the old ink snaps back to solid
    let revivedFirst = sessionView.strokes[0].alpha(at: t), revivedNew = sessionView.strokes.last!.alpha(at: t)
    check("new stroke mid-fade brings old ink back to solid", revivedFirst == 1 && revivedNew == 1, "alphas \(revivedFirst), \(revivedNew)")
    sessionView.endStroke()
    t += holdSeconds + fadeSeconds + 0.1
    sessionView.tick()
    check("everything is gone after the last pause", sessionView.strokes.isEmpty, "\(sessionView.strokes.count) left")
    exit(failures == 0 ? 0 : 1)
}

// MARK: - Entry

if CommandLine.arguments.contains("--selftest") { selfTest() }
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
