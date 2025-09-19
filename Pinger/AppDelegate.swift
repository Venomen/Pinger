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
    static let activeHost = "activeHost"     // legacy
    static let monitored = "monitoredHosts"  // multi-select
    static let notify = "notify"
    static let interval = "interval"
    static let flap = "flap"
    static let logsEnabled = "logsEnabled"
    static let showDockIcon = "showDockIcon"
}

// Simple logger toggled by UserDefaults
private func L(_ msg: @autoclosure () -> String) {
    if UserDefaults.standard.object(forKey: PrefKey.logsEnabled) as? Bool ?? true {
        print(msg())
    }
}

// JSON model for persisted config
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

// Per-host anti-flap state
private struct HostState {
    var consecutiveUp = 0
    var consecutiveDown = 0
    var lastStableIsUp: Bool? = nil
    var inFlight = false
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
    private var activeHost: String?              // legacy (for migration)

    // 🔒 Shared state protected by a serial queue
    private let stateQ = DispatchQueue(label: "net.deregowski.Pinger.state")
    private var monitoredHosts = Set<String>()           // protected by stateQ
    private var hostStates: [String: HostState] = [:]    // protected by stateQ

    // Menu item map (UI only)
    private var hostMenuItems: [String: NSMenuItem] = [:]

    // Reentrancy & anti-flicker (UI)
    private var menuOpen = false
    private var lastStatusText = ""

    // Preferences
    private var isNotificationsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: PrefKey.notify) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: PrefKey.notify) }
    }
    private var isDockIconShown: Bool {
        get { UserDefaults.standard.object(forKey: PrefKey.showDockIcon) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: PrefKey.showDockIcon) }
    }

    // MARK: - App lifecycle
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

    // MARK: - Dock icon (activation policy)
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

    // MARK: - Timer control
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

        let addItem = NSMenuItem(title: "Add Host…", action: #selector(addHost), keyEquivalent: "a")
        addItem.target = self
        menu.addItem(addItem)

        let removeItem = NSMenuItem(title: "Remove Selected", action: #selector(removeSelectedHosts), keyEquivalent: "")
        removeItem.target = self
        menu.addItem(removeItem)

        // NEW: Select/Deselect all
        let selectAll = NSMenuItem(title: "Select All Targets", action: #selector(selectAllTargets), keyEquivalent: "")
        selectAll.target = self
        menu.addItem(selectAll)

        let deselectAll = NSMenuItem(title: "Deselect All Targets", action: #selector(deselectAllTargets), keyEquivalent: "")
        deselectAll.target = self
        menu.addItem(deselectAll)

        menu.addItem(.separator())

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

    // Build/refresh checkable target list with per-host dot
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

        // ❌ No auto-refill defaults here
        // Just ensure HostState exists for known hosts
        stateQ.sync {
            for h in self.hosts where self.hostStates[h] == nil {
                self.hostStates[h] = HostState()
            }
        }

        var insertAt = startIdx ?? 1
        let monSnap = stateQ.sync { self.monitoredHosts }
        for host in hosts {
            let item = NSMenuItem(title: host, action: #selector(toggleMonitorHost(_:)), keyEquivalent: "")
            item.target = self
            item.state = monSnap.contains(host) ? .on : .off
            item.image = miniDot(for: host)
            item.image?.size = NSSize(width: 10, height: 10)
            m.insertItem(item, at: insertAt)
            hostMenuItems[host] = item
            insertAt += 1
        }
    }

    // MARK: - Menu delegate
    func menuWillOpen(_ menu: NSMenu) { menuOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    // MARK: - Actions
    @objc private func toggleStartStop() {
        if isRunning {
            stopTimer()
            return
        }
        // START requested
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

    @objc private func toggleMonitorHost(_ sender: NSMenuItem) {
        let host = sender.title
        stateQ.sync {
            if self.monitoredHosts.contains(host) {
                self.monitoredHosts.remove(host)
            } else {
                self.monitoredHosts.insert(host)
                self.hostStates[host] = HostState()
            }
        }
        sender.state = stateQ.sync { self.monitoredHosts.contains(host) ? .on : .off }
        updateMenuIcon(for: host)
        savePrefs()
        autoSaveConfigToDisk()
        updateAggregateTrayIcon()

        let isMonitored = stateQ.sync { self.monitoredHosts.contains(host) }
        if isRunning && isMonitored {
            DispatchQueue.global(qos: .utility).async { [weak self] in self?.pingOne(host: host) }
        }
    }

    @objc private func selectAllTargets() {
        stateQ.sync {
            self.monitoredHosts = Set(self.hosts)
            for h in self.hosts where self.hostStates[h] == nil { self.hostStates[h] = HostState() }
        }
        refreshTargetsSection()
        savePrefs()
        autoSaveConfigToDisk()
        updateAggregateTrayIcon()
    }

    @objc private func deselectAllTargets() {
        stateQ.sync { self.monitoredHosts.removeAll() }
        refreshTargetsSection()
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
        refreshTargetsSection()
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

    // MARK: - Tick / Parallel pings
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
        // atomically mark inFlight
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
                    if st.lastStableIsUp == nil || st.lastStableIsUp! != ns {
                        changedTo = ns
                    }
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

    // ICMP via /sbin/ping (requires App Sandbox OFF)
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
        // otherwise keep previous color while stabilizing
    }

    private func miniDot(for host: String) -> NSImage? {
        let stable = stateQ.sync { self.hostStates[host]?.lastStableIsUp }
        let color: NSColor = (stable == nil) ? .systemGray : (stable! ? .systemGreen : .systemRed)
        return NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [color]))
    }

    private func updateMenuIcon(for host: String) {
        DispatchQueue.main.async {
            if let item = self.hostMenuItems[host] {
                item.image = self.miniDot(for: host)
                item.image?.size = NSSize(width: 10, height: 10)
            }
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

    // MARK: - Prefs & Config file
    private func loadPrefs() {
        let ud = UserDefaults.standard

        // First run: if key missing -> defaults; if key exists (even empty array) -> use it.
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
                // first run: default = active if exists else all (could be empty)
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
        ud.set(hosts, forKey: PrefKey.hosts)                      // may be empty
        let mon = stateQ.sync { Array(self.monitoredHosts) }
        ud.set(mon, forKey: PrefKey.monitored)                    // may be empty
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

    // Foreground notifications
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    // MARK: - Small helpers
    private func showInfoAlert(title: String, text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.alertStyle = .informational
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}
