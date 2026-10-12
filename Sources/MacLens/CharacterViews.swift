import AppKit
import SwiftUI
import MacLensCore

/// Desktop character (#39): an optional way to deliver water reminders and alerts. A small mascot walks in from the side of
/// the screen with a prop that fits the alert and waits, with the message in a speech bubble, until a button is clicked.
///
/// Lightweight by construction:
///  - Nothing exists while no alert uses it: no window, view or timer. While its queue is empty, `tick` returns before reading
///    any signal, and it has no timer of its own; it's ticked by the existing sampler and water timer.
///  - The walk is a ~1 s, 30 fps window move plus a redraw of one small `Canvas`; then the timer stops.
///  - While it waits on screen, one 1 s timer (with tolerance) checks screen sharing and blinks every 4 s.
///  - When it leaves, the panel and its views are released.
@MainActor final class CharacterStore: ObservableObject {
    private var queue = CharacterQueue()
    private let panel = CharacterPanelController()
    weak var water: WaterStore?
    /// Whether a queued alert still applies (battery still low, Mac still hot, still shown as Character…). Set by `AppModel`.
    var isValid: (CharacterAlert) -> Bool = { _ in true }
    var openTab: ((Tab) -> Void)?
    var openUpdate: (() -> Void)?
    /// No input for this long counts as away: alerts wait until the user is back.
    static let awayAfter: TimeInterval = 5 * 60

    init() {
        panel.onPresenceCheck = { [weak self] in self?.tick() }
        panel.onAction = { [weak self] in self?.perform($0) }
    }

    /// Visible or queued; the water engine treats this like its on-screen alert, so reminders never pile up.
    func contains(_ kind: CharacterAlertKind) -> Bool { queue.contains(kind) }

    func add(_ a: CharacterAlert) {
        if queue.add(a) { panel.update(a) }
        tick()
    }

    func tick() {
        if panel.isLeaving { // walking off: only vanish if a share starts
            if PresenceSignals.screenIsShared() == true { panel.vanish() }
            return
        }
        guard !queue.isIdle else { return }
        let test = queue.showing?.isTest ?? queue.pending.first?.isTest ?? false // a test ignores pause and away, never sharing
        let paused = !test && (water?.isPaused ?? false)
        let sharing = PresenceSignals.screenIsShared() ?? false
        let away = !test && queue.showing == nil &&
            (PresenceSignals.screenIsLocked() || (PresenceSignals.idleSeconds() ?? 0) >= Self.awayAfter)
        let decision = queue.tick(sharing: sharing, paused: paused, away: away) { [isValid] a in a.isTest || isValid(a) }
        switch decision {
        case .show(let a): panel.enter(a, canPauseUntilShiftEnd: water?.inWorkHours ?? false)
        case .hide: panel.vanish()
        case .wait: break
        }
    }

    func test(_ kind: CharacterAlertKind) {
        var a = Self.sample(kind, waterInterval: water?.intervalMinutes ?? 30)
        a.isTest = true
        add(a)
    }

    /// `--character-dismiss-after` (measurement): as if Dismiss were clicked.
    func dismissVisible() { perform(.dismiss) }

    private func perform(_ action: CharacterAction) {
        guard let a = queue.dismiss() else { return }
        switch action {
        case .done: if a.kind == .water { water?.done() }
        case .snooze: water?.snooze(minutes: 10)
        case .pause(let m): water?.pause(minutes: m)
        case .pauseShift: water?.pauseUntilEndOfShift()
        case .dismiss: break
        case .open(let tab): openTab?(tab)
        case .update: openUpdate?()
        }
        panel.leave { [weak self] in self?.tick() } // then the next queued alert, if any
    }

    static func sample(_ kind: CharacterAlertKind, waterInterval: Int = 30) -> CharacterAlert {
        switch kind {
        case .water: return water(interval: waterInterval)
        case .batteryLow: return CharacterAlert(kind: kind, title: "Battery at 20%", message: "Your battery dropped to your 20% alert level. Plug in soon.")
        case .batteryHigh: return CharacterAlert(kind: kind, title: "Battery charged to 80%", message: "Reached your 80% alert level. You can unplug to reduce battery wear.")
        case .hot: return CharacterAlert(kind: kind, title: "Your Mac is running hot", message: "Thermal state is Serious. Heat & Battery shows what's using energy.")
        case .runaway: return CharacterAlert(kind: kind, title: "node is using a lot of CPU", message: "98% CPU for over 5 min (PID 4242).", subject: "node")
        case .update: return CharacterAlert(kind: kind, title: "MacLens 9.9.0 is available", message: "You have 1.5.0. See what's new and update.")
        }
    }

    static func water(interval: Int) -> CharacterAlert {
        CharacterAlert(kind: .water, title: "Time to drink some water", message: "Your \(interval)-minute reminder. Take a sip and stretch for a moment.")
    }
}

