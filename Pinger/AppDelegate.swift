//
//  AppDelegate.swift
//  Pinger
//
//  Created by Dawid Deregowski on 19/09/2025.
//

import Cocoa
import UserNotifications
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    
    // Core components
    private let monitoringEngine = MonitoringEngine()
    private let statusBarManager = StatusBarManager()
    private let menuBuilder = MenuBuilder()
    private let configManager = ConfigurationManager()
    
    // State tracking
    private var mainMenu: NSMenu?
    private var isMenuOpen = false
    
    // MARK: - Lifecycle
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupComponents()
        loadConfiguration()
        setupUI()
        setupNotifications()
        
        // Don't auto-start monitoring - user should click Start button manually
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        monitoringEngine.stopMonitoring()
        saveConfiguration()
    }
    
    // MARK: - Setup
    
    private func setupComponents() {
        // Set delegates
        monitoringEngine.delegate = self
        menuBuilder.delegate = self
        
        // Configuration is already loaded in ConfigurationManager init
        
        // Update monitoring engine with hosts
        monitoringEngine.updateHosts(configManager.hosts)
    }
    
    private func loadConfiguration() {
        // Load app configuration from defaults
        Config.intervalSeconds = UserDefaults.standard.pingerInterval
        Config.upThreshold = UserDefaults.standard.pingerFlap
        Config.downThreshold = UserDefaults.standard.pingerFlap
        
        // Load configuration from disk (includes monitored hosts and types)
        if let loadedConfig = configManager.loadConfigFromDisk() {
            // Set monitored hosts in the monitoring engine
            monitoringEngine.setMonitoredHosts(loadedConfig.monitoredHosts)
            
            // Set monitoring types for each host
            for (host, type) in loadedConfig.hostTypes {
                monitoringEngine.setMonitoringType(for: host, type: type)
            }
        }
    }
    
    private func setupUI() {
        // Status bar is already setup in StatusBarManager init
        
        // Create initial menu
        updateUI()
        
        // Apply dock icon preference
        applyActivationPolicyFromPrefs()
    }
    
    private func setupNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                AppLogger.L("notification authorization error: \(error)")
            } else {
                AppLogger.L("notification authorization granted: \(granted)")
            }
        }
    }
    
    // MARK: - UI Updates
    
    private func updateUI() {
        let hosts = configManager.hosts
        let monitoredHosts = monitoringEngine.getMonitoredHosts()
        let hostStates = monitoringEngine.getAllHostStates()
        let isRunning = monitoringEngine.isRunning
        
        // Update menu builder state
        menuBuilder.updateMenu(hosts: hosts, monitored: monitoredHosts, states: hostStates, isRunning: isRunning)
        
        // Create menu only once
        if mainMenu == nil {
            mainMenu = menuBuilder.buildMenu()
            mainMenu?.delegate = self
            statusBarManager.setMenu(mainMenu!)
        }
        
        // Update status bar icon - only check monitored hosts like in original
        var anyDown = false
        var anyUnknown = false
        
        for host in monitoredHosts {
            if let hostState = hostStates[host] {
                if let stable = hostState.lastStableIsUp {
                    if !stable {
                        anyDown = true
                    }
                } else {
                    anyUnknown = true
                }
            } else {
                anyUnknown = true
            }
        }
        
        let isEmpty = monitoredHosts.isEmpty
        AppLogger.L("updateUI: running=\(isRunning), hosts=\(hosts.count), monitored=\(monitoredHosts.count), anyDown=\(anyDown), anyUnknown=\(anyUnknown), isEmpty=\(isEmpty)")
        statusBarManager.updateAggregateTrayIcon(anyDown: anyDown, anyUnknown: anyUnknown, isRunning: isRunning, isEmpty: isEmpty)
    }
    
    private func forceMenuRefresh() {
        // Force complete menu rebuild for settings changes
        DispatchQueue.main.async {
            // Force rebuild
            self.mainMenu = self.menuBuilder.buildMenu()
            self.mainMenu?.delegate = self
            self.statusBarManager.setMenu(self.mainMenu!)
            
            // Update with current state immediately
            self.menuBuilder.updateMenu(hosts: self.configManager.hosts, 
                                       monitored: self.monitoringEngine.getMonitoredHosts(), 
                                       states: self.monitoringEngine.getAllHostStates(), 
                                       isRunning: self.monitoringEngine.isRunning)
        }
    }
    
    private func saveConfiguration() {
        configManager.savePreferences()
        // Save monitoring state to disk via ConfigurationManager
        let monitoredHosts = monitoringEngine.getMonitoredHosts()
        let hostStates = monitoringEngine.getAllHostStates()
        configManager.saveConfigToDisk(monitoredHosts: monitoredHosts, hostStates: hostStates)
    }
    
    private func applyActivationPolicyFromPrefs() {
        let showDockIcon = UserDefaults.standard.pingerShowDockIcon
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
    }
    
    private func relaunchApp() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = [bundlePath]
        
        try? task.run()
        
        NSApp.terminate(nil)
    }
    
    private func sendNotification(host: String, isUp: Bool) {
        guard UserDefaults.standard.pingerNotificationsEnabled else { return }
        
        AppLogger.L("sending notification: \(host) is \(isUp ? "UP" : "DOWN")")
        
        let content = UNMutableNotificationContent()
        content.title = isUp ? "Host reachable" : "Host down"
        content.body = host
        content.sound = UNNotificationSound.default
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                AppLogger.L("notification send error: \(error)")
            }
        }
    }
    
    private func showAbout() {
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "-"
        let path = configManager.getConfigFilePath()
        let desc = "A tiny menu bar monitor that pings selected hosts in parallel."
        
        let alert = NSAlert()
        alert.messageText = "Pinger"
        alert.informativeText = """
        Version: \(version) (\(build))
        
        Author: \(Config.appAuthor)
        
        \(desc)
        
        Configuration: \(path)
        """
        alert.addButton(withTitle: "OK")
        alert.alertStyle = .informational
        
        // For menu bar apps without main window, runModal is still appropriate
        DispatchQueue.main.async {
            alert.runModal()
        }
    }
}

