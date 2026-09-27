import SwiftUI

// The entry point.
//
// TOP-LEVEL CODE RATHER THAN `@main`, and that is B2's first finding applied: a file named
// `main.swift` IS the top-level entry file, so `@main` cannot be used in a module that
// contains it. The SwiftUI `App` struct is therefore launched EXPLICITLY from here, which is
// the other half of the same finding — and without that call the app runs, holds its event
// loop, and shows no menu bar item at all, which is the second trap this file exists to
// avoid.
//
// `NSApp` does not exist in top-level code, so anything AppKit needs happens in
// `ConsoleAppDelegate.applicationDidFinishLaunching` where it does.
let consoleApplication = NSApplication.shared
let consoleDelegate = ConsoleAppDelegate()
consoleApplication.delegate = consoleDelegate
// No Dock icon, ever: the operator's way in is the menu bar and always has been.
consoleApplication.setActivationPolicy(.accessory)
ExactMacConsoleApp.main()

final class ConsoleAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
