import Cocoa
import QuartzCore

// Eyes come from the FLAT bitmap (rows 4-8), shifted toward the mouse or reshaped per EyeState.
// Mouth rows (10-15) come from whichever bitmap matches the current mouth.
let eyeRows = 4...8
let mouthRowRange = 10..<16
let cropRows = 3..<16      // vertical crop of the 32x16 face
let cropCols = 6..<26      // horizontal crop
let cyan = NSColor(red: 0x31 / 255, green: 0xD8 / 255, blue: 0xFF / 255, alpha: 1)

enum Mouth: String { case flat = "FLAT", smile = "SMILE", wide = "WIDE_TALK", small = "SMALL_O", big = "BIG_O" }
enum EyeState { case open, line, half, wide }

final class FaceView: NSView {
    var scale: CGFloat = 2
    var mouth: Mouth = .flat { didSet { if mouth != oldValue { needsDisplay = true } } }
    var eyeState: EyeState = .open { didSet { if eyeState != oldValue { needsDisplay = true } } }
    var eyeDX = 0 { didSet { if eyeDX != oldValue { needsDisplay = true } } }
    var eyeDY = 0 { didSet { if eyeDY != oldValue { needsDisplay = true } } }
    var cross = 0 { didSet { if cross != oldValue { needsDisplay = true } } }   // pulls eyes toward the nose

    override var isFlipped: Bool { true }

    // (source row, destination row) pairs for each eye shape
    func eyeMap() -> [(Int, Int)] {
        switch eyeState {
        case .open: return eyeRows.map { ($0, $0) }
        case .line: return [(7, 7)]
        case .half: return [(6, 6), (7, 7), (8, 8)]
        case .wide: return eyeRows.map { ($0, $0) } + [(4, 3), (8, 9)]
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 3, yRadius: bounds.height / 3).fill()

        let flat = faceRows["FLAT"]!
        let mouthRows = faceRows[mouth.rawValue]!
        var grid = [[Bool]](repeating: [Bool](repeating: false, count: 32), count: 16)
        func bit(_ row: UInt32, _ x: Int) -> Bool { (row >> UInt32(31 - x)) & 1 == 1 }

        for (src, dst) in eyeMap() {
            for x in 0..<32 where bit(flat[src], x) {
                let nx = x + eyeDX + (x < 16 ? cross : -cross), ny = dst + eyeDY
                if nx >= 0, nx < 32, ny >= 0, ny < 16 { grid[ny][nx] = true }
            }
        }
        for y in mouthRowRange {
            for x in 0..<32 where bit(mouthRows[y], x) { grid[y][x] = true }
        }

        let w = CGFloat(cropCols.count) * scale, h = CGFloat(cropRows.count) * scale
        let ox = ((bounds.width - w) / 2).rounded(), oy = ((bounds.height - h) / 2).rounded()
        cyan.setFill()
        for y in cropRows {
            for x in cropCols where grid[y][x] {
                NSRect(x: ox + CGFloat(x - cropCols.lowerBound) * scale,
                       y: oy + CGFloat(y - cropRows.lowerBound) * scale,
                       width: scale, height: scale).fill()
            }
        }
    }
}

enum Stage { case awake, wander, drowsy, asleep }