enum CharacterAction {
    case done, snooze, pause(Int), pauseShift, dismiss, open(Tab), update
}

extension CharacterAlertKind {
    var label: String {
        switch self {
        case .water: return "Water reminder"
        case .batteryLow, .batteryHigh: return "Battery"
        case .hot: return "Heat"
        case .runaway: return "Runaway process"
        case .update: return "Update"
        }
    }
    var testTitle: String {
        switch self {
        case .water: return "Water reminder (glass of water)"
        case .batteryLow: return "Battery low (dragging a cable)"
        case .batteryHigh: return "Battery charged (unplugging)"
        case .hot: return "Running hot (fanning)"
        case .runaway: return "Runaway CPU (holding a sign)"
        case .update: return "Update available (gift box)"
        }
    }
}

// MARK: - Panel and walk

/// What the bubble shows. Set once per alert, so SwiftUI renders the bubble once, not during the walk.
@MainActor final class CharacterViewState: ObservableObject {
    @Published var alert: CharacterAlert
    @Published var bubble = false
    let canPauseUntilShiftEnd: Bool
    init(alert: CharacterAlert, canPauseUntilShiftEnd: Bool) { self.alert = alert; self.canPauseUntilShiftEnd = canPauseUntilShiftEnd }
}

@MainActor final class CharacterPanelController {
    var onPresenceCheck: (() -> Void)?
    var onAction: ((CharacterAction) -> Void)?
    private(set) var isLeaving = false
    private var panel: NSPanel?
    private var bubble: NSHostingView<CharacterBubbleHost>?
    private var mascot: MascotNSView?
    private var state: CharacterViewState?
    private var frameTimer: Timer?
    private var presenceTimer: Timer?
    private var lastFrame: CFTimeInterval = 0
    private var frames = 0
    private var seconds = 0
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// The mascot sits at the bottom-trailing corner of the panel, inside `inset`; the bubble's tail overlaps its top by `overlap`.
    nonisolated static let mascotSize: CGFloat = 120
    nonisolated static let inset: CGFloat = 4
    nonisolated static let overlap: CGFloat = 6
    /// Panel origin offset from the screen edge that puts the whole mascot just past it.
    nonisolated static let offEdge: CGFloat = mascotSize + inset

