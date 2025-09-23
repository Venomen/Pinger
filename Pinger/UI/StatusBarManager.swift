//
//  StatusBarManager.swift
//  Pinger
//
//  Created by Dawid Deregowski on 19/09/2025.
//

import Cocoa

// MARK: - Status Bar Manager
class StatusBarManager {
    private var statusItem: NSStatusItem!
    private var lastStatusText = ""
    
    init() {
        setupStatusItem()
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setTrayIcon(color: .systemGray, tooltip: "Paused")
    }
    
    func setMenu(_ menu: NSMenu) {
        statusItem.menu = menu
    }
    
    func updateStatusText(_ text: String) {
        guard text != lastStatusText else { return }
        lastStatusText = text
        // This will be handled by menu updates
    }
    
    func setTrayIcon(color: NSColor, tooltip: String) {
        DispatchQueue.main.async {
            let base = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
            self.statusItem.button?.image = base?.withSymbolConfiguration(.init(paletteColors: [color]))
            self.statusItem.button?.image?.isTemplate = false
            self.statusItem.button?.toolTip = tooltip
        }
    }
    
    func updateAggregateTrayIcon(anyDown: Bool, anyUnknown: Bool, isRunning: Bool, isEmpty: Bool) {
        DispatchQueue.main.async {
            if !isRunning {
                self.setTrayIcon(color: .systemGray, tooltip: "Paused")
                return
            }
            
            if isEmpty {
                self.setTrayIcon(color: .systemGray, tooltip: "No targets")
                return
            }
            
            if anyDown {
                self.setTrayIcon(color: .systemRed, tooltip: "Some hosts down")
            } else if !anyUnknown {
                self.setTrayIcon(color: .systemGreen, tooltip: "All hosts up")
            }
            // During stabilization we keep the previous color
            
            // Debug logging
            AppLogger.L("StatusBar: running=\(isRunning), isEmpty=\(isEmpty), anyDown=\(anyDown), anyUnknown=\(anyUnknown)")
        }
    }
}