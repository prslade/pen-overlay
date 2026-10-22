// PenOverlay: draw on top of everything with a pen tablet while screen recording.
//
// Hold the chord (default Control+Option) and draw with the pen. Everything stays up while you keep
// drawing, and after you pause it all holds for a moment, then fades together. With the chord released the overlay is fully click-through, so the pen and mouse behave
// normally. In Wacom Tablet Properties, map an ExpressKey to "Modifier..." with Control+Option so
// it holds the chord while pressed.
//
// Menu > "Keep drawings until trashed" stops the fade. While there is ink, the macOS Trash sits in the
// bottom-right corner (drag it anywhere); double-click it and everything is pulled in.
//
// Menu > "Open at login" adds the app to System Settings > General > Login Items. Install it first
// (`./build.sh install`) so the login item points at a copy that a rebuild does not delete.
//
// Env: PENOVERLAY_CHORD (e.g. "ctrl+opt", "cmd+shift"), PENOVERLAY_HOLD, PENOVERLAY_FADE (seconds),
//      PENOVERLAY_WIDTH (points), PENOVERLAY_OPACITY (0 to 1).
// Flags: --log-events (print what the pen reports), --selftest (render and fade checks, then exit),
//        --open-at-login on|off|status (change or print the login item, then exit).

import AppKit
import QuartzCore
import ServiceManagement

