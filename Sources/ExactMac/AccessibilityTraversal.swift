// The Swift Programming Language
// https://docs.swift.org/swift-book

@preconcurrency import ApplicationServices // For Accessibility API (AXUIElement, etc.)
import Foundation // For basic types, JSONEncoder, Date
import OSLog

private let logger = sdkLogger(category: "AccessibilityTraversal")
let accessibilityTrustCheckShouldPrompt = false

/// Mark AXUIElement as Sendable - it's safe because it's an opaque CFTypeRef
/// managed by the Accessibility framework. We only store/pass references.
extension AXUIElement: @retroactive @unchecked Sendable {}

/// A Sendable and Hashable wrapper around `AXUIElement`.
///
/// `AXUIElement` is a Core Foundation type that does not natively conform to
/// Swift's `Sendable` or `Hashable` protocols. This wrapper provides both,
/// enabling safe use across concurrency domains and in collections like `Set`.
///
/// The underlying `AXUIElement` is thread-safe by nature (CFTypeRef), so
/// the `@unchecked Sendable` conformance is safe.
public struct SendableAXUIElement: @unchecked Sendable, Hashable {
    /// The wrapped accessibility element reference.
    public let element: AXUIElement

    /// Creates a new wrapper around an `AXUIElement`.
    /// - Parameter element: The accessibility element to wrap.
    public init(_ element: AXUIElement) {
        self.element = element
    }

    /// Implement Hashable using CFHash for CFTypeRef
    public func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }

    public static func == (lhs: SendableAXUIElement, rhs: SendableAXUIElement) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }
}

// --- Error Enum ---

/// Errors that can occur during accessibility traversal operations.
public enum ExactMacError: Error, LocalizedError {
    /// Accessibility access is denied. The user must grant permissions in System Settings.
    case accessibilityDenied
    /// No running application was found with the specified PID.
    case appNotFound(pid: Int32)
    /// JSON encoding of the response failed.
    case jsonEncodingFailed(Error)
    /// An unexpected internal error occurred.
    case internalError(String)

    public var errorDescription: String? {
        switch self {
        case .accessibilityDenied:
            "Accessibility access is denied. Please grant permissions in System Settings > Privacy & Security > Accessibility."
        case let .appNotFound(pid):
            "No running application found with PID \(pid)."
        case let .jsonEncodingFailed(underlyingError):
            "Failed to encode response to JSON: \(underlyingError.localizedDescription)"
        case let .internalError(message):
            "Internal SDK error: \(message)"
        }
    }
}

// --- Public Data Structures for API Response ---

/// Represents a single UI element discovered during accessibility traversal.
///
/// Each `ElementData` contains the element's role, text content, position, size,
/// and other accessibility attributes. Elements are uniquely identified within
/// a traversal by their hierarchical `path`.
public struct ElementData: Codable, Hashable, Sendable {
    /// The accessibility role of the element (e.g., "AXButton", "AXTextField").
    public var role: String
    /// The text content of the element, if available.
    public var text: String?
    /// The x-coordinate of the element's top-left corner in Quartz screen coordinates
    /// (origin at top-left of primary display, X increases rightward).
    public var x: Double?
    /// The y-coordinate of the element's top-left corner in Quartz screen coordinates
    /// (origin at top-left of primary display, Y increases downward).
    public var y: Double?
    /// The width of the element in points.
    public var width: Double?
    /// The height of the element in points.
    public var height: Double?
    /// The underlying AXUIElement reference for performing accessibility actions.
    /// Excluded from Codable encoding.
    public var axElement: SendableAXUIElement?
    /// Whether the element is enabled for interaction.
    public var enabled: Bool?
    /// Whether the element currently has keyboard focus.
    public var focused: Bool?
    /// Additional accessibility attributes as key-value pairs.
    public var attributes: [String: String]
    /// Hierarchical path from application root to this element.
    /// - Positive indices (0, 1, 2, ...): child index via AXChildren
    /// - Negative indices (-1, -2, ...): window index via AXWindows (encoded as -(windowIndex + 1))
    /// - Special value -10000: main window via AXMainWindow
    public var path: [Int32]