// MARK: - MonitoringEngineDelegate

extension AppDelegate: MonitoringEngineDelegate {
    func monitoringEngine(_ engine: MonitoringEngine, didUpdateHost host: String) {
        DispatchQueue.main.async {
            // Update MenuBuilder state first
            let hosts = self.configManager.hosts
            let monitoredHosts = engine.getMonitoredHosts()
            let hostStates = engine.getAllHostStates()
            let isRunning = engine.isRunning
            
            // Update MenuBuilder internal state without rebuilding menu structure
            self.menuBuilder.updateInternalState(hosts: hosts, monitored: monitoredHosts, states: hostStates, isRunning: isRunning)
            
            // Update specific host icon with fresh state
            self.menuBuilder.updateMenuIcon(for: host)
            
            // Update status bar icon only
            var anyDown = false
            var anyUnknown = false
            let isEmpty = monitoredHosts.isEmpty
            
            for monitoredHost in monitoredHosts {
                if let hostState = hostStates[monitoredHost] {
                    if let stable = hostState.lastStableIsUp {
                        if !stable {
                            anyDown = true
                        }
                    } else {
                        anyUnknown = true
                    }
                } else {
                    anyUnknown = true
                }
            }
            
            self.statusBarManager.updateAggregateTrayIcon(anyDown: anyDown, anyUnknown: anyUnknown, isRunning: isRunning, isEmpty: isEmpty)
        }
    }
    
    func monitoringEngine(_ engine: MonitoringEngine, didChangeStatusFor host: String, isUp: Bool) {
        DispatchQueue.main.async {
            self.sendNotification(host: host, isUp: isUp)
            
            // Update MenuBuilder state first
            let hosts = self.configManager.hosts
            let monitoredHosts = engine.getMonitoredHosts()
            let hostStates = engine.getAllHostStates()
            let isRunning = engine.isRunning
            
            // Update MenuBuilder internal state without rebuilding menu structure
            self.menuBuilder.updateInternalState(hosts: hosts, monitored: monitoredHosts, states: hostStates, isRunning: isRunning)
            
            // Update specific host icon with fresh state
            self.menuBuilder.updateMenuIcon(for: host)
            
            // Update status bar icon only
            var anyDown = false
            var anyUnknown = false
            let isEmpty = monitoredHosts.isEmpty
            
            for monitoredHost in monitoredHosts {
                if let hostState = hostStates[monitoredHost] {
                    if let stable = hostState.lastStableIsUp {
                        if !stable {
                            anyDown = true
                        }
                    } else {
                        anyUnknown = true
                    }
                } else {
                    anyUnknown = true
                }
            }
            
            self.statusBarManager.updateAggregateTrayIcon(anyDown: anyDown, anyUnknown: anyUnknown, isRunning: isRunning, isEmpty: isEmpty)
        }
    }
    
