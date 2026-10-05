import Darwin
import Foundation

/// THE CONSOLE'S OWN IDENTITY, RESOLVED THE SAME WAY A CALLER'S IS.
///
/// The console records its local operator actions — the biometric-gate toggle — into the
/// decision log, and the entry needs a caller identity like any other. Building one by
/// hand would put an unverified "ExactMacConsole" on the record, which is exactly the
/// self-attestation the identity machinery exists to prevent, so the resolution goes
/// through the same `SystemProcessInspector` a socket peer's does: `proc_pidpath` for the
/// executable, the bundle's own Info.plist for the identifier, and the code signature for
/// the signing facts. The row in the log is evidence, not a label.
///
/// THERE IS NO ANCESTRY HERE, and that is a fact rather than an omission: the entry's
/// caller IS this process, so the tree would start and end at itself. `parentProcessIdentifier`
/// is recorded — launchd or the shell that started the app — but the walk is not performed,
/// because `ancestry(from:startingAfter:)` is private to the resolver that guards its own
/// cycle and depth handling, and duplicating it here would be a second place for that
/// discipline to rot.
enum SelfIdentityResolver {
    /// Resolves the calling process itself. A process whose own path cannot be read still
    /// yields an identity — unresolved, escalated, never omitted — which is the same rule
    /// `CallerIdentityResolver.resolve` applies to a socket peer.
    static func resolve(
        processIdentifier: Int32 = getpid(),
        effectiveUserIdentifier: uid_t = getuid(),
    ) -> CallerIdentity {
        let inspector = SystemProcessInspector()
        let code = inspector.codeIdentity(processIdentifier: processIdentifier)
        let parent = inspector.parentProcessIdentifier(of: processIdentifier)
        return CallerIdentity(
            processIdentifier: processIdentifier,
            effectiveUserIdentifier: effectiveUserIdentifier,
            parentProcessIdentifier: parent,
            code: code ?? CodeIdentity(
                executablePath: "<unresolved pid \(processIdentifier)>",
                bundleIdentifier: nil,
                designatedRequirement: nil,
                signature: .unresolved,
            ),
            isFullyResolved: code != nil,
            ancestors: [],
            isAncestryTruncated: false,
        )
    }
}