    func enter(_ alert: CharacterAlert, canPauseUntilShiftEnd: Bool) {
        vanish()
        let s = CharacterViewState(alert: alert, canPauseUntilShiftEnd: canPauseUntilShiftEnd)
        let b = NSHostingView(rootView: CharacterBubbleHost(state: s, act: { [weak self] in self?.onAction?($0) }))
        let m = MascotNSView(pose: MascotPose(kind: alert.kind, subject: alert.subject))
        let p = makePanel()
        let content = FlippedView()
        content.addSubview(b)
        content.addSubview(m)
        p.contentView = content
        panel = p; bubble = b; mascot = m; state = s
        layout()
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { vanish(); return }
        let target = NSPoint(x: vf.maxX - p.frame.width - 24, y: vf.minY)
        if reduceMotion { // Reduce Motion: fade in where it stands
            p.setFrameOrigin(target)
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.25; p.animator().alphaValue = 1 }
            arrived()
            return
        }
        p.setFrameOrigin(NSPoint(x: vf.maxX - p.frame.width + Self.offEdge, y: vf.minY)) // mascot just past the edge
        p.ignoresMouseEvents = true // nothing to click while walking
        p.orderFrontRegardless()
        m.pose.walking = true
        walk(to: target.x, tired: alert.kind == .batteryLow) { [weak self] in self?.arrived() }
    }

    /// Same kind again while visible (e.g. the battery dropped another percent): redraw in place.
    func update(_ a: CharacterAlert) {
        guard let s = state, let m = mascot else { return }
        s.alert = a
        m.pose.subject = a.subject
        layout()
    }

    /// Walk off the way it came, then release everything.
    func leave(done: @escaping () -> Void) {
        guard let p = panel, let s = state, let m = mascot else { done(); return }
        presenceTimer?.invalidate(); presenceTimer = nil
        isLeaving = true
        s.bubble = false
        p.ignoresMouseEvents = true
        if reduceMotion {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; p.animator().alphaValue = 0 }) { [weak self] in
                MainActor.assumeIsolated { self?.vanish(); done() }
            }
            return
        }
        m.pose.carrying = false
        m.pose.blinking = false
        m.facingRight = true
        m.pose.walking = true
        let edge = (p.screen ?? NSScreen.main)?.visibleFrame.maxX ?? p.frame.maxX
        walk(to: edge - p.frame.width + Self.offEdge, tired: false) { [weak self] in self?.vanish(); done() }
    }

    /// Gone at once, without animation: a screen share started, or a pause was set.
    func vanish() {
        frameTimer?.invalidate(); frameTimer = nil
        presenceTimer?.invalidate(); presenceTimer = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil; bubble = nil; mascot = nil; state = nil
        isLeaving = false
    }

    /// Bubble on top, mascot at the bottom-trailing corner; keeps the panel's bottom-right corner where it is.
    private func layout() {
        guard let p = panel, let b = bubble, let m = mascot, let content = p.contentView else { return }
        let bs = b.fittingSize
        let width = max(bs.width, Self.mascotSize) + 2 * Self.inset
        let height = Self.inset + bs.height - Self.overlap + Self.mascotSize + Self.inset
        b.frame = NSRect(x: width - Self.inset - bs.width, y: Self.inset, width: bs.width, height: bs.height)
        m.frame = NSRect(x: width - Self.inset - Self.mascotSize, y: height - Self.inset - Self.mascotSize,
                         width: Self.mascotSize, height: Self.mascotSize)
        let old = p.frame
        p.setContentSize(NSSize(width: width, height: height))
        content.frame = NSRect(x: 0, y: 0, width: width, height: height)
        if old.width > 1 { p.setFrameOrigin(NSPoint(x: old.maxX - p.frame.width, y: old.minY)) }
    }

    private func arrived() {
        guard let p = panel, let s = state, let m = mascot else { return }
        m.pose.walking = false
        m.pose.phase = 0
        s.bubble = true
        p.ignoresMouseEvents = false
        seconds = 0
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.presenceTick() } }
        t.tolerance = 0.3 // lets macOS coalesce the wakeup
        RunLoop.main.add(t, forMode: .common)
        presenceTimer = t
    }

    private func presenceTick() {
        onPresenceCheck?() // may vanish
        guard let m = mascot else { return }
        seconds += 1
        if seconds % 4 == 0 {
            m.pose.blinking = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak m] in MainActor.assumeIsolated { m?.pose.blinking = false } }
        }
    }

    private func walk(to x: CGFloat, tired: Bool, done: @escaping () -> Void) {
        frameTimer?.invalidate()
        lastFrame = CACurrentMediaTime()
        frames = 0
        let speed: CGFloat = tired ? 95 : 150 // points per second
        let stepRate = tired ? 8.0 : 12.0     // leg swing, radians per second
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, let p = self.panel, let m = self.mascot else { timer.invalidate(); return }
                let now = CACurrentMediaTime()
                let dt = min(now - self.lastFrame, 0.1)
                self.lastFrame = now
                var o = p.frame.origin
                let dir: CGFloat = x < o.x ? -1 : 1
                o.x += dir * speed * dt
                let reached = dir < 0 ? o.x <= x : o.x >= x
                if reached { o.x = x }
                p.setFrameOrigin(o)
                m.pose.phase += dt * stepRate
                self.frames += 1
                if self.frames % 10 == 0 { self.onPresenceCheck?() } // a share starting mid-walk
                guard self.panel === p else { return } // vanished
                if reached { timer.invalidate(); self.frameTimer = nil; done() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        frameTimer = t
    }

    private func makePanel() -> NSPanel {
        let p = WaterPanel(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                           styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false // a shadow on a transparent window is recomputed from its pixels on every redraw
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = true
        // Extra layer only: asks capture to leave the window out. Not relied on (newer capture APIs may ignore it);
        // the screen-watcher check is what hides the character during a share.
        p.sharingType = .none
        return p
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The mascot, drawn with Core Graphics into a small layer. Deliberately not a SwiftUI `Canvas`: each Canvas re-render
/// (every walk frame, every blink) made SwiftUI's GPU renderer allocate ~100 MB of graphics memory for a few seconds.
final class MascotNSView: NSView {
    var pose: MascotPose { didSet { if pose != oldValue { needsDisplay = true } } }
    var facingRight = false { didSet { if facingRight != oldValue { needsDisplay = true } } }

    init(pose: MascotPose) {
        self.pose = pose
        super.init(frame: NSRect(x: 0, y: 0, width: CharacterPanelController.mascotSize, height: CharacterPanelController.mascotSize))
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil } // clicks on the mascot do nothing

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        if facingRight { cg.translateBy(x: bounds.width, y: 0); cg.scaleBy(x: -1, y: 1) }
        MascotDrawing.draw(pose, cg)
    }
}

// MARK: - Views

struct CharacterBubbleHost: View {
    @ObservedObject var state: CharacterViewState
    let act: (CharacterAction) -> Void

    var body: some View {
        CharacterBubble(alert: state.alert, canPauseUntilShiftEnd: state.canPauseUntilShiftEnd, act: act)
            .opacity(state.bubble ? 1 : 0)
            .allowsHitTesting(state.bubble)
    }
}

/// The speech bubble, with a tail pointing down at the mascot's head. Solid fill: no blur or material behind it.
struct CharacterBubble: View {
    let alert: CharacterAlert
    let canPauseUntilShiftEnd: Bool
    let act: (CharacterAction) -> Void
    static let width: CGFloat = 280
    static let tail: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 14, height: 14)
                Text("MacLens").font(.caption.weight(.semibold))
                Text("· \(alert.kind.label)").font(.caption).foregroundStyle(.secondary)
            }
            Text(alert.title).font(.headline).fixedSize(horizontal: false, vertical: true)
            if !alert.message.isEmpty {
                Text(alert.message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) { buttons }.controlSize(.small)
        }
        .padding(12)
        .padding(.bottom, Self.tail)
        .frame(width: Self.width, alignment: .leading)
        .background(BubbleShape(tail: Self.tail, tailX: Self.width - 52).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(BubbleShape(tail: Self.tail, tailX: Self.width - 52).stroke(Color.primary.opacity(0.18), lineWidth: 1))
    }

    @ViewBuilder private var buttons: some View {
        switch alert.kind {
        case .water:
            Menu("Pause…") {
                Button("30 minutes") { act(.pause(30)) }
                Button("1 hour") { act(.pause(60)) }
                Button("2 hours") { act(.pause(120)) }
                Button("Until end of shift") { act(.pauseShift) }.disabled(!canPauseUntilShiftEnd)
            }
            .fixedSize()
            Spacer()
            Button("Snooze 10 min") { act(.snooze) }
            Button("Done") { act(.done) }.keyboardShortcut(.defaultAction)
        case .batteryLow, .hot:
            Button("Open Heat & Battery") { act(.open(.heat)) }
            Spacer()
            Button("Dismiss") { act(.dismiss) }.keyboardShortcut(.defaultAction)
        case .batteryHigh:
            Spacer()
            Button("Dismiss") { act(.dismiss) }.keyboardShortcut(.defaultAction)
        case .runaway:
            Button("Open Processes") { act(.open(.processes)) }
            Spacer()
            Button("Dismiss") { act(.dismiss) }.keyboardShortcut(.defaultAction)
        case .update:
            Button("Later") { act(.dismiss) }
            Spacer()
            Button("See what's new") { act(.update) }.keyboardShortcut(.defaultAction)
        }
    }
}

