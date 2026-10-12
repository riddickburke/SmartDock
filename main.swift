import Cocoa
import ServiceManagement

// MARK: - Low-level Dock control

/// Toggles Dock auto-hide instantly (no `killall Dock`, so no flicker).
/// Primary path: the CoreDock call that Hammerspoon & co. use (no permissions needed).
/// Fallback: System Events AppleScript (needs Automation permission).
enum DockControl {
    private typealias SetFn = @convention(c) (UInt8) -> Void
    private typealias GetFn = @convention(c) () -> UInt8

    private static let lib = dlopen(
        "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)

    private static func sym(_ name: String) -> UnsafeMutableRawPointer? {
        if let h = DockControl.lib, let s = dlsym(h, name) { return s }
        return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) // RTLD_DEFAULT
    }

    private static let setFn: SetFn? = {
        guard let s = DockControl.sym("CoreDockSetAutoHideEnabled") else { return nil }
        return unsafeBitCast(s, to: SetFn.self)
    }()

    private static let getFn: GetFn? = {
        guard let s = DockControl.sym("CoreDockGetAutoHideEnabled") else { return nil }
        return unsafeBitCast(s, to: GetFn.self)
    }()

    static func isAutoHide() -> Bool {
        if let g = getFn { return g() != 0 }
        let dom = "com.apple.dock" as CFString
        CFPreferencesAppSynchronize(dom)
        return (CFPreferencesCopyAppValue("autohide" as CFString, dom) as? Bool) ?? false
    }

    static func setAutoHide(_ on: Bool) {
        if let s = setFn { s(on ? 1 : 0); return }
        let src = "tell application \"System Events\" to set autohide of dock preferences to \(on)"
        var err: NSDictionary?
        NSAppleScript(source: src)?.executeAndReturnError(&err)
        if let err = err { NSLog("SmartDock AppleScript error: \(err)") }
    }
}

// MARK: - Screen helpers

enum DockEdge { case bottom, left, right }

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
    /// Frame in global CG coordinates (origin top-left of primary) - same space as CGWindow bounds.
    var cgFrame: CGRect { CGDisplayBounds(displayID) }
}

// MARK: - Controller

final class DockController {
    private let ud = UserDefaults.standard

    // Persistent settings
    var enabled: Bool {
        get { ud.bool(forKey: "enabled") }
        set {
            ud.set(newValue, forKey: "enabled")
            pending = nil
            if newValue {
                original = DockControl.isAutoHide()
                ud.set(original, forKey: "originalAutoHide")
                tick()
            } else {
                restore()
            }
        }
    }
    /// false = hide on ANY overlap with the Dock area; true = only for big (near-maximized) windows
    var largeOnly: Bool {
        get { ud.bool(forKey: "largeOnly") }
        set { ud.set(newValue, forKey: "largeOnly"); tick() }
    }
    var ignored: Set<String> {
        get { Set(ud.stringArray(forKey: "ignored") ?? []) }
        set { ud.set(Array(newValue), forKey: "ignored") }
    }

    // State
    private var original: Bool
    private var pending: Bool?
    private var pendingSince = Date()
    private var lastApply = Date.distantPast
    private var dockDisplay: CGDirectDisplayID?
    private var thickness: [CGDirectDisplayID: CGFloat] = [:]
    private var timer: Timer?

    // Cached Dock prefs
    private var edge: DockEdge = .bottom
    private var tile: CGFloat = 64
    private var prefsRead = Date.distantPast

    init() {
        ud.register(defaults: ["enabled": true, "largeOnly": false])
        // If we crashed while managing the Dock, keep the ORIGINAL user setting we saved earlier.
        if ud.bool(forKey: "managing"), ud.object(forKey: "originalAutoHide") != nil {
            original = ud.bool(forKey: "originalAutoHide")
        } else {
            original = DockControl.isAutoHide()
            ud.set(original, forKey: "originalAutoHide")
        }
    }

