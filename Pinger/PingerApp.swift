//
//  PingerApp.swift
//  Pinger
//
//  Created by Dawid Deregowski on 19/09/2025.
//

import SwiftUI

@main
struct PingerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() } // no windows, just menubar
    }
}