    /// Implement Hashable for use in Set.
    /// NOTE: `path` is deliberately EXCLUDED from equality and hashing.
    /// Path encodes HOW an element was discovered (e.g., via AXWindows vs AXChildren),
    /// not WHAT it is. Two traversals of the same UI can discover the same element
    /// via different paths, and they should be treated as equal for diff purposes.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(role)
        hasher.combine(text)
        hasher.combine(x)
        hasher.combine(y)
        hasher.combine(width)
        hasher.combine(height)
    }

    public static func == (lhs: ElementData, rhs: ElementData) -> Bool {
        lhs.role == rhs.role && lhs.text == rhs.text && lhs.x == rhs.x && lhs.y == rhs.y
            && lhs.width == rhs.width && lhs.height == rhs.height
    }

    /// Add this enum to exclude axElement from Codable
    enum CodingKeys: String, CodingKey {
        case role, text, x, y, width, height, enabled, focused, attributes, path
        // axElement is deliberately excluded - it cannot be encoded/decoded
    }
}

public enum AccessibilityTraversalLimitError: Error, Equatable, LocalizedError {
    case depthExceeded
    case nodeLimitExceeded
    case deadlineExceeded

    public var errorDescription: String? {
        switch self {
        case .depthExceeded:
            "Accessibility traversal exceeded its maximum depth"
        case .nodeLimitExceeded:
            "Accessibility traversal exceeded its maximum node count"
        case .deadlineExceeded:
            "Accessibility traversal exceeded its deadline"
        }
    }
}

final class AccessibilityTraversalBudget {
    private let maxDepth: Int
    private let maxNodes: Int
    private let deadlineExceeded: () -> Bool
    private var visitedNodeCount = 0

    init(
        maxDepth: Int,
        maxNodes: Int,
        deadlineExceeded: @escaping () -> Bool,
    ) {
        precondition(maxDepth >= 0)
        precondition(maxNodes > 0)
        self.maxDepth = maxDepth
        self.maxNodes = maxNodes
        self.deadlineExceeded = deadlineExceeded
    }

    func beginElement(depth: Int) throws {
        try checkAXStep()
        guard depth <= maxDepth else {
            throw AccessibilityTraversalLimitError.depthExceeded
        }
        guard visitedNodeCount < maxNodes else {
            throw AccessibilityTraversalLimitError.nodeLimitExceeded
        }
        visitedNodeCount += 1
    }

    func checkAXStep() throws {
        try Task.checkCancellation()
        guard !deadlineExceeded() else {
            throw AccessibilityTraversalLimitError.deadlineExceeded
        }
    }
}

func isUnavailableOptionalTraversalMetadataError(_ error: AXError) -> Bool {
    switch error {
    case .failure, .cannotComplete, .attributeUnsupported, .noValue:
        true
    default:
        false
    }
}

func stableTraversalElements(_ elements: [ElementData]) -> [ElementData] {
    elements.sorted {
        let lhsY = $0.y ?? Double.greatestFiniteMagnitude
        let rhsY = $1.y ?? Double.greatestFiniteMagnitude
        if lhsY != rhsY {
            return lhsY < rhsY
        }
        let lhsX = $0.x ?? Double.greatestFiniteMagnitude
        let rhsX = $1.x ?? Double.greatestFiniteMagnitude
        if lhsX != rhsX {
            return lhsX < rhsX
        }
        return $0.path.lexicographicallyPrecedes($1.path)
    }
}