    func start() {
        let t = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        timer = t

        let ws = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.activeSpaceDidChangeNotification,
                  NSWorkspace.didActivateApplicationNotification,
                  NSWorkspace.didHideApplicationNotification,
                  NSWorkspace.didUnhideApplicationNotification,
                  NSWorkspace.didWakeNotification] {
            ws.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.tick() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Monitor plugged/unplugged/rearranged: forget geometry, re-learn it.
            self?.thickness.removeAll()
            self?.pending = nil
            self?.tick()
        }
        tick()
    }

    func shutdown() {
        timer?.invalidate()
        restore()
    }

    private func restore() {
        if DockControl.isAutoHide() != original { DockControl.setAutoHide(original) }
        ud.set(false, forKey: "managing")
    }

    private func apply(_ hide: Bool) {
        ud.set(true, forKey: "managing")
        DockControl.setAutoHide(hide)
        lastApply = Date()
        pending = nil
    }

    // MARK: Geometry

    private func refreshPrefs() {
        guard Date().timeIntervalSince(prefsRead) > 1 else { return }
        prefsRead = Date()
        let dom = "com.apple.dock" as CFString
        CFPreferencesAppSynchronize(dom)
        let o = (CFPreferencesCopyAppValue("orientation" as CFString, dom) as? String) ?? "bottom"
        let newEdge: DockEdge = (o == "left") ? .left : (o == "right") ? .right : .bottom
        if newEdge != edge { edge = newEdge; thickness.removeAll() }
        if let t = CFPreferencesCopyAppValue("tilesize" as CFString, dom) as? NSNumber {
            tile = CGFloat(t.doubleValue)
        }
    }

    /// Size of the Dock strip on this screen, measured while the Dock is visible.
    private func measure(_ s: NSScreen) -> CGFloat {
        switch edge {
        case .bottom: return s.visibleFrame.minY - s.frame.minY
        case .left:   return s.visibleFrame.minX - s.frame.minX
        case .right:  return s.frame.maxX - s.visibleFrame.maxX
        }
    }

    private func dockZone(on f: CGRect, thickness tk: CGFloat) -> CGRect {
        switch edge {
        case .bottom: return CGRect(x: f.minX, y: f.maxY - tk, width: f.width, height: tk).insetBy(dx: 0, dy: -4)
        case .left:   return CGRect(x: f.minX, y: f.minY, width: tk, height: f.height).insetBy(dx: -4, dy: 0)
        case .right:  return CGRect(x: f.maxX - tk, y: f.minY, width: tk, height: f.height).insetBy(dx: -4, dy: 0)
        }
    }

    // MARK: Main loop

    func tick() {
        guard enabled else { return }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        refreshPrefs()

        let now = Date()
        let hidden = DockControl.isAutoHide()

        // While the Dock is visible and settled, learn which display it's on and how thick it is.
        if !hidden && now.timeIntervalSince(lastApply) > 1.5 {
            for s in screens {
                let t = measure(s)
                if t > 12 {
                    thickness[s.displayID] = t
                    dockDisplay = s.displayID
                    break
                }
            }
        }

        // Only ever look at the display that owns the Dock (default: primary).
        let target = screens.first { $0.displayID == dockDisplay } ?? screens[0]
        let f = target.cgFrame
        let zone = dockZone(on: f, thickness: thickness[target.displayID] ?? (tile + 36))

        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return }
        let me = Int(ProcessInfo.processInfo.processIdentifier)
        let ignoredNow = ignored
        let large = largeOnly

        var overlap = false
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,                 // normal app windows only
                  let pid = w[kCGWindowOwnerPID as String] as? Int, pid != me,
                  let owner = w[kCGWindowOwnerName as String] as? String,
                  owner != "Dock", !ignoredNow.contains(owner),
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let bd = w[kCGWindowBounds as String] as? [String: Any],
                  let r = CGRect(dictionaryRepresentation: bd as CFDictionary),
                  r.width >= 60, r.height >= 40
            else { continue }

            let i = zone.intersection(r)
            guard !i.isNull, i.width > 1, i.height > 1 else { continue }
            if large && !(r.width >= f.width * 0.8 && r.height >= f.height * 0.7) { continue }
            overlap = true
            break
        }

        // Debounce: hide quickly, show a little slower, never re-apply the same state.
        if overlap == hidden { pending = nil; return }
        if pending != overlap { pending = overlap; pendingSince = now; return }
        let delay: TimeInterval = overlap ? 0.12 : 0.35
        if now.timeIntervalSince(pendingSince) >= delay { apply(overlap) }
    }
}

// MARK: - App / menu bar UI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let controller = DockController()
    var item: NSStatusItem!
    var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        var img: NSImage?
        for name in ["dock.rectangle", "rectangle.bottomthird.inset.filled", "rectangle"] {
            img = NSImage(systemSymbolName: name, accessibilityDescription: "SmartDock")
            if img != nil { break }
        }
        if let img = img { img.isTemplate = true; item.button?.image = img } else { item.button?.title = "▁" }
        refreshIcon()

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        // Restore the user's Dock setting on kill/Ctrl-C as well as on normal quit.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApp.terminate(nil) }
            src.resume()
            signalSources.append(src)
        }
        controller.start()
    }

    func applicationWillTerminate(_ n: Notification) { controller.shutdown() }

    func refreshIcon() { item.button?.appearsDisabled = !controller.enabled }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let c = controller

        func add(_ title: String, _ sel: Selector, on: Bool = false, to m: NSMenu = menu) {
            let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            mi.target = self
            mi.state = on ? .on : .off
            m.addItem(mi)
        }

        add("Enabled", #selector(toggleEnabled), on: c.enabled)
        menu.addItem(.separator())
        add("Hide when any window overlaps the Dock", #selector(setModeAny), on: !c.largeOnly)
        add("Hide only for maximized-size windows", #selector(setModeLarge), on: c.largeOnly)
        menu.addItem(.separator())

        if let name = NSWorkspace.shared.frontmostApplication?.localizedName,
           name != ProcessInfo.processInfo.processName {
            let mi = NSMenuItem(title: "Ignore “\(name)”", action: #selector(ignoreFront), keyEquivalent: "")
            mi.target = self
            mi.representedObject = name
            menu.addItem(mi)
        }
        let sub = NSMenu()
        if c.ignored.isEmpty {
            let none = NSMenuItem(title: "None", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        } else {
            for name in c.ignored.sorted() {
                let mi = NSMenuItem(title: "Remove “\(name)”", action: #selector(removeIgnored(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = name
                sub.addItem(mi)
            }
        }
        let subItem = NSMenuItem(title: "Ignored Apps", action: nil, keyEquivalent: "")
        subItem.submenu = sub
        menu.addItem(subItem)
        menu.addItem(.separator())

        if #available(macOS 13.0, *) {
            add("Launch at Login", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled)
        }
        let quit = NSMenuItem(title: "Quit SmartDock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    @objc func toggleEnabled() { controller.enabled.toggle(); refreshIcon() }
    @objc func setModeAny() { controller.largeOnly = false }
    @objc func setModeLarge() { controller.largeOnly = true }

    @objc func ignoreFront(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        controller.ignored.insert(name)
        controller.tick()
    }

    @objc func removeIgnored(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        controller.ignored.remove(name)
        controller.tick()
    }

    @objc func toggleLogin() {
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
                else { try SMAppService.mainApp.register() }
            } catch { NSLog("SmartDock login item error: \(error)") }
        }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
