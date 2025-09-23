//
//  Extensions.swift
//  Pinger
//
//  Created by Dawid Deregowski on 19/09/2025.
//

import Cocoa

// MARK: - CALayer Animation Extension
extension CALayer {
    func animate(keyPath: String, from: Any?, to: Any?, duration: TimeInterval) {
        let anim = CABasicAnimation(keyPath: keyPath)
        anim.fromValue = from
        anim.toValue = to
        anim.duration = duration
        add(anim, forKey: keyPath)
    }
}

// MARK: - NSView Helper Extension
extension NSView {
    func findSubview(with id: NSUserInterfaceItemIdentifier) -> NSView? {
        if self.identifier == id { return self }
        for v in subviews {
            if let f = v.findSubview(with: id) { return f }
        }
        return nil
    }
}

// MARK: - UserDefaults Pinger Extensions
extension UserDefaults {
    var pingerHosts: [String] {
        get { array(forKey: PrefKey.hosts) as? [String] ?? [] }
        set { set(newValue, forKey: PrefKey.hosts) }
    }
    
    var pingerMonitoredHosts: [String] {
        get { array(forKey: PrefKey.monitored) as? [String] ?? [] }
        set { set(newValue, forKey: PrefKey.monitored) }
    }
    
    var pingerNotificationsEnabled: Bool {
        get { object(forKey: PrefKey.notify) as? Bool ?? true }
        set { set(newValue, forKey: PrefKey.notify) }
    }
    
    var pingerShowDockIcon: Bool {
        get { object(forKey: PrefKey.showDockIcon) as? Bool ?? true }
        set { set(newValue, forKey: PrefKey.showDockIcon) }
    }
    
    var pingerLogsEnabled: Bool {
        get { object(forKey: PrefKey.logsEnabled) as? Bool ?? true }
        set { set(newValue, forKey: PrefKey.logsEnabled) }
    }
    
    var pingerAutostart: Bool {
        get { object(forKey: PrefKey.autostart) as? Bool ?? false }
        set { set(newValue, forKey: PrefKey.autostart) }
    }
    
    var pingerInterval: TimeInterval {
        get { object(forKey: PrefKey.interval) as? TimeInterval ?? 1.0 }
        set { set(newValue, forKey: PrefKey.interval) }
    }
    
    var pingerFlap: Int {
        get { object(forKey: PrefKey.flap) as? Int ?? 2 }
        set { set(newValue, forKey: PrefKey.flap) }
    }
    
    var pingerHostMonitoringTypes: [String: String] {
        get { object(forKey: PrefKey.hostMonitoringTypes) as? [String: String] ?? [:] }
        set { set(newValue, forKey: PrefKey.hostMonitoringTypes) }
    }
}