/// Statistics about the accessibility traversal operation.
///
/// Provides counts of collected elements, excluded elements, and breakdowns
/// by element type and reason for exclusion.
public struct Statistics: Codable, Sendable {
    /// Total number of elements collected.
    public var count: Int = 0
    /// Number of elements excluded during traversal.
    public var excluded_count: Int = 0
    /// Number of elements excluded because they have non-interactable roles.
    public var excluded_non_interactable: Int = 0
    /// Number of elements excluded because they have no text content.
    public var excluded_no_text: Int = 0
    /// Number of collected elements that have text content.
    public var with_text_count: Int = 0
    /// Number of collected elements without text content.
    public var without_text_count: Int = 0
    /// Number of elements with valid geometry (position and size).
    public var visible_elements_count: Int = 0
    /// Count of elements by their accessibility role.
    public var role_counts: [String: Int] = [:]
}

/// The result of an accessibility tree traversal operation.
///
/// Contains all collected elements, traversal statistics, and timing information.
public struct ResponseData: Codable, Sendable {
    /// The display name of the application that was traversed.
    public let app_name: String
    /// The collected UI elements from the accessibility tree.
    public var elements: [ElementData]
    /// Statistics about the traversal operation.
    public var stats: Statistics
    /// The time taken to complete the traversal, in seconds (as a formatted string).
    public let processing_time_seconds: String
}

// --- Main Public Function ---

/// Traverses the accessibility tree of an application specified by its PID.
///
/// - Parameter pid: The Process ID (PID) of the target application.
/// - Parameter onlyVisibleElements: If true, only collects elements with valid position and size. Defaults to false.
/// - Parameter shouldActivate: If true, activates the target application before traversal. Defaults to false
///   to avoid stealing focus during background polling (e.g. ObservationManager). Set to true only
///   when the caller explicitly intends to bring the app to the foreground.
/// - Returns: A `ResponseData` struct containing the collected elements, statistics, and timing information.
/// - Throws: `ExactMacError` if accessibility is denied, the app is not found, or an internal error occurs.
public func traverseAccessibilityTree(pid: Int32, onlyVisibleElements: Bool = false, shouldActivate: Bool = false) throws
    -> ResponseData
{
    let operation = AccessibilityTraversalOperation(
        pid: pid, onlyVisibleElements: onlyVisibleElements, shouldActivate: shouldActivate,
    )
    return try operation.executeTraversal()
}

/// Traverses one exact Accessibility subtree while preserving the owning
/// application's process identity and trust boundary.
public func traverseAccessibilitySubtree(
    pid: Int32,
    rootElement: AXUIElement,
    onlyVisibleElements: Bool = false,
) throws -> ResponseData {
    let operation = AccessibilityTraversalOperation(
        pid: pid,
        onlyVisibleElements: onlyVisibleElements,
        shouldActivate: false,
        rootElement: rootElement,
    )
    return try operation.executeTraversal()
}

// --- Internal Implementation Detail ---

/// Class to encapsulate the state and logic of a single traversal operation
private class AccessibilityTraversalOperation {
    let pid: Int32
    let onlyVisibleElements: Bool
    let shouldActivate: Bool
    let rootElement: AXUIElement?
    var visitedElements: Set<AXUIElement> = []
    var collectedElements: [ElementData] = []
    var statistics: Statistics = .init()
    var stepStartTime: Date = .init()
    let traversalBudget: AccessibilityTraversalBudget

    /// Define roles considered non-interactable by default
    let nonInteractableRoles: Set<String> = [
        "AXGroup", "AXStaticText", "AXUnknown", "AXSeparator",
        "AXHeading", "AXLayoutArea", "AXHelpTag", "AXGrowArea",
        "AXOutline", "AXScrollArea", "AXSplitGroup", "AXSplitter",
        "AXToolbar", "AXDisclosureTriangle",
    ]

    init(
        pid: Int32,
        onlyVisibleElements: Bool,
        shouldActivate: Bool = false,
        rootElement: AXUIElement? = nil,
    ) {
        self.pid = pid
        self.onlyVisibleElements = onlyVisibleElements
        self.shouldActivate = shouldActivate
        self.rootElement = rootElement
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        traversalBudget = AccessibilityTraversalBudget(
            maxDepth: 100,
            maxNodes: 100_000,
            deadlineExceeded: { ProcessInfo.processInfo.systemUptime >= deadline },
        )
    }

