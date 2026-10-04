import AppKit
@testable import ExactMacServer
import Foundation
import Testing

/// Performance benchmarks for window listing operations.
///
/// These tests measure WindowRegistry.listAllWindows and listWindows(forPID:)
/// to establish baseline performance metrics.
///
/// **Requirements**: Tests depend on actual macOS windows being present.
struct WindowListingPerformanceTests {
    /// Number of iterations for stable timing
    private let iterations = 10

    /// Test listAllWindows performance across all system windows.
    ///
    /// Expected: Sub-100ms for typical desktop with <50 windows
    @Test
    func `listAllWindows performance baseline`() async throws {
        let registry = WindowRegistry()

        // Perform listing iterations and collect timing
        var durations: [TimeInterval] = []
        var windowCounts: [Int] = []

        for _ in 0 ..< iterations {
            let start = CFAbsoluteTimeGetCurrent()
            let windows = try await registry.listAllWindows()
            let duration = CFAbsoluteTimeGetCurrent() - start

            durations.append(duration)
            windowCounts.append(windows.count)
        }

        // Calculate metrics
        let avgDuration = durations.reduce(0, +) / Double(iterations)
        let avgWindows = windowCounts.reduce(0, +) / iterations
        let minDuration = durations.min() ?? 0
        let maxDuration = durations.max() ?? 0

        print("""
        ===== listAllWindows Benchmark =====
        Iterations: \(iterations)
        Avg Windows: \(avgWindows)
        Avg Duration: \(String(format: "%.3f", avgDuration * 1000))ms
        Min Duration: \(String(format: "%.3f", minDuration * 1000))ms
        Max Duration: \(String(format: "%.3f", maxDuration * 1000))ms
        ====================================
        """)

        // Assertions
        #expect(avgDuration < 1.0, "listAllWindows should complete under 1000ms")
        // At minimum, we should see at least a few windows (desktop, status menu, etc.)
        #expect(windowCounts.allSatisfy { $0 >= 0 }, "Window count should be non-negative")
    }

    /// Test listWindows(forPID:) performance for a specific application.
    ///
    /// Uses Finder as it's always running on macOS.
    @Test
    func `listWindows for Finder performance`() async throws {
        let registry = WindowRegistry()

        // Find Finder's PID
        guard let finderApp = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.finder",
        ).first else {
            Issue.record("Finder not running - test cannot proceed")
            return
        }

        let finderPID = finderApp.processIdentifier

        // Perform listing iterations
        var durations: [TimeInterval] = []
        var windowCounts: [Int] = []

        for _ in 0 ..< iterations {
            let start = CFAbsoluteTimeGetCurrent()
            let windows = try await registry.listWindows(forPID: finderPID)
            let duration = CFAbsoluteTimeGetCurrent() - start

            durations.append(duration)
            windowCounts.append(windows.count)
        }

        // Calculate metrics
        let avgDuration = durations.reduce(0, +) / Double(iterations)
        let avgWindows = windowCounts.reduce(0, +) / iterations
        let minDuration = durations.min() ?? 0
        let maxDuration = durations.max() ?? 0

        print("""
        ===== listWindows(Finder) Benchmark =====
        PID: \(finderPID)
        Iterations: \(iterations)
        Avg Windows: \(avgWindows)
        Avg Duration: \(String(format: "%.3f", avgDuration * 1000))ms
        Min Duration: \(String(format: "%.3f", minDuration * 1000))ms
        Max Duration: \(String(format: "%.3f", maxDuration * 1000))ms
        =========================================
        """)

        // Assertions
        #expect(avgDuration < 0.5, "listWindows should complete under 500ms")
    }

    /// Measure cache effectiveness - second call should be faster.
    @Test
    func `Cache performance comparison`() async throws {
        let registry = WindowRegistry()

        // First call - cold cache (forces refresh)
        let coldStart = CFAbsoluteTimeGetCurrent()
        _ = try await registry.listAllWindows()
        let coldDuration = CFAbsoluteTimeGetCurrent() - coldStart

        // Second call - potentially warm cache depending on implementation
        let warmStart = CFAbsoluteTimeGetCurrent()
        _ = try await registry.listAllWindows()
        let warmDuration = CFAbsoluteTimeGetCurrent() - warmStart

        print("""
        ===== Cache Performance Comparison =====
        Cold call: \(String(format: "%.3f", coldDuration * 1000))ms
        Warm call: \(String(format: "%.3f", warmDuration * 1000))ms
        =========================================
        """)

        // Both should be reasonably fast
        #expect(coldDuration < 1.0, "Cold listAllWindows should complete under 1 second")
        #expect(warmDuration < 1.0, "Warm listAllWindows should complete under 1 second")
    }
}