let environment = ProcessInfo.processInfo.environment
func tunable(_ key: String, _ fallback: Double) -> Double { environment[key].flatMap(Double.init) ?? fallback }
let holdSeconds = tunable("PENOVERLAY_HOLD", 1.5)   // a finished stroke stays fully visible this long
let fadeSeconds = tunable("PENOVERLAY_FADE", 0.8)   // then fades out over this long
let baseWidth = CGFloat(tunable("PENOVERLAY_WIDTH", 3.5))
let strokeOpacity = CGFloat(tunable("PENOVERLAY_OPACITY", 0.85))   // 1 = solid
let suckSeconds: CFTimeInterval = 0.4   // emptying the trash pulls the ink in over this long
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
    var persistent = false   // keep mode: the ink never fades

    init(at t: CFTimeInterval) { lastActivity = t }

    /// Fully opaque while the pen is down and for holdSeconds after the last activity, then fades linearly.
    func alpha(at t: CFTimeInterval) -> CGFloat {
        if penDown || persistent { return 1 }
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
    private(set) var keep = false
    var now: () -> CFTimeInterval = { CACurrentMediaTime() }
    private var timer: Timer?
    private var lastRegion = CGRect.null
    private var eraserActive = false
    private var pull: (start: CFTimeInterval, target: CGPoint)?   // set while the ink is being sucked away

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
        pull = nil
        invalidate()
    }

    /// In keep mode ink stays solid until it is cleared. Leaving it restarts the hold, so the ink fades
    /// out instead of vanishing.
    func setKeep(_ on: Bool) {
        keep = on
        session?.persistent = on
        if !on {
            session?.lastActivity = now()
            if !strokes.isEmpty { startTimer() }
        }
    }

    /// Pulls everything on screen into `target` (view coordinates) and then clears it. False if there was nothing to pull.
    @discardableResult
    func suckUp(into target: CGPoint) -> Bool {
        guard !strokes.isEmpty, pull == nil else { return false }
        endStroke()
        pull = (now(), target)
        startTimer()
        return true
    }

    /// How the ink looks at progress p (0 to 1) of the pull: it shrinks toward the target on an
    /// accelerating curve, swirls a little on the way, and fades over the last quarter.
    static func pullPose(at p: CGFloat) -> (scale: CGFloat, angle: CGFloat, fade: CGFloat) {
        let e = p * p
        return (max(0.02, 1 - e), -e * 0.8, 1 - max(0, (p - 0.75) / 0.25))   // clockwise: the can is low, so ink lifts instead of sinking off-screen
    }

    // MARK: Input

    override func mouseDown(with event: NSEvent) {
        guard capturing, pull == nil else { return }
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
            s.persistent = keep
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
        if let p = pull, t - p.start >= suckSeconds { clear() }
        strokes.removeAll { $0.alpha(at: t) <= 0 }
        invalidate()
        if strokes.isEmpty || (keep && pull == nil) {   // kept ink never changes, so nothing to animate
            timer?.invalidate()
            timer = nil
        }
    }

    /// Redraw only where strokes are now or were last frame; a full-screen redraw at 60 fps is wasteful.
    private func invalidate() {
        var region = CGRect.null
        for s in strokes { region = region.union(s.bounds) }
        if pull != nil { region = bounds }   // the ink is moving all over, so redraw the whole screen
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
        ctx.saveGState()
        var fade: CGFloat = 1
        if let p = pull {
            let pose = OverlayView.pullPose(at: CGFloat(min(1, max(0, (t - p.start) / suckSeconds))))
            ctx.translateBy(x: p.target.x, y: p.target.y)
            ctx.rotate(by: pose.angle)
            ctx.scaleBy(x: pose.scale, y: pose.scale)
            ctx.translateBy(x: -p.target.x, y: -p.target.y)
            fade = pose.fade
        }
        defer { ctx.restoreGState() }
        for stroke in strokes {
            let alpha = stroke.alpha(at: t) * fade
            guard alpha > 0, !stroke.points.isEmpty, pull != nil || stroke.bounds.intersects(dirtyRect) else { continue }
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

/// One point short of the display on every side. A window that covers the whole display, even a fully
/// transparent one, makes Mission Control draw the Spaces bar thumbnails (Desktop 1, Desktop 2) as bare
/// wallpaper for every space the window is in, and this one is in all of them. Window level and collection
/// behavior make no difference; a window a point smaller does not trigger it.
func overlayFrame(for screenFrame: NSRect) -> NSRect {
    screenFrame.insetBy(dx: 1, dy: 1)
}

func makePanel(for screen: NSScreen, color: NSColor) -> (OverlayPanel, OverlayView) {
    let frame = overlayFrame(for: screen.frame)
    let panel = OverlayPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
    panel.level = .screenSaver
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    let view = OverlayView(frame: NSRect(origin: .zero, size: frame.size), color: color)
    panel.contentView = view
    panel.setFrame(frame, display: true)
    panel.orderFrontRegardless()
    return (panel, view)
}

// MARK: - Trash

/// macOS lets only the frontmost app change the cursor, and this app never is (it must not take focus from
/// what is being recorded). The window server has a per-connection switch for exactly that case, but it
/// is private, so it is looked up at run time: if it ever goes away the hand just doesn't show.
/// Call before the first window appears. Returns false if the switch wasn't found or was refused.
@discardableResult
func allowCursorInBackground() -> Bool {
    typealias MainConnection = @convention(c) () -> Int32
    typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
    let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)   // RTLD_DEFAULT
    guard let connection = dlsym(rtldDefault, "CGSMainConnectionID"),
          let setProperty = dlsym(rtldDefault, "CGSSetConnectionProperty") else { return false }
    let id = unsafeBitCast(connection, to: MainConnection.self)()
    return unsafeBitCast(setProperty, to: SetProperty.self)(id, id, "SetsCursorInBackground" as CFString, kCFBooleanTrue) == 0
}

/// The system Trash for keep mode, drawn with macOS's own icons. Double-click it to sweep the drawings
/// away: it swells as they go in, turns into the full bin with paper in it, then fades.
final class TrashView: NSView {
    static let side: CGFloat = 84         // the panel; leaves room for the swell and the shadow
    static let iconSide: CGFloat = 64     // the bin at rest
    static let lingerSeconds: CFTimeInterval = 0.45   // the full bin stays up this long after the ink lands
    static let empty = NSImage(named: NSImage.trashEmptyName)
    static let full = NSImage(named: NSImage.trashFullName)
    var onEmpty: () -> Void = {}
    var now: () -> CFTimeInterval = { CACurrentMediaTime() }
    private var playing: CFTimeInterval?   // when the emptying animation started
    private var timer: Timer?
    var isPlaying: Bool { playing != nil }
    private var grab: CGPoint?   // where inside the can the cursor took hold, while dragging

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Where the bin takes clicks (and shows the pointing hand): it hugs the bin, since clear pixels
    /// around it fall through to the app below.
    var hitRect: NSRect {
        NSRect(x: bounds.midX - TrashView.iconSide / 2, y: bounds.midY - TrashView.iconSide / 2,
               width: TrashView.iconSide, height: TrashView.iconSide).insetBy(dx: 6, dy: 3)
    }

    /// This app is never the active one, so the hand needs a tracking area that works while inactive
    /// (plain cursor rects would only apply to the key window) plus allowCursorInBackground().
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: hitRect,
                                       options: [.cursorUpdate, .mouseEnteredAndExited, .mouseMoved, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseEntered(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onEmpty(); return }
        guard let window = window else { return }
        let m = NSEvent.mouseLocation
        grab = CGPoint(x: m.x - window.frame.minX, y: m.y - window.frame.minY)
    }

    /// Drags the whole panel. Screen coordinates, because the view moves under the cursor.
    override func mouseDragged(with event: NSEvent) {
        let m = NSEvent.mouseLocation
        guard let window = window, let grab = grab,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(m) }) else { return }
        window.setFrameOrigin(TrashView.origin(cursor: m, grab: grab, in: screen.frame))
    }

    override func mouseUp(with event: NSEvent) {
        if grab != nil, let window = window {
            UserDefaults.standard.set(NSStringFromPoint(window.frame.origin), forKey: "trashOrigin")
        }
        grab = nil
    }

    /// Where the can's origin goes while dragging: under the cursor, but kept inside `screen`.
    static func origin(cursor: CGPoint, grab: CGPoint, in screen: CGRect) -> CGPoint {
        CGPoint(x: min(max(cursor.x - grab.x, screen.minX), screen.maxX - side),
                y: min(max(cursor.y - grab.y, screen.minY), screen.maxY - side))
    }

    /// Plays the emptying animation: the ink goes in over suckSeconds, then the full bin lingers.
    func play() {
        playing = now()
        needsDisplay = true
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func step() {
        needsDisplay = true
        if elapsed() >= suckSeconds + TrashView.lingerSeconds {
            playing = nil
            timer?.invalidate()
            timer = nil
        }
    }

    private func elapsed() -> CFTimeInterval {
        guard let start = playing else { return 0 }
        return max(0, now() - start)
    }

    /// The bin `t` seconds into the animation: it turns into the full bin just before the last ink lands,
    /// and swells with a small bounce around the landing.
    static func pose(at t: CFTimeInterval) -> (full: Bool, swell: CGFloat) {
        let from = suckSeconds * 0.7, to = suckSeconds + 0.25
        let u = CGFloat(min(1, max(0, (t - from) / (to - from))))
        return (t >= suckSeconds * 0.9, 1 + 0.15 * sin(.pi * u))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Fully clear pixels let clicks fall through, and the bin is see-through at the rim, so a 1% tint
        // under it keeps the click and drag from landing on the app below. It hugs the bin, where the shadow hides its edge.
        ctx.setFillColor(NSColor(white: 0, alpha: 0.01).cgColor)
        ctx.addPath(CGPath(roundedRect: hitRect, cornerWidth: 8, cornerHeight: 8, transform: nil))
        ctx.fillPath()

        let pose = TrashView.pose(at: elapsed())
        let size = TrashView.iconSide * pose.swell
        let rect = NSRect(x: bounds.midX - size / 2, y: bounds.midY - size / 2, width: size, height: size)
        let shadow = NSShadow()   // the glass bin is pale, so it needs one to read on a light page
        shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        (pose.full ? TrashView.full : TrashView.empty)?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Sits where it was last dragged, or in the bottom-right corner of `screen` the first time (or if that
/// spot is no longer on any display). Above the overlay so it stays clickable.
func makeTrashPanel(on screen: NSScreen) -> (OverlayPanel, TrashView) {
    let side = TrashView.side, margin: CGFloat = 24
    let area = screen.visibleFrame
    var frame = NSRect(x: area.maxX - side - margin, y: area.minY + margin, width: side, height: side)
    if let saved = UserDefaults.standard.string(forKey: "trashOrigin") {
        let remembered = NSRect(origin: NSPointFromString(saved), size: frame.size)
        if NSScreen.screens.contains(where: { $0.frame.contains(remembered) }) { frame = remembered }
    }
    let panel = OverlayPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    let view = TrashView(frame: NSRect(origin: .zero, size: frame.size))
    panel.contentView = view
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

// MARK: - Login item

/// Launch at login through the system's Login Items list, so it can also be switched off in System Settings.
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    /// `.mixed` means the item is registered but switched off in System Settings, waiting for approval.
    static var menuState: NSControl.StateValue {
        switch status {
        case .enabled: return .on
        case .requiresApproval: return .mixed
        default: return .off
        }
    }

    static func set(_ on: Bool) throws {
        if on && status != .enabled { try SMAppService.mainApp.register() }
        if !on && status != .notRegistered { try SMAppService.mainApp.unregister() }
    }

    static var label: String {
        switch status {
        case .enabled: return "on"
        case .requiresApproval: return "needs approval in System Settings > General > Login Items"
        default: return "off"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let chord = Chord(environment["PENOVERLAY_CHORD"] ?? "ctrl+opt")
    var panels: [(panel: OverlayPanel, view: OverlayView)] = []
    var statusItem: NSStatusItem!
    var loginItem: NSMenuItem?
    var trash: (panel: OverlayPanel, view: TrashView)?
    var trashShown = false
    var colorIndex = UserDefaults.standard.integer(forKey: "colorIndex")
    var keep = UserDefaults.standard.bool(forKey: "keepDrawings")
    var active = false
    var paused = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !palette.indices.contains(colorIndex) { colorIndex = 0 }
        allowCursorInBackground()
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
        panels.forEach { $0.view.setKeep(keep) }
        buildTrash()
    }

    /// The can exists only while keep mode is on. It starts hidden and updateTrash brings it in once there is ink.
    func buildTrash() {
        trash?.panel.close()
        trash = nil
        trashShown = false
        guard keep, let screen = NSScreen.screens.first else { return }
        let made = makeTrashPanel(on: screen)
        made.1.onEmpty = { [weak self] in self?.emptyTrash() }
        made.0.alphaValue = 0
        made.0.orderOut(nil)
        trash = made
        updateTrash()
    }

    /// Shows the can while any ink is on screen, and for as long as it is still playing its emptying
    /// animation; fades it out otherwise.
    func updateTrash() {
        guard let trash = trash else { return }
        let want = trash.view.isPlaying || panels.contains { !$0.view.strokes.isEmpty }
        guard want != trashShown else { return }
        trashShown = want
        if want { trash.panel.orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            trash.panel.animator().alphaValue = want ? 1 : 0
        }, completionHandler: { [weak self] in
            if self?.trashShown == false { trash.panel.orderOut(nil) }
        })
    }

    func emptyTrash() {
        guard let trash = trash else { return }
        let f = trash.panel.frame
        let mouth = CGPoint(x: f.midX, y: f.minY + f.height * 0.72)   // the bin's rim, where the ink goes in
        let pulled = panels.map { entry -> Bool in
            let o = entry.panel.frame.origin   // each overlay's view fills its panel, so global minus origin is local
            return entry.view.suckUp(into: CGPoint(x: mouth.x - o.x, y: mouth.y - o.y))
        }
        if pulled.contains(true) { trash.view.play() }
    }

    @objc func screensChanged() {
        buildPanels()
        setActive(false)
    }

    func pollChord() {
        let held = !paused && chord.isHeld
        if held != active { setActive(held) }
        updateTrash()
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
        let keepItem = NSMenuItem(title: "Keep drawings until trashed", action: #selector(toggleKeep), keyEquivalent: "")
        keepItem.target = self
        keepItem.state = keep ? .on : .off
        menu.addItem(keepItem)
        let clear = NSMenuItem(title: "Clear", action: #selector(clearAll), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
        let pause = NSMenuItem(title: paused ? "Resume" : "Pause (pen acts as a normal cursor)",
                               action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Open at login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.menuState
        loginItem = login
        menu.addItem(login)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        statusItem.menu = menu
    }

    /// The login item can also change in System Settings, so read it again each time the menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) { loginItem?.state = LoginItem.menuState }

    @objc func toggleLogin() {
        do {
            try LoginItem.set(LoginItem.status != .enabled)
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            NSAlert(error: error).runModal()
        }
        if LoginItem.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        loginItem?.state = LoginItem.menuState
    }

    @objc func pickColor(_ sender: NSMenuItem) {
        colorIndex = sender.tag
        UserDefaults.standard.set(colorIndex, forKey: "colorIndex")
        panels.forEach { $0.view.color = palette[colorIndex].color }
        rebuildMenu()
    }

    @objc func toggleKeep() {
        keep.toggle()
        UserDefaults.standard.set(keep, forKey: "keepDrawings")
        panels.forEach { $0.view.setKeep(keep) }
        buildTrash()
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

    func alpha(of v: NSView, atX x: CGFloat, y: CGFloat) -> CGFloat {
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

    // Keep mode: ink stays solid until cleared; leaving the mode restarts the hold, then it fades.
    var inkClock: CFTimeInterval = 1000
    func inkedView() -> OverlayView {
        let v = OverlayView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), color: .red)
        v.now = { inkClock }
        v.setKeep(true)
        v.beginStroke()
        for i in 0..<40 { v.extend(to: CGPoint(x: 40 + CGFloat(i) * 8, y: 100), width: 10) }
        v.endStroke()
        return v
    }
    let kept = inkedView()
    inkClock += 600
    kept.tick()
    let keptAlpha = alpha(of: kept, atX: 200, y: 100)
    check("kept ink is still solid after ten minutes", kept.strokes.count == 1 && abs(keptAlpha - strokeOpacity) < 0.03, "alpha \(keptAlpha), \(kept.strokes.count) strokes")
    kept.setKeep(false)
    inkClock += holdSeconds * 0.5
    let holding = alpha(of: kept, atX: 200, y: 100)
    check("leaving keep mode restarts the hold", abs(holding - strokeOpacity) < 0.03, "alpha \(holding)")
    inkClock += holdSeconds * 0.5 + fadeSeconds + 0.1
    kept.tick()
    check("then the ink fades away", kept.strokes.isEmpty, "\(kept.strokes.count) left")

    // The overlay must not cover its whole display, or Mission Control blanks the Desktop thumbnails.
    let display = NSRect(x: -1440, y: 0, width: 1512, height: 982)
    let cover = overlayFrame(for: display)
    check("overlay stays inside its display", display.contains(cover), "\(cover) in \(display)")
    check("overlay does not cover the whole display", cover != display && cover.width < display.width && cover.height < display.height, "\(cover.size) vs \(display.size)")
    check("overlay gives up at most a point per side", cover.minX - display.minX <= 1 && display.maxX - cover.maxX <= 1
          && cover.minY - display.minY <= 1 && display.maxY - cover.maxY <= 1, "origin \(cover.origin), size \(cover.size)")

    // Emptying the trash: the ink moves toward the can, then is gone.
    let pulled = inkedView()
    let blank = OverlayView(frame: pulled.frame, color: .red)
    check("nothing to pull on an empty screen", !blank.suckUp(into: .zero), "returned true")
    let target = CGPoint(x: 380, y: 30)
    check("pulling ink in reports it had ink", pulled.suckUp(into: target), "returned false")
    let atStart = alpha(of: pulled, atX: 200, y: 100)
    check("ink has not moved when the pull starts", abs(atStart - strokeOpacity) < 0.03, "alpha \(atStart)")
    inkClock += suckSeconds * 0.5
    let pose = OverlayView.pullPose(at: 0.5)
    let rel = CGPoint(x: 200 - target.x, y: 100 - target.y)
    let moved = CGPoint(x: target.x + pose.scale * (rel.x * cos(pose.angle) - rel.y * sin(pose.angle)),
                        y: target.y + pose.scale * (rel.x * sin(pose.angle) + rel.y * cos(pose.angle)))
    let atNew = alpha(of: pulled, atX: moved.x, y: moved.y)
    check("midway the ink has moved toward the can", abs(atNew - strokeOpacity * pose.fade) < 0.05, "alpha \(atNew) at (\(Int(moved.x)), \(Int(moved.y)))")
    check("and left where it was", alpha(of: pulled, atX: 200, y: 100) < 0.05, "alpha \(alpha(of: pulled, atX: 200, y: 100))")
    inkClock += suckSeconds
    pulled.tick()
    check("ink is gone once pulled in", pulled.strokes.isEmpty, "\(pulled.strokes.count) left")

    // The can: the system bin on a click-catching tint that hugs it, empty until the ink lands and then full; double-click empties.
    var trashClock: CFTimeInterval = 50
    let can = TrashView(frame: NSRect(x: 0, y: 0, width: TrashView.side, height: TrashView.side))
    can.now = { trashClock }
    let bin = alpha(of: can, atX: 42, y: 30), beside = alpha(of: can, atX: 20, y: 40), canCorner = alpha(of: can, atX: 1, y: 1)
    check("can draws the bin and catches clicks around it", bin > 0.1 && beside > 0.005 && canCorner == 0,
          "bin alpha \(bin), beside \(beside), corner \(canCorner)")
    let emptyAbove = alpha(of: can, atX: 26, y: 68)   // above the rim, where paper sticks out of the full bin
    can.play()
    trashClock += suckSeconds + 0.3
    let fullAbove = alpha(of: can, atX: 26, y: 68)
    check("bin fills with paper once the ink lands", emptyAbove < 0.2 && fullAbove > 0.6, "alpha \(emptyAbove) empty, \(fullAbove) full")
    let before = TrashView.pose(at: 0), landed = TrashView.pose(at: suckSeconds)
    let settled = TrashView.pose(at: suckSeconds + TrashView.lingerSeconds)
    check("bin is empty at first and full when the ink lands", !before.full && landed.full, "full \(before.full) then \(landed.full)")
    check("bin swells at the landing and settles after", before.swell == 1 && landed.swell > 1.05 && abs(settled.swell - 1) < 0.001,
          "swell \(before.swell), \(landed.swell), \(settled.swell)")
    check("can reports it is playing during the pull", can.isPlaying, "isPlaying false")
    can.updateTrackingAreas()
    let hover = can.trackingAreas.first
    check("can has a hover area that works while the app is inactive",
          can.trackingAreas.count == 1 && hover?.options.contains(.cursorUpdate) == true && hover?.options.contains(.activeAlways) == true,
          "\(can.trackingAreas.count) areas, options \(hover?.options.rawValue ?? 0)")
    check("hover area hugs the bin", hover?.rect.contains(CGPoint(x: 42, y: 42)) == true && hover?.rect.contains(CGPoint(x: 2, y: 2)) == false,
          "rect \(hover?.rect ?? .zero)")
    NSCursor.arrow.set()
    let arrowFirst = NSCursor.current != NSCursor.pointingHand   // control: the comparison can tell them apart
    if let enter = NSEvent.enterExitEvent(with: .cursorUpdate, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil) {
        can.cursorUpdate(with: enter)
    }
    check("hovering the bin shows the pointing hand", arrowFirst && NSCursor.current == NSCursor.pointingHand, "arrow first \(arrowFirst), cursor \(NSCursor.current)")
    let screenRect = CGRect(x: 0, y: 0, width: 1000, height: 600), grab = CGPoint(x: 10, y: 20)
    let dragged = TrashView.origin(cursor: CGPoint(x: 500, y: 300), grab: grab, in: screenRect)
    check("dragging keeps the grab point under the cursor", dragged == CGPoint(x: 490, y: 280), "origin \(dragged)")
    let pinned = TrashView.origin(cursor: CGPoint(x: 5000, y: -400), grab: grab, in: screenRect)
    check("dragging never leaves the screen", pinned == CGPoint(x: 1000 - TrashView.side, y: 0), "origin \(pinned)")
    var emptied = 0
    can.onEmpty = { emptied += 1 }
    func click(_ count: Int) {
        if let e = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: 0, context: nil, eventNumber: 0, clickCount: count, pressure: 1) {
            can.mouseDown(with: e)
        }
    }
    click(1)
    check("a single click does nothing", emptied == 0, "emptied \(emptied) times")
    click(2)
    check("a double-click empties the can", emptied == 1, "emptied \(emptied) times")
    exit(failures == 0 ? 0 : 1)
}

// MARK: - Entry

if CommandLine.arguments.contains("--selftest") { selfTest() }
if let flag = CommandLine.arguments.firstIndex(of: "--open-at-login") {
    let value = CommandLine.arguments.dropFirst(flag + 1).first
    guard let value = value, ["on", "off", "status"].contains(value) else {
        print("usage: PenOverlay --open-at-login on|off|status")
        exit(2)
    }
    do { if value != "status" { try LoginItem.set(value == "on") } } catch {
        print("could not change the login item: \(error.localizedDescription)")
        exit(1)
    }
    print("open at login: \(LoginItem.label)")
    exit(0)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
