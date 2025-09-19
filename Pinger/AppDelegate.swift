//
//  AppDelegate.swift
//  Pinger
//
//  Created by Dawid Deregowski on 19/09/2025.
//

import Cocoa
import UserNotifications

// MARK: - Config & keys
fileprivate enum Config {
    static var intervalSeconds: TimeInterval = 1.0
    static var upThreshold = 2
    static var downThreshold = 2
    static let pingPath = "/sbin/ping"                   // App Sandbox OFF required
    static let defaultHosts = ["1.1.1.1", "8.8.8.8", "9.9.9.9"]
    static let appAuthor = "deregowski.net © 2025"
}

fileprivate enum PrefKey {
    static let hosts = "hosts"
    static let activeHost = "activeHost"     // legacy (do migracji)
    static let monitored = "monitoredHosts"  // multi-select
    static let notify = "notify"
    static let interval = "interval"
    static let flap = "flap"
    static let logsEnabled = "logsEnabled"
    static let showDockIcon = "showDockIcon"
}

// Prosty logger sterowany flagą w UserDefaults
private func L(_ msg: @autoclosure () -> String) {
    if UserDefaults.standard.object(forKey: PrefKey.logsEnabled) as? Bool ?? true {
        print(msg())
    }
}

// Model JSON dla configu
struct PingerConfig: Codable {
    var hosts: [String]
    var monitored: [String]?
    var activeHost: String?
    var interval: Double
    var flap: Int
    var notify: Bool
    var logs: Bool
    var showDock: Bool
}

// Stan anti-flap per-host
private struct HostState {
    var consecutiveUp = 0
    var consecutiveDown = 0
    var lastStableIsUp: Bool? = nil
    var inFlight = false
}

// Lekki przycisk do menu z hover/press highlight (menu nie zamyka się)
final class HoverMenuButton: NSButton {
    private var tracking: NSTrackingArea?
    private let hoverColor = NSColor.controlAccentColor.withAlphaComponent(0.16)
    private let pressColor = NSColor.controlAccentColor.withAlphaComponent(0.26)
    private let normalColor = NSColor.clear

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .texturedRounded
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = normalColor.cgColor
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let opts: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
        tracking = NSTrackingArea(rect: bounds, options: opts, owner: self, userInfo: nil)
        if let t = tracking { addTrackingArea(t) }
    }

    override func mouseEntered(with event: NSEvent) {
        animateBackground(to: hoverColor)
    }

    override func mouseExited(with event: NSEvent) {
        animateBackground(to: normalColor)
    }

    override func mouseDown(with event: NSEvent) {
        animateBackground(to: pressColor)
        // wywołaj akcję tak jak zwykły przycisk (menu zostaje otwarte)
        sendAction(action, to: target)
        // krótkie „wygaszenie” po kliknięciu
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
            self?.animateBackground(to: self?.hoverColor ?? .clear)
        }
    }

    private func animateBackground(to color: NSColor) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            self.layer?.animate(keyPath: "backgroundColor",
                                from: self.layer?.backgroundColor,
                                to: color.cgColor,
                                duration: ctx.duration)
            self.layer?.backgroundColor = color.cgColor
        }
    }
}

private extension CALayer {
    func animate(keyPath: String, from: Any?, to: Any?, duration: TimeInterval) {
        let anim = CABasicAnimation(keyPath: keyPath)
        anim.fromValue = from
        anim.toValue = to
        anim.duration = duration
        add(anim, forKey: keyPath)
    }
}


class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSMenuDelegate {

    // UI
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem?
    private var startStopMenuItem: NSMenuItem?
    private var pingIntervalMenu: NSMenu?
    private var flapMenu: NSMenu?
    private var dockIconMenuItem: NSMenuItem?

    // Timer
    private var timer: DispatchSourceTimer?
    private var isRunning = false

    // Model
    private var hosts: [String] = []
    private var activeHost: String?              // legacy (dla migracji)