struct BubbleShape: Shape {
    let tail: CGFloat
    let tailX: CGFloat

    /// One outline, so the stroke doesn't cross the base of the tail.
    func path(in r: CGRect) -> Path {
        let b = CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height - tail)
        let c: CGFloat = 14
        var p = Path()
        p.move(to: CGPoint(x: b.minX + c, y: b.minY))
        p.addArc(tangent1End: CGPoint(x: b.maxX, y: b.minY), tangent2End: CGPoint(x: b.maxX, y: b.maxY), radius: c)
        p.addArc(tangent1End: CGPoint(x: b.maxX, y: b.maxY), tangent2End: CGPoint(x: b.minX, y: b.maxY), radius: c)
        p.addLine(to: CGPoint(x: tailX + 9, y: b.maxY))
        p.addLine(to: CGPoint(x: tailX + 2, y: r.maxY))
        p.addLine(to: CGPoint(x: tailX - 9, y: b.maxY))
        p.addArc(tangent1End: CGPoint(x: b.minX, y: b.maxY), tangent2End: CGPoint(x: b.minX, y: b.minY), radius: c)
        p.addArc(tangent1End: CGPoint(x: b.minX, y: b.minY), tangent2End: CGPoint(x: b.maxX, y: b.minY), radius: c)
        p.closeSubpath()
        return p
    }
}

/// Bubble and mascot as one SwiftUI view, for `--snapshot` renders only (the panel lays out AppKit views instead).
struct CharacterPreview: View {
    let alert: CharacterAlert
    var body: some View {
        VStack(alignment: .trailing, spacing: -CharacterPanelController.overlap) {
            CharacterBubble(alert: alert, canPauseUntilShiftEnd: true, act: { _ in })
            MascotImage(pose: MascotPose(kind: alert.kind, subject: alert.subject))
        }
        .padding(CharacterPanelController.inset)
    }
}

/// The mascot as a static image, for snapshots.
struct MascotImage: View {
    let pose: MascotPose
    var mirrored = false
    var body: some View {
        Image(nsImage: MascotDrawing.image(pose, mirrored: mirrored))
            .frame(width: CharacterPanelController.mascotSize, height: CharacterPanelController.mascotSize)
    }
}

// MARK: - The mascot

struct MascotPose: Equatable {
    var kind: CharacterAlertKind
    var subject: String?
    var phase = 0.0
    var walking = false
    var blinking = false
    /// Holding the alert's prop. False while walking off.
    var carrying = true
}

