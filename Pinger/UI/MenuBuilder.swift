//
//  MenuBuilder.swift
//  Pinger
//
//  Created by Dawid Deregowski on 19/09/2025.
//

import Cocoa

// MARK: - Menu Action
enum MenuAction {
    case startStop
    case addHost(String)
    case clearHostField
    case toggleHost(String)
    case toggleAllTargets
    case removeSelectedHosts
    case toggleMonitoringType(String)
    case setInterval(TimeInterval)
    case setFlap(Int)
    case toggleNotifications
    case toggleLogs
    case toggleDockIcon
    case toggleAutostart
    case showAbout
    case quit
}

// MARK: - Menu Builder Delegate
protocol MenuBuilderDelegate: AnyObject {
    func menuBuilder(_ builder: MenuBuilder, didSelectAction action: MenuAction)
}

// MARK: - Menu Builder
class MenuBuilder: NSObject, NSMenuDelegate {
    weak var delegate: MenuBuilderDelegate?
    
    // State
    private var hosts: [String] = []
    private var monitoredHosts = Set<String>()
    private var hostStates: [String: HostState] = [:]
    private var isRunning = false
    private var menuOpen = false
    private var currentMenu: NSMenu?
    
    // UI References
    private var statusMenuItem: NSMenuItem?
    private var startStopMenuItem: NSMenuItem?
    private var errorMessageItem: NSMenuItem?
    private var toggleAllButton: NSButton?
    private var inlineAddTextField: PersistentMenuTextField?
    private var hostMenuItems: [String: NSMenuItem] = [:]
    
    // Settings menu references
    private var settingsMenuItem: NSMenuItem?
    private var notificationsMenuItem: NSMenuItem?
    private var logsMenuItem: NSMenuItem?
    private var dockIconMenuItem: NSMenuItem?
    private var autostartMenuItem: NSMenuItem?
    private var pingIntervalMenu: NSMenu?
    private var flapMenu: NSMenu?
    
    // MARK: - Public Interface
    
    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        currentMenu = menu  // Store reference
        
        // Status
        let status = createDisabledMenuItem(title: "Status: Paused")
        menu.addItem(status)
        statusMenuItem = status
        menu.addItem(createSeparator())
        