    /// --- Main Execution Method ---
    func executeTraversal() throws -> ResponseData {
        try Task.checkCancellation()
        let overallStartTime = Date()
        logger.info(
            "starting traversal for pid: \(String(describing: self.pid), privacy: .public) (Visible Only: \(String(describing: self.onlyVisibleElements), privacy: .public))",
        )
        stepStartTime = Date() // Initialize step timer
        // 1. Accessibility Check
        logger.info("checking accessibility permissions...")
        try traversalBudget.checkAXStep()
        let promptValue = accessibilityTrustCheckShouldPrompt ? kCFBooleanTrue : kCFBooleanFalse
        let checkOptions = ["AXTrustedCheckOptionPrompt": promptValue] as CFDictionary
        let isTrusted = AXIsProcessTrustedWithOptions(checkOptions)

        if !isTrusted {
            logger.error("❌ accessibility access is denied.")
            logger.error(
                "please grant permissions in system settings > privacy & security > accessibility.",
            )
            throw ExactMacError.accessibilityDenied
        }
        logStepCompletion("checking accessibility permissions (granted)")

        // 2. Create the AX application directly. Lagging Workspace or WindowServer
        // process views must never guard a valid Accessibility target.
        let appElement = AXUIElementCreateApplication(pid)
        let titleValue = try copyAttributeValue(
            element: appElement,
            attribute: kAXTitleAttribute as String,
        )
        let targetAppName = if let title = titleValue as? String,
                               !title.isEmpty
        {
            title
        } else {
            "App (PID: \(pid))"
        }

        // 3. Activation is an AX action followed by AX readback. The server
        // normally performs this inside its global mutation lease and calls
        // traversal with shouldActivate=false; this path preserves the direct
        // SDK API without relying on NSRunningApplication.
        var didActivate = false
        if shouldActivate {
            try traversalBudget.checkAXStep()
            let setResult = AXUIElementSetAttributeValue(
                appElement,
                kAXFrontmostAttribute as CFString,
                true as CFTypeRef,
            )
            guard setResult == .success else {
                throw ExactMacError.internalError(
                    "Failed to set AXFrontmost for PID \(pid): AX error \(setResult.rawValue)",
                )
            }
            let frontmostValue = try copyAttributeValue(
                element: appElement,
                attribute: kAXFrontmostAttribute as String,
            )
            guard frontmostValue as? Bool == true else {
                throw ExactMacError.internalError(
                    "AXFrontmost did not converge for PID \(pid)",
                )
            }
            didActivate = true
        }
        if didActivate {
            logStepCompletion("activating application '\(targetAppName)'")
        } else if !shouldActivate {
            logger.trace("skipping app activation (shouldActivate=false) for pid \(self.pid, privacy: .public)")
        }

        // 4. Start Traversal
        try Task.checkCancellation()
        try walkElementTree(element: rootElement ?? appElement, depth: 0, path: [])
        logStepCompletion(
            "traversing accessibility tree (\(collectedElements.count) elements collected)",
        )

        // 5. Process Results
        let sortedElements = stableTraversalElements(collectedElements)
        // logStepCompletion("sorting \(sortedElements.count) elements") // Log implicitly

        // Set the final count statistic
        statistics.count = sortedElements.count

        // --- Calculate Total Time ---
        let overallEndTime = Date()
        let totalProcessingTime = overallEndTime.timeIntervalSince(overallStartTime)
        let formattedTime = String(format: "%.2f", totalProcessingTime)
        logger.info("total execution time: \(formattedTime, privacy: .public) seconds")

        // 6. Prepare Response
        return ResponseData(
            app_name: targetAppName,
            elements: sortedElements,
            stats: statistics,
            processing_time_seconds: formattedTime,
        )
        // JSON encoding will be handled by the caller of the library function if needed
    }

