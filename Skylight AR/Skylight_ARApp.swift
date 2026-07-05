//
//  Skylight_ARApp.swift
//  Skylight AR
//
//  Created by Hemal on 04/06/2026.
//

import SwiftUI

@main
struct Skylight_ARApp: App {
    init() { Analytics.start() }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