        // Start/Stop
        let startStop = makeInlineButton(title: "Start", action: #selector(startStopAction))
        menu.addItem(startStop)
        startStopMenuItem = startStop
        
        menu.addItem(createSeparator())
        
        // Targets header
        let header = makeTargetsHeader()
        menu.addItem(header)
        menu.addItem(createSeparator())
        
        // Host list will be added here dynamically
        refreshTargetsSection(in: menu)
        
        // Add host row
        menu.addItem(makeInlineAddHostRow())
        menu.addItem(createSeparator())
        
        // Settings
        menu.addItem(buildSettingsMenu())
        
        // About & Quit
        let aboutItem = createMenuItem(title: "About Pinger", action: #selector(showAboutAction))
        menu.addItem(createSeparator())
        menu.addItem(aboutItem)
        
        let quitItem = createMenuItem(title: "Quit", action: #selector(quitAction), keyEquivalent: "q")
        menu.addItem(quitItem)
        
        return menu
    }
    
    func updateMenu(hosts: [String], monitored: Set<String>, states: [String: HostState], isRunning: Bool, fullRebuild: Bool = true) {
        self.hosts = hosts
        self.monitoredHosts = monitored
        self.hostStates = states
        self.isRunning = isRunning
        
        if fullRebuild {
            updateStartStopTitle()
            refreshTargetsSection(in: currentMenu)
            updateToggleButtonIcon()
            updateSettingsStates()
            updateErrorState()
        } else {
            // Lightweight update for frequent operations
            AppLogger.L("updateMenu (lightweight): hosts=\(hosts.count), monitored=\(monitored.count)")
            updateStartStopTitle()
            updateToggleButtonIcon()
        }
    }
    
    // Convenience method for lightweight updates
    func updateInternalState(hosts: [String], monitored: Set<String>, states: [String: HostState], isRunning: Bool) {
        updateMenu(hosts: hosts, monitored: monitored, states: states, isRunning: isRunning, fullRebuild: false)
    }
    
    func updateStatusText(_ text: String) {
        DispatchQueue.main.async {
            self.statusMenuItem?.title = "Status: \(text)"
        }
    }
    
    func updateMenuIcon(for host: String) {
        DispatchQueue.main.async {
            guard let item = self.hostMenuItems[host],
                  let container = item.view,
                  let dot = container.findSubview(with: NSUserInterfaceItemIdentifier("dot-\(host)")) as? NSImageView,
                  let btn = container.findSubview(with: NSUserInterfaceItemIdentifier(host)) as? MenuCheckboxButton else { 
                AppLogger.L("updateMenuIcon failed to find UI elements for host: \(host)")
                return 
            }
            
            let checked = self.monitoredHosts.contains(host)
            let stable = self.hostStates[host]?.lastStableIsUp
            
            dot.image = self.miniDot(for: host)
            btn.state = checked ? .on : .off
            
            AppLogger.L("updateMenuIcon for \(host): checked=\(checked), stable=\(stable?.description ?? "nil")")
        }
    }
    
    func updateMonitoringTypeIcon(for host: String) {
        DispatchQueue.main.async {
            guard let item = self.hostMenuItems[host],
                  let container = item.view,
                  let typeButton = container.findSubview(with: NSUserInterfaceItemIdentifier("type-\(host)")) as? NSButton else { return }
            
            let hostState = self.hostStates[host]
            let currentType = hostState?.monitoringType ?? .icmp
            
            typeButton.image = NSImage(systemSymbolName: currentType.icon, 
                                      accessibilityDescription: currentType.displayName)
            typeButton.toolTip = "Switch to \(currentType == .icmp ? "HTTP" : "ICMP") monitoring"
        }
    }
    
    func showInlineError(_ message: String) {
        guard let menu = statusMenuItem?.menu else { return }
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
    
    func hideInlineError() {
        guard let errorItem = errorMessageItem,
              let menu = statusMenuItem?.menu else { return }
        
        menu.removeItem(errorItem)
        errorMessageItem = nil
    }
    
    // MARK: - NSMenuDelegate
    
    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        updateErrorState()
        
        // Try to set focus to text field
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let textField = self.inlineAddTextField {
                textField.window?.makeFirstResponder(textField)
            }
        }
    }
    
    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
    }
    
    // MARK: - Private Methods
    
    private func makeTargetsHeader() -> NSMenuItem {
        let header = NSMenuItem(title: "Targets", action: nil, keyEquivalent: "")
        header.isEnabled = false
        
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
        toggleButton.action = #selector(toggleAllAction)
        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        toggleButton.imageScaling = .scaleProportionallyDown
        toggleAllButton = toggleButton
        
        let removeButton = NSButton(frame: .zero)
        removeButton.setButtonType(.momentaryPushIn)
        removeButton.isBordered = false
        removeButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Remove Selected")
        removeButton.target = self
        removeButton.action = #selector(removeSelectedAction)
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
        return header
    }
    