    func monitoringEngine(_ engine: MonitoringEngine, didUpdateOverallStatus text: String) {
        DispatchQueue.main.async {
            self.menuBuilder.updateStatusText(text)
        }
    }
}

// MARK: - MenuBuilderDelegate

extension AppDelegate: MenuBuilderDelegate {
    func menuBuilder(_ builder: MenuBuilder, didSelectAction action: MenuAction) {
        switch action {
        case .startStop:
            handleStartStop()
        case .addHost(let host):
            handleAddHost(host)
        case .clearHostField:
            // Handle clear host field if needed
            break
        case .toggleHost(let host):
            handleToggleHost(host)
        case .toggleAllTargets:
            handleToggleAllTargets()
        case .removeSelectedHosts:
            handleRemoveSelectedHosts()
        case .toggleMonitoringType(let host):
            handleToggleMonitoringType(host)
        case .setInterval(let interval):
            handleSetInterval(interval)
        case .setFlap(let flap):
            handleSetFlap(flap)
        case .toggleNotifications:
            handleToggleNotifications()
        case .toggleLogs:
            handleToggleLogs()
        case .toggleDockIcon:
            handleToggleDockIcon()
        case .toggleAutostart:
            handleToggleAutostart()
        case .showAbout:
            showAbout()
        case .quit:
            NSApp.terminate(nil)
        }
    }
    
    // MARK: - Action Handlers
    
    private func handleStartStop() {
        if monitoringEngine.isRunning {
            monitoringEngine.stopMonitoring()
            menuBuilder.updateStatusText("Paused")
        } else {
            // Check if we have any monitored hosts
            let monitoredHosts = monitoringEngine.getMonitoredHosts()
            guard !monitoredHosts.isEmpty else {
                NSSound.beep()
                return
            }
            
            // Start monitoring
            monitoringEngine.startMonitoring()
            
            // Close menu after successful start
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                // Menu will update automatically
            }
        }
        
