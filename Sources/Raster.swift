import AppKit
import ApplicationServices
import ServiceManagement
import UniformTypeIdentifiers

@main
enum RasterApp {
    static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = Store()
    private let rasterMenu = NSMenu()
    private var settings: SettingsController?
    private var appSlots: [Slot] = []
    private var rasterItem: NSStatusItem?
    private var overflow: [Entry] = []
    private var measureGeneration = 0
    private var measuring = false
    private var shownRunning: [String: Bool] = [:]
    private var screenDebounce: DispatchWorkItem?
    private var collapsed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        collapsed = UserDefaults.standard.bool(forKey: "rowCollapsed")
        store.load()
        rasterMenu.delegate = self
        let settings = SettingsController(store: store)
        settings.onChange = { [weak self] in self?.present(remeasure: false) }
        settings.onLoginToggle = { [weak self] in self?.toggleLogin() }
        self.settings = settings
        installMenus()
        watch()
        present()
        DispatchQueue.main.async {
            WindowReveal.promptIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        clearItems()
    }

    // MARK: - Menu bar

    /// `remeasure` is for launch, screen changes, and showing the row. Reordering keeps the icons that are already up.
    private func present(remeasure: Bool = true) {
        measureGeneration += 1
        let generation = measureGeneration
        if collapsed {
            measuring = false
            show(limit: 0)
            return
        }
        let countChanged = appSlots.count + overflow.count != store.entries().count
        if !remeasure, !countChanged, rasterItem != nil {
            measuring = false
            show(limit: appSlots.count)
            return
        }
        measuring = true
        ensureRaster()
        clearApps()
        measureCapacity { [weak self] measured in
            guard let self, generation == self.measureGeneration else { return }
            self.show(limit: measured)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                self.settle(generation: generation)
            }
        }
    }

    /// If the first layout spilled off the menu bar, drop the extras once. Raster stays where it is.
    private func settle(generation: Int, waits: Int = 0) {
        guard generation == measureGeneration else { return }
        if slotsNotReady() {
            if waits < 25 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.settle(generation: generation, waits: waits + 1)
                }
            } else {
                measuring = false
                debug("gave up, the menu bar was not laid out")
            }
            return
        }
        let appsOn = appSlots.filter { self.isOnMenuBar($0.item) }.count
        let rasterOn = rasterItem.map { isOnMenuBar($0) } ?? false
        if rasterOn && appsOn == appSlots.count {
            measuring = false
            let rasterX = rasterItem?.button?.window?.frame.minX ?? -1
            let leftX = appSlots.last?.item.button?.window?.frame.minX ?? rasterX
            debug(String(format: "%d on the bar, %d in the menu, left %.0f, raster %.0f", appsOn, overflow.count, leftX, rasterX))
            refreshTooltips()
            return
        }
        let next = rasterOn ? appsOn : max(0, min(appsOn, appSlots.count - 1))
        if next < appSlots.count {
            show(limit: next)
            debug("settled to \(next)")
        }
        measuring = false
    }

    private func correctIfNeeded() {
        guard !collapsed, !measuring, !slotsNotReady() else { return }
        let rasterOn = rasterItem.map { isOnMenuBar($0) } ?? false
        let appsOn = appSlots.filter { self.isOnMenuBar($0.item) }.count
        guard rasterOn && appsOn == appSlots.count else {
            settle(generation: measureGeneration)
            return
        }
    }

    /// First created sits nearest the clock. Raster is created first, so it stays at the right end. Apps are created from the end of the list, so the top of the list is on the left.
    private func show(limit: Int) {
        let usable = store.entries()
        let count = max(0, min(limit, usable.count))
        let shown = Array(usable.prefix(count))
        overflow = Array(usable.dropFirst(count))
        ensureRaster()
        clearApps()
        for entry in shown.reversed() {
            appSlots.append(makeAppItem(entry))
        }
        debug("show \(count)")
        refreshTooltips()
    }

    private func ensureRaster() {
        let item: NSStatusItem
        if let rasterItem {
            item = rasterItem
        } else {
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let button = item.button {
                button.image = AppGlyph.image
                button.imageScaling = .scaleProportionallyDown
                button.target = self
                button.action = #selector(rasterClicked(_:))
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            }
            rasterItem = item
        }
        item.button?.toolTip = collapsed ? "Show apps" : "Hide apps"
        item.button?.setAccessibilityLabel(collapsed ? "Raster, apps hidden" : "Raster")
    }

    @objc private func rasterClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            sender.isHighlighted = true
            rasterMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
            sender.isHighlighted = false
            return
        }
        collapsed.toggle()
        UserDefaults.standard.set(collapsed, forKey: "rowCollapsed")
        present()
    }

    private func makeAppItem(_ entry: Entry) -> Slot {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let open = runningApp(entry.url) != nil
        shownRunning[Store.canonical(entry.url)] = open
        if let button = item.button {
            button.image = Icons.barIcon(url: entry.url, running: open)
            button.imageScaling = .scaleProportionallyDown
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(appClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = entry.name
            button.setAccessibilityLabel(open ? "\(entry.name), running" : entry.name)
        }
        return Slot(url: entry.url, item: item)
    }

    private func clearApps() {
        for slot in appSlots {
            NSStatusBar.system.removeStatusItem(slot.item)
        }
        appSlots.removeAll()
        shownRunning.removeAll()
    }

    private func clearItems() {
        clearApps()
        if let rasterItem {
            NSStatusBar.system.removeStatusItem(rasterItem)
            self.rasterItem = nil
        }
    }

    /// Measures the free space to the left of the Raster icon, which stays on the bar.
    private func measureCapacity(then: @escaping (Int) -> Void) {
        ensureRaster()
        guard let rasterItem else {
            then(12)
            return
        }
        readFrame(of: rasterItem, tries: 25, requireOnBar: true) { [weak self] frame, screen in
            guard let self else { return }
            self.debug(String(
                format: "raster (%.0f,%.0f %.0fx%.0f) screen %@ top %.0f aux %@",
                frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
                screen?.localizedName ?? "nil",
                screen?.frame.maxY ?? -1,
                String(describing: screen?.auxiliaryTopRightArea)
            ))
            let slot = max(frame.width, 24)
            let right = frame.minX
            guard self.isOnMenuBar(frame, screen: screen), right > slot else {
                then(12)
                return
            }
            let attempts = [right - 24, 1000, 720, 480, 320, 220].filter { $0 > slot }
            self.probeWall(attempts: attempts, slot: slot, right: right, then: then)
        }
    }

    private func readFrame(of item: NSStatusItem, tries: Int, requireOnBar: Bool = false, then: @escaping (NSRect, NSScreen?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            let frame = item.button?.window?.frame ?? .zero
            let screen = item.button?.window?.screen ?? NSScreen.main
            let placed = frame.height > 2 && (!requireOnBar || (self?.isOnMenuBar(frame, screen: screen) ?? false))
            if placed || tries <= 0 || self == nil {
                then(frame, screen)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self?.readFrame(of: item, tries: tries - 1, requireOnBar: requireOnBar, then: then)
                }
            }
        }
    }

    private func probeWall(attempts: [CGFloat], slot: CGFloat, right: CGFloat, then: @escaping (Int) -> Void) {
        guard let length = attempts.first else {
            then(max(4, Int((right * 0.4) / slot) - 1))
            return
        }
        let wide = NSStatusBar.system.statusItem(withLength: length)
        wide.button?.alphaValue = 0
        readFrame(of: wide, tries: 25) { [weak self] frame, screen in
            guard let self else { return }
            NSStatusBar.system.removeStatusItem(wide)
            if self.isOnMenuBar(frame, screen: screen) {
                let left = frame.minX
                let apps = max(0, Int(floor((right - left - 4) / slot)))
                self.debug(String(format: "lane %.0f–%.0f, slot %.0f, room for %d", left, right, slot, apps))
                then(apps)
            } else {
                self.probeWall(attempts: Array(attempts.dropFirst()), slot: slot, right: right, then: then)
            }
        }
    }

    private func isOnMenuBar(_ item: NSStatusItem) -> Bool {
        guard let window = item.button?.window else { return false }
        return isOnMenuBar(window.frame, screen: window.screen)
    }

    private func isOnMenuBar(_ frame: CGRect, screen: NSScreen?) -> Bool {
        guard let screen, frame.width > 2, frame.height > 2 else { return false }
        if abs(frame.maxY - screen.frame.maxY) > 6 { return false }
        if frame.minX <= 1 { return false }
        if let lane = screen.auxiliaryTopRightArea, lane.width > 20, frame.minX < lane.minX - 2 {
            return false
        }
        return true
    }

    private func slotsNotReady() -> Bool {
        let items = appSlots.map(\.item) + (rasterItem.map { [$0] } ?? [])
        return items.contains { ($0.button?.window?.frame.height ?? 0) < 2 }
    }

    private func watch() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification
        ]
        for name in names {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                self?.refreshTooltips()
                if note.name == NSWorkspace.didActivateApplicationNotification {
                    self?.correctIfNeeded()
                }
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.screenDebounce?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.present() }
            self.screenDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
            self?.correctIfNeeded()
        }
        timer.tolerance = 2
    }

    // MARK: - Clicks

    @objc private func appClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent, let url = url(for: sender) else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            popContext(for: url, button: sender)
        } else {
            reveal(url)
        }
    }

    private func url(for button: NSStatusBarButton) -> URL? {
        appSlots.first { $0.item.button === button }?.url
    }

    private func reveal(_ url: URL) {
        if let running = runningApp(url) {
            if WindowReveal.shouldHide(running) {
                running.hide()
            } else {
                WindowReveal.show(running)
            }
            refreshTooltips()
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                self?.alert("Could not open \(Store.displayName(url)).", detail: error.localizedDescription)
            }
        }
    }

    private func popContext(for url: URL, button: NSStatusBarButton) {
        let running = runningApp(url)
        let menu = NSMenu()

        let hide = NSMenuItem(title: "Hide", action: #selector(hideApp(_:)), keyEquivalent: "")
        hide.target = self
        hide.representedObject = url.path as NSString
        hide.isEnabled = running != nil && running?.isHidden == false

        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp(_:)), keyEquivalent: "")
        quit.target = self
        quit.representedObject = url.path as NSString
        quit.isEnabled = running != nil

        let finder = NSMenuItem(title: "Show in Finder", action: #selector(revealApp(_:)), keyEquivalent: "")
        finder.target = self
        finder.representedObject = url.path as NSString

        let remove = NSMenuItem(title: "Remove from Bar", action: #selector(removeApp(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = url.path as NSString

        menu.addItem(hide)
        menu.addItem(quit)
        menu.addItem(finder)
        menu.addItem(.separator())
        menu.addItem(remove)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu == rasterMenu else { return }
        menu.removeAllItems()
        if !overflow.isEmpty {
            for entry in overflow {
                let item = NSMenuItem(title: entry.name, action: #selector(openOverflow(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.url.path as NSString
                item.image = Icons.menuIcon(url: entry.url, running: runningApp(entry.url) != nil)
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let privacyItem = NSMenuItem(title: "Privacy", action: #selector(showPrivacy), keyEquivalent: "")
        privacyItem.target = self
        menu.addItem(privacyItem)

        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLoginFromMenu), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Raster", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func openOverflow(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        reveal(URL(fileURLWithPath: path))
    }

    @objc private func hideApp(_ sender: NSMenuItem) {
        guard let url = url(from: sender), let running = runningApp(url) else { return }
        running.hide()
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        guard let url = url(from: sender), let running = runningApp(url) else { return }
        running.terminate()
    }

    @objc private func revealApp(_ sender: NSMenuItem) {
        guard let url = url(from: sender) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func removeApp(_ sender: NSMenuItem) {
        guard let url = url(from: sender) else { return }
        store.remove(path: url.path)
        settings?.reload()
        present()
    }

    @objc private func showSettings() {
        settings?.show()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showPrivacy() {
        PrivacyWindow.show()
        NSApp.activate(ignoringOtherApps: true)
    }

    static func returnToMenuBarIfIdle() {
        let visible = NSApp.windows.contains { $0.isVisible }
        if !visible {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    @objc private func toggleLoginFromMenu() {
        toggleLogin()
    }

    private func url(from item: NSMenuItem) -> URL? {
        (item.representedObject as? String).map { URL(fileURLWithPath: $0) }
    }

    private func runningApp(_ url: URL) -> NSRunningApplication? {
        let path = Store.canonical(url)
        let bid = Bundle(url: url)?.bundleIdentifier
        return NSWorkspace.shared.runningApplications.first { app in
            if let bid, app.bundleIdentifier == bid { return true }
            if let other = app.bundleURL, Store.canonical(other) == path { return true }
            return false
        }
    }

    private func refreshTooltips() {
        for slot in appSlots {
            let name = Store.displayName(slot.url)
            let running = runningApp(slot.url)
            let open = running != nil
            let key = Store.canonical(slot.url)
            if shownRunning[key] != open {
                shownRunning[key] = open
                slot.item.button?.image = Icons.barIcon(url: slot.url, running: open)
                slot.item.button?.setAccessibilityLabel(open ? "\(name), running" : name)
            }
            let tip: String
            if let running, running.isActive, !running.isHidden {
                tip = "\(name) — click to hide"
            } else if running != nil {
                tip = "\(name) — running"
            } else {
                tip = name
            }
            slot.item.button?.toolTip = tip
        }
    }

    // MARK: - Login

    private func installMenus() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(NSMenuItem(title: "About Raster", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        let privacyItem = NSMenuItem(title: "Privacy", action: #selector(showPrivacy), keyEquivalent: "")
        privacyItem.target = self
        appMenu.addItem(privacyItem)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Raster", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }

    private func toggleLogin() {
        let service = SMAppService.mainApp
        switch service.status {
        case .enabled:
            do {
                try service.unregister()
            } catch {
                alert("Could not change Open at Login.", detail: error.localizedDescription)
            }
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
        default:
            do {
                try service.register()
            } catch {
                alert("Could not change Open at Login.", detail: error.localizedDescription)
            }
        }
        settings?.reloadLogin()
    }

    private func alert(_ message: String, detail: String?) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Raster"
        alert.informativeText = detail.map { "\(message)\n\n\($0)" } ?? message
        alert.runModal()
    }

    private func debug(_ message: String) {
        guard ProcessInfo.processInfo.environment["RASTER_DEBUG"] == "1" else { return }
        let line = "Raster: \(message)\n"
        fputs(line, stderr)
        fflush(stderr)
        if let data = line.data(using: .utf8) {
            let url = URL(fileURLWithPath: "/tmp/raster-status.txt")
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}

private enum WindowReveal {
    private static var prompted = false

    /// Hide only when a window is actually on screen. Minimized and hidden apps get shown instead.
    static func shouldHide(_ app: NSRunningApplication) -> Bool {
        guard app.isActive, !app.isHidden else { return false }
        if case .yes = visibleWindow(app) { return true }
        return false
    }

    static func show(_ app: NSRunningApplication) {
        app.unhide()
        switch visibleWindow(app) {
        case .yes:
            bringForward(app)
        case .no(let windows):
            for window in windows where deminiaturize(window) {
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            }
            bringForward(app)
            if windows.isEmpty {
                sendReopen(app.processIdentifier)
            }
        case .unknown:
            promptForAccess()
            bringForward(app)
        }
    }

    static func promptIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        promptForAccess()
    }

    /// Ask macOS to activate this app from Raster, then fall back to Launch Services.
    private static func bringForward(_ app: NSRunningApplication) {
        NSApp.yieldActivation(to: app)
        if app.activate(from: .current, options: [.activateAllWindows]) { return }
        guard let url = app.bundleURL else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    private enum Windows {
        case yes
        case no([AXUIElement])
        case unknown
    }

    private static func visibleWindow(_ app: NSRunningApplication) -> Windows {
        guard let windows = windows(of: app) else { return .unknown }
        if windows.contains(where: { !isMinimized($0) }) { return .yes }
        return .no(windows)
    }

    /// `nil` means Accessibility did not answer. An empty list means the app has no windows.
    private static func windows(of app: NSRunningApplication) -> [AXUIElement]? {
        guard AXIsProcessTrusted() else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement] ?? []
    }

    private static func isMinimized(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success else { return false }
        if let flag = value as? Bool { return flag }
        return (value as? NSNumber)?.boolValue ?? false
    }

    @discardableResult
    private static func deminiaturize(_ window: AXUIElement) -> Bool {
        guard isMinimized(window) else { return false }
        return AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success
    }

    private static func promptForAccess() {
        guard !prompted else { return }
        prompted = true
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private static func sendReopen(_ pid: pid_t) {
        var target = AEAddressDesc()
        var process = pid
        guard AECreateDesc(typeKernelProcessID, &process, MemoryLayout.size(ofValue: process), &target) == noErr else { return }
        defer { AEDisposeDesc(&target) }

        var event = AppleEvent()
        guard AECreateAppleEvent(
            kCoreEventClass,
            kAEReopenApplication,
            &target,
            AEReturnID(kAutoGenerateReturnID),
            AETransactionID(kAnyTransactionID),
            &event
        ) == noErr else { return }
        defer { AEDisposeDesc(&event) }
        AESendMessage(&event, nil, AESendMode(kAENoReply), kAEDefaultTimeout)
    }
}

private struct Slot {
    let url: URL
    let item: NSStatusItem
}

private struct Entry {
    let url: URL
    let name: String
}

private struct PinnedApp: Codable {
    var path: String
    var bookmark: Data?
}

private final class Store {
    private(set) var pinned: [PinnedApp] = []
    private let defaults = UserDefaults.standard

    func load() {
        if let data = defaults.data(forKey: "pinnedApps"),
           let decoded = try? JSONDecoder().decode([PinnedApp].self, from: data) {
            pinned = decoded
            return
        }
        pinned = Self.dockApps()
        save()
    }

    func save() {
        if let data = try? JSONEncoder().encode(pinned) {
            defaults.set(data, forKey: "pinnedApps")
        }
    }

    func entries() -> [Entry] {
        pinned.compactMap { pin in
            guard let url = resolve(pin) else { return nil }
            return Entry(url: url, name: Self.displayName(url))
        }
    }

    func add(urls: [URL]) {
        for url in urls {
            guard url.pathExtension == "app" else { continue }
            let path = Self.canonical(url)
            guard FileManager.default.fileExists(atPath: path) else { continue }
            if pinned.contains(where: { Self.canonical(URL(fileURLWithPath: $0.path)) == path }) { continue }
            let bookmark = try? URL(fileURLWithPath: path).bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            pinned.append(PinnedApp(path: path, bookmark: bookmark))
        }
        save()
    }

    func remove(at indexes: IndexSet) {
        pinned = pinned.enumerated().filter { !indexes.contains($0.offset) }.map(\.element)
        save()
    }

    func remove(path: String) {
        let needle = Self.canonical(URL(fileURLWithPath: path))
        pinned.removeAll { pin in
            if Self.canonical(URL(fileURLWithPath: pin.path)) == needle { return true }
            if let url = resolve(pin), Self.canonical(url) == needle { return true }
            return false
        }
        save()
    }

    func move(from: Int, to: Int) {
        guard pinned.indices.contains(from) else { return }
        let item = pinned.remove(at: from)
        let dest = max(0, min(to, pinned.count))
        pinned.insert(item, at: dest)
        save()
    }

    func resolve(_ pin: PinnedApp) -> URL? {
        if let bookmark = pin.bookmark {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withoutUI, .withoutMounting],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ), FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        let path = pin.path
        if FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let name = URL(fileURLWithPath: path).lastPathComponent
        let alternatives = [
            "/Applications/\(name)",
            "/System/Applications/\(name)",
            "/System/Volumes/Preboot/Cryptexes/App/System/Applications/\(name)"
        ]
        return alternatives.first { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    static func displayName(_ url: URL) -> String {
        FileManager.default.displayName(atPath: url.path)
    }

    static func canonical(_ url: URL) -> String {
        var path = url.resolvingSymlinksInPath().standardizedFileURL.path
        if path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private static func dockApps() -> [PinnedApp] {
        let dockURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.apple.dock.plist")
        guard let data = try? Data(contentsOf: dockURL),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let tiles = root["persistent-apps"] as? [[String: Any]] else { return [] }

        var apps: [PinnedApp] = []
        var seen = Set<String>()
        for tile in tiles {
            guard let tileData = tile["tile-data"] as? [String: Any],
                  let fileData = tileData["file-data"] as? [String: Any],
                  let raw = fileData["_CFURLString"] as? String,
                  let url = URL(string: raw) else { continue }
            let path = canonical(url)
            guard path.hasSuffix(".app") else { continue }
            guard seen.insert(path).inserted else { continue }
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let bookmark = try? URL(fileURLWithPath: path).bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            apps.append(PinnedApp(path: path, bookmark: bookmark))
        }
        return apps
    }
}

private enum Icons {
    /// Closed apps stay recognizable, but quiet. A dot or ring disappears at menu-bar size.
    static let closedOpacity: CGFloat = 0.4

    static func barIcon(url: URL, running: Bool = true) -> NSImage {
        scaledIcon(url: url, side: 18, running: running)
    }

    static func menuIcon(url: URL, running: Bool) -> NSImage {
        scaledIcon(url: url, side: 16, running: running)
    }

    private static func scaledIcon(url: URL, side: CGFloat, running: Bool) -> NSImage {
        let source = NSWorkspace.shared.icon(forFile: url.path)
        let fraction = running ? 1 : closedOpacity
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: fraction)
            return true
        }
        image.isTemplate = false
        return image
    }
}

private enum AppGlyph {
    static let image: NSImage = {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            // Four overlapping app tiles, matching the application icon.
            for index in stride(from: 3, through: 0, by: -1) {
                let offset = CGFloat(index) * 2.2
                let rect = NSRect(x: 1.4 + offset, y: 1.4 + offset, width: 8.6, height: 8.6)
                let tile = NSBezierPath(roundedRect: rect, xRadius: 1.9, yRadius: 1.9)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current?.cgContext.setBlendMode(.clear)
                tile.lineWidth = 1.4
                tile.stroke()
                NSGraphicsContext.restoreGraphicsState()
                NSColor.black.setFill()
                tile.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()
}

private final class PrivacyWindow: NSObject, NSWindowDelegate {
    static let shared = PrivacyWindow()
    private let window: NSWindow

    private override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "Privacy"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let text = NSTextView()
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 16, height: 16)
        text.string = Self.policy
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = text
        window.contentView = scroll
    }

    static func show() {
        shared.window.center()
        shared.window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async {
            AppDelegate.returnToMenuBarIfIdle()
        }
    }

    private static let policy: String = {
        guard let url = Bundle.main.url(forResource: "PrivacyPolicy", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.isEmpty else {
            return "The privacy policy is missing from the app."
        }
        return text
    }()
}

private final class SettingsController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    let store: Store
    var onChange: () -> Void = {}
    var onLoginToggle: () -> Void = {}

    private let window: NSWindow
    private let table = NSTableView()
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let loginCheckbox = NSButton(checkboxWithTitle: "Open at Login", target: nil, action: nil)

    init(store: Store) {
        self.store = store
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 624),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "Raster"
        window.isReleasedWhenClosed = false
        window.delegate = self
        build()
    }

    func show() {
        reload()
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func reload() {
        table.reloadData()
        removeButton.isEnabled = table.selectedRow >= 0
        reloadLogin()
    }

    func reloadLogin() {
        loginCheckbox.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async {
            AppDelegate.returnToMenuBarIfIdle()
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        store.pinned.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard store.pinned.indices.contains(row) else { return nil }
        let pin = store.pinned[row]
        let url = store.resolve(pin)
        let missing = url == nil
        let name = url.map(Store.displayName) ?? URL(fileURLWithPath: pin.path).deletingPathExtension().lastPathComponent
        let width = tableColumn?.width ?? tableView.bounds.width
        let height = tableView.rowHeight
        let rowView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let icon = NSImageView(frame: NSRect(x: 4, y: (height - 20) / 2, width: 20, height: 20))
        icon.imageScaling = .scaleProportionallyDown
        if let url {
            icon.image = Icons.barIcon(url: url)
        }
        let field = NSTextField(labelWithString: missing ? "\(name) — not found" : name)
        field.frame = NSRect(x: 32, y: (height - 18) / 2, width: width - 40, height: 18)
        field.lineBreakMode = .byTruncatingTail
        field.textColor = missing ? .secondaryLabelColor : .labelColor
        field.autoresizingMask = [.width]
        rowView.addSubview(icon)
        rowView.addSubview(field)
        return rowView
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: .string)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource as AnyObject === tableView else { return [] }
        if dropOperation == .on {
            let rect = tableView.rect(ofRow: row)
            let location = tableView.convert(info.draggingLocation, from: nil)
            let after = location.y > rect.midY
            tableView.setDropRow(after ? row + 1 : row, dropOperation: .above)
        }
        return .move
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        session.animatesToStartingPositionsOnCancelOrFail = true
        let rows = Array(rowIndexes)
        session.enumerateDraggingItems(options: [], for: tableView, classes: [NSPasteboardItem.self], searchOptions: [:]) { draggingItem, index, _ in
            guard rows.indices.contains(index) else { return }
            let row = rows[index]
            let rect = tableView.frameOfCell(atColumn: 0, row: row)
            if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) {
                draggingItem.setDraggingFrame(rect, contents: cell)
            } else {
                draggingItem.draggingFrame = rect
            }
        }
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard info.draggingSource as AnyObject === tableView else { return false }
        guard let raw = info.draggingPasteboard.string(forType: .string), let from = Int(raw) else { return false }
        var to = row
        if from < to { to -= 1 }
        to = max(0, min(to, store.pinned.count - 1))
        guard from != to else { return true }
        store.move(from: from, to: to)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            table.beginUpdates()
            table.moveRow(at: from, to: to)
            table.endUpdates()
        }
        onChange()
        return true
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton.isEnabled = table.selectedRow >= 0
    }

    private func build() {
        let appColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        appColumn.title = "App"
        appColumn.resizingMask = .autoresizingMask
        table.addTableColumn(appColumn)
        table.headerView = nil
        table.rowHeight = 28
        table.intercellSpacing = NSSize(width: 0, height: 6)
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.registerForDraggedTypes([.string])
        table.draggingDestinationFeedbackStyle = .regular
        table.style = .inset

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = table
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let blurb = NSTextField(wrappingLabelWithString: "The top of the list is on the left. Further apps extend toward the Raster icon. Apps that do not fit are in the Raster menu.")
        blurb.textColor = .secondaryLabelColor
        blurb.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        blurb.preferredMaxLayoutWidth = 400
        blurb.translatesAutoresizingMaskIntoConstraints = false

        let add = NSButton(title: "Add…", target: self, action: #selector(addApps))
        add.bezelStyle = .rounded
        add.translatesAutoresizingMaskIntoConstraints = false

        removeButton.target = self
        removeButton.action = #selector(removeSelected)
        removeButton.bezelStyle = .rounded
        removeButton.isEnabled = false
        removeButton.translatesAutoresizingMaskIntoConstraints = false

        loginCheckbox.target = self
        loginCheckbox.action = #selector(loginClicked)
        loginCheckbox.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(blurb)
        content.addSubview(scroll)
        content.addSubview(add)
        content.addSubview(removeButton)
        content.addSubview(loginCheckbox)

        NSLayoutConstraint.activate([
            blurb.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            blurb.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            blurb.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            scroll.topAnchor.constraint(equalTo: blurb.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: add.topAnchor, constant: -16),

            add.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            add.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),

            removeButton.leadingAnchor.constraint(equalTo: add.trailingAnchor, constant: 8),
            removeButton.centerYAnchor.constraint(equalTo: add.centerYAnchor),

            loginCheckbox.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            loginCheckbox.centerYAnchor.constraint(equalTo: add.centerYAnchor)
        ])

        window.contentView = content
    }

    @objc private func addApps() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.application]
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Add"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            self.store.add(urls: panel.urls)
            self.reload()
            self.onChange()
        }
    }

    @objc private func removeSelected() {
        let indexes = table.selectedRowIndexes
        guard !indexes.isEmpty else { return }
        store.remove(at: indexes)
        reload()
        onChange()
    }

    @objc private func loginClicked() {
        onLoginToggle()
    }
}
