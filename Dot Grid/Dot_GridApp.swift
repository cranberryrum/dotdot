//
//  Dot_GridApp.swift
//  Dot Grid
//
//  Created by Aditya on 11/06/26.
//

import SwiftUI

@main
struct Dot_GridApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
#if DEBUG
        AppStoreCapture.prepareIfNeeded()
#endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