    // --- Helper Functions (now methods of the class) ---

    /// Safely copy an attribute value
    func copyAttributeValue(element: AXUIElement, attribute: String) throws -> CFTypeRef? {
        try copyAttributeValue(element: element, attribute: attribute, optionalMetadata: false)
    }

    /// Copy descriptive metadata without letting an attribute-local absence
    /// invalidate an otherwise readable element. Identity, hierarchy,
    /// geometry, and focus reads continue to fail closed.
    func copyOptionalMetadataAttributeValue(element: AXUIElement, attribute: String) throws -> CFTypeRef? {
        try copyAttributeValue(element: element, attribute: attribute, optionalMetadata: true)
    }

    private func copyAttributeValue(
        element: AXUIElement,
        attribute: String,
        optionalMetadata: Bool,
    ) throws -> CFTypeRef? {
        try traversalBudget.checkAXStep()
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        switch result {
        case .success:
            return value
        case .attributeUnsupported, .noValue:
            return nil
        case let error where optionalMetadata && isUnavailableOptionalTraversalMetadataError(error):
            return nil
        default:
            throw ExactMacError.internalError(
                "Failed to read Accessibility attribute \(attribute): AX error \(result.rawValue)",
            )
        }
    }

    /// ISO 8601 formatter for CFDate display conversion. Lazily initialized.
    /// The formatter is immutable after initialization; `nonisolated(unsafe)` is safe.
    private nonisolated(unsafe) static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Converts a CFTypeRef to its display string representation.
    ///
    /// Handles:
    /// - CFString → String
    /// - CFBoolean → "true" / "false"
    /// - CFNumber → decimal string via NSNumber bridging
    /// - CFDate → ISO 8601 formatted string
    /// - AXValue (kAXValueTypeCFRange) → "{location, length}" format
    func getDisplayString(_ value: CFTypeRef?) -> String? {
        guard let value else { return nil }
        let typeID = CFGetTypeID(value)
        if typeID == CFStringGetTypeID() {
            let cfString = value as! CFString
            return cfString as String
        } else if typeID == CFBooleanGetTypeID() {
            return CFBooleanGetValue((value as! CFBoolean)) ? "true" : "false"
        } else if typeID == CFNumberGetTypeID() {
            let nsNumber = value as! NSNumber
            return nsNumber.stringValue
        } else if typeID == CFDateGetTypeID() {
            let cfDate = value as! CFDate
            let date = cfDate as Date
            return Self.iso8601Formatter.string(from: date)
        } else if typeID == AXValueGetTypeID() {
            let axValue = value as! AXValue
            var range = CFRange(location: 0, length: 0)
            if AXValueGetValue(axValue, .cfRange, &range) {
                return "{\(range.location), \(range.length)}"
            }
            return nil
        }
        return nil
    }

    /// Extract bool value
    func getBoolValue(_ value: CFTypeRef?) -> Bool? {
        guard let value, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    /// Extract CGPoint
    func getCGPointValue(_ value: CFTypeRef?) -> CGPoint? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var pointValue = CGPoint.zero
        if AXValueGetValue(axValue, .cgPoint, &pointValue) {
            return pointValue
        }
        return nil
    }

