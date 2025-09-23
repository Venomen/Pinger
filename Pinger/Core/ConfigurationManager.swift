//
//  ConfigurationManager.swift
//  Pinger
//
//  Created by Dawid Deregowski on 19/09/2025.
//

import Foundation

// MARK: - Configuration Manager
class ConfigurationManager {
    private(set) var hosts: [String] = []
    private(set) var activeHost: String?
    
    // MARK: - Initialization
    init() {
        loadPreferences()
    }
    
    // MARK: - Host Management
    func addHost(_ host: String) -> Bool {
        guard !hosts.contains(host) else { return false }
        hosts.insert(host, at: 0) // Add to beginning
        savePreferences()
        return true
    }
    
    func removeHosts(_ hostsToRemove: [String]) {
        hosts = hosts.filter { !hostsToRemove.contains($0) }
        savePreferences()
    }
    
    func updateHosts(_ newHosts: [String]) {
        hosts = newHosts
        savePreferences()
    }
    
    // MARK: - Preferences Management
    private func loadPreferences() {
        let ud = UserDefaults.standard
        
        // Load hosts
        if ud.object(forKey: PrefKey.hosts) != nil {
            hosts = ud.pingerHosts
        } else {
            hosts = Config.defaultHosts
            ud.pingerHosts = hosts
        }
        
        // Load legacy active host (for migration)
        if let act = ud.string(forKey: PrefKey.activeHost), hosts.contains(act) {
            activeHost = act
        } else {
            activeHost = hosts.first
            if let active = activeHost {
                ud.set(active, forKey: PrefKey.activeHost)
            }
        }
        
        // Load other preferences
        if ud.object(forKey: PrefKey.notify) == nil {
            ud.pingerNotificationsEnabled = true
        }
        
        if let interval = ud.object(forKey: PrefKey.interval) as? Double {
            Config.intervalSeconds = interval
        }
        
        if let flap = ud.object(forKey: PrefKey.flap) as? Int {
            Config.upThreshold = flap
            Config.downThreshold = flap
        }
        
        if ud.object(forKey: PrefKey.logsEnabled) == nil {
            ud.pingerLogsEnabled = true
        }
        
        if ud.object(forKey: PrefKey.showDockIcon) == nil {
            ud.pingerShowDockIcon = true
        }
        
        if ud.object(forKey: PrefKey.autostart) == nil {
            ud.pingerAutostart = false
        }
    }
    
    func savePreferences() {
        let ud = UserDefaults.standard
        ud.pingerHosts = hosts
        if let active = activeHost {
            ud.set(active, forKey: PrefKey.activeHost)
        }
    }
    
    // MARK: - Configuration File Management
    private func configFileURL() throws -> URL {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory,
                                              in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Pinger", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }
    
    func saveConfigToDisk(monitoredHosts: Set<String>, hostStates: [String: HostState]) {
        do {
            let ud = UserDefaults.standard
            let hostTypes = hostStates.compactMapValues { $0.monitoringType.rawValue }
            
            let config = PingerConfig(
                hosts: hosts,
                monitored: Array(monitoredHosts),
                activeHost: activeHost,
                interval: Config.intervalSeconds,
                flap: Config.upThreshold,
                notify: ud.pingerNotificationsEnabled,
                logs: ud.pingerLogsEnabled,
                showDock: ud.pingerShowDockIcon,
                hostTypes: hostTypes
            )
            
            let data = try JSONEncoder().encode(config)
            let url = try configFileURL()
            try data.write(to: url, options: .atomic)
            AppLogger.L("config auto-saved to \(url.path)")
        } catch {
            AppLogger.L("config auto-save failed: \(error)")
        }
    }
    
    @discardableResult
    func loadConfigFromDisk() -> (monitoredHosts: Set<String>, hostTypes: [String: MonitoringType])? {
        do {
            let url = try configFileURL()
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            
            let data = try Data(contentsOf: url)
            let config = try JSONDecoder().decode(PingerConfig.self, from: data)
            
            // Update configuration
            hosts = config.hosts
            activeHost = config.activeHost
            Config.intervalSeconds = config.interval
            Config.upThreshold = config.flap
            Config.downThreshold = config.flap
            
            let ud = UserDefaults.standard
            ud.pingerNotificationsEnabled = config.notify
            ud.pingerLogsEnabled = config.logs
            ud.pingerShowDockIcon = config.showDock
            
            // Extract monitoring types
            var hostTypes: [String: MonitoringType] = [:]
            if let configTypes = config.hostTypes {
                for (host, typeString) in configTypes {
                    if let type = MonitoringType(rawValue: typeString) {
                        hostTypes[host] = type
                    }
                }
            }
            
            let monitoredHosts = Set(config.monitored?.filter { hosts.contains($0) } ?? [])
            
            savePreferences()
            AppLogger.L("config loaded from \(url.path)")
            
            return (monitoredHosts: monitoredHosts, hostTypes: hostTypes)
        } catch {
            AppLogger.L("config load failed: \(error)")
            return nil
        }
    }
    
    func getConfigFilePath() -> String {
        return (try? configFileURL().path) ?? "(unavailable)"
    }
}