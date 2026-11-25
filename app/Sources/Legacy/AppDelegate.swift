// SPDX-License-Identifier: MIT
// Copyright (c) 2026 José González Divassón
//
// AppDelegate.swift - the iOS 12 application. iOS 12 has no scene lifecycle, so the window is made
// here (the SwiftUI app uses @main and the scene phase instead). The calculator turns off and keeps
// its memory when the app goes to the background, and wakes up when it comes back, as on the Mac.

import UIKit

@UIApplicationMain
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.rootViewController = CalculatorViewController()
        w.backgroundColor = UIColor(rgb: 0x241E1A)
        w.makeKeyAndVisible()
        window = w
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        LegacyCalculator.shared.saveState()
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        LegacyCalculator.shared.resumeAfterBackground()
    }

    func applicationWillTerminate(_ application: UIApplication) {
        LegacyCalculator.shared.saveState()
    }
}
