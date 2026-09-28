import ExactMacServer
import Foundation

/// The operator-facing sentence for a scope, composed here rather than received.
///
/// ## Why the app composes it
///
/// The server exposes `AuthorizationScope` as STRUCTURE — an application target, a window
/// target, an operation count — and deliberately does not expose a display string for it.
/// That is the right call on the server's side and it is stated in the type: the scope is
/// "derived from the request bytes rather than accepted from anything that displays it". A
/// server that shipped ready-made prose would have two places that decide what a grant
/// means, and they would eventually disagree.
///
/// So the sentence is composed HERE, from the parts the engine produced. Composing is not
/// re-deriving: which application and which window a request touches was decided by the
/// engine from the request bytes, and this function only puts words on that decision. It
/// never widens or narrows it, and it cannot be a second source of authority because it has
/// no inputs other than the authority's own output.
///
/// ## Why it is a pure function
///
/// It is the prompt's scope line, and it is asserted directly rather than through a render.
/// The parts are exhaustive enums with no default case in this switch, so a scope the server
/// can express and this cannot describe is a COMPILE ERROR rather than a prompt that quietly
/// understates what was granted — which is the failure direction that matters: an operator
/// who is shown less than they agreed to has agreed to something they did not read.
enum ScopeDescription {
    /// The whole scope, in the words the design puts on the scope line.
    static func describe(_ scope: AuthorizationScope) -> String {
        let parts = [application(scope.application), window(scope.window)]
            .compactMap(\.self)
        var sentence = parts.isEmpty ? "any application" : parts.joined(separator: ", ")
        if let limit = scope.operationLimit {
            // THE COUNT IS NAMED, because a transaction that exceeds its declared count is
            // denied rather than extended, and an operator who is approving "up to 8 hours"
            // has not been told how many operations that permits.
            sentence += " for up to \(limit) operation\(limit == 1 ? "" : "s")"
        }
        return sentence
    }

    /// The application half, or nil when the scope is not narrowed to one.
    private static func application(_ target: TargetApplication) -> String? {
        switch target {
        case .any:
            nil
        case let .bundleIdentifier(identifier):
            "in \(identifier)"
        case let .processIdentifier(pid):
            "in process \(pid)"
        case let .opaqueApplication(resourceName, resolvedBundleIdentifier):
            // THE RESOLVED NAME IS PREFERRED AND THE OPAQUE ONE IS THE FALLBACK, because a
            // resource name is a 64-character digest and an operator cannot picture it. The
            // engine carries the resolved identifier for exactly this.
            "in \(resolvedBundleIdentifier ?? resourceName)"
        }
    }

    /// The window half, or nil when the scope is not narrowed to one.
    private static func window(_ target: TargetWindow) -> String? {
        switch target {
        case .any:
            nil
        case let .identifier(identifier):
            "in window \(identifier)"
        }
    }
}
