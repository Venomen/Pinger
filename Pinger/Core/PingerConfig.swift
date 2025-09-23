//
//  PingerConfig.swift
//  Pinger
//
//  Created by Dawid Deregowski on 19/09/2025.
//

import Foundation

// MARK: - Configuration
enum Config {
    static var intervalSeconds: TimeInterval = 1.0
    static var upThreshold = 2
    static var downThreshold = 2
    static let pingPath = "/sbin/ping"                   // App Sandbox OFF required
    static let defaultHosts = ["1.1.1.1", "8.8.8.8", "9.9.9.9"]
    static let appAuthor = "deregowski.net © 2025"
    static let httpTimeout: TimeInterval = 5.0
    static let maxRedirects = 3
}

// MARK: - Preference Keys
enum PrefKey {
    static let hosts = "hosts"
    static let activeHost = "activeHost"     // legacy (for migration)
    static let monitored = "monitoredHosts"  // multi-select
    static let notify = "notify"
    static let interval = "interval"
    static let flap = "flap"
    static let logsEnabled = "logsEnabled"
    static let showDockIcon = "showDockIcon"
    static let hostMonitoringTypes = "hostMonitoringTypes"
    static let autostart = "autostart"
}

// MARK: - Monitoring Type
enum MonitoringType: String, Codable, CaseIterable {
    case icmp = "icmp"
    case http = "http"
    
    var displayName: String {
        switch self {
        case .icmp: return "ICMP"
        case .http: return "HTTP"
        }
    }
    
    var icon: String {
        switch self {
        case .icmp: return "waveform.path.ecg"
        case .http: return "globe"
        }
    }
}

// MARK: - Data Models
struct PingerConfig: Codable {
    var hosts: [String]
    var monitored: [String]?
    var activeHost: String?
    var interval: Double
    var flap: Int
    var notify: Bool
    var logs: Bool
    var showDock: Bool
    var hostTypes: [String: String]?  // host -> "icmp"/"http"
}

struct HostState {
    var consecutiveUp = 0
    var consecutiveDown = 0
    var lastStableIsUp: Bool? = nil
    var inFlight = false
    var monitoringType: MonitoringType = .icmp
    var lastHttpStatus: Int? = nil
}