/// The MacLens mascot: a lens-headed chibi, drawn in a 120 × 120 pt top-left-origin space. Faces left; mirrored to face right.
enum MascotDrawing {
    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    private static func white(_ a: CGFloat = 1) -> CGColor { CGColor(gray: 1, alpha: a) }
    static let blue = rgb(0.24, 0.55, 0.95)   // the app icon's gradient ends
    static let deep = rgb(0.10, 0.33, 0.72)
    static let glass = rgb(0.88, 0.94, 1.0)
    static let ink = rgb(0.09, 0.13, 0.27)
    static let blush = rgb(1.0, 0.52, 0.6)
    static let halo = white(0.9)              // keeps the outline visible on dark wallpapers
    static let water = rgb(0.30, 0.62, 0.98)
    static let cable = CGColor(gray: 0.3, alpha: 1)
    static let gold = rgb(1.0, 0.8, 0.22)
    static let sweat = rgb(0.55, 0.82, 1.0)
    static let wood = rgb(0.55, 0.35, 0.2)
    static let fanFill = rgb(1, 0.7, 0.3)
    static let fanEdge = rgb(0.85, 0.45, 0.1)

    enum Eyes { case open, happy, tired, dizzy }
    enum Mouth { case smile, grin, flat, wavy, pant }

