import ExactMac
import ExactMacServer
import Foundation
import OSLog

private let logger = ExactMac.sdkLogger(category: "Main")

// A STARTUP FAILURE IS A CLEAN ERROR, NOT A TRAP. `try await main()` at top level turns any
// throw into a Swift runtime error, which prints a stack-ish "Fatal error: Error raised at
// top level" to stderr and aborts. The most likely startup failure in this system is a
// pathname another server already holds, and an operator who hits it deserves the sentence
// the server actually has — "is claimed by a running server; refusing to take the pathname
// over" — rather than a trap that hides it behind a transport error.
//
// THIS IS THE WHOLE EXECUTABLE. Every declaration the server needs lives in the
// `ExactMacServer` library, which the GUI app in `Console/` links instead. Both hosts enter
// the same `main()`, so there is one server lifecycle and not two that can drift.
do {
    try await ExactMacServer.main()
} catch {
    logger.error("ExactMacServer failed to start: \(String(describing: error), privacy: .public)")
    Foundation.exit(1)
}
