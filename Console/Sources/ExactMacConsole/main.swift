import ExactMacServer
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
// THIS BINARY IS THE WHOLE PRODUCT. It hosts the ExactMac gRPC server in this process and
// presents the operator's consent prompt itself: one process, one run loop, a direct call
// between the two halves, and no console socket.
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

/// ONE MODEL, BUILT HERE AND SHARED. The SwiftUI scene and the server's consent closure must
/// be looking at the same state: the closure reaches the model whose window shows the prompt,
/// and a second model would render a request into a state nobody reads.
let consoleModel = ConsoleRuntime.model

// THE CONSENT HANDLER THE SERVER CALLS, OR NIL — AND NIL IS THE DENIAL.
//
// IT IS NIL RATHER THAN A CLOSURE THAT ALWAYS DENIES when this process cannot present a
// window, so the server's own posture accounting agrees with this one instead of the two
// disagreeing: a handler that is installed but cannot answer looks, from the server's side,
// like an operator who never replies.
/// THE CONSENT HANDLER THE SERVER CALLS.
///
/// A NAMED FUNCTION RATHER THAN AN INLINE CLOSURE because it is the seam the whole product
/// turns on, and a seam worth reading should not be an expression buried in a ternary at
/// top level. It takes the server's own types and returns the server's own type: nothing in
/// between is translated, so nothing in between can be wrong in a way the server would
/// accept.
///
/// NIL IS PROPAGATED AS NIL. A request that was cancelled, superseded, or never put to the
/// operator is not an answer, and the interceptor is the thing that turns "nobody answered"
/// into a denial. This must not invent an approval to fill the shape.
@MainActor
func obtainConsent(
    request: AuthorizationRequest,
    identity: CallerIdentity,
    decision: AuthorizationDecision,
) async -> ConsentAnswer? {
    guard let answer = await consoleModel.answer(
        request: request,
        identity: identity,
        decision: decision,
    ) else {
        return nil
    }
    return ConsentAnswer(
        // THE REQUEST'S OWN ID, not a synthesised one. It is what the answer is bound to,
        // and the server re-checks it against the request it asked about.
        requestID: request.id,
        isApproved: answer.isApproved,
        // MAPPED THROUGH THE SERVER'S OWN NAME, never this module's `rawValue`. Returning the
        // console's spelling is what once made every single approval enforce as a denial,
        // because the server parses `allowOnce` and not `once`.
        selected: answer.isApproved ? OfferedDecision.Kind(rawValue: answer.kind.serverValue) : nil,
        note: answer.note,
        biometricObtained: answer.biometricObtained,
    )
}

/// The handler, or nil when this process has nowhere to put a prompt.
///
/// IT IS NIL RATHER THAN A CLOSURE THAT ALWAYS DENIES, so the server's own posture
/// accounting agrees with this one instead of the two disagreeing: a handler that is
/// installed but cannot answer looks, from the server's side, like an operator who never
/// replies.
/// AN IF RATHER THAN A TERNARY, which is both clearer here and the only form the type
/// checker accepts for a `@MainActor` global referenced in an expression at top level.
let consentHandler: ConsentAnswering? = if operatorInterface.canObtainConsent {
    obtainConsent
} else {
    nil
}

/// THE SOCKET PATH IS SET HERE BECAUSE NOTHING ELSE SETS IT ANY MORE.
///
/// The LaunchAgent plist used to carry `GRPC_UNIX_SOCKET` in its `EnvironmentVariables`
/// block, and `ServerConfig` deliberately has no default for it: an unset socket path means
/// the server takes the TCP branch, where there is no owning user to authenticate, so every
/// consent-requiring capability denies. That is the right default for a server someone
/// started by hand, and it is the WRONG default for the app, which is the product and would
/// come up denying everything with no way to say why. An environment variable already set is
/// left alone, so a diagnostic run can still point the app somewhere else.
let defaultSocketPath = NSHomeDirectory() + "/Library/Caches/exactmac.sock"
if ProcessInfo.processInfo.environment["GRPC_UNIX_SOCKET"]?.isEmpty != false {
    setenv("GRPC_UNIX_SOCKET", defaultSocketPath, 1)
}

if consentHandler == nil {
    launchLogger.warning(
        "Starting without an operator interface, so every consent-requiring capability is denied. This is the safe direction.",
    )
}

// THE SERVER STARTS IN A TASK AND ITS FAILURE IS A CLEAN ERROR.
//
// NOT AT TOP LEVEL: `serveHosted` runs until the server stops, and a blocking call here
// would never reach `ExactMacConsoleApp.main()` — the app would host a server with no menu
// bar, no windows, and no way to ask anybody anything.
//
// NOT A TRAP EITHER: a `try` at the top level of `main.swift` turns a thrown error into a
// runtime trap that prints a stack-shaped message and aborts. The likeliest startup failure
// is a socket pathname another server still holds, and an operator who hits it deserves the
// sentence the server actually has rather than a trap that hides it behind a transport error.
Task { @MainActor in
    do {
        // REPORTED BEFORE AWAITING, because `serveHosted` does not return until the server
        // stops. Waiting for it to tell us it started would mean the app sat in its
        // initialiser state for the whole life of the server.
        consoleModel.reportServerStarted()
        try await ExactMacServer.serveHosted(consent: consentHandler)
    } catch {
        let reason = String(describing: error)
        launchLogger.error(
            "The ExactMac server did not start: \(reason, privacy: .public)",
        )
        consoleModel.reportServerStartFailure(reason: reason)
        // REPORTED AND LEFT, rather than retried in a loop: a pathname held by a live server
        // does not become free by asking again, and a tight retry would bury the one line
        // that says why in a stream of identical ones.
    }
}

ExactMacConsoleApp.main()

final class ConsoleAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