    private func makeHostRow(for host: String, checked: Bool) -> NSMenuItem {
        // Status dot
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
        
        // Monitoring type button
        let typeButton = NSButton(frame: .zero)
        typeButton.setButtonType(.momentaryPushIn)
        typeButton.isBordered = false
        typeButton.bezelStyle = .texturedRounded
        typeButton.focusRingType = .none
        
        let currentType = hostStates[host]?.monitoringType ?? .icmp
        typeButton.image = NSImage(systemSymbolName: currentType.icon,
                                  accessibilityDescription: currentType.displayName)
        typeButton.imageScaling = .scaleProportionallyDown
        typeButton.target = self
        typeButton.action = #selector(toggleMonitoringTypeAction(_:))
        typeButton.identifier = NSUserInterfaceItemIdentifier("type-\(host)")
        typeButton.translatesAutoresizingMaskIntoConstraints = false
        typeButton.toolTip = "Switch to \(currentType == .icmp ? "HTTP" : "ICMP") monitoring"
        NSLayoutConstraint.activate([
            typeButton.widthAnchor.constraint(equalToConstant: 16),
            typeButton.heightAnchor.constraint(equalToConstant: 16)
        ])
        
        // Checkbox
        let checkbox = MenuCheckboxButton(frame: .zero)
        checkbox.title = host
        checkbox.identifier = NSUserInterfaceItemIdentifier(host)
        checkbox.state = checked ? .on : .off
        checkbox.target = self
        checkbox.action = #selector(hostCheckboxAction(_:))
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        
        // Layout
        let pad = NSView(frame: .zero)
        pad.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pad.widthAnchor.constraint(equalToConstant: 12)
        ])
        
        let stack = NSStackView(views: [pad, dot, typeButton, checkbox])
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
        
        let menuItem = NSMenuItem()
        menuItem.view = container
        return menuItem
    }
    
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
        textField.action = #selector(addHostAction(_:))
        textField.translatesAutoresizingMaskIntoConstraints = false
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
        addBtn.action = #selector(addHostAction(_:))
        addBtn.translatesAutoresizingMaskIntoConstraints = false
        
        // Clear button
        let clearBtn = HoverMenuButton(frame: .zero)
        clearBtn.title = "Clear"
        clearBtn.target = self
        clearBtn.action = #selector(clearHostFieldAction)
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
        
        let menuItem = NSMenuItem()
        menuItem.view = container
        return menuItem
    }
    
    private func makeInlineButton(title: String, action: Selector) -> NSMenuItem {
        let rowHeight: CGFloat = 24
        let leftPadding: CGFloat = 12
        let rightPadding: CGFloat = 8
        let totalWidth: CGFloat = 260
        
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
        
        let menuItem = NSMenuItem()
        menuItem.view = container
        return menuItem
    }
    
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
        
        let menuItem = NSMenuItem()
        menuItem.view = container
        menuItem.isEnabled = false
        return menuItem
    }
    
    private func buildSettingsMenu() -> NSMenuItem {
        let settings = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let settingsSub = NSMenu()
        // Remove autoenablesItems = false to match original behavior
        
        // Ping interval
        let intervalItem = NSMenuItem(title: "Ping interval", action: nil, keyEquivalent: "")
        let intervalSub = NSMenu()
        // Remove autoenablesItems = false to match original behavior
        for (title, value) in [("0.5 s", 0.5), ("1 s", 1.0), ("2 s", 2.0), ("5 s", 5.0)] {
            let item = NSMenuItem(title: title, action: #selector(setIntervalAction(_:)), keyEquivalent: "")
            item.representedObject = value
            item.target = self
            if abs(Config.intervalSeconds - value) < 0.001 { item.state = .on }
            intervalSub.addItem(item)
        }
        intervalItem.submenu = intervalSub
        pingIntervalMenu = intervalSub
        settingsSub.addItem(intervalItem)
        
        // Anti-flap
        let flapItem = NSMenuItem(title: "Stabilization (anti-flap)", action: nil, keyEquivalent: "")
        let flapSub = NSMenu()
        // Remove autoenablesItems = false to match original behavior
        for val in [1, 2, 3] {
            let item = NSMenuItem(title: "\(val)× confirmation", action: #selector(setFlapAction(_:)), keyEquivalent: "")
            item.representedObject = val
            item.target = self
            item.state = (val == Config.upThreshold && val == Config.downThreshold) ? .on : .off
            flapSub.addItem(item)
        }
        flapItem.submenu = flapSub
        flapMenu = flapSub
        settingsSub.addItem(flapItem)
        
        // Notifications
        let notifyItem = NSMenuItem(title: "Notifications", action: #selector(toggleNotificationsAction), keyEquivalent: "")
        notifyItem.target = self
        notifyItem.state = UserDefaults.standard.pingerNotificationsEnabled ? .on : .off
        notificationsMenuItem = notifyItem  // Store reference
        settingsSub.addItem(notifyItem)
        
        // Logs
        let logsItem = NSMenuItem(title: "Console logs", action: #selector(toggleLogsAction), keyEquivalent: "")
        logsItem.target = self
        logsItem.state = UserDefaults.standard.pingerLogsEnabled ? .on : .off
        logsMenuItem = logsItem  // Store reference
        settingsSub.addItem(logsItem)
        
        // Dock icon
        let dockItem = NSMenuItem(title: "Show Dock icon", action: #selector(toggleDockIconAction), keyEquivalent: "")
        dockItem.target = self
        dockItem.state = UserDefaults.standard.pingerShowDockIcon ? .on : .off
        dockIconMenuItem = dockItem  // Store reference
        settingsSub.addItem(dockItem)
        
        // Autostart
        let autostartItem = NSMenuItem(title: "Launch at login", action: #selector(toggleAutostartAction), keyEquivalent: "")
        autostartItem.target = self
        autostartItem.state = UserDefaults.standard.pingerAutostart ? .on : .off
        autostartMenuItem = autostartItem  // Store reference
        settingsSub.addItem(autostartItem)
        
        settings.submenu = settingsSub
        settingsMenuItem = settings  // Store main settings reference
        return settings
    }
    
    private func refreshTargetsSection(in menu: NSMenu? = nil) {
        guard let menu = menu ?? statusMenuItem?.menu else { return }
        
        // Find targets section boundaries
        var startIdx: Int?
        var endIdx: Int?
        var addHostRowIdx: Int?
        
        for (i, item) in menu.items.enumerated() {
            if item.title == "Targets" && !item.isEnabled {
                startIdx = i + 1
            } else if startIdx != nil && item.isSeparatorItem {
                endIdx = i
                break
            } else if let view = item.view,
                      view.findSubview(with: NSUserInterfaceItemIdentifier("addHostField")) != nil {
                addHostRowIdx = i
            }
        }
        
        // Remove existing host items
        if let s = startIdx, let e = endIdx, e > s {
            hostMenuItems.removeAll()
            for i in (s..<e).reversed() {
                if i != addHostRowIdx && i < menu.items.count {
                    // Additional safety check before removing
                    let item = menu.items[i]
                    if item.view != nil && !item.isSeparatorItem && item.title != "Targets" {
                        menu.removeItem(at: i)
                    }
                }
            }
        }
        
        // Add host rows
        var insertAt = startIdx ?? 1
        if let addRowIdx = addHostRowIdx {
            insertAt = addRowIdx
        }
        
        for host in hosts {
            let row = makeHostRow(for: host, checked: monitoredHosts.contains(host))
            menu.insertItem(row, at: insertAt)
            hostMenuItems[host] = row
            insertAt += 1
        }
    }
    
    private func updateStartStopTitle() {
        DispatchQueue.main.async {
            if let container = self.startStopMenuItem?.view,
               let button = container.subviews.first(where: { $0 is HoverMenuButton }) as? HoverMenuButton {
                button.title = self.isRunning ? "Stop" : "Start"
            }
        }
    }
    
    private func updateToggleButtonIcon() {
        DispatchQueue.main.async {
            guard let button = self.toggleAllButton else { return }
            
            let allSelected = self.monitoredHosts.count == self.hosts.count && !self.hosts.isEmpty
            let iconName = allSelected ? "checkmark.circle.fill" : "checkmark.circle"
            button.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "Toggle All")
            button.toolTip = allSelected ? "Deselect All Targets" : "Select All Targets"
        }
    }
    
    private func updateErrorState() {
        guard !isRunning else {
            hideInlineError()
            return
        }
        
        if hosts.isEmpty {
            showInlineError("⚠️ Add a host before starting")
        } else if monitoredHosts.isEmpty {
            showInlineError("⚠️ Select at least one target to monitor")
        } else {
            hideInlineError()
        }
    }
    
    private func miniDot(for host: String) -> NSImage? {
        let stable = hostStates[host]?.lastStableIsUp
        let color: NSColor = (stable == nil) ? .systemGray : (stable! ? .systemGreen : .systemRed)
        
        return NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [color]))
    }
    
    func updateSettingsStates() {
        DispatchQueue.main.async {
            // Update checkbox states for settings items
            self.notificationsMenuItem?.state = UserDefaults.standard.pingerNotificationsEnabled ? .on : .off
            self.logsMenuItem?.state = UserDefaults.standard.pingerLogsEnabled ? .on : .off
            self.dockIconMenuItem?.state = UserDefaults.standard.pingerShowDockIcon ? .on : .off
            self.autostartMenuItem?.state = UserDefaults.standard.pingerAutostart ? .on : .off
            
            // Update interval selection
            if let intervalMenu = self.pingIntervalMenu {
                for item in intervalMenu.items {
                    if let value = item.representedObject as? TimeInterval {
                        item.state = (abs(Config.intervalSeconds - value) < 0.001) ? .on : .off
                    }
                }
            }
            
            // Update flap selection  
            if let flapMenu = self.flapMenu {
                for item in flapMenu.items {
                    if let value = item.representedObject as? Int {
                        item.state = (value == Config.upThreshold && value == Config.downThreshold) ? .on : .off
                    }
                }
            }
        }
    }
    
    // MARK: - Actions
    
    @objc private func startStopAction() {
        delegate?.menuBuilder(self, didSelectAction: .startStop)
    }
    
    @objc private func addHostAction(_ sender: Any) {
        guard let textField = inlineAddTextField else { return }
        let newHost = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newHost.isEmpty else { return }
        
        delegate?.menuBuilder(self, didSelectAction: .addHost(newHost))
        textField.stringValue = ""
    }
    
    @objc private func clearHostFieldAction() {
        delegate?.menuBuilder(self, didSelectAction: .clearHostField)
        inlineAddTextField?.stringValue = ""
    }
    
    @objc private func hostCheckboxAction(_ sender: MenuCheckboxButton) {
        guard let host = sender.identifier?.rawValue else { return }
        delegate?.menuBuilder(self, didSelectAction: .toggleHost(host))
    }
    
    @objc private func toggleAllAction() {
        delegate?.menuBuilder(self, didSelectAction: .toggleAllTargets)
    }
    
    @objc private func removeSelectedAction() {
        delegate?.menuBuilder(self, didSelectAction: .removeSelectedHosts)
    }
    
    @objc private func toggleMonitoringTypeAction(_ sender: NSButton) {
        guard let identifier = sender.identifier?.rawValue,
              identifier.hasPrefix("type-") else { return }
        let host = String(identifier.dropFirst(5))
        delegate?.menuBuilder(self, didSelectAction: .toggleMonitoringType(host))
    }
    
    @objc private func setIntervalAction(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? TimeInterval else { return }
        delegate?.menuBuilder(self, didSelectAction: .setInterval(value))
    }
    
    @objc private func setFlapAction(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Int else { return }
        delegate?.menuBuilder(self, didSelectAction: .setFlap(value))
    }
    
    @objc private func toggleNotificationsAction() {
        delegate?.menuBuilder(self, didSelectAction: .toggleNotifications)
    }
    
    @objc private func toggleLogsAction() {
        delegate?.menuBuilder(self, didSelectAction: .toggleLogs)
    }
    
    @objc private func toggleDockIconAction() {
        delegate?.menuBuilder(self, didSelectAction: .toggleDockIcon)
    }
    
    @objc private func toggleAutostartAction() {
        delegate?.menuBuilder(self, didSelectAction: .toggleAutostart)
    }
    
    @objc private func showAboutAction() {
        delegate?.menuBuilder(self, didSelectAction: .showAbout)
    }
    
    @objc private func quitAction() {
        delegate?.menuBuilder(self, didSelectAction: .quit)
    }
    
    // MARK: - Helper Methods
    
    private func createMenuItem(title: String, action: Selector? = nil, keyEquivalent: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = target ?? self
        return item
    }
    
    private func createSeparator() -> NSMenuItem {
        return NSMenuItem.separator()
    }
    
    private func createDisabledMenuItem(title: String) -> NSMenuItem {
        let item = createMenuItem(title: title)
        item.isEnabled = false
        return item
    }
}