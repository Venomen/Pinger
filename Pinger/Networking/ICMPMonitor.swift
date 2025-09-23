//
//  ICMPMonitor.swift
//  Pinger
//
//  Created by Dawid Deregowski on 19/09/2025.
//

import Foundation

// MARK: - ICMP Monitor
class ICMPMonitor {
    
    func ping(host: String, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let result = self.runPingOnceICMP(host: host)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }
    
    private func runPingOnceICMP(host: String) -> Bool {
        let task = Process()
        task.launchPath = Config.pingPath
        task.arguments = ["-n", "-c", "1", "-W", "1000", "-q", host]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

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
}