    /// A static image of a pose (snapshots).
    static func image(_ p: MascotPose, mirrored: Bool = false) -> NSImage {
        let s = CharacterPanelController.mascotSize
        return NSImage(size: NSSize(width: s, height: s), flipped: true) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            if mirrored { cg.translateBy(x: s, y: 0); cg.scaleBy(x: -1, y: 1) }
            draw(p, cg)
            return true
        }
    }

    /// Draws into a top-left-origin context. Needs `NSGraphicsContext.current` (for the text on the runaway sign).
    static func draw(_ p: MascotPose, _ cg: CGContext) {
        let swing = p.walking ? sin(p.phase) : 0
        let prop = p.carrying ? p.kind : nil
        if prop == .batteryLow { drawCable(cg) }

        // Legs swing from the hips; shoes point the way it faces.
        for (hipX, sign) in [(63.0, 1.0), (77.0, -1.0)] {
            let a = swing * 0.42 * sign
            let hip = CGPoint(x: hipX, y: 98)
            let foot = CGPoint(x: hipX - sin(a) * 14, y: 98 + cos(a) * 14)
            line(cg, hip, foot, deep, 7)
            fill(cg, Path(ellipseIn: CGRect(x: foot.x - 6.5, y: foot.y - 1, width: 10, height: 5.5)), ink)
        }

        cg.saveGState()
        defer { cg.restoreGState() }
        cg.translateBy(x: 0, y: p.walking ? -abs(swing) * 2 : 0) // bob
        line(cg, CGPoint(x: 82, y: 84), CGPoint(x: 87 + swing * 4, y: 97), blue, 6) // back arm

        let body = Path(roundedRect: CGRect(x: 55, y: 75, width: 30, height: 26), cornerRadius: 11)
        fill(cg, body, blue)
        stroke(cg, body, halo, 1.5)

        // Head: a lens. Outline, rim, band, glass, glare.
        let c = CGPoint(x: 70, y: 45)
        fill(cg, circle(c, 33.5), halo)
        fill(cg, circle(c, 32), deep)
        fill(cg, circle(c, 29), blue)
        fill(cg, circle(c, 24), glass)
        cg.saveGState()
        cg.translateBy(x: 81, y: 31)
        cg.rotate(by: -35 * .pi / 180)
        fill(cg, Path(ellipseIn: CGRect(x: -4.5, y: -2.4, width: 9, height: 4.8)), white())
        cg.restoreGState()
        fill(cg, circle(CGPoint(x: 86, y: 38), 1.6), white())

        let (eyes, mouth) = face(p.kind)
        let cheeks = p.kind == .hot ? rgb(1, 0.35, 0.35, 0.9) : blush.copy(alpha: 0.5)!
        for x in [49.0, 81.0] { fill(cg, Path(ellipseIn: CGRect(x: x - 4, y: 52, width: 8, height: 4.5)), cheeks) }
        drawEyes(cg, p.blinking && eyes != .happy ? nil : eyes)
        drawMouth(cg, mouth)
        if p.kind == .hot || p.kind == .runaway { drop(cg, CGPoint(x: 100, y: 22)); drop(cg, CGPoint(x: 40, y: 25)) }
        if p.kind == .update { sparkle(cg, CGPoint(x: 101, y: 17), 6); sparkle(cg, CGPoint(x: 37, y: 18), 4) }
        if p.kind == .batteryLow { battery(cg, level: 0.2, color: rgb(0.95, 0.2, 0.2)) }
        if p.kind == .batteryHigh { battery(cg, level: 1, color: rgb(0.2, 0.75, 0.3)); sparkle(cg, CGPoint(x: 37, y: 18), 4) }

        drawProp(cg, prop, subject: p.subject, swing: swing)
    }

    private static func face(_ kind: CharacterAlertKind) -> (Eyes, Mouth) {
        switch kind {
        case .water: return (.open, .smile)
        case .batteryLow: return (.tired, .flat)
        case .batteryHigh, .update: return (.happy, .grin)
        case .hot: return (.open, .wavy)
        case .runaway: return (.dizzy, .pant)
        }
    }

    /// nil = blinking.
    private static func drawEyes(_ cg: CGContext, _ eyes: Eyes?) {
        let y = 47.0
        for (i, x) in [57.0, 75.0].enumerated() {
            guard let eyes else {
                var p = Path(); p.move(to: CGPoint(x: x - 4.5, y: y)); p.addQuadCurve(to: CGPoint(x: x + 4.5, y: y), control: CGPoint(x: x, y: y + 3.5))
                stroke(cg, p, ink, 2.2); continue
            }
            switch eyes {
            case .open, .tired:
                fill(cg, Path(ellipseIn: CGRect(x: x - 4.5, y: y - 6.5, width: 9, height: 13)), ink)
                if eyes == .tired { // heavy lids, drooping at the outer corners
                    let o: CGFloat = i == 0 ? -1 : 1
                    let outer = CGPoint(x: x + 5.5 * o, y: y + 1.5), inner = CGPoint(x: x - 5.5 * o, y: y - 1)
                    fill(cg, poly([(outer.x, y - 8), (inner.x, y - 8), (inner.x, inner.y), (outer.x, outer.y)]), glass)
                    line(cg, outer, inner, ink, 2)
                } else {
                    fill(cg, circle(CGPoint(x: x - 1.5, y: y - 3), 2.3), white())
                }
                fill(cg, circle(CGPoint(x: x + 1.8, y: y + 2.8), 1.1), white())
            case .happy:
                var p = Path(); p.move(to: CGPoint(x: x - 4.5, y: y + 2)); p.addQuadCurve(to: CGPoint(x: x + 4.5, y: y + 2), control: CGPoint(x: x, y: y - 6))
                stroke(cg, p, ink, 2.4)
            case .dizzy: // > <
                let d: CGFloat = i == 0 ? 1 : -1
                var p = Path()
                p.move(to: CGPoint(x: x - 4 * d, y: y - 4.5)); p.addLine(to: CGPoint(x: x + 3.5 * d, y: y)); p.addLine(to: CGPoint(x: x - 4 * d, y: y + 4.5))
                stroke(cg, p, ink, 2.4)
            }
        }
    }

    private static func drawMouth(_ cg: CGContext, _ mouth: Mouth) {
        var p = Path()
        switch mouth {
        case .smile:
            p.move(to: CGPoint(x: 62, y: 58)); p.addQuadCurve(to: CGPoint(x: 70, y: 58), control: CGPoint(x: 66, y: 63))
        case .flat:
            p.move(to: CGPoint(x: 63, y: 60.5)); p.addQuadCurve(to: CGPoint(x: 69, y: 60.5), control: CGPoint(x: 66, y: 59.5))
        case .wavy:
            p.move(to: CGPoint(x: 61, y: 60))
            p.addQuadCurve(to: CGPoint(x: 64.3, y: 60), control: CGPoint(x: 62.7, y: 58))
            p.addQuadCurve(to: CGPoint(x: 67.7, y: 60), control: CGPoint(x: 66, y: 62))
            p.addQuadCurve(to: CGPoint(x: 71, y: 60), control: CGPoint(x: 69.3, y: 58))
        case .grin:
            var g = Path(); g.move(to: CGPoint(x: 61.5, y: 57.5)); g.addQuadCurve(to: CGPoint(x: 70.5, y: 57.5), control: CGPoint(x: 66, y: 67)); g.closeSubpath()
            fill(cg, g, ink)
            fill(cg, Path(ellipseIn: CGRect(x: 64, y: 60.5, width: 4, height: 2.6)), blush)
            return
        case .pant:
            fill(cg, Path(ellipseIn: CGRect(x: 63.5, y: 56.5, width: 5, height: 6.5)), ink)
            return
        }
        stroke(cg, p, ink, 2)
    }

    private static let shoulder = CGPoint(x: 58, y: 84)

    private static func drawProp(_ cg: CGContext, _ kind: CharacterAlertKind?, subject: String?, swing: Double) {
        switch kind {
        case .water: // a glass of water, held out
            let glassPath = poly([(27, 66), (43, 66), (41, 92), (29, 92)])
            fill(cg, glassPath, white(0.7))
            fill(cg, poly([(27.7, 75), (42.3, 75), (41, 92), (29, 92)]), water)
            stroke(cg, glassPath, CGColor(gray: 0.45, alpha: 1), 1.4)
            line(cg, CGPoint(x: 30, y: 70), CGPoint(x: 30.8, y: 88), white(0.9), 1.5)
            arm(cg, to: CGPoint(x: 43, y: 84))
        case .batteryLow: // dragging the cable; plug held low
            arm(cg, to: CGPoint(x: 42, y: 93))
            plug(cg, CGRect(x: 31, y: 88, width: 11, height: 10), prongsUp: false)
        case .batteryHigh: // unplugged, held up
            var c = Path(); c.move(to: CGPoint(x: 41.5, y: 64)); c.addCurve(to: CGPoint(x: 28, y: 116), control1: CGPoint(x: 40, y: 92), control2: CGPoint(x: 24, y: 100))
            c.addLine(to: CGPoint(x: 16, y: 116))
            stroke(cg, c, cable, 2.5)
            plug(cg, CGRect(x: 36, y: 54, width: 11, height: 10), prongsUp: true)
            arm(cg, to: CGPoint(x: 45, y: 63))
        case .hot: // fanning itself
            let center = CGPoint(x: 40, y: 76)
            var fan = Path(); fan.move(to: center)
            fan.addArc(center: center, radius: 15, startAngle: .degrees(200), endAngle: .degrees(340), clockwise: false)
            fan.closeSubpath()
            fill(cg, fan, fanFill)
            stroke(cg, fan, fanEdge, 1.2)
            for deg in [230.0, 260, 290, 320] {
                let r = deg * .pi / 180
                line(cg, center, CGPoint(x: center.x + cos(r) * 14, y: center.y + sin(r) * 14), fanEdge, 0.8)
            }
            line(cg, center, CGPoint(x: 40, y: 86), wood, 2.5)
            arm(cg, to: CGPoint(x: 42, y: 82))
        case .runaway: // a sign with the process name
            line(cg, CGPoint(x: 25, y: 82), CGPoint(x: 27, y: 98), wood, 2.5)
            let board = Path(roundedRect: CGRect(x: 2, y: 54, width: 46, height: 28), cornerRadius: 3)
            fill(cg, board, white())
            stroke(cg, board, ink, 1.5)
            let name = subject.map { $0.count > 8 ? String($0.prefix(7)) + "…" : $0 } ?? "?"
            text(name, at: CGPoint(x: 25, y: 63), size: 9, weight: .bold, color: NSColor(cgColor: ink) ?? .black)
            text("CPU!!", at: CGPoint(x: 25, y: 74), size: 8, weight: .heavy, color: .systemRed)
            arm(cg, to: CGPoint(x: 29, y: 92))
        case .update: // a gift box
            let box = Path(CGRect(x: 26, y: 78, width: 22, height: 20))
            fill(cg, box, rgb(0.98, 0.42, 0.45))
            stroke(cg, box, rgb(0.75, 0.2, 0.25), 1.2)
            fill(cg, Path(CGRect(x: 35.8, y: 78, width: 2.5, height: 20)), gold)
            fill(cg, Path(CGRect(x: 26, y: 86.8, width: 22, height: 2.5)), gold)
            for x in [30.5, 37.5] { stroke(cg, Path(ellipseIn: CGRect(x: x, y: 72, width: 6.5, height: 6)), gold, 2) }
            arm(cg, to: CGPoint(x: 47, y: 88))
        case nil: // empty-handed, swinging
            arm(cg, to: CGPoint(x: 53 - swing * 4, y: 97))
        }
    }

    private static func drawCable(_ cg: CGContext) {
        var c = Path(); c.move(to: CGPoint(x: 37, y: 98))
        c.addCurve(to: CGPoint(x: 60, y: 117), control1: CGPoint(x: 36, y: 110), control2: CGPoint(x: 46, y: 117))
        c.addLine(to: CGPoint(x: 120, y: 117))
        stroke(cg, c, cable, 2.5)
    }

    private static func plug(_ cg: CGContext, _ r: CGRect, prongsUp: Bool) {
        fill(cg, Path(roundedRect: r, cornerRadius: 2), CGColor(gray: 0.3, alpha: 1))
        let prong = CGColor(gray: 0.6, alpha: 1)
        if prongsUp {
            for x in [r.minX + 2.5, r.maxX - 2.5] { line(cg, CGPoint(x: x, y: r.minY), CGPoint(x: x, y: r.minY - 4.5), prong, 1.6) }
        } else {
            for y in [r.minY + 2.5, r.maxY - 2.5] { line(cg, CGPoint(x: r.minX, y: y), CGPoint(x: r.minX - 4.5, y: y), prong, 1.6) }
        }
    }

    /// A small battery icon above the head, so the battery alerts read at a glance.
    private static func battery(_ cg: CGContext, level: CGFloat, color: CGColor) {
        let r = CGRect(x: 92, y: 9, width: 15, height: 8.5)
        let shell = Path(roundedRect: r, cornerRadius: 2)
        fill(cg, shell, white())
        stroke(cg, shell, ink, 1.3)
        fill(cg, Path(roundedRect: CGRect(x: r.maxX + 0.6, y: r.midY - 1.7, width: 1.8, height: 3.4), cornerRadius: 0.8), ink)
        fill(cg, Path(roundedRect: CGRect(x: r.minX + 1.6, y: r.minY + 1.6, width: max(2.5, (r.width - 3.2) * level), height: r.height - 3.2),
                      cornerRadius: 1), color)
    }

    private static func arm(_ cg: CGContext, to hand: CGPoint) { line(cg, shoulder, hand, blue, 6) }

    private static func drop(_ cg: CGContext, _ at: CGPoint) {
        var p = Path(); p.move(to: CGPoint(x: at.x, y: at.y - 5))
        p.addQuadCurve(to: CGPoint(x: at.x, y: at.y + 4), control: CGPoint(x: at.x + 5.5, y: at.y + 2.5))
        p.addQuadCurve(to: CGPoint(x: at.x, y: at.y - 5), control: CGPoint(x: at.x - 5.5, y: at.y + 2.5))
        fill(cg, p, sweat)
        stroke(cg, p, white(0.8), 0.8)
    }

    private static func sparkle(_ cg: CGContext, _ at: CGPoint, _ r: CGFloat) {
        var p = Path(); p.move(to: CGPoint(x: at.x, y: at.y - r))
        for (dx, dy) in [(1.0, 0.0), (0.0, 1.0), (-1.0, 0.0), (0.0, -1.0)] {
            p.addQuadCurve(to: CGPoint(x: at.x + dx * r, y: at.y + dy * r), control: at)
        }
        fill(cg, p, gold)
    }

    /// Centered text. Uses AppKit string drawing in the current (flipped) graphics context.
    private static func text(_ s: String, at: CGPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
        let sz = (s as NSString).size(withAttributes: attrs)
        (s as NSString).draw(at: CGPoint(x: at.x - sz.width / 2, y: at.y - sz.height / 2), withAttributes: attrs)
    }

    private static func fill(_ cg: CGContext, _ p: Path, _ color: CGColor) {
        cg.addPath(p.cgPath); cg.setFillColor(color); cg.fillPath()
    }

    private static func stroke(_ cg: CGContext, _ p: Path, _ color: CGColor, _ width: CGFloat) {
        cg.addPath(p.cgPath)
        cg.setStrokeColor(color); cg.setLineWidth(width); cg.setLineCap(.round); cg.setLineJoin(.round)
        cg.strokePath()
    }

    private static func line(_ cg: CGContext, _ a: CGPoint, _ b: CGPoint, _ color: CGColor, _ width: CGFloat) {
        var p = Path(); p.move(to: a); p.addLine(to: b)
        stroke(cg, p, color, width)
    }

    private static func circle(_ c: CGPoint, _ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)) }

    private static func poly(_ pts: [(CGFloat, CGFloat)]) -> Path {
        var p = Path()
        p.addLines(pts.map { CGPoint(x: $0.0, y: $0.1) })
        p.closeSubpath()
        return p
    }
}

