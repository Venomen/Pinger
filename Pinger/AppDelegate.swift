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
    static let activeHost = "activeHost"     // legacy (for migration)
    static let monitored = "monitoredHosts"  // multi-select
    static let notify = "notify"
    static let interval = "interval"
    static let flap = "flap"
    static let logsEnabled = "logsEnabled"
    static let showDockIcon = "showDockIcon"
}

// Simple logger controlled by UserDefaults flag
private struct AppLogger {
    static func L(_ msg: @autoclosure () -> String) {
        if UserDefaults.standard.object(forKey: PrefKey.logsEnabled) as? Bool ?? true {
            print(msg())
        }
    }
}

// Model JSON config
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

// Anti-flap state per-host
private struct HostState {
    var consecutiveUp = 0
    var consecutiveDown = 0
    var lastStableIsUp: Bool? = nil
    var inFlight = false
}

// Lightweight menu button with hover/press highlight (doesn't close menu)
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
                // call action like a regular button (menu stays open)
        sendAction(action, to: target)
        // brief "fade out" after click
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

// Checkbox that doesn't close menu
final class MenuCheckboxButton: NSButton {
    private var tracking: NSTrackingArea?
    private let hoverColor = NSColor.controlAccentColor.withAlphaComponent(0.08)
    private let normalColor = NSColor.clear
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setButtonType(.switch)
        isBordered = false
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 4
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
        // Toggle state
        state = (state == .on) ? .off : .on
        // Call action
        sendAction(action, to: target)
        // Don't call super.mouseDown - this prevents default behavior
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

// TextField with persistent focus for menu use
final class PersistentMenuTextField: NSTextField {
    
    override func awakeFromNib() {
        super.awakeFromNib()
        setupTextField()
    }
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupTextField()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTextField()
    }
    
