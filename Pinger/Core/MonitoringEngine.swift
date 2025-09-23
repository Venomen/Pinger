//
//  MonitoringEngine.swift
//  Pinger
//
//  Created by Dawid Deregowski on 19/09/2025.
//

import Foundation

// MARK: - Monitoring Engine Delegate
protocol MonitoringEngineDelegate: AnyObject {
    func monitoringEngine(_ engine: MonitoringEngine, didUpdateHost host: String)
    func monitoringEngine(_ engine: MonitoringEngine, didChangeStatusFor host: String, isUp: Bool)
    func monitoringEngine(_ engine: MonitoringEngine, didUpdateOverallStatus text: String)
}

// MARK: - Monitoring Engine
class MonitoringEngine {
    weak var delegate: MonitoringEngineDelegate?
    
    // State management
    private let stateQueue = DispatchQueue(label: "monitoring.state")
    private var timer: DispatchSourceTimer?
    private(set) var isRunning = false
    
    // Data
    private(set) var hostStates: [String: HostState] = [:]
    private(set) var monitoredHosts = Set<String>()
    
    // Monitoring components
    private let icmpMonitor = ICMPMonitor()
    private let httpMonitor = HTTPMonitor()
    
    // MARK: - Public Interface
    
    func startMonitoring() {
        stopMonitoring()
        isRunning = true
        
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 0.1, repeating: Config.intervalSeconds)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
        
        // Initial tick
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.tick() }
    }
    
    func stopMonitoring() {
        timer?.cancel()
        timer = nil
        isRunning = false
        
        // Reset states but preserve monitoring types
        stateQueue.async { [weak self] in
            guard let self = self else { return }
            for key in self.hostStates.keys {
                let currentType = self.hostStates[key]?.monitoringType ?? .icmp
                var newState = HostState()
                newState.monitoringType = currentType
                self.hostStates[key] = newState
            }
        }
        
        delegate?.monitoringEngine(self, didUpdateOverallStatus: "Paused")
    }
    
    func updateHosts(_ hosts: [String]) {
        stateQueue.sync {
            // Add missing hosts
            for host in hosts where self.hostStates[host] == nil {
                self.hostStates[host] = HostState()
            }
            
            // Remove hosts that no longer exist
            let hostsSet = Set(hosts)
            let keysToRemove = self.hostStates.keys.filter { !hostsSet.contains($0) }
            for key in keysToRemove {
                self.hostStates.removeValue(forKey: key)
                self.monitoredHosts.remove(key)
            }
        }
    }
    
    func setMonitoredHosts(_ hosts: Set<String>) {
        stateQueue.sync {
            self.monitoredHosts = hosts
        }
    }
    
    func toggleMonitoring(for host: String) {
        stateQueue.sync {
            if self.monitoredHosts.contains(host) {
                self.monitoredHosts.remove(host)
            } else {
                self.monitoredHosts.insert(host)
                if self.hostStates[host] == nil {
                    self.hostStates[host] = HostState()
                }
            }
        }
    }
    
    func toggleMonitoringType(for host: String) {
        stateQueue.sync {
            guard var hostState = self.hostStates[host] else { return }
            
            // Toggle type
            hostState.monitoringType = (hostState.monitoringType == .icmp) ? .http : .icmp
            
            // Reset state when changing type
            hostState.consecutiveUp = 0
            hostState.consecutiveDown = 0
            hostState.lastStableIsUp = nil
            hostState.lastHttpStatus = nil
            
            self.hostStates[host] = hostState
        }
        
        // Ping immediately if running
        if isRunning {
            pingOne(host: host)
        }
    }
    
    func resetStatesForFlapChange() {
        stateQueue.sync {
            for key in self.hostStates.keys {
                let currentType = self.hostStates[key]?.monitoringType ?? .icmp
                var newState = HostState()
                newState.monitoringType = currentType
                self.hostStates[key] = newState
            }
        }
    }
    
    func setMonitoringType(for host: String, type: MonitoringType) {
        stateQueue.sync {
            if self.hostStates[host] == nil {
                self.hostStates[host] = HostState()
            }
            self.hostStates[host]?.monitoringType = type
        }
    }
    
    func getHostState(for host: String) -> HostState? {
        return stateQueue.sync { self.hostStates[host] }
    }
    
    func getAllHostStates() -> [String: HostState] {
        return stateQueue.sync { self.hostStates }
    }
    
    func getMonitoredHosts() -> Set<String> {
        return stateQueue.sync { self.monitoredHosts }
    }
    
    // MARK: - Private Methods
    
    private func tick() {
        guard isRunning else { return }
        
        let targets: [String] = stateQueue.sync { Array(self.monitoredHosts) }
        guard !targets.isEmpty else {
            delegate?.monitoringEngine(self, didUpdateOverallStatus: "No targets selected")
            return
        }
        
        delegate?.monitoringEngine(self, didUpdateOverallStatus: "Checking… (\(targets.count) host\(targets.count > 1 ? "s" : ""))")
        
        for host in targets {
            pingOne(host: host)
        }
    }
    
    private func pingOne(host: String) {
        // Check if already in flight
        let shouldStart: Bool = stateQueue.sync {
            var state = self.hostStates[host] ?? HostState()
            if state.inFlight { return false }
            state.inFlight = true
            self.hostStates[host] = state
            return true
        }
        
        guard shouldStart else { return }
        
        let monitoringType = stateQueue.sync {
            self.hostStates[host]?.monitoringType ?? .icmp
        }
        
        switch monitoringType {
        case .icmp:
            icmpMonitor.ping(host: host) { [weak self] isUp in
                self?.handlePingResult(host: host, isUp: isUp, httpStatus: nil)
            }
        case .http:
            httpMonitor.checkHTTP(host: host) { [weak self] isUp, httpStatus in
                self?.handlePingResult(host: host, isUp: isUp, httpStatus: httpStatus)
            }
        }
    }
    
    private func handlePingResult(host: String, isUp: Bool, httpStatus: Int?) {
        var changedTo: Bool? = nil
        
        stateQueue.sync {
            guard var state = self.hostStates[host] else { return }
            
            state.inFlight = false
            state.lastHttpStatus = httpStatus
            
            if isUp {
                state.consecutiveUp += 1
                state.consecutiveDown = 0
                if state.consecutiveUp >= Config.upThreshold && state.lastStableIsUp != true {
                    state.lastStableIsUp = true
                    changedTo = true
                }
            } else {
                state.consecutiveDown += 1
                state.consecutiveUp = 0
                if state.consecutiveDown >= Config.downThreshold && state.lastStableIsUp != false {
                    state.lastStableIsUp = false
                    changedTo = false
                }
            }
            
            self.hostStates[host] = state
        }
        
        // Notify delegate
        DispatchQueue.main.async {
            self.delegate?.monitoringEngine(self, didUpdateHost: host)
            
            if let newStatus = changedTo {
                self.delegate?.monitoringEngine(self, didChangeStatusFor: host, isUp: newStatus)
            }
        }
    }
}