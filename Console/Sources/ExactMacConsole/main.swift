import OSLog
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
// A THIRD TRAP, and it is the one that is easy to reintroduce: `NSApplication.shared` DOES
// NOT EXIST IN TOP-LEVEL CODE. Touching AppKit here — including to ask whether a window
// server session is available — is a crash before `main()` has ever been entered, so
// everything AppKit needs happens in `ConsoleAppDelegate.applicationDidFinishLaunching`
// where the run loop is up. `ServerHosting` reads the window server session through
// CoreGraphics, which has no such restriction, precisely so the operating mode can be
// classified from top-level code.
//
// This binary is the WHOLE PRODUCT: it hosts the ExactMac gRPC server in this process and
// presents the operator's consent prompt itself, with no second process and no console
// socket. The server half of that is NOT WIRED HERE YET — see the report on
// `ServerHosting`'s caller. What is established here is the order the server has to
// respect when it arrives: AppKit up, mode classified, then the server.
let consoleApplication = NSApplication.shared
let consoleDelegate = ConsoleAppDelegate()
consoleApplication.delegate = consoleDelegate
// No Dock icon, ever: the operator's way in is the menu bar and always has been.
consoleApplication.setActivationPolicy(.accessory)

// THE MODE IS CLASSIFIED ONCE, HERE, AND BEFORE ANYTHING ASKS THE OPERATOR. It is the fact
// every other decision depends on — a process that cannot present a prompt must deny
// consent-requiring requests rather than queue them for an operator who is not there — and
// a property of the process rather than of a request, so it is settled at launch.
let operatorInterface = ServerHosting.current()
let launchLogger = Logger(
    subsystem: "io.github.joeycumines.exactmac.console",
    category: "launch",
)
launchLogger.notice("ExactMac operating mode: \(operatorInterface.summary, privacy: .public)")

ExactMacConsoleApp.main()

final class ConsoleAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