    private func setupTextField() {
        refusesFirstResponder = false
    }
    
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        // Always try to become first responder on click
        window?.makeFirstResponder(self)
    }
    
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
    
    override var acceptsFirstResponder: Bool {
        return true
    }
    
    // Handle all keyboard input including paste
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Handle Command+V (paste)
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers?.lowercased() == "v" {
            // Make sure we have focus
            window?.makeFirstResponder(self)
            // Small delay to ensure focus is set
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                if let pasteboard = NSPasteboard.general.string(forType: .string) {
                    self.stringValue = pasteboard
                }
            }
            return true
        }
        
        // Handle Command+A (select all)
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers?.lowercased() == "a" {
            window?.makeFirstResponder(self)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                if let textEditor = self.currentEditor() {
                    textEditor.selectAll(self)
                }
            }
            return true
        }
        
        // Handle Command+C (copy)
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers?.lowercased() == "c" {
            window?.makeFirstResponder(self)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(self.stringValue, forType: .string)
            }
            return true
        }
        
        return super.performKeyEquivalent(with: event)
    }
    
    override func keyDown(with event: NSEvent) {
        // Ensure we maintain focus
        if window?.firstResponder != self {
            window?.makeFirstResponder(self)
        }
        super.keyDown(with: event)
    }
    
    // Override becomeFirstResponder to be more aggressive
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        return result
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
    private var activeHost: String?              // legacy (for migration)

        // Shared state protected by serial queue
    private let stateQ = DispatchQueue(label: "app.pinger.state")
    private var monitoredHosts = Set<String>()           // secured by stateQ
    private var hostStates: [String: HostState] = [:]    // secured by stateQ

    // Mapping host -> menu item (for quick icon updates)
    private var hostMenuItems: [String: NSMenuItem] = [:]

    // Anti-flicker in status
    private var menuOpen = false
    private var lastStatusText = ""

    // Inline add host field
    private var inlineAddTextField: NSTextField?
    
    // Toggle all targets button
    private var toggleAllButton: NSButton?
    
    // Inline error message
    private var errorMessageItem: NSMenuItem?

    // Prefs
    private var isNotificationsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: PrefKey.notify) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: PrefKey.notify) }
    }
    private var isDockIconShown: Bool {
        get { UserDefaults.standard.object(forKey: PrefKey.showDockIcon) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: PrefKey.showDockIcon) }
    }

    // MARK: - Lifecycle
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

        AppLogger.L("start with hosts=\(hosts), monitored=\(stateQ.sync { Array(monitoredHosts) })")

        autoSaveConfigToDisk()
        
        // Set up global keyboard monitoring for paste when menu is open
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.menuOpen else { return event }
            
            if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers?.lowercased() == "v" {
                if let textField = self.inlineAddTextField {
                    textField.window?.makeFirstResponder(textField)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                        if let pasteboard = NSPasteboard.general.string(forType: .string) {
                            textField.stringValue = pasteboard
                        }
                    }
                    return nil // consume the event
                }
            }
            return event
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopTimer()
        autoSaveConfigToDisk()
    }

    // MARK: - Dock Icon
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
        updateErrorState() // Check for errors when stopping
    }

    private func restartTimerKeepingState() {
        if isRunning { startTimer() }
    }

    /// Creates a "flat" button as menu view with hover/press highlighting.
    private func makeInlineButton(title: String, action: Selector) -> NSMenuItem {
        let rowHeight: CGFloat = 24
        let leftPadding: CGFloat = 12
        let rightPadding: CGFloat = 8
        let totalWidth: CGFloat = 260   // you can adjust

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
        mi.view = container            // height comes from container frame (24)
        return mi
    }
    
    /// Creates an inline error message that appears in the menu
    private func makeErrorMessage(text: String) -> NSMenuItem {
        let rowHeight: CGFloat = 24
        let leftPadding: CGFloat = 12
        let rightPadding: CGFloat = 8
        let totalWidth: CGFloat = 260

        let container = NSView(frame: NSRect(x: 0, y: 0, width: totalWidth, height: rowHeight))

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .systemRed
        label.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: leftPadding),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -rightPadding),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        let mi = NSMenuItem()
        mi.view = container
        mi.isEnabled = false
        return mi
    }
    
    /// Shows inline error message in menu
    private func showInlineError(_ message: String) {
        guard let menu = statusItem.menu else { return }
        
        // Remove existing error message if any
        hideInlineError()
        
        // Find Start/Stop button position
        var insertIndex: Int?
        for (i, item) in menu.items.enumerated() {
            if item == startStopMenuItem {
                insertIndex = i + 1
                break
            }
        }
        
        guard let index = insertIndex else { return }
        
        let errorItem = makeErrorMessage(text: message)
        menu.insertItem(errorItem, at: index)
        errorMessageItem = errorItem
    }
    
    /// Hides inline error message from menu
    private func hideInlineError() {
        guard let errorItem = errorMessageItem,
              let menu = statusItem.menu else { return }
        
        menu.removeItem(errorItem)
        errorMessageItem = nil
    }
    
    /// Checks current state and shows appropriate error message if needed
    private func updateErrorState() {
        // Only show errors when not running
        guard !isRunning else {
            hideInlineError()
            return
        }
        
        if hosts.isEmpty {
            showInlineError("⚠️ Add a host before starting")
        } else {
            let anySelected = stateQ.sync { !self.monitoredHosts.isEmpty }
            if !anySelected {
                showInlineError("⚠️ Select at least one target to monitor")
            } else {
                hideInlineError()
            }
        }
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

        let startStop = makeInlineButton(title: "Start", action: #selector(toggleStartStop))
        menu.addItem(startStop)
        startStopMenuItem = startStop

        menu.addItem(.separator())

        // Header "Targets" with toggle button
        let header = NSMenuItem(title: "Targets", action: nil, keyEquivalent: "")
        header.isEnabled = false
        
        // Create custom view for header with toggle icon
        let headerContainer = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        
        let headerLabel = NSTextField(labelWithString: "Targets")
        headerLabel.font = NSFont.menuFont(ofSize: 13)
        headerLabel.textColor = NSColor.secondaryLabelColor
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        
        let toggleButton = NSButton(frame: .zero)
        toggleButton.setButtonType(.momentaryPushIn)
        toggleButton.isBordered = false
        toggleButton.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "Toggle All")
        toggleButton.target = self
        toggleButton.action = #selector(toggleAllTargets)
        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        toggleButton.imageScaling = .scaleProportionallyDown
        toggleAllButton = toggleButton
        
        let removeButton = NSButton(frame: .zero)
        removeButton.setButtonType(.momentaryPushIn)
        removeButton.isBordered = false
        removeButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Remove Selected")
        removeButton.target = self
        removeButton.action = #selector(removeSelectedHostsInline)
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.imageScaling = .scaleProportionallyDown
        
        headerContainer.addSubview(headerLabel)
        headerContainer.addSubview(toggleButton)
        headerContainer.addSubview(removeButton)
        
        NSLayoutConstraint.activate([
            headerLabel.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: 12),
            headerLabel.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),
            
            removeButton.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor, constant: -12),
            removeButton.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),
            removeButton.widthAnchor.constraint(equalToConstant: 16),
            removeButton.heightAnchor.constraint(equalToConstant: 16),
            
            toggleButton.trailingAnchor.constraint(equalTo: removeButton.leadingAnchor, constant: -8),
            toggleButton.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),
            toggleButton.widthAnchor.constraint(equalToConstant: 16),
            toggleButton.heightAnchor.constraint(equalToConstant: 16)
        ])
        
        header.view = headerContainer
        menu.addItem(header)
        menu.addItem(.separator())
        refreshTargetsSection(in: menu)

        // Inline add host row
        menu.addItem(makeInlineAddHostRow())

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
            // Find HoverMenuButton in the container
            if let container = self.startStopMenuItem?.view,
               let button = container.subviews.first(where: { $0 is HoverMenuButton }) as? HoverMenuButton {
                button.title = self.isRunning ? "Stop" : "Start"
            }
        }
    }

    // MARK: - Targets as row: [padding][dot][checkbox]

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

        // Use new MenuCheckboxButton instead of NSButton
        let btn = MenuCheckboxButton(frame: .zero)
        btn.title = host
        btn.identifier = NSUserInterfaceItemIdentifier(host)
        btn.state = checked ? .on : .off
        btn.target = self
        btn.action = #selector(hostCheckboxToggled(_:))
        btn.translatesAutoresizingMaskIntoConstraints = false

        // left padding (12pt)
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

    // Add new method
    private func makeInlineAddHostRow() -> NSMenuItem {
        let rowHeight: CGFloat = 28
        let leftPadding: CGFloat = 12
        let rightPadding: CGFloat = 8
        let totalWidth: CGFloat = 260

        let container = NSView(frame: NSRect(x: 0, y: 0, width: totalWidth, height: rowHeight))

        // TextField
        let textField = PersistentMenuTextField(frame: .zero)
        textField.placeholderString = "IP or host"
        textField.identifier = NSUserInterfaceItemIdentifier("addHostField")
        textField.target = self
        textField.action = #selector(addHostInline(_:))
        textField.translatesAutoresizingMaskIntoConstraints = false
        
        // Enable standard text editing behavior (copy/paste/select all)
        textField.isEditable = true
        textField.isSelectable = true
        textField.allowsEditingTextAttributes = false
        textField.importsGraphics = false
        textField.refusesFirstResponder = false
        
        inlineAddTextField = textField

        // Add button
        let addBtn = HoverMenuButton(frame: .zero)
        addBtn.title = "Add"
        addBtn.target = self
        addBtn.action = #selector(addHostInline(_:))
        addBtn.translatesAutoresizingMaskIntoConstraints = false

        // Clear button
        let clearBtn = HoverMenuButton(frame: .zero)
        clearBtn.title = "Clear"
        clearBtn.target = self
        clearBtn.action = #selector(clearAddHostField)
        clearBtn.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(textField)
        container.addSubview(addBtn)
        container.addSubview(clearBtn)

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: leftPadding),
            textField.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            textField.heightAnchor.constraint(equalToConstant: 22),
            
            addBtn.leadingAnchor.constraint(equalTo: textField.trailingAnchor, constant: 6),
            addBtn.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            addBtn.widthAnchor.constraint(equalToConstant: 44),
            addBtn.heightAnchor.constraint(equalToConstant: 24),
            
            clearBtn.leadingAnchor.constraint(equalTo: addBtn.trailingAnchor, constant: 4),
            clearBtn.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -rightPadding),
            clearBtn.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            clearBtn.widthAnchor.constraint(equalToConstant: 44),
            clearBtn.heightAnchor.constraint(equalToConstant: 24)
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
        
        // Find position of inline add host row (don't delete it)
        var addHostRowIdx: Int?
        if let s = startIdx, let e = endIdx {
            for i in s..<e {
                if let view = m.item(at: i)?.view,
                   view.subviews.contains(where: { $0.identifier?.rawValue == "addHostField" }) {
                    addHostRowIdx = i
                    break
                }
            }
        }
        
        if let s = startIdx, let e = endIdx, e > s {
            hostMenuItems.removeAll()
            for i in (s..<e).reversed() {
                // Don't delete add host row
                if i != addHostRowIdx {
                    m.removeItem(at: i)
                }
            }
        }

        stateQ.sync {
            for h in self.hosts where self.hostStates[h] == nil {
                self.hostStates[h] = HostState()
            }
        }

        let monSnap = stateQ.sync { self.monitoredHosts }
        var insertAt = startIdx ?? 1

        // If add host row exists, insert hosts before it
        if let addRowIdx = addHostRowIdx {
            insertAt = addRowIdx
        }

        for host in hosts {
            let row = makeHostRow(for: host, checked: monSnap.contains(host))
            m.insertItem(row, at: insertAt)
            hostMenuItems[host] = row
            insertAt += 1
        }
        
        updateToggleButtonIcon()
        updateErrorState()
    }

    // MARK: - Menu delegate
    func menuWillOpen(_ menu: NSMenu) { 
        menuOpen = true
        updateErrorState() // Check error state when opening menu
        
        // Try to set focus to text field when menu opens
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let textField = self.inlineAddTextField {
                textField.window?.makeFirstResponder(textField)
            }
        }
    }
    
    func menuDidClose(_ menu: NSMenu) { 
        menuOpen = false 
    }
    
    // Add menu-level keyboard handling
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        // This helps maintain keyboard focus context
    }

    // MARK: - Actions

    @objc private func toggleStartStop() {
        if isRunning {
            stopTimer()
            // Don't close menu after Stop - let user see the status
            return
        }
        
        // Check if we can start
        if hosts.isEmpty {
            updateErrorState() // This will show the appropriate error
            return
        }
        let anySelected = stateQ.sync { !self.monitoredHosts.isEmpty }
        if !anySelected {
            updateErrorState() // This will show the appropriate error
            return
        }
        
        // Start successfully
        hideInlineError()
        startTimer()
        // Close menu after successful start
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.statusItem.menu?.cancelTracking()
        }
    }

    /// Checkbox in host row (normal click, ⌥ solo, ⌘ invert selection)
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
            updateToggleButtonIcon()
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
            updateToggleButtonIcon()
            updateErrorState() // Update error state when selection changes
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

    // ————— Inline (don't close menu) —————

    @objc private func toggleAllTargets() {
        let currentMonitored = stateQ.sync { self.monitoredHosts }
        
        // If all hosts are monitored, deselect all
        // Otherwise select all
        if currentMonitored.count == hosts.count && !hosts.isEmpty {
            deselectAllTargets()
        } else {
            selectAllTargets()
        }
        refreshTargetsSection() // refresh list "on the fly"
        updateToggleButtonIcon()
    }

    @objc private func removeSelectedHostsInline() {
        removeSelectedHosts()
        refreshTargetsSection()
        updateToggleButtonIcon()
    }

    // ——— These methods can also be called from other places ———

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

    @objc private func addHostInline(_ sender: Any) {
        guard let textField = inlineAddTextField else { return }
        
        // If this was called by clicking the Add button or pressing Enter,
        // process the text field content
        if sender is HoverMenuButton || sender is NSTextField {
            let newHost = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newHost.isEmpty else { 
                NSSound.beep()
                return 
            }
            
            if !hosts.contains(newHost) {
                hosts.insert(newHost, at: 0)
                stateQ.sync {
                    self.monitoredHosts.insert(newHost)
                    self.hostStates[newHost] = HostState()
                }
                savePrefs()
                refreshTargetsSection()
                autoSaveConfigToDisk()
                textField.stringValue = ""
                updateToggleButtonIcon()
                updateErrorState() // Update error state when hosts change
                
                if isRunning {
                    DispatchQueue.global(qos: .utility).async { [weak self] in 
                        self?.pingOne(host: newHost) 
                    }
                }
            } else {
                NSSound.beep()
            }
        }
    }

    @objc private func clearAddHostField() {
        inlineAddTextField?.stringValue = ""
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
        AppLogger.L("console logs \(enabled ? "enabled" : "disabled")")
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

    // MARK: - Tick / parallel ping
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
        // atomic inFlight marker
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

    // ICMP via /sbin/ping (Sandbox OFF)
    private func runPingOnceICMP(host: String) -> Bool {
        let task = Process()
        task.launchPath = Config.pingPath
        task.arguments = ["-n", "-c", "1", "-W", "1000", "-q", host]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError  = pipe

        do {
            AppLogger.L("exec: \(Config.pingPath) \(task.arguments!.joined(separator: " "))")
            try task.run()
            task.waitUntilExit()
            return Int(task.terminationStatus) == 0
        } catch {
            AppLogger.L("ping exec failed: \(error)")
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

    /// Sets tray dot color based on aggregate state
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
        // durring stabilization we keep the previous color
    }

    private func updateToggleButtonIcon() {
        DispatchQueue.main.async {
            guard let button = self.toggleAllButton else { return }
            
            let currentMonitored = self.stateQ.sync { self.monitoredHosts }
            let allSelected = currentMonitored.count == self.hosts.count && !self.hosts.isEmpty
            
            // If all are selected - show icon for deselecting
            // If not all selected - show icon for selecting
            let iconName = allSelected ? "checkmark.circle.fill" : "checkmark.circle"
            button.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "Toggle All")
            
            // Tooltip
            button.toolTip = allSelected ? "Deselect All Targets" : "Select All Targets"
        }
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

        // First run -> defaults; if key exists (even empty list) -> use it
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
        ud.set(hosts, forKey: PrefKey.hosts)                      // can be empty
        let mon = stateQ.sync { Array(self.monitoredHosts) }
        ud.set(mon, forKey: PrefKey.monitored)                    // can be empty
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
            AppLogger.L("config auto-saved to \(url.path)")
        } catch { AppLogger.L("config auto-save failed: \(error)") }
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
            AppLogger.L("config loaded from \(url.path)")
            return true
        } catch {
            AppLogger.L("config load failed: \(error)")
            return false
        }
    }

    // MARK: - Mods in foreground
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