    /// Extract CGSize
    func getCGSizeValue(_ value: CFTypeRef?) -> CGSize? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var sizeValue = CGSize.zero
        if AXValueGetValue(axValue, .cgSize, &sizeValue) {
            return sizeValue
        }
        return nil
    }

    /// Extract attributes, text, and geometry
    func extractElementAttributes(element: AXUIElement) throws -> (
        role: String, roleDesc: String?, text: String?, allTextParts: [String], position: CGPoint?,
        size: CGSize?, enabled: Bool?, focused: Bool?, attributes: [String: String],
    ) {
        var role = "AXUnknown"
        var roleDesc: String?
        var textParts: [String] = []
        var position: CGPoint?
        var size: CGSize?
        var enabled: Bool?
        var focused: Bool?
        var attributes: [String: String] = [:]

        if let roleValue = try copyAttributeValue(element: element, attribute: kAXRoleAttribute as String) {
            role = getDisplayString(roleValue) ?? "AXUnknown"
        }
        if let roleDescValue = try copyAttributeValue(
            element: element,
            attribute: kAXRoleDescriptionAttribute as String,
            optionalMetadata: true,
        ) {
            roleDesc = getDisplayString(roleDescValue)
        }

        let textAttributes = [
            kAXValueAttribute as String, kAXTitleAttribute as String, kAXDescriptionAttribute as String,
            "AXLabel", "AXHelp",
        ]
        for attr in textAttributes {
            let attrValue = try copyOptionalMetadataAttributeValue(element: element, attribute: attr)
            if let attrValue,
               let text = getDisplayString(attrValue),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                textParts.append(text)
            }
        }
        let combinedText =
            textParts.isEmpty
                ? nil : textParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

        if let posValue = try copyAttributeValue(
            element: element, attribute: kAXPositionAttribute as String,
        ) {
            position = getCGPointValue(posValue)
        }

        if let sizeValue = try copyAttributeValue(element: element, attribute: kAXSizeAttribute as String) {
            size = getCGSizeValue(sizeValue)
        }

        if let enabledValue = try copyAttributeValue(
            element: element, attribute: kAXEnabledAttribute as String,
        ) {
            enabled = getBoolValue(enabledValue)
        }

        if let focusedValue = try copyAttributeValue(
            element: element, attribute: kAXFocusedAttribute as String,
        ) {
            focused = getBoolValue(focusedValue)
        }

        // Add some common attributes
        let commonAttributes = [
            kAXTitleAttribute as String,
            kAXValueAttribute as String,
            kAXDescriptionAttribute as String,
            kAXHelpAttribute as String,
        ]
        for attr in commonAttributes {
            let attrValue = try copyOptionalMetadataAttributeValue(element: element, attribute: attr)
            if let attrValue,
               let strValue = getDisplayString(attrValue)
            {
                attributes[attr] = strValue
            }
        }

        return (role, roleDesc, combinedText, textParts, position, size, enabled, focused, attributes)
    }

    /// Recursive traversal function (now a method)
    func walkElementTree(element: AXUIElement, depth: Int, path: [Int32]) throws {
        try Task.checkCancellation()
        // 1. Check for cycles, then fail closed at finite traversal limits.
        if visitedElements.contains(element) {
            return
        }
        try traversalBudget.beginElement(depth: depth)
        visitedElements.insert(element)

        // 2. Process the current element
        let (role, roleDesc, combinedText, _, position, size, enabled, focused, attributes) =
            try extractElementAttributes(
                element: element,
            )
        let hasText = combinedText != nil && !combinedText!.isEmpty
        let isNonInteractable = nonInteractableRoles.contains(role)
        let roleWithoutAX = role.starts(with: "AX") ? String(role.dropFirst(2)) : role

        statistics.role_counts[role, default: 0] += 1

        // 3. Determine Geometry and Visibility
        var finalX: Double?
        var finalY: Double?
        var finalWidth: Double?
        var finalHeight: Double?
        if let p = position, let s = size, s.width > 0 || s.height > 0 {
            finalX = Double(p.x)
            finalY = Double(p.y)
            finalWidth = s.width > 0 ? Double(s.width) : nil
            finalHeight = s.height > 0 ? Double(s.height) : nil
        }
        let isGeometricallyVisible =
            finalX != nil && finalY != nil && finalWidth != nil && finalHeight != nil

        // Always update the visible_elements_count stat based on geometry, regardless of collection
        if isGeometricallyVisible {
            statistics.visible_elements_count += 1
        }

        // 4. Apply Filtering Logic
        var displayRole = role
        if let desc = roleDesc, !desc.isEmpty, !desc.elementsEqual(roleWithoutAX) {
            displayRole = "\(role) (\(desc))"
        }

        // Determine if the element passes the original filter criteria
        let passesOriginalFilter = !isNonInteractable || hasText

        // Determine if the element should be collected based on the new flag
        let shouldCollectElement =
            passesOriginalFilter && (!onlyVisibleElements || isGeometricallyVisible)

        if shouldCollectElement {
            let elementData = ElementData(
                role: displayRole, text: combinedText,
                x: finalX, y: finalY, width: finalWidth, height: finalHeight,
                axElement: SendableAXUIElement(element), enabled: enabled, focused: focused,
                attributes: attributes,
                path: path,
            )

            collectedElements.append(elementData)
            if hasText {
                statistics.with_text_count += 1
            } else {
                statistics.without_text_count += 1
            }
        } else {
            // Update exclusion counts
            statistics.excluded_count += 1
            // Only increment reason-specific counters when those are the actual exclusion reasons.
            // If element was excluded solely due to visibility (passesOriginalFilter=true but not visible),
            // do NOT blame its text or role status.
            if !passesOriginalFilter {
                if isNonInteractable {
                    statistics.excluded_non_interactable += 1
                }
                if !hasText {
                    statistics.excluded_no_text += 1
                }
            }
        }

        // 5. Recursively traverse children, windows, main window
        // a) Windows (use negative indices starting from -1 to distinguish from regular children)
        if let windowsValue = try copyOptionalMetadataAttributeValue(
            element: element, attribute: kAXWindowsAttribute as String,
        ) {
            if let windowsArray = windowsValue as? [AXUIElement] {
                for (windowIndex, windowElement) in windowsArray.enumerated()
                    where !visitedElements.contains(windowElement)
                {
                    // Use -(windowIndex + 1) to distinguish windows from children
                    let windowPath = path + [Int32(-(windowIndex + 1))]
                    try walkElementTree(element: windowElement, depth: depth + 1, path: windowPath)
                }
            } else if CFGetTypeID(windowsValue) == CFArrayGetTypeID() {}
        }

        // b) Main Window (use special index -10000 to distinguish)
        if let mainWindowValue = try copyOptionalMetadataAttributeValue(
            element: element, attribute: kAXMainWindowAttribute as String,
        ) {
            if CFGetTypeID(mainWindowValue) == AXUIElementGetTypeID() {
                let mainWindowElement = mainWindowValue as! AXUIElement
                if !visitedElements.contains(mainWindowElement) {
                    let mainWindowPath = path + [Int32(-10000)]
                    try walkElementTree(element: mainWindowElement, depth: depth + 1, path: mainWindowPath)
                }
            } else {}
        }

        // c) Regular Children (use 0-based indices)
        if let childrenValue = try copyOptionalMetadataAttributeValue(
            element: element, attribute: kAXChildrenAttribute as String,
        ) {
            if let childrenArray = childrenValue as? [AXUIElement] {
                for (childIndex, childElement) in childrenArray.enumerated()
                    where !visitedElements.contains(childElement)
                {
                    let childPath = path + [Int32(childIndex)]
                    try walkElementTree(element: childElement, depth: depth + 1, path: childPath)
                }
            } else if CFGetTypeID(childrenValue) == CFArrayGetTypeID() {}
        }
    }

    /// Helper function logs duration of the step just completed
    func logStepCompletion(_ stepDescription: String) {
        let endTime = Date()
        let duration = endTime.timeIntervalSince(stepStartTime)
        let durationStr = String(format: "%.3f", duration)
        logger.info("[\(durationStr, privacy: .public)s] finished '\(stepDescription, privacy: .public)'")
        stepStartTime = endTime // Reset start time for the next step
    }
} // End of AccessibilityTraversalOperation class