// MARK: - Settings

struct CharacterSettingsSection: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var model: AppModel

    var body: some View {
        Section("Desktop character") {
            Picker("Battery, heat and runaway alerts", selection: $settings.alertStyle) {
                ForEach(AlertStyle.allCases) { Text($0.title).tag($0) }
            }
            Picker("Update alerts", selection: $settings.updateAlertStyle) {
                ForEach(AlertStyle.allCases) { Text($0.title).tag($0) }
            }
            LabeledContent("Water reminders", value: "Set under Water reminders → Show as")
            Menu("Show a test character") {
                ForEach(CharacterAlertKind.allCases, id: \.self) { k in Button(k.testTitle) { model.character.test(k) } }
            }
            .fixedSize()
            Text("Off unless an alert is shown as Character. The character walks in from the side of the screen and stays until you click one of its buttons. It never appears while the screen is shared, recorded or mirrored: if a share starts, it disappears at once and comes back when the share ends, if the alert still applies. It also waits while you're away and while reminders are paused. It never takes keyboard focus.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: settings.alertStyle) { if settings.alertStyle == .notification { model.notifier.requestAuthorization() } }
        .onChange(of: settings.updateAlertStyle) { if settings.updateAlertStyle == .notification { model.notifier.requestAuthorization() } }
    }
}
