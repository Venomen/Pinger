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
    static var intervalSeconds: TimeInterval = 1.0      // adjustable in Settings
    static var upThreshold = 2                           // 1/2/3 – anti-flap
    static var downThreshold = 2
    static let pingPath = "/sbin/ping"                   // requires App Sandbox OFF
    static let defaultHosts = ["1.1.1.1", "8.8.8.8", "9.9.9.9"]
    static let appAuthor = "deregowski.net © 2025"
}

fileprivate enum PrefKey {
    static let hosts = "hosts"
    static let activeHost = "activeHost"
    static let notify = "notify"
    static let interval = "interval"
    static let flap = "flap"          // 1/2/3
    static let logsEnabled = "logsEnabled"
    static let showDockIcon = "showDockIcon" // <- new
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
    var activeHost: String?
    var interval: Double
    var flap: Int
    var notify: Bool
    var logs: Bool
    var showDock: Bool // <- new
}

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSMenuDelegate {

    // UI
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem?      // “Status: …”
    private var startStopMenuItem: NSMenuItem?   // Start/Stop toggle
    private var pingIntervalMenu: NSMenu?        // interval radio list
    private var flapMenu: NSMenu?                // anti-flap radio list
    private var dockIconMenuItem: NSMenuItem?    // Show Dock icon toggle

    // Timer
    private var timer: DispatchSourceTimer?
    private var isRunning = false                // default: PAUSED

    // Model
    private var hosts: [String] = []
    private var activeHost: String?
    private var lastStableIsUp: Bool?            // after anti-flap
    private var consecutiveUp = 0
    private var consecutiveDown = 0

    // Reentrancy & anti-flicker
    private let checkGate = DispatchSemaphore(value: 1)
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
        // Apply Dock visibility policy ASAP (before UI)
        applyActivationPolicyFromPrefs()

        // Menu bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [.systemGray]))
        statusItem.button?.image?.isTemplate = false
        statusItem.button?.toolTip = "Ping Monitor"

        let menu = buildMenu()
        menu.delegate = self
        statusItem.menu = menu

        // Notifications
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // Load prefs and (if present) config file
        loadPrefs()
        _ = loadConfigFromDiskIfPresent() // merge if config.json exists

        // Reflect Dock icon setting in menu
        dockIconMenuItem?.state = isDockIconShown ? .on : .off

        // Start paused UI
        isRunning = false
        updateStartStopTitle()
        setStatusText("Paused")
        updateIcon(isUp: nil) // gray only when paused

        L("start with hosts=\(hosts), active=\(activeHost ?? "nil")")

        // First-launch auto-save (creates config.json if missing)
        autoSaveConfigToDisk()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopTimer()
        // Auto-save current settings on quit
        autoSaveConfigToDisk()
    }

    // MARK: - Dock icon (activation policy)
    private func applyActivationPolicyFromPrefs() {
        let desired: NSApplication.ActivationPolicy = isDockIconShown ? .regular : .accessory
        NSApp.setActivationPolicy(desired)
    }

    private func relaunchApp() {
        guard let bundlePath = Bundle.main.bundlePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            NSApp.terminate(nil)
            return
        }
        // Launch new instance
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = [bundlePath]
        try? task.run()
        // Terminate current instance
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
        // immediate first check
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.tick() }
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
        isRunning = false
        updateStartStopTitle()
        // clear state and UI
        lastStableIsUp = nil
        consecutiveUp = 0; consecutiveDown = 0
        setStatusText("Paused")
        updateIcon(isUp: nil) // gray = paused
    }

    private func restartTimerKeepingState() {
        if isRunning { startTimer() }
    }

    // MARK: - Menu
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        // 0) Status
        let status = NSMenuItem(title: "Status: Paused", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        statusMenuItem = status
        menu.addItem(.separator())

        // 1) Start/Stop
        let startStop = NSMenuItem(title: "Start", action: #selector(toggleStartStop), keyEquivalent: "s")
        startStop.target = self
        menu.addItem(startStop)
        startStopMenuItem = startStop

        menu.addItem(.separator())

        // 2) Targets header + dynamic list
        let header = NSMenuItem(title: "Targets", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        refreshTargetsSection(in: menu)

        // Add/Remove host
        let addItem = NSMenuItem(title: "Add Host…", action: #selector(addHost), keyEquivalent: "a")
        addItem.target = self
        menu.addItem(addItem)

        let removeItem = NSMenuItem(title: "Remove Active Host", action: #selector(removeActiveHost), keyEquivalent: "")
        removeItem.target = self
        menu.addItem(removeItem)

        menu.addItem(.separator())

        // 3) Settings
        let settings = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let settingsSub = NSMenu()

        // Ping interval
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

        // Anti-flap
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

        // Notifications
        let notifyItem = NSMenuItem(title: "Notifications", action: #selector(toggleNotifications(_:)), keyEquivalent: "")
        notifyItem.target = self
        notifyItem.state = isNotificationsEnabled ? .on : .off
        settingsSub.addItem(notifyItem)

        // Console logs
        let logsItem = NSMenuItem(title: "Console logs", action: #selector(toggleLogs(_:)), keyEquivalent: "")
        logsItem.target = self
        logsItem.state = (UserDefaults.standard.object(forKey: PrefKey.logsEnabled) as? Bool ?? true) ? .on : .off
        settingsSub.addItem(logsItem)

        // Show Dock icon (runtime policy + relaunch)
        let dockItem = NSMenuItem(title: "Show Dock icon", action: #selector(toggleDockIcon(_:)), keyEquivalent: "")
        dockItem.target = self
        dockItem.state = isDockIconShown ? .on : .off
        settingsSub.addItem(dockItem)
        dockIconMenuItem = dockItem

        settings.submenu = settingsSub
        menu.addItem(settings)

        // 4) About
        let aboutItem = NSMenuItem(title: "About Pinger", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(.separator())
        menu.addItem(aboutItem)

        // 5) Quit
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

    // Inject dynamic target list
    private func refreshTargetsSection(in menu: NSMenu? = nil) {
        let m = menu ?? statusItem.menu!

        // Find "Targets" section boundaries
        var startIdx: Int?
        var endIdx: Int?
        for (i, item) in m.items.enumerated() {
            if item.title == "Targets" && !item.isEnabled { startIdx = i + 1 }
            else if startIdx != nil && item.isSeparatorItem { endIdx = i; break }
        }
        // Clear previous items
        if let s = startIdx, let e = endIdx, e > s {
            for _ in s..<e { m.removeItem(at: s) }
        }
        // Ensure defaults on first run
        if hosts.isEmpty {
            hosts = Config.defaultHosts
            if activeHost == nil { activeHost = hosts.first }
            savePrefs()
        }
        // Insert radio list
        var insertAt = startIdx ?? 1
        let active = activeHost
        for host in hosts {
            let item = NSMenuItem(title: host, action: #selector(selectHost(_:)), keyEquivalent: "")
            item.target = self
            item.state = (host == active) ? .on : .off
            m.insertItem(item, at: insertAt)
            insertAt += 1
        }
    }

    // MARK: - Menu delegate (reduce status flicker when open)
    func menuWillOpen(_ menu: NSMenu) { menuOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    // MARK: - Actions
    @objc private func toggleStartStop() {
        if isRunning { stopTimer() } else { startTimer() }
    }

    @objc private func selectHost(_ sender: NSMenuItem) {
        activeHost = sender.title
        savePrefs()
        consecutiveUp = 0
        consecutiveDown = 0
        lastStableIsUp = nil
        refreshTargetsSection()
        if isRunning {
            DispatchQueue.global(qos: .utility).async { [weak self] in self?.tick() }
        } else {
            setStatusText("Paused")
            updateIcon(isUp: nil)
        }
        autoSaveConfigToDisk()
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
                hosts.insert(newHost, at: 0) // add to top
                activeHost = newHost         // and make active
                savePrefs()
                refreshTargetsSection()
                if isRunning {
                    DispatchQueue.global(qos: .utility).async { [weak self] in self?.tick() }
                } else {
                    setStatusText("Paused")
                    updateIcon(isUp: nil)
                }
                autoSaveConfigToDisk()
            }
        }
    }

    @objc private func removeActiveHost() {
        guard let active = activeHost, let idx = hosts.firstIndex(of: active) else { return }
        hosts.remove(at: idx)
        activeHost = hosts.first
        savePrefs()
        refreshTargetsSection()
        if !isRunning { updateIcon(isUp: nil) }
        autoSaveConfigToDisk()
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
        UserDefaults.standard.set(val, forKey: PrefKey.flap)
        consecutiveUp = 0; consecutiveDown = 0; lastStableIsUp = nil
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
        // Apply policy + relaunch for a clean switch
        applyActivationPolicyFromPrefs()
        relaunchApp()
    }

    @objc private func showAbout() {
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "-"
        let path = (try? configFileURL().path) ?? "(unavailable)"
        let desc =
        """
        A tiny menu bar monitor that pings a chosen host on an interval.
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

    // MARK: - Tick / Ping / Anti-flap
    private func tick() {
        if !isRunning { return }
        if checkGate.wait(timeout: .now()) != .success { return }
        defer { checkGate.signal() }

        guard let host = activeHost, !host.isEmpty else {
            setStatusText("Waiting…")
            return
        }

        if !menuOpen { setStatusText("Checking… (\(host))") }
        // keep last icon while checking

        let up = runPingOnceICMP(host: host)  // real ICMP (Sandbox OFF)

        // Immediately reflect raw result on the icon (green/red),
        // gray is reserved strictly for "paused".
        updateIcon(isUp: up ? true : false)

        L("PING \(host) -> \(up ? "UP" : "DOWN")")
        applyAntiFlap(with: up, host: host)
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

            let status = Int(task.terminationStatus)
            let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            let output = String(data: data, encoding: .utf8) ?? ""

            if status == 0 {
                if let line = output.split(separator: "\n").first(where: { $0.contains("round-trip") || $0.contains("rtt") }) {
                    setStatusText("UP \(host) • \(line)")
                } else {
                    setStatusText("UP \(host)")
                }
                L("ping OK \(host) \(output)")
                return true
            } else {
                if output.contains("Operation not permitted") {
                    setStatusText("ERROR: ICMP blocked (sandbox)")
                } else {
                    setStatusText("DOWN \(host)")
                }
                L("ping FAIL \(host) exit=\(status) output=\(output)")
                return false
            }
        } catch {
            setStatusText("ERROR \(host)")
            L("ping exec failed: \(error)")
            return false
        }
    }

    private func applyAntiFlap(with isUp: Bool, host: String) {
        if isUp { consecutiveUp += 1; consecutiveDown = 0 }
        else    { consecutiveDown += 1; consecutiveUp = 0 }

        // Determine stable state
        var newStable: Bool?
        if isUp,   consecutiveUp   >= Config.upThreshold   { newStable = true  }
        if !isUp,  consecutiveDown >= Config.downThreshold { newStable = false }

        if let newStable = newStable {
            // Notify only on real change of the *stable* state
            if lastStableIsUp == nil || lastStableIsUp! != newStable {
                if isNotificationsEnabled { notifyChange(isUp: newStable, host: host) }
            }
            lastStableIsUp = newStable
            // Ensure icon matches stable state (green/red)
            updateIcon(isUp: newStable)
            setStatusText("\(newStable ? "UP" : "DOWN") \(host)")
        }
    }

    // MARK: - UI helpers
    private func setStatusText(_ text: String) {
        if menuOpen { return }                    // don't flicker while menu is open
        if text == lastStatusText { return }      // anti-flicker
        lastStatusText = text
        DispatchQueue.main.async {
            self.statusMenuItem?.title = "Status: " + text
        }
    }

    private func updateIcon(isUp: Bool?) {
        DispatchQueue.main.async {
            let base = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
            switch isUp {
            case .some(true):
                self.statusItem.button?.image = base?.withSymbolConfiguration(.init(paletteColors: [.systemGreen]))
                self.statusItem.button?.toolTip = "Reachable"
            case .some(false):
                self.statusItem.button?.image = base?.withSymbolConfiguration(.init(paletteColors: [.systemRed]))
                self.statusItem.button?.toolTip = "No response"
            case .none:
                self.statusItem.button?.image = base?.withSymbolConfiguration(.init(paletteColors: [.systemGray]))
                self.statusItem.button?.toolTip = "Paused"
            }
            self.statusItem.button?.image?.isTemplate = false
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

        // Hosts
        if let saved = ud.array(forKey: PrefKey.hosts) as? [String], !saved.isEmpty {
            hosts = saved
        } else {
            hosts = Config.defaultHosts
            ud.set(hosts, forKey: PrefKey.hosts)
        }

        // Active
        if let act = ud.string(forKey: PrefKey.activeHost), hosts.contains(act) {
            activeHost = act
        } else {
            activeHost = hosts.first
            ud.set(activeHost, forKey: PrefKey.activeHost)
        }

        // Notifications
        if ud.object(forKey: PrefKey.notify) == nil { ud.set(true, forKey: PrefKey.notify) }

        // Interval
        if let iv = ud.object(forKey: PrefKey.interval) as? Double { Config.intervalSeconds = iv }

        // Anti-flap
        if let flap = ud.object(forKey: PrefKey.flap) as? Int {
            Config.upThreshold = flap; Config.downThreshold = flap
        }

        // Logs
        if ud.object(forKey: PrefKey.logsEnabled) == nil { ud.set(true, forKey: PrefKey.logsEnabled) }

        // Dock icon (default true)
        if ud.object(forKey: PrefKey.showDockIcon) == nil { ud.set(true, forKey: PrefKey.showDockIcon) }

        // UI
        setStatusText("Paused")
        updateIcon(isUp: nil)
    }

    private func savePrefs() {
        let ud = UserDefaults.standard
        ud.set(hosts, forKey: PrefKey.hosts)
        ud.set(activeHost, forKey: PrefKey.activeHost)
    }

    private func configFileURL() throws -> URL {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory,
                                              in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Pinger", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    /// Writes the current settings to Application Support/Pinger/config.json
    private func autoSaveConfigToDisk() {
        do {
            let cfg = PingerConfig(
                hosts: hosts,
                activeHost: activeHost,
                interval: Config.intervalSeconds,
                flap: Config.upThreshold,
                notify: isNotificationsEnabled,
                logs: (UserDefaults.standard.object(forKey: PrefKey.logsEnabled) as? Bool ?? true),
                showDock: isDockIconShown
            )
            let data = try JSONEncoder().encode(cfg)
            let url = try configFileURL()
            try data.write(to: url, options: Data.WritingOptions.atomic)
            L("config auto-saved to \(url.path)")
        } catch {
            L("config auto-save failed: \(error)")
        }
    }

    /// Loads config.json if present (merges into current state). Returns true if loaded.
    @discardableResult
    private func loadConfigFromDiskIfPresent() -> Bool {
        do {
            let url = try configFileURL()
            guard FileManager.default.fileExists(atPath: url.path) else { return false }
            let data = try Data(contentsOf: url)
            let cfg = try JSONDecoder().decode(PingerConfig.self, from: data)

            self.hosts = cfg.hosts
            self.activeHost = cfg.activeHost ?? cfg.hosts.first
            Config.intervalSeconds = cfg.interval
            Config.upThreshold = cfg.flap
            Config.downThreshold = cfg.flap
            isNotificationsEnabled = cfg.notify
            UserDefaults.standard.set(cfg.logs, forKey: PrefKey.logsEnabled)
            UserDefaults.standard.set(cfg.showDock, forKey: PrefKey.showDockIcon)

            // Apply policy (in case user toggled this in a previous session)
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
}