        updateUI()
    }
    
    private func handleAddHost(_ host: String) {
        guard configManager.addHost(host) else {
            NSSound.beep()
            return
        }
        
        monitoringEngine.updateHosts(configManager.hosts)
        updateUI()
        
        // If menu is open, defer update to avoid crash
        if isMenuOpen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.menuBuilder.updateMenu(hosts: self.configManager.hosts,
                                          monitored: self.monitoringEngine.getMonitoredHosts(),
                                          states: self.monitoringEngine.getAllHostStates(),
                                          isRunning: self.monitoringEngine.isRunning)
            }
        } else {
            menuBuilder.updateMenu(hosts: configManager.hosts,
                                  monitored: monitoringEngine.getMonitoredHosts(),
                                  states: monitoringEngine.getAllHostStates(),
                                  isRunning: monitoringEngine.isRunning)
        }
        
        saveConfiguration()
    }
    
    private func handleToggleHost(_ host: String) {
        // Always toggle monitoring state, regardless of whether monitoring is running
        monitoringEngine.toggleMonitoring(for: host)
        
        // Update UI - this will properly refresh menu state and icons
        updateUI()
        
        saveConfiguration()
    }
    
    private func handleToggleAllTargets() {
        let currentMonitored = monitoringEngine.getMonitoredHosts()
        
        if currentMonitored.count == configManager.hosts.count {
            // Deselect all
            monitoringEngine.setMonitoredHosts(Set())
        } else {
            // Select all
            monitoringEngine.setMonitoredHosts(Set(configManager.hosts))
        }
        
        // Update UI - this will properly refresh all menu states and icons
        updateUI()
        
        saveConfiguration()
    }
    
    private func handleRemoveSelectedHosts() {
        let selected = monitoringEngine.getMonitoredHosts()
        guard !selected.isEmpty else {
            NSSound.beep()
            return
        }
        
        let hostsToRemove = configManager.hosts.filter { selected.contains($0) }
        configManager.removeHosts(hostsToRemove)
        monitoringEngine.updateHosts(configManager.hosts)
        
        updateUI()
        saveConfiguration()
    }
    
    private func handleToggleMonitoringType(_ host: String) {
        monitoringEngine.toggleMonitoringType(for: host)
        updateUI()
        // Use direct UI updates for immediate visual feedback
        menuBuilder.updateMonitoringTypeIcon(for: host)
        menuBuilder.updateMenuIcon(for: host) // Reset dot to gray
        saveConfiguration()
    }
    
    private func handleSetInterval(_ interval: TimeInterval) {
        Config.intervalSeconds = interval
        UserDefaults.standard.pingerInterval = interval
        
        // Restart monitoring if running to apply new interval
        if monitoringEngine.isRunning {
            monitoringEngine.stopMonitoring()
            monitoringEngine.startMonitoring()
        }
        
        updateUI()
        // Use direct settings update instead of full menu refresh
        menuBuilder.updateSettingsStates()
        saveConfiguration()
    }
    
    private func handleSetFlap(_ flap: Int) {
        Config.upThreshold = flap
        Config.downThreshold = flap
        UserDefaults.standard.pingerFlap = flap
        
        monitoringEngine.resetStatesForFlapChange()
        updateUI()
        // Use direct settings update instead of full menu refresh
        menuBuilder.updateSettingsStates()
        saveConfiguration()
    }
    
    private func handleToggleNotifications() {
        let current = UserDefaults.standard.pingerNotificationsEnabled
        UserDefaults.standard.pingerNotificationsEnabled = !current
        // Use direct settings update instead of full menu refresh
        menuBuilder.updateSettingsStates()
        saveConfiguration()
    }
    
    private func handleToggleLogs() {
        let current = UserDefaults.standard.pingerLogsEnabled
        UserDefaults.standard.pingerLogsEnabled = !current
        AppLogger.L("console logs \(!current ? "enabled" : "disabled")")
        // Use direct settings update instead of full menu refresh
        menuBuilder.updateSettingsStates()
        saveConfiguration()
    }
    
    private func handleToggleDockIcon() {
        let current = UserDefaults.standard.pingerShowDockIcon
        UserDefaults.standard.pingerShowDockIcon = !current
        // Use direct settings update instead of full menu refresh
        menuBuilder.updateSettingsStates()
        saveConfiguration()
        
        applyActivationPolicyFromPrefs()
        relaunchApp()
    }
    
    private func handleToggleAutostart() {
        let current = UserDefaults.standard.pingerAutostart
        UserDefaults.standard.pingerAutostart = !current
        // Use direct settings update instead of full menu refresh
        menuBuilder.updateSettingsStates()
        saveConfiguration()
        
        // Configure launch at login
        configureLaunchAtLogin(!current)
    }
    
    private func configureLaunchAtLogin(_ enable: Bool) {
        if #available(macOS 13.0, *) {
            // Use modern API for macOS 13+
            do {
                if enable {
                    try SMAppService.mainApp.register()
                    AppLogger.L("Launch at login enabled")
                } else {
                    try SMAppService.mainApp.unregister()
                    AppLogger.L("Launch at login disabled")
                }
            } catch {
                AppLogger.L("Failed to configure launch at login: \(error)")
                NSSound.beep()
            }
        } else {
            // For older macOS versions, show message that feature requires macOS 13+
            AppLogger.L("Launch at login requires macOS 13.0 or later")
            if enable {
                // Show alert to user
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Launch at Login"
                    alert.informativeText = "This feature requires macOS 13.0 or later. Please update your system to use this functionality."
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
                // Reset the setting back to false since we can't enable it
                UserDefaults.standard.pingerAutostart = false
                menuBuilder.updateSettingsStates()
            }
        }
    }
}

// MARK: - NSMenuDelegate

extension AppDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        AppLogger.L("Menu opened")
    }
    
    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        AppLogger.L("Menu closed")
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension AppDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        return [.alert, .sound]
    }
}