final class App: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let view = FaceView()

    // click state
    var talkTimer: Timer?
    var resetTimer: Timer?
    var talkIndex = 0
    var clickMouth: Mouth?

    // behaviour state (times from CACurrentMediaTime)
    var lastMouse = NSEvent.mouseLocation
    var lastActivity = CACurrentMediaTime()
    var nextBlink = CACurrentMediaTime() + 4
    var blinkUntil = 0.0
    var startleUntil = 0.0
    var yawnUntil = 0.0
    var nextWander = 0.0
    var wanderDX = 0, wanderDY = 0

    // Menu-bar-high strip at top centre of main screen (just right of the notch if present).
    func layout() -> NSRect {
        let screen = NSScreen.main!
        let barH = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
        view.scale = CGFloat(max(1, Int((barH - 2) / 11)))
        let size = NSSize(width: CGFloat(cropCols.count) * view.scale + 8, height: barH)
        var cx = screen.frame.midX
        if screen.safeAreaInsets.top > 0, let right = screen.auxiliaryTopRightArea {
            cx = right.minX + 8 + size.width / 2
        }
        return NSRect(origin: NSPoint(x: cx - size.width / 2, y: screen.frame.maxY - barH), size: size)
    }

    @objc func reposition() {
        guard NSScreen.main != nil else { return }
        let r = layout()
        window.setFrame(r, display: true)
        view.frame = NSRect(origin: .zero, size: r.size)
        view.needsDisplay = true
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        guard NSScreen.main != nil else { exit(1) }
        let size = layout().size

        window = NSWindow(contentRect: NSRect(origin: layout().origin, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .statusBar
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        view.frame = NSRect(origin: .zero, size: size)
        window.contentView = view
        window.orderFrontRegardless()
        NotificationCenter.default.addObserver(self, selector: #selector(reposition), name: NSApplication.didChangeScreenParametersNotification, object: nil)

        Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }

        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in self?.pressed() }
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp, .otherMouseUp]) { [weak self] _ in self?.released() }

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(woke), name: NSWorkspace.screensDidWakeNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(woke), name: .init("com.apple.screenIsUnlocked"), object: nil)
    }

    // Mouse moved or clicked. Coming back from drowsy/asleep startles the eyes wide.
    func activity(_ now: Double) {
        if now - lastActivity > 120 { startleUntil = now + 0.5 }
        lastActivity = now
    }

    // Wake from sleep / unlock: yawn (eyes shut, big O), then wide eyes.
    @objc func woke() {
        let now = CACurrentMediaTime()
        lastActivity = now
        yawnUntil = now + 1.2
        lastMouse = NSEvent.mouseLocation
    }

    func tick() {
        let now = CACurrentMediaTime()
        let m = NSEvent.mouseLocation
        if hypot(m.x - lastMouse.x, m.y - lastMouse.y) > 1 { activity(now) }
        lastMouse = m

        let idle = now - lastActivity
        let stage: Stage = idle < 20 ? .awake : idle < 120 ? .wander : idle < 300 ? .drowsy : .asleep

        // blink
        if now >= nextBlink {
            blinkUntil = now + 0.12
            nextBlink = now + (Double.random(in: 0..<1) < 0.25 ? 0.3 : Double.random(in: 3...6))
        }

        // poke: cursor near the face
        let f = window.frame
        let gapX = max(f.minX - m.x, 0, m.x - f.maxX), gapY = max(f.minY - m.y, 0, m.y - f.maxY)
        let dist = hypot(gapX, gapY)
        let poking = dist < 50 && (stage == .awake || stage == .wander)

        // eyes
        if now < yawnUntil { view.eyeState = .line }
        else if now < yawnUntil + 0.5 || now < startleUntil { view.eyeState = .wide }
        else if stage == .asleep { view.eyeState = .line }
        else if stage == .drowsy { view.eyeState = .half }
        else { view.eyeState = now < blinkUntil ? .line : .open }

        if stage == .wander && !poking {
            if now >= nextWander {
                nextWander = now + Double.random(in: 1.2...3)
                wanderDX = Int.random(in: -3...3)
                wanderDY = [-1, 0, 0, 0, 1].randomElement()!
            }
            view.eyeDX = wanderDX
            view.eyeDY = wanderDY
        } else if stage == .drowsy || stage == .asleep {
            view.eyeDX = 0
            view.eyeDY = 0
        } else {
            let c = NSPoint(x: f.midX, y: f.midY)
            let vx = max(-1, min(1, (m.x - c.x) / 250))
            let vy = max(-1, min(1, (c.y - m.y) / 600))   // screen y is up; grid y is down
            view.eyeDX = Int((vx * 3).rounded())
            view.eyeDY = Int(vy.rounded())
        }
        view.cross = poking && dist == 0 ? 2 : 0

        // mouth
        if let c = clickMouth { view.mouth = c }
        else if now < yawnUntil { view.mouth = .big }
        else if poking { view.mouth = .small }
        else { view.mouth = .flat }
    }

    // Held: cycle talking mouths. Released: smile briefly, then flat.
    func pressed() {
        activity(CACurrentMediaTime())
        resetTimer?.invalidate()
        talkTimer?.invalidate()
        let seq: [Mouth] = [.big, .wide, .small, .wide]
        talkIndex = 0
        clickMouth = seq[0]
        talkTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.talkIndex = (self.talkIndex + 1) % seq.count
            self.clickMouth = seq[self.talkIndex]
        }
    }

    func released() {
        talkTimer?.invalidate()
        clickMouth = .smile
        resetTimer?.invalidate()
        resetTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { [weak self] _ in self?.clickMouth = nil }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = App()
app.delegate = delegate
app.run()