    // 🔒 Wspólny stan chroniony kolejką szeregową
    private let stateQ = DispatchQueue(label: "net.deregowski.Pinger.state")
    private var monitoredHosts = Set<String>()           // chronione przez stateQ
    private var hostStates: [String: HostState] = [:]    // chronione przez stateQ

    // Mapowanie host -> pozycja menu (dla szybkiej aktualizacji ikon)
    private var hostMenuItems: [String: NSMenuItem] = [:]

    // Anti-flicker w statusie
    private var menuOpen = false
    private var lastStatusText = ""

    // Preferencje
    private var isNotificationsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: PrefKey.notify) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: PrefKey.notify) }
    }
    private var isDockIconShown: Bool {
        get { UserDefaults.standard.object(forKey: PrefKey.showDockIcon) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: PrefKey.showDockIcon) }
    }

    // MARK: - Cykl życia
    func applicationDidFinishLaunching(_ notification: Notification) {
        applyActivationPolicyFromPrefs()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setTrayIcon(color: .systemGray, tooltip: "Paused")

        let menu = buildMenu()
        menu.delegate = self
        statusItem.menu = menu

        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        loadPrefs()
        _ = loadConfigFromDiskIfPresent()

        dockIconMenuItem?.state = isDockIconShown ? .on : .off

        isRunning = false
        updateStartStopTitle()
        setStatusText("Paused")
        updateAggregateTrayIcon()

        L("start with hosts=\(hosts), monitored=\(stateQ.sync { Array(monitoredHosts) })")

        autoSaveConfigToDisk()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopTimer()
        autoSaveConfigToDisk()
    }

    // MARK: - Ikona w Docku
    private func applyActivationPolicyFromPrefs() {
        NSApp.setActivationPolicy(isDockIconShown ? .regular : .accessory)
    }

    private func relaunchApp() {
        guard let bundlePath = Bundle.main.bundlePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            NSApp.terminate(nil); return
        }
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = [bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: - Timer
    private func startTimer() {
        stopTimer()
        isRunning = true
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 0.1, repeating: Config.intervalSeconds)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        updateStartStopTitle()
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.tick() }
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
        isRunning = false
        updateStartStopTitle()

        stateQ.async { [weak self] in
            guard let self else { return }
            for k in self.hostStates.keys { self.hostStates[k] = HostState() }
        }

        setStatusText("Paused")
        setTrayIcon(color: .systemGray, tooltip: "Paused")
        refreshTargetsSection()
    }

    private func restartTimerKeepingState() {
        if isRunning { startTimer() }
    }

    /// Tworzy „płaski” przycisk jako widok menu z podświetleniem hover/press.
    private func makeInlineButton(title: String, action: Selector) -> NSMenuItem {
        let rowHeight: CGFloat = 24
        let leftPadding: CGFloat = 12
        let rightPadding: CGFloat = 8
        let totalWidth: CGFloat = 260   // możesz dostroić

        let container = NSView(frame: NSRect(x: 0, y: 0, width: totalWidth, height: rowHeight))

        let btn = HoverMenuButton(frame: .zero)
        btn.title = title
        btn.target = self
        btn.action = action
        btn.font = .systemFont(ofSize: NSFont.systemFontSize)

        let btnX = leftPadding
        let btnW = totalWidth - leftPadding - rightPadding
        btn.frame = NSRect(x: btnX, y: 0, width: btnW, height: rowHeight)
        btn.autoresizingMask = [.width, .minYMargin, .maxYMargin]

        container.addSubview(btn)

        let mi = NSMenuItem()
        mi.view = container            // wysokość bierze się z frame kontenera (24)
        return mi
    }


    // MARK: - Menu
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        let status = NSMenuItem(title: "Status: Paused", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        statusMenuItem = status
        menu.addItem(.separator())

        let startStop = NSMenuItem(title: "Start", action: #selector(toggleStartStop), keyEquivalent: "s")
        startStop.target = self
        menu.addItem(startStop)
        startStopMenuItem = startStop

        menu.addItem(.separator())

        let header = NSMenuItem(title: "Targets", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        refreshTargetsSection(in: menu)

        // „Add Host…” może zamknąć menu (standardowo otwiera dialog) – zostawiamy jako zwykły item.
        let addItem = NSMenuItem(title: "Add Host…", action: #selector(addHost), keyEquivalent: "a")
        addItem.target = self
        menu.addItem(addItem)

        // ⬇⬇⬇ Te trzy jako widoki — klik NIE zamyka menu:
        menu.addItem(makeInlineButton(title: "Remove Selected", action: #selector(removeSelectedHostsInline)))
        menu.addItem(makeInlineButton(title: "Select All Targets", action: #selector(selectAllTargetsInline)))
        menu.addItem(makeInlineButton(title: "Deselect All Targets", action: #selector(deselectAllTargetsInline)))
        // ⬆⬆⬆

        menu.addItem(.separator())

        // Settings
        let settings = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let settingsSub = NSMenu()

        let intervalItem = NSMenuItem(title: "Ping interval", action: nil, keyEquivalent: "")
        let intervalSub = NSMenu()
        for (title, value) in [("0.5 s", 0.5), ("1 s", 1.0), ("2 s", 2.0), ("5 s", 5.0)] {
            let it = NSMenuItem(title: title, action: #selector(setInterval(_:)), keyEquivalent: "")
            it.representedObject = value
            it.target = self
            if abs(Config.intervalSeconds - value) < 0.001 { it.state = .on }
            intervalSub.addItem(it)
        }
        intervalItem.submenu = intervalSub
        pingIntervalMenu = intervalSub
        settingsSub.addItem(intervalItem)

        let flapItem = NSMenuItem(title: "Stabilization (anti-flap)", action: nil, keyEquivalent: "")
        let flapSub = NSMenu()
        for val in [1,2,3] {
            let it = NSMenuItem(title: "\(val)× confirmation", action: #selector(setFlap(_:)), keyEquivalent: "")
            it.representedObject = val
            it.target = self
            it.state = (val == Config.upThreshold && val == Config.downThreshold) ? .on : .off
            flapSub.addItem(it)
        }
        flapItem.submenu = flapSub
        flapMenu = flapSub
        settingsSub.addItem(flapItem)

        let notifyItem = NSMenuItem(title: "Notifications", action: #selector(toggleNotifications(_:)), keyEquivalent: "")
        notifyItem.target = self
        notifyItem.state = isNotificationsEnabled ? .on : .off
        settingsSub.addItem(notifyItem)

        let logsItem = NSMenuItem(title: "Console logs", action: #selector(toggleLogs(_:)), keyEquivalent: "")
        logsItem.target = self
        logsItem.state = (UserDefaults.standard.object(forKey: PrefKey.logsEnabled) as? Bool ?? true) ? .on : .off
        settingsSub.addItem(logsItem)

        let dockItem = NSMenuItem(title: "Show Dock icon", action: #selector(toggleDockIcon(_:)), keyEquivalent: "")
        dockItem.target = self
        dockItem.state = isDockIconShown ? .on : .off
        settingsSub.addItem(dockItem)
        dockIconMenuItem = dockItem

        settings.submenu = settingsSub
        menu.addItem(settings)

        let aboutItem = NSMenuItem(title: "About Pinger", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(.separator())
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    private func updateStartStopTitle() {
        DispatchQueue.main.async {
            self.startStopMenuItem?.title = self.isRunning ? "Stop" : "Start"
        }
    }

    // MARK: - Targets jako wiersz: [padding][dot][checkbox]

    private func makeHostRow(for host: String, checked: Bool) -> NSMenuItem {
        // dot
        let dot = NSImageView()
        dot.identifier = NSUserInterfaceItemIdentifier("dot-\(host)")
        dot.image = miniDot(for: host)
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.setContentHuggingPriority(.required, for: .horizontal)
        dot.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10)
        ])

        // checkbox
        let btn = NSButton(checkboxWithTitle: host, target: self, action: #selector(hostCheckboxToggled(_:)))
        btn.identifier = NSUserInterfaceItemIdentifier(host)
        btn.state = checked ? .on : .off
        btn.isBordered = false
        btn.translatesAutoresizingMaskIntoConstraints = false

        // padding po lewej (12pt)
        let pad = NSView(frame: .zero)
        pad.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pad.widthAnchor.constraint(equalToConstant: 12)
        ])

        let stack = NSStackView(views: [pad, dot, btn])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .firstBaseline
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 2, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        let mi = NSMenuItem()
        mi.view = container
        return mi
    }

    private func refreshTargetsSection(in menu: NSMenu? = nil) {
        let m = menu ?? statusItem.menu!

        var startIdx: Int?
        var endIdx: Int?
        for (i, item) in m.items.enumerated() {
            if item.title == "Targets" && !item.isEnabled { startIdx = i + 1 }
            else if startIdx != nil && item.isSeparatorItem { endIdx = i; break }
        }
        if let s = startIdx, let e = endIdx, e > s {
            hostMenuItems.removeAll()
            for _ in s..<e { m.removeItem(at: s) }
        }

        stateQ.sync {
            for h in self.hosts where self.hostStates[h] == nil {
                self.hostStates[h] = HostState()
            }
        }

        let monSnap = stateQ.sync { self.monitoredHosts }
        var insertAt = startIdx ?? 1

        for host in hosts {
            let row = makeHostRow(for: host, checked: monSnap.contains(host))
            m.insertItem(row, at: insertAt)
            hostMenuItems[host] = row
            insertAt += 1
        }
    }

    // MARK: - Menu delegate
    func menuWillOpen(_ menu: NSMenu) { menuOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    // MARK: - Akcje

    @objc private func toggleStartStop() {
        if isRunning {
            stopTimer()
            return
        }
        if hosts.isEmpty {
            showInfoAlert(title: "No hosts added",
                          text: "Add a host via “Add Host…” before starting.")
            return
        }
        let anySelected = stateQ.sync { !self.monitoredHosts.isEmpty }
        if !anySelected {
            showInfoAlert(title: "No targets selected",
                          text: "Select at least one target in the “Targets” section.")
            return
        }
        startTimer()
    }

    /// Checkbox w wierszu hosta (zwykły klik, ⌥ solo, ⌘ odwróć zaznaczenie)
    @objc private func hostCheckboxToggled(_ sender: NSButton) {
        guard let host = sender.identifier?.rawValue else { return }
        let modifiers = NSApp.currentEvent?.modifierFlags ?? []

        var desiredOn = (sender.state == .on)
        if modifiers.contains(.command) { desiredOn.toggle() } // ⌘ invert

        if modifiers.contains(.option) {
            // ⌥ solo
            stateQ.sync {
                if desiredOn {
                    self.monitoredHosts = [host]
                    if self.hostStates[host] == nil { self.hostStates[host] = HostState() }
                } else {
                    self.monitoredHosts.removeAll()
                }
            }
            refreshTargetsSection()
        } else {
            stateQ.sync {
                if desiredOn {
                    self.monitoredHosts.insert(host)
                    if self.hostStates[host] == nil { self.hostStates[host] = HostState() }
                } else {
                    self.monitoredHosts.remove(host)
                }
            }
            updateMenuIcon(for: host)
        }

        sender.state = desiredOn ? .on : .off

        savePrefs()
        autoSaveConfigToDisk()
        updateAggregateTrayIcon()

        let nowMonitored = stateQ.sync { self.monitoredHosts.contains(host) }
        if isRunning && nowMonitored {
            DispatchQueue.global(qos: .utility).async { [weak self] in self?.pingOne(host: host) }
        }
    }

    // ————— Inline (nie zamykają menu) —————

    @objc private func selectAllTargetsInline() {
        selectAllTargets()
        refreshTargetsSection() // odśwież listę „w locie”
    }

    @objc private func deselectAllTargetsInline() {
        deselectAllTargets()
        refreshTargetsSection()
    }

    @objc private func removeSelectedHostsInline() {
        removeSelectedHosts()
        refreshTargetsSection()
    }

    // ——— Te metody mogą być też wołane z innych miejsc ———

    @objc private func selectAllTargets() {
        stateQ.sync {
            self.monitoredHosts = Set(self.hosts)
            for h in self.hosts where self.hostStates[h] == nil { self.hostStates[h] = HostState() }
        }
        savePrefs()
        autoSaveConfigToDisk()
        updateAggregateTrayIcon()
    }

    @objc private func deselectAllTargets() {
        stateQ.sync { self.monitoredHosts.removeAll() }
        savePrefs()
        autoSaveConfigToDisk()
        updateAggregateTrayIcon()
    }

    @objc private func addHost() {
        let alert = NSAlert()
        alert.messageText = "Add Host"
        alert.informativeText = "Enter IP or hostname to monitor."
        let tf = NSTextField(string: "")
        tf.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = tf
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            let newHost = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newHost.isEmpty else { return }
            if !hosts.contains(newHost) {
                hosts.insert(newHost, at: 0)
                stateQ.sync {
                    self.monitoredHosts.insert(newHost)
                    self.hostStates[newHost] = HostState()
                }
                savePrefs()
                refreshTargetsSection()
                autoSaveConfigToDisk()
                if isRunning {
                    DispatchQueue.global(qos: .utility).async { [weak self] in self?.pingOne(host: newHost) }
                }
            }
        }
    }

    @objc private func removeSelectedHosts() {
        let selected = stateQ.sync { self.monitoredHosts }
        if selected.isEmpty {
            NSSound.beep()
            return
        }
        let toRemove = hosts.filter { selected.contains($0) }
        guard !toRemove.isEmpty else { return }

        stateQ.sync {
            for h in toRemove {
                self.monitoredHosts.remove(h)
                self.hostStates.removeValue(forKey: h)
                self.hosts.removeAll { $0 == h }
            }
        }
        savePrefs()
        autoSaveConfigToDisk()
        updateAggregateTrayIcon()
    }

    @objc private func setInterval(_ sender: NSMenuItem) {
        guard let val = sender.representedObject as? TimeInterval else { return }
        Config.intervalSeconds = val
        pingIntervalMenu?.items.forEach { $0.state = .off }
        sender.state = .on
        UserDefaults.standard.set(val, forKey: PrefKey.interval)
        restartTimerKeepingState()
        autoSaveConfigToDisk()
    }

    @objc private func setFlap(_ sender: NSMenuItem) {
        guard let val = sender.representedObject as? Int else { return }
        Config.upThreshold = val
        Config.downThreshold = val
        flapMenu?.items.forEach { $0.state = .off }
        sender.state = .on
        stateQ.sync {
            for k in self.hostStates.keys { self.hostStates[k] = HostState() }
        }
        autoSaveConfigToDisk()
    }

    @objc private func toggleNotifications(_ sender: NSMenuItem) {
        isNotificationsEnabled.toggle()
        sender.state = isNotificationsEnabled ? .on : .off
        autoSaveConfigToDisk()
    }

    @objc private func toggleLogs(_ sender: NSMenuItem) {
        let enabled = !(UserDefaults.standard.object(forKey: PrefKey.logsEnabled) as? Bool ?? true)
        UserDefaults.standard.set(enabled, forKey: PrefKey.logsEnabled)
        sender.state = enabled ? .on : .off
        L("console logs \(enabled ? "enabled" : "disabled")")
        autoSaveConfigToDisk()
    }

    @objc private func toggleDockIcon(_ sender: NSMenuItem) {
        isDockIconShown.toggle()
        sender.state = isDockIconShown ? .on : .off
        autoSaveConfigToDisk()
        applyActivationPolicyFromPrefs()
        relaunchApp()
    }

    @objc private func showAbout() {
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "-"
        let path = (try? configFileURL().path) ?? "(unavailable)"
        let desc =
        """
        A tiny menu bar monitor that pings selected hosts in parallel.
        Uses /sbin/ping (ICMP). Requires App Sandbox OFF and /sbin/ping at that path.
        Anti-flap stabilization and notifications built-in. Config file is JSON, autosaved.
        """
        let alert = NSAlert()
        alert.messageText = "Pinger"
        alert.informativeText =
        """
        Version: \(version) (\(build))
        Author: \(Config.appAuthor)
        Settings file: \(path)

        \(desc)
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Tick / ping równoległy
    private func tick() {
        if !isRunning { return }

        let targets: [String] = stateQ.sync { Array(self.monitoredHosts) }
        guard !targets.isEmpty else {
            setStatusText("No targets selected")
            setTrayIcon(color: .systemGray, tooltip: "No targets")
            return
        }

        if !menuOpen {
            setStatusText("Checking… (\(targets.count) host\(targets.count > 1 ? "s" : ""))")
        }

        for host in targets {
            pingOne(host: host)
        }
    }

    private func pingOne(host: String) {
        // atomowy znacznik inFlight
        let shouldStart: Bool = stateQ.sync {
            var st = self.hostStates[host] ?? HostState()
            if st.inFlight { return false }
            st.inFlight = true
            self.hostStates[host] = st
            return true
        }
        if !shouldStart { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let up = self.runPingOnceICMP(host: host)

            var changedTo: Bool? = nil
            self.stateQ.sync {
                var st = self.hostStates[host] ?? HostState()
                if up { st.consecutiveUp += 1; st.consecutiveDown = 0 }
                else  { st.consecutiveDown += 1; st.consecutiveUp = 0 }

                var newStable: Bool?
                if up,   st.consecutiveUp   >= Config.upThreshold   { newStable = true  }
                if !up,  st.consecutiveDown >= Config.downThreshold { newStable = false }

                if let ns = newStable {
                    if st.lastStableIsUp == nil || st.lastStableIsUp! != ns { changedTo = ns }
                    st.lastStableIsUp = ns
                }
                st.inFlight = false
                self.hostStates[host] = st
            }

            if let ns = changedTo, self.isNotificationsEnabled {
                self.notifyChange(isUp: ns, host: host)
            }
            self.updateMenuIcon(for: host)
            self.updateAggregateTrayIcon()

            if !self.menuOpen {
                let counts = self.stateQ.sync {
                    (
                        up: self.monitoredHosts.compactMap { self.hostStates[$0]?.lastStableIsUp }.filter { $0 }.count,
                        total: self.monitoredHosts.count
                    )
                }
                self.setStatusText("\(counts.up)/\(counts.total) up")
            }
        }
    }

    // ICMP przez /sbin/ping (Sandbox OFF)
    private func runPingOnceICMP(host: String) -> Bool {
        let task = Process()
        task.launchPath = Config.pingPath
        task.arguments = ["-n", "-c", "1", "-W", "1000", "-q", host]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError  = pipe

        do {
            L("exec: \(Config.pingPath) \(task.arguments!.joined(separator: " "))")
            try task.run()
            task.waitUntilExit()
            return Int(task.terminationStatus) == 0
        } catch {
            L("ping exec failed: \(error)")
            return false
        }
    }

    // MARK: - UI helpers
    private func setStatusText(_ text: String) {
        if menuOpen { return }
        if text == lastStatusText { return }
        lastStatusText = text
        DispatchQueue.main.async {
            self.statusMenuItem?.title = "Status: " + text
        }
    }

    private func setTrayIcon(color: NSColor, tooltip: String) {
        DispatchQueue.main.async {
            let base = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
            self.statusItem.button?.image = base?.withSymbolConfiguration(.init(paletteColors: [color]))
            self.statusItem.button?.image?.isTemplate = false
            self.statusItem.button?.toolTip = tooltip
        }
    }

    /// Ustala kolor kropki na trayu na podstawie łącznego stanu
    private func updateAggregateTrayIcon() {
        if !isRunning {
            setTrayIcon(color: .systemGray, tooltip: "Paused")
            return
        }
        let isEmpty = stateQ.sync { self.monitoredHosts.isEmpty }
        if isEmpty {
            setTrayIcon(color: .systemGray, tooltip: "No targets")
            return
        }

        let tuple: (Bool, Bool) = stateQ.sync {
            var down = false
            var unknown = false
            for h in self.monitoredHosts {
                guard let st = self.hostStates[h]?.lastStableIsUp else { unknown = true; continue }
                if st == false { down = true }
            }
            return (down, unknown)
        }
        let anyDown = tuple.0
        let anyUnknown = tuple.1

        if anyDown {
            setTrayIcon(color: .systemRed, tooltip: "Some hosts down")
        } else if !anyUnknown {
            setTrayIcon(color: .systemGreen, tooltip: "All hosts up")
        }
        // w trakcie stabilizacji utrzymujemy poprzedni kolor
    }

    private func miniDot(for host: String) -> NSImage? {
        let stable = stateQ.sync { self.hostStates[host]?.lastStableIsUp }
        let color: NSColor = (stable == nil) ? .systemGray : (stable! ? .systemGreen : .systemRed)
        return NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [color]))
    }

    private func updateMenuIcon(for host: String) {
        DispatchQueue.main.async {
            guard let item = self.hostMenuItems[host],
                  let container = item.view,
                  let dot = container.findSubview(with: NSUserInterfaceItemIdentifier("dot-\(host)")) as? NSImageView,
                  let btn = container.findSubview(with: NSUserInterfaceItemIdentifier(host)) as? NSButton else { return }

            dot.image = self.miniDot(for: host)
            let checked = self.stateQ.sync { self.monitoredHosts.contains(host) }
            btn.state = checked ? .on : .off
        }
    }

    private func notifyChange(isUp: Bool, host: String) {
        let content = UNMutableNotificationContent()
        content.title = isUp ? "Host reachable" : "Host down"
        content.body = host
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    // MARK: - Prefs & config file
    private func loadPrefs() {
        let ud = UserDefaults.standard

        // Pierwsze uruchomienie -> defaults; jeśli klucz istnieje (nawet pusta lista) -> użyj go
        if ud.object(forKey: PrefKey.hosts) != nil {
            hosts = (ud.array(forKey: PrefKey.hosts) as? [String]) ?? []
        } else {
            hosts = Config.defaultHosts
            ud.set(hosts, forKey: PrefKey.hosts)
        }

        if let act = ud.string(forKey: PrefKey.activeHost), hosts.contains(act) {
            activeHost = act
        } else {
            activeHost = hosts.first
            ud.set(activeHost, forKey: PrefKey.activeHost)
        }

        stateQ.sync {
            if let arr = ud.array(forKey: PrefKey.monitored) as? [String] {
                self.monitoredHosts = Set(arr.filter { hosts.contains($0) })
            } else {
                if let a = activeHost, hosts.contains(a) { self.monitoredHosts = [a] }
                else { self.monitoredHosts = Set(hosts) }
                ud.set(Array(self.monitoredHosts), forKey: PrefKey.monitored)
            }
            for h in hosts where self.hostStates[h] == nil { self.hostStates[h] = HostState() }
        }

        if ud.object(forKey: PrefKey.notify) == nil { ud.set(true, forKey: PrefKey.notify) }
        if let iv = ud.object(forKey: PrefKey.interval) as? Double { Config.intervalSeconds = iv }
        if let flap = ud.object(forKey: PrefKey.flap) as? Int { Config.upThreshold = flap; Config.downThreshold = flap }
        if ud.object(forKey: PrefKey.logsEnabled) == nil { ud.set(true, forKey: PrefKey.logsEnabled) }
        if ud.object(forKey: PrefKey.showDockIcon) == nil { ud.set(true, forKey: PrefKey.showDockIcon) }

        setStatusText("Paused")
        updateAggregateTrayIcon()
    }

    private func savePrefs() {
        let ud = UserDefaults.standard
        ud.set(hosts, forKey: PrefKey.hosts)                      // może być pusta
        let mon = stateQ.sync { Array(self.monitoredHosts) }
        ud.set(mon, forKey: PrefKey.monitored)                    // może być pusta
        if let a = activeHost { ud.set(a, forKey: PrefKey.activeHost) }
    }

    private func configFileURL() throws -> URL {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory,
                                              in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Pinger", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    private func autoSaveConfigToDisk() {
        do {
            let cfg = PingerConfig(
                hosts: hosts,
                monitored: stateQ.sync { Array(self.monitoredHosts) },
                activeHost: activeHost,
                interval: Config.intervalSeconds,
                flap: Config.upThreshold,
                notify: isNotificationsEnabled,
                logs: (UserDefaults.standard.object(forKey: PrefKey.logsEnabled) as? Bool ?? true),
                showDock: isDockIconShown
            )
            let data = try JSONEncoder().encode(cfg)
            let url = try configFileURL()
            try data.write(to: url, options: .atomic)
            L("config auto-saved to \(url.path)")
        } catch { L("config auto-save failed: \(error)") }
    }

    @discardableResult
    private func loadConfigFromDiskIfPresent() -> Bool {
        do {
            let url = try configFileURL()
            guard FileManager.default.fileExists(atPath: url.path) else { return false }
            let data = try Data(contentsOf: url)
            let cfg = try JSONDecoder().decode(PingerConfig.self, from: data)

            self.hosts = cfg.hosts
            stateQ.sync {
                if let mon = cfg.monitored {
                    self.monitoredHosts = Set(mon.filter { cfg.hosts.contains($0) })
                } else if let a = cfg.activeHost, cfg.hosts.contains(a) {
                    self.monitoredHosts = [a]
                } else {
                    self.monitoredHosts = Set(cfg.hosts)
                }
                self.hostStates.removeAll()
                for h in self.hosts { self.hostStates[h] = HostState() }
            }

            self.activeHost = cfg.activeHost
            Config.intervalSeconds = cfg.interval
            Config.upThreshold = cfg.flap
            Config.downThreshold = cfg.flap
            isNotificationsEnabled = cfg.notify
            UserDefaults.standard.set(cfg.logs, forKey: PrefKey.logsEnabled)
            UserDefaults.standard.set(cfg.showDock, forKey: PrefKey.showDockIcon)

            applyActivationPolicyFromPrefs()

            savePrefs()
            refreshTargetsSection()
            restartTimerKeepingState()
            L("config loaded from \(url.path)")
            return true
        } catch {
            L("config load failed: \(error)")
            return false
        }
    }

    // MARK: - Notyfikacje w foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    // MARK: - Małe helpery
    private func showInfoAlert(title: String, text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.alertStyle = .informational
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}

// MARK: - NSView helper
private extension NSView {
    func findSubview(with id: NSUserInterfaceItemIdentifier) -> NSView? {
        if self.identifier == id { return self }
        for v in subviews {
            if let f = v.findSubview(with: id) { return f }
        }
        return nil
    }
}
