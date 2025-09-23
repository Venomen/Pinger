//
//  AppLogger.swift
//  Pinger
//
//  Created by Dawid Deregowski on 19/09/2025.
//

import Foundation

// MARK: - Simple Logger
struct AppLogger {
    static func L(_ msg: @autoclosure () -> String) {
        if UserDefaults.standard.pingerLogsEnabled {
            print(msg())
        }
    }
}