//
//  CustomControls.swift
//  Pinger
//
//  Created by Dawid Deregowski on 19/09/2025.
//

import Cocoa

// MARK: - Hover Menu Button
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

// MARK: - Menu Checkbox Button
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

// MARK: - Persistent Menu TextField
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
                    textEditor.selectAll(nil)
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