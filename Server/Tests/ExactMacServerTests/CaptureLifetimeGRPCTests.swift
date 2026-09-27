import ApplicationServices
import CoreGraphics
@testable import ExactMac
@testable import ExactMacProto
@testable import ExactMacServer
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import ImageIO
import SwiftProtobuf
import Testing
import UniformTypeIdentifiers

@Suite(.serialized)
struct CaptureLifetimeGRPCTests {
    @Test(arguments: captureImageFaultCases)
    func `every capture family rejects corrupt mismatched or dimension-false image bytes`(
        testCase: CaptureImageFaultTestCase,
    ) async throws {
        let fixture = try await captureLifetimeFixture(imageFault: testCase.fault)
        await fixture.probe.release()

        try await withCaptureLifetimeClient(fixture.composition) { client, _ in
            // A transport-level unavailable (connection failure under load) can
            // arrive before the application ever sees the request. Retry only
            // when the capture sink was never invoked, so an application-level
            // unavailable (which always follows a capture attempt) is never
            // masked by the retry, and the invocation-count assertion below
            // still fails closed on an admission regression.
            for attempt in 0 ..< 3 {
                let call = captureLifetimeCall(
                    rpc: testCase.rpc,
                    fixture: fixture,
                    client: client,
                    format: testCase.format,
                )
                do {
                    try await call.value
                    Issue.record("Expected encoded image validation failure")
                    break
                } catch let error as RPCError {
                    let sinkInvoked = await fixture.sink.invocationCount > 0
                    if error.code == .unavailable, !sinkInvoked, attempt < 2 {
                        continue
                    }
                    #expect(error.code == .unavailable)
                    break
                } catch {
                    Issue.record("Expected RPCError, got \(error)")
                    break
                }
            }
            #expect(await fixture.sink.invocationCount == 1)
            #expect(await fixture.composition.captureWorkOwner.activeCaptureCount() == 0)
        }
    }

    @Test(arguments: captureEncodingCases)
    func `every capture family enforces the same format and quality contract`(
        testCase: CaptureEncodingTestCase,
    ) async throws {
        let fixture = try await captureLifetimeFixture()
        await fixture.probe.release()

        try await withCaptureLifetimeClient(fixture.composition) { client, _ in
            // As in the fault-injection test above, a transport-level
            // unavailable (connection failure under load) is transient:
            // retry it, and let the sink/encoding assertions below fail
            // closed on any application-level regression.
            var lastError: RPCError?
            var succeeded = false
            for attempt in 0 ..< 3 {
                let call = captureLifetimeCall(
                    rpc: testCase.rpc,
                    fixture: fixture,
                    client: client,
                    format: testCase.format,
                    quality: testCase.quality,
                )
                do {
                    try await call.value
                    succeeded = true
                    break
                } catch let error as RPCError {
                    lastError = error
                    if error.code == .unavailable, attempt < 2 {
                        continue
                    }
                    break
                } catch {
                    Issue.record("Expected RPCError, got \(error)")
                    break
                }
            }
            if let expected = testCase.expected {
                #expect(succeeded, Comment(rawValue: String(describing: lastError)))
                #expect(await fixture.sink.invocationCount == 1)
                #expect(await fixture.sink.lastEncoding == expected)
            } else {
                var invalidArgumentObserved: RPCError?
                for attempt in 0 ..< 3 {
                    let call = captureLifetimeCall(
                        rpc: testCase.rpc,
                        fixture: fixture,
                        client: client,
                        format: testCase.format,
                        quality: testCase.quality,
                    )
                    do {
                        try await call.value
                        Issue.record("Expected invalid format/quality request")
                        break
                    } catch let error as RPCError {
                        if error.code == .invalidArgument {
                            invalidArgumentObserved = error
                            break
                        }
                        if error.code == .unavailable, attempt < 2 {
                            continue
                        }
                        Issue.record("Expected invalidArgument, got \(error)")
                        break
                    } catch {
                        Issue.record("Expected RPCError, got \(error)")
                        break
                    }
                }
                #expect(invalidArgumentObserved != nil)
                #expect(await fixture.sink.invocationCount == 0)
                #expect(await fixture.composition.captureWorkOwner.activeCaptureCount() == 0)
            }
        }
    }

    @Test(arguments: CaptureLifetimeRPC.allCases)
    func `capture owner admits every preparation phase before suspension`(
        rpc: CaptureLifetimeRPC,
    ) async throws {
        let preparationProbe = CaptureLifetimeProbe()
        let windowPreparationProbe = CaptureSynchronousPreparationProbe()
        let topologyProvider: any DisplayTopologyProviding = if rpc == .window {
            CaptureLifetimeTopologyProvider()
        } else {
            CapturePreparationTopologyProvider(probe: preparationProbe)
        }
        let fixture = try await captureLifetimeFixture(
            topologyProvider: topologyProvider,
            windowPreparationProbe: rpc == .window ? windowPreparationProbe : nil,
        )
        await fixture.probe.release()

        try await withCaptureLifetimeClient(fixture.composition) { client, _ in
            let call = captureLifetimeCall(
                rpc: rpc,
                fixture: fixture,
                client: client,
            )
            var shutdown: Task<Void, Never>?
            do {
                if rpc == .window {
                    try await windowPreparationProbe.waitUntilEntered()
                } else {
                    try await preparationProbe.waitUntilEntered()
                }
                #expect(await fixture.composition.captureWorkOwner.activeCaptureCount() == 1)

                shutdown = Task {
                    await fixture.composition.serviceLifetime.shutdown()
                }
                try await pollCaptureLifetimeCondition("capture owner drain") {
                    await fixture.composition.captureWorkOwner.lifecycleState() != .accepting
                }
                #expect(await fixture.composition.captureWorkOwner.lifecycleState() == .draining)
                #expect(await fixture.composition.captureWorkOwner.activeCaptureCount() == 1)
                #expect(await fixture.sink.invocationCount == 0)

                if rpc == .window {
                    windowPreparationProbe.release()
                } else {
                    await preparationProbe.release()
                }
                await expectCancelledCapture(call)
                await shutdown?.value
                #expect(await fixture.composition.captureWorkOwner.lifecycleState() == .drained)
                #expect(await fixture.composition.captureWorkOwner.activeCaptureCount() == 0)
                #expect(await fixture.sink.invocationCount == 0)
            } catch {
                call.cancel()
                windowPreparationProbe.release()
                await preparationProbe.release()
                await shutdown?.value
                _ = await call.result
                throw error
            }
        }
    }

    @Test(arguments: CaptureLifetimeRPC.allCases)
    func `generated client disconnect retains and joins every capture family`(
        rpc: CaptureLifetimeRPC,
    ) async throws {
        let fixture = try await captureLifetimeFixture()

        try await withCaptureLifetimeClient(fixture.composition) { client, disconnect in
            let call = captureLifetimeCall(
                rpc: rpc,
                fixture: fixture,
                client: client,
            )
            do {
                try await fixture.probe.waitUntilEntered()
                #expect(await fixture.composition.captureWorkOwner.activeCaptureCount() == 1)

                disconnect()
                try await fixture.probe.waitUntilCancellationObserved()
                #expect(await fixture.composition.captureWorkOwner.activeCaptureCount() == 1)

                await fixture.probe.release()
                await expectDisconnectedCapture(call)
                try await pollCaptureLifetimeCondition("capture owner settlement") {
                    await fixture.composition.captureWorkOwner.activeCaptureCount() == 0
                }
                #expect(await fixture.composition.captureWorkOwner.activeCaptureCount() == 0)
                #expect(await fixture.sink.invocationCount == 1)
            } catch {
                disconnect()
                call.cancel()
                await fixture.probe.release()
                _ = await call.result
                throw error
            }
        }
    }

    @Test
    func `caller task cancellation retains and joins resistant capture work`() async throws {
        let probe = CaptureLifetimeProbe()
        let sink = CaptureLifetimeSink(probe: probe)
        let owner = CaptureWorkOwner()
        let call = Task {
            try await owner.withCapture {
                try await sink.captureDisplay(
                    captureLifetimeDisplay,
                    format: .png,
                    quality: 85,
                    includeOCR: false,
                )
            }
        }
        do {
            try await probe.waitUntilEntered()

            call.cancel()
            try await probe.waitUntilCancellationObserved()
            #expect(await owner.activeCaptureCount() == 1)

            await probe.release()
            await expectCancelledCapture(call)
            #expect(await owner.activeCaptureCount() == 0)
        } catch {
            call.cancel()
            await probe.release()
            _ = await call.result
            throw error
        }
    }

    @Test(arguments: CaptureLifetimeRPC.allCases)
    func `service drain cancels and joins every public capture family`(
        rpc: CaptureLifetimeRPC,
    ) async throws {
        let fixture = try await captureLifetimeFixture()

        try await withCaptureLifetimeClient(fixture.composition) { client, _ in
            let call = captureLifetimeCall(
                rpc: rpc,
                fixture: fixture,
                client: client,
            )
            var shutdown: Task<Void, Never>?
            do {
                try await fixture.probe.waitUntilEntered()
                #expect(await fixture.composition.captureWorkOwner.activeCaptureCount() == 1)

                shutdown = Task { await fixture.composition.serviceLifetime.shutdown() }
                try await fixture.probe.waitUntilCancellationObserved()
                #expect(await fixture.composition.serviceLifetime.lifecycleState() == .draining)
                #expect(await fixture.composition.captureWorkOwner.lifecycleState() == .draining)
                #expect(await fixture.composition.captureWorkOwner.activeCaptureCount() == 1)

                await fixture.probe.release()
                await expectCancelledCapture(call)
                await shutdown?.value
                #expect(await fixture.composition.captureWorkOwner.lifecycleState() == .drained)
                #expect(await fixture.composition.captureWorkOwner.activeCaptureCount() == 0)
                #expect(await fixture.composition.serviceLifetime.lifecycleState() == .drained)
                #expect(await fixture.sink.invocationCount == 1)
            } catch {
                call.cancel()
                await fixture.probe.release()
                await shutdown?.value
                _ = await call.result
                throw error
            }
        }
    }

    @Test
    func `capture owner closes admission while drain joins resistant work`() async throws {
        let probe = CaptureLifetimeProbe()
        let sink = CaptureLifetimeSink(probe: probe)
        let composition = ExactMacServiceComposition(
            displayTopologyProvider: CaptureLifetimeTopologyProvider(),
            screenshotCapture: sink,
        )

        #expect(composition.serviceLifetime.captureWorkOwner === composition.captureWorkOwner)
        #expect(composition.exactMacService.captureWorkOwner === composition.captureWorkOwner)

        let active = Task {
            try await composition.captureWorkOwner.withCapture {
                try await sink.captureDisplay(
                    captureLifetimeDisplay,
                    format: .png,
                    quality: 85,
                    includeOCR: false,
                )
            }
        }
        try await probe.waitUntilEntered()

        let shutdown = Task { await composition.serviceLifetime.shutdown() }
        try await probe.waitUntilCancellationObserved()
        #expect(await composition.serviceLifetime.lifecycleState() == .draining)
        #expect(await composition.captureWorkOwner.lifecycleState() == .draining)
        #expect(await composition.captureWorkOwner.activeCaptureCount() == 1)

        do {
            _ = try await composition.captureWorkOwner.withCapture {
                try await sink.captureDisplay(
                    captureLifetimeDisplay,
                    format: .png,
                    quality: 85,
                    includeOCR: false,
                )
            }
            Issue.record("Expected capture admission to close during drain")
        } catch let error as RPCError {
            #expect(error.code == .unavailable)
        }
        #expect(await sink.invocationCount == 1)

        await probe.release()
        await expectCancelledCapture(active)
        await shutdown.value
        #expect(await composition.captureWorkOwner.lifecycleState() == .drained)
        #expect(await composition.captureWorkOwner.activeCaptureCount() == 0)
        #expect(await composition.serviceLifetime.lifecycleState() == .drained)
    }

    @Test
    func `element capture rejects a sibling window scope before capture`() async throws {
        let fixture = try await captureLifetimeFixture()
        await fixture.probe.release()

        try await withCaptureLifetimeClient(fixture.composition) { client, _ in
            do {
                let _: Exactmac_V1_CaptureElementScreenshotResponse = try await captureLifetimeUnary(
                    client: client,
                    request: Exactmac_V1_CaptureElementScreenshotRequest.with {
                        $0.parent = fixture.otherWindowName
                        $0.elementID = fixture.elementID
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.CaptureElementScreenshot.descriptor,
                )
                Issue.record("Expected sibling-window element capture to fail closed")
            } catch let error as RPCError {
                #expect(error.code == .failedPrecondition)
            }
            #expect(await fixture.sink.invocationCount == 0)
        }
    }

    @Test
    func `malformed resource names reject before closed capture admission`() async throws {
        let topology = CaptureLifetimeTopologyProvider()
        let fixture = try await captureLifetimeFixture(topologyProvider: topology)
        await fixture.probe.release()
        await fixture.composition.captureWorkOwner.shutdown()

        try await withCaptureLifetimeClient(fixture.composition) { client, _ in
            await expectCaptureLifetimeRPCError(.invalidArgument) {
                let _: Exactmac_V1_CaptureScreenshotResponse = try await captureLifetimeUnary(
                    client: client,
                    request: Exactmac_V1_CaptureScreenshotRequest.with {
                        $0.display = "displays/not-an-id"
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.CaptureScreenshot.descriptor,
                )
            }
            await expectCaptureLifetimeRPCError(.invalidArgument) {
                let _: Exactmac_V1_CaptureRegionScreenshotResponse = try await captureLifetimeUnary(
                    client: client,
                    request: Exactmac_V1_CaptureRegionScreenshotRequest.with {
                        $0.display = "displays/not-an-id"
                        $0.region = captureLifetimeRegion
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.CaptureRegionScreenshot.descriptor,
                )
            }
            await expectCaptureLifetimeRPCError(.invalidArgument) {
                let _: Exactmac_V1_CaptureElementScreenshotResponse = try await captureLifetimeUnary(
                    client: client,
                    request: Exactmac_V1_CaptureElementScreenshotRequest.with {
                        $0.parent = "not/a/parent"
                        $0.elementID = fixture.elementID
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.CaptureElementScreenshot.descriptor,
                )
            }
            await expectCaptureLifetimeRPCError(.invalidArgument) {
                let _: Exactmac_V1_CaptureWindowScreenshotResponse = try await captureLifetimeUnary(
                    client: client,
                    request: Exactmac_V1_CaptureWindowScreenshotRequest.with {
                        $0.window = "not/a/window"
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.CaptureWindowScreenshot.descriptor,
                )
            }
        }

        #expect(await topology.snapshotCount == 0)
        #expect(await fixture.sink.invocationCount == 0)
    }

    @Test
    func `element capture reports mixed-scale pixel padding and display-edge clipping`() async throws {
        let display = DisplayTopologyDisplay(
            displayID: 78,
            frame: CGRect(x: -4, y: -1, width: 4, height: 4),
            visibleFrame: CGRect(x: -4, y: -1, width: 4, height: 4),
            isMain: true,
            scale: 1.5,
        )
        let elementFrame = CGRect(x: -1.2, y: 1.4, width: 1, height: 1)
        let fixture = try await captureLifetimeFixture(
            display: display,
            elementBounds: elementFrame,
        )
        await fixture.probe.release()

        try await withCaptureLifetimeClient(fixture.composition) { client, _ in
            let response: Exactmac_V1_CaptureElementScreenshotResponse =
                try await captureLifetimeUnary(
                    client: client,
                    request: Exactmac_V1_CaptureElementScreenshotRequest.with {
                        $0.parent = fixture.parent
                        $0.elementID = fixture.elementID
                        $0.format = .png
                        $0.padding = 3
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.CaptureElementScreenshot.descriptor,
                )

            let expectedRegion = CGRect(
                x: -10.0 / 3.0,
                y: -1,
                width: 10.0 / 3.0,
                height: 4,
            )
            #expect(response.parent == fixture.parent)
            #expect(response.elementID == fixture.elementID)
            #expect(response.elementFrame == captureLifetimeRegionMessage(elementFrame))
            #expect(response.display == display.name)
            #expect(response.scale == display.scale)
            #expect(response.padding == 3)
            #expect(response.clipped)
            #expect(abs(response.region.x - expectedRegion.origin.x) < 0.000_001)
            #expect(abs(response.region.y - expectedRegion.origin.y) < 0.000_001)
            #expect(abs(response.region.width - expectedRegion.width) < 0.000_001)
            #expect(abs(response.region.height - expectedRegion.height) < 0.000_001)
            #expect(response.width == 5)
            #expect(response.height == 6)
            #expect(await fixture.sink.lastRegion == expectedRegion)
            #expect(await fixture.sink.invocationCount == 1)
        }
    }

    @Test
    func `element capture rejects bounds changed while capture is in flight`() async throws {
        let fixture = try await captureLifetimeFixture()

        try await withCaptureLifetimeClient(fixture.composition) { client, _ in
            let call = Task {
                try await captureLifetimeUnary(
                    client: client,
                    request: Exactmac_V1_CaptureElementScreenshotRequest.with {
                        $0.parent = fixture.parent
                        $0.elementID = fixture.elementID
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.CaptureElementScreenshot.descriptor,
                ) as Exactmac_V1_CaptureElementScreenshotResponse
            }
            do {
                try await fixture.probe.waitUntilEntered()
                fixture.system.replaceElementBounds(
                    CGRect(x: 0.25, y: 0, width: 1.75, height: 2),
                )
                await fixture.probe.release()

                do {
                    _ = try await call.value
                    Issue.record("Expected changed element bounds to reject captured pixels")
                } catch let error as RPCError {
                    #expect(error.code == .aborted)
                }
                #expect(await fixture.sink.invocationCount == 1)
            } catch {
                call.cancel()
                await fixture.probe.release()
                _ = await call.result
                throw error
            }
        }
    }

    @Test
    func `element capture rejects reparenting while capture is in flight`() async throws {
        let fixture = try await captureLifetimeFixture()

        try await withCaptureLifetimeClient(fixture.composition) { client, _ in
            let call = Task {
                try await captureLifetimeUnary(
                    client: client,
                    request: Exactmac_V1_CaptureElementScreenshotRequest.with {
                        $0.parent = fixture.parent
                        $0.elementID = fixture.elementID
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.CaptureElementScreenshot.descriptor,
                ) as Exactmac_V1_CaptureElementScreenshotResponse
            }
            do {
                try await fixture.probe.waitUntilEntered()
                fixture.system.reparentElementToOtherWindow()
                await fixture.probe.release()

                do {
                    _ = try await call.value
                    Issue.record("Expected changed element ancestry to reject captured pixels")
                } catch let error as RPCError {
                    #expect(error.code == .failedPrecondition)
                }
                #expect(await fixture.sink.invocationCount == 1)
            } catch {
                call.cancel()
                await fixture.probe.release()
                _ = await call.result
                throw error
            }
        }
    }

    @Test
    func `element capture rejects cyclic live AX ancestry before capture`() async throws {
        let fixture = try await captureLifetimeFixture()
        fixture.system.makeElementParentCycle()
        await fixture.probe.release()

        try await withCaptureLifetimeClient(fixture.composition) { client, _ in
            await expectCaptureLifetimeRPCError(.failedPrecondition) {
                let _: Exactmac_V1_CaptureElementScreenshotResponse = try await captureLifetimeUnary(
                    client: client,
                    request: Exactmac_V1_CaptureElementScreenshotRequest.with {
                        $0.parent = fixture.parent
                        $0.elementID = fixture.elementID
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.CaptureElementScreenshot.descriptor,
                )
            }
            #expect(await fixture.sink.invocationCount == 0)
        }
    }
}

enum CaptureLifetimeRPC: CaseIterable, Equatable, Sendable {
    case display
    case region
    case window
    case element
}

struct CaptureEncoding: Equatable, Sendable {
    let format: Exactmac_V1_ImageFormat
    let quality: Int32
}

struct CaptureEncodingTestCase: Sendable {
    let rpc: CaptureLifetimeRPC
    let format: Exactmac_V1_ImageFormat
    let quality: Int32
    let expected: CaptureEncoding?
}

enum CaptureImageFault: Sendable {
    case corrupt
    case truncated
    case wrongFormat
    case wrongDimensions
}

struct CaptureImageFaultTestCase: Sendable {
    let rpc: CaptureLifetimeRPC
    let fault: CaptureImageFault
    let format: Exactmac_V1_ImageFormat
}

private let captureImageFaultCases: [CaptureImageFaultTestCase] =
    CaptureLifetimeRPC.allCases.flatMap { rpc in
        [
            CaptureImageFaultTestCase(rpc: rpc, fault: .corrupt, format: .png),
            CaptureImageFaultTestCase(rpc: rpc, fault: .wrongFormat, format: .png),
            CaptureImageFaultTestCase(rpc: rpc, fault: .wrongDimensions, format: .png),
        ] + [Exactmac_V1_ImageFormat.png, .jpeg, .tiff].map { format in
            CaptureImageFaultTestCase(rpc: rpc, fault: .truncated, format: format)
        }
    }

private let captureEncodingCases: [CaptureEncodingTestCase] = CaptureLifetimeRPC.allCases.flatMap { rpc in
    [
        CaptureEncodingTestCase(
            rpc: rpc,
            format: .unspecified,
            quality: 0,
            expected: CaptureEncoding(format: .png, quality: 0),
        ),
        CaptureEncodingTestCase(
            rpc: rpc,
            format: .png,
            quality: 0,
            expected: CaptureEncoding(format: .png, quality: 0),
        ),
        CaptureEncodingTestCase(
            rpc: rpc,
            format: .tiff,
            quality: 0,
            expected: CaptureEncoding(format: .tiff, quality: 0),
        ),
        CaptureEncodingTestCase(
            rpc: rpc,
            format: .jpeg,
            quality: 0,
            expected: CaptureEncoding(format: .jpeg, quality: 85),
        ),
        CaptureEncodingTestCase(
            rpc: rpc,
            format: .jpeg,
            quality: 1,
            expected: CaptureEncoding(format: .jpeg, quality: 1),
        ),
        CaptureEncodingTestCase(
            rpc: rpc,
            format: .jpeg,
            quality: 100,
            expected: CaptureEncoding(format: .jpeg, quality: 100),
        ),
        CaptureEncodingTestCase(rpc: rpc, format: .unspecified, quality: 1, expected: nil),
        CaptureEncodingTestCase(rpc: rpc, format: .png, quality: 1, expected: nil),
        CaptureEncodingTestCase(rpc: rpc, format: .tiff, quality: 100, expected: nil),
        CaptureEncodingTestCase(rpc: rpc, format: .jpeg, quality: -1, expected: nil),
        CaptureEncodingTestCase(rpc: rpc, format: .jpeg, quality: 101, expected: nil),
    ]
}

private struct CaptureLifetimeFixture {
    let probe: CaptureLifetimeProbe
    let sink: CaptureLifetimeSink
    let composition: ExactMacServiceComposition
    let system: CaptureLifetimeSystem
    let parent: String
    let windowName: String
    let otherWindowName: String
    let elementID: String
}

private func captureLifetimeFixture(
    topologyProvider: (any DisplayTopologyProviding)? = nil,
    windowPreparationProbe: CaptureSynchronousPreparationProbe? = nil,
    imageFault: CaptureImageFault? = nil,
    display: DisplayTopologyDisplay = captureLifetimeDisplay,
    elementBounds: CGRect? = nil,
) async throws -> CaptureLifetimeFixture {
    let probe = CaptureLifetimeProbe()
    let sink = CaptureLifetimeSink(probe: probe, imageFault: imageFault)
    let pid: pid_t = 7701
    let windowID: CGWindowID = 7702
    let elementAX = AXUIElementCreateApplication(7799)
    let otherWindowID = windowID + 1
    let system = CaptureLifetimeSystem(
        pid: pid,
        windows: [
            (windowID, "Capture lifetime"),
            (otherWindowID, "Other capture window"),
        ],
        element: elementAX,
        windowFrame: display.frame,
        elementBounds: elementBounds ?? display.frame,
        windowPreparationProbe: windowPreparationProbe,
    )
    let composition = ExactMacServiceComposition(
        system: system,
        legacyPIDResourceNamesForTests: true,
        displayTopologyProvider: topologyProvider ?? CaptureLifetimeTopologyProvider(display: display),
        screenshotCapture: sink,
    )
    let applicationName = "applications/\(pid)"
    let bindings = try await composition.windowRegistry.listWindowBindings(
        applicationName: applicationName,
        pid: pid,
        processIdentity: nil,
    )
    guard let windowName = bindings.first(where: { $0.windowID == windowID })?.name,
          let otherWindowName = bindings.first(where: { $0.windowID == otherWindowID })?.name
    else {
        throw CaptureLifetimeTestError.missingWindowBinding
    }

    let registeredElement = try await composition.elementRegistry.registerTraversalElements(
        [
            ElementData(
                role: "AXButton",
                text: "Capture target",
                x: (elementBounds ?? display.frame).origin.x,
                y: (elementBounds ?? display.frame).origin.y,
                width: (elementBounds ?? display.frame).width,
                height: (elementBounds ?? display.frame).height,
                axElement: SendableAXUIElement(elementAX),
                attributes: [:],
                path: [0],
            ),
        ],
        pid: pid,
        scope: windowName,
    )
    guard let elementID = registeredElement.first?.elementID else {
        throw CaptureLifetimeTestError.missingElement
    }

    return CaptureLifetimeFixture(
        probe: probe,
        sink: sink,
        composition: composition,
        system: system,
        parent: windowName,
        windowName: windowName,
        otherWindowName: otherWindowName,
        elementID: elementID,
    )
}

private let captureLifetimeDisplay = DisplayTopologyDisplay(
    displayID: 77,
    frame: CGRect(x: 0, y: 0, width: 2, height: 2),
    visibleFrame: CGRect(x: 0, y: 0, width: 2, height: 2),
    isMain: true,
    scale: 1,
)

private actor CaptureLifetimeTopologyProvider: DisplayTopologyProviding {
    private let display: DisplayTopologyDisplay
    private(set) var snapshotCount = 0

    init(display: DisplayTopologyDisplay = captureLifetimeDisplay) {
        self.display = display
    }

    func snapshot() async throws -> DisplayTopologySnapshot {
        snapshotCount += 1
        return DisplayTopologySnapshot(displays: [display])
    }

    func cursorLocation() async throws -> CGPoint {
        .zero
    }
}

private actor CapturePreparationTopologyProvider: DisplayTopologyProviding {
    private let probe: CaptureLifetimeProbe

    init(probe: CaptureLifetimeProbe) {
        self.probe = probe
    }

    func snapshot() async throws -> DisplayTopologySnapshot {
        await probe.run()
        return DisplayTopologySnapshot(displays: [captureLifetimeDisplay])
    }

    func cursorLocation() async throws -> CGPoint {
        .zero
    }
}

private final class CaptureLifetimeSystem: SystemOperations, @unchecked Sendable {
    private let lock = NSLock()
    private let pid: pid_t
    private let applicationElement: AXUIElement
    private let element: AXUIElement
    private let windows: [(id: CGWindowID, title: String, element: AXUIElement)]
    private let windowFrame: CGRect
    private let windowPreparationProbe: CaptureSynchronousPreparationProbe?
    private var elementBounds: CGRect
    private var elementParent: AXUIElement?

    init(
        pid: pid_t,
        windows: [(CGWindowID, String)],
        element: AXUIElement,
        windowFrame: CGRect,
        elementBounds: CGRect,
        windowPreparationProbe: CaptureSynchronousPreparationProbe?,
    ) {
        self.pid = pid
        applicationElement = AXUIElementCreateApplication(pid)
        self.element = element
        let windowElements = windows.map { window in
            (
                id: window.0,
                title: window.1,
                element: AXUIElementCreateApplication(pid_t(window.0)),
            )
        }
        self.windows = windowElements
        self.windowFrame = windowFrame
        self.windowPreparationProbe = windowPreparationProbe
        self.elementBounds = elementBounds
        elementParent = windowElements.first?.element
    }

    func replaceElementBounds(_ bounds: CGRect) {
        lock.lock()
        elementBounds = bounds
        lock.unlock()
    }

    func reparentElementToOtherWindow() {
        lock.lock()
        elementParent = windows.dropFirst().first?.element
        lock.unlock()
    }

    func makeElementParentCycle() {
        lock.lock()
        elementParent = element
        lock.unlock()
    }

    func cgWindowListCopyWindowInfo(
        options _: CGWindowListOption,
        relativeToWindow _: CGWindowID,
    ) -> [[String: Any]] {
        windows.map { window in
            [
                kCGWindowNumber as String: window.id,
                kCGWindowOwnerPID as String: pid,
                kCGWindowBounds as String: [
                    "X": windowFrame.origin.x,
                    "Y": windowFrame.origin.y,
                    "Width": windowFrame.width,
                    "Height": windowFrame.height,
                ],
                kCGWindowName as String: window.title,
                kCGWindowLayer as String: Int32(0),
                kCGWindowIsOnscreen as String: true,
            ]
        }
    }

    func getRunningApplicationBundleID(pid _: pid_t) -> String? {
        "com.example.capture-lifetime"
    }

    func createAXApplication(pid: Int32) -> AnyObject? {
        pid == self.pid ? applicationElement : AXUIElementCreateApplication(pid)
    }

    func copyAXAttribute(element: AnyObject, attribute: String) -> Any? {
        if CFEqual(element, applicationElement) {
            if attribute == kAXWindowsAttribute as String {
                windowPreparationProbe?.run()
                return windows.map(\.element)
            }
            if attribute == kAXHiddenAttribute as String {
                return false
            }
        }
        if let window = windows.first(where: { CFEqual(element, $0.element) }) {
            if attribute == kAXRoleAttribute as String {
                return kAXWindowRole as String
            }
            if attribute == kAXTitleAttribute as String {
                return window.title
            }
            if attribute == kAXMinimizedAttribute as String {
                return false
            }
            if attribute == kAXPositionAttribute as String {
                var position = windowFrame.origin
                return AXValueCreate(.cgPoint, &position)
            }
            if attribute == kAXSizeAttribute as String {
                var size = windowFrame.size
                return AXValueCreate(.cgSize, &size)
            }
        }
        guard CFEqual(element, self.element) else { return nil }
        lock.lock()
        var bounds = elementBounds
        lock.unlock()
        if attribute == kAXPositionAttribute as String {
            return AXValueCreate(.cgPoint, &bounds.origin)
        }
        if attribute == kAXSizeAttribute as String {
            return AXValueCreate(.cgSize, &bounds.size)
        }
        if attribute == kAXParentAttribute as String {
            lock.lock()
            let parent = elementParent
            lock.unlock()
            return parent
        }
        return nil
    }

    func copyAXAttributeResult(element: AnyObject, attribute: String) -> AXAttributeRead {
        if let value = copyAXAttribute(element: element, attribute: attribute) {
            return AXAttributeRead(errorCode: AXError.success.rawValue, value: value)
        }
        if attribute == kAXParentAttribute as String {
            return AXAttributeRead(errorCode: AXError.noValue.rawValue, value: nil)
        }
        return AXAttributeRead(errorCode: Int32.min, value: nil)
    }

    func copyAXMultipleAttributes(element _: AnyObject, attributes _: [String]) -> [String: Any]? {
        nil
    }

    func setAXAttribute(element _: AnyObject, attribute _: String, value _: Any) -> Int32 {
        AXError.cannotComplete.rawValue
    }

    func performAXAction(element _: AnyObject, action _: String) -> Int32 {
        AXError.cannotComplete.rawValue
    }

    func getAXWindowID(element: AnyObject) -> CGWindowID? {
        windows.first(where: { CFEqual(element, $0.element) })?.id
    }

    func getAXElementPID(element: AnyObject) -> AXElementPIDRead {
        if CFEqual(element, applicationElement) ||
            CFEqual(element, self.element) ||
            windows.contains(where: { CFEqual(element, $0.element) })
        {
            return AXElementPIDRead(errorCode: AXError.success.rawValue, pid: pid)
        }
        return AXElementPIDRead(errorCode: AXError.invalidUIElement.rawValue, pid: nil)
    }
}

private actor CaptureLifetimeSink: ScreenshotCapturing {
    private let probe: CaptureLifetimeProbe
    private let imageFault: CaptureImageFault?
    private(set) var invocationCount = 0
    private(set) var lastEncoding: CaptureEncoding?
    private(set) var lastRegion: CGRect?

    init(
        probe: CaptureLifetimeProbe,
        imageFault: CaptureImageFault? = nil,
    ) {
        self.probe = probe
        self.imageFault = imageFault
    }

    func captureDisplay(
        _ display: DisplayTopologyDisplay,
        format: Exactmac_V1_ImageFormat,
        quality: Int32,
        includeOCR _: Bool,
    ) async throws -> ScreenshotCaptureOutput {
        invocationCount += 1
        lastEncoding = CaptureEncoding(format: format, quality: quality)
        await probe.run()
        return try ScreenshotCaptureOutput(
            data: imageData(format: format, width: 2, height: 2),
            format: format,
            pixelWidth: 2,
            pixelHeight: 2,
            displayID: display.displayID,
            logicalFrame: display.frame,
            scale: display.scale,
            ocrResult: .notRequested,
        )
    }

    func captureRegion(
        _ region: CGRect,
        display: DisplayTopologyDisplay,
        format: Exactmac_V1_ImageFormat,
        quality: Int32,
        includeOCR _: Bool,
    ) async throws -> ScreenshotCaptureOutput {
        invocationCount += 1
        lastEncoding = CaptureEncoding(format: format, quality: quality)
        lastRegion = region
        await probe.run()
        let width = Int32(region.width * display.scale)
        let height = Int32(region.height * display.scale)
        return try ScreenshotCaptureOutput(
            data: imageData(
                format: format,
                width: Int(width),
                height: Int(height),
            ),
            format: format,
            pixelWidth: width,
            pixelHeight: height,
            displayID: display.displayID,
            logicalFrame: region,
            scale: display.scale,
            ocrResult: .notRequested,
        )
    }

    func captureWindow(
        _ source: WindowScreenshotCaptureSource,
        format: Exactmac_V1_ImageFormat,
        quality: Int32,
        includeShadow: Bool,
        includeOCR _: Bool,
    ) async throws -> WindowScreenshotCaptureOutput {
        invocationCount += 1
        lastEncoding = CaptureEncoding(format: format, quality: quality)
        await probe.run()
        let width = Int32(source.admittedFrame.width)
        let height = Int32(source.admittedFrame.height)
        return try WindowScreenshotCaptureOutput(
            data: imageData(
                format: format,
                width: Int(width),
                height: Int(height),
            ),
            format: format,
            pixelWidth: width,
            pixelHeight: height,
            sourceName: source.name,
            windowID: source.windowID,
            ownerPID: source.ownerPID,
            windowFrame: source.admittedFrame,
            logicalFrame: source.admittedFrame,
            scale: 1,
            shadowIncluded: includeShadow,
            clipped: false,
            ocrResult: .notRequested,
        )
    }

    private func imageData(
        format: Exactmac_V1_ImageFormat,
        width: Int,
        height: Int,
    ) throws -> Data {
        switch imageFault {
        case nil:
            return try captureLifetimeImageData(
                format: format,
                width: width,
                height: height,
            )
        case .corrupt:
            return Data([0x89, 0x50, 0x4E, 0x47])
        case .truncated:
            let valid = try captureLifetimeImageData(
                format: format,
                width: width,
                height: height,
            )
            return Data(valid.prefix(max(1, valid.count / 2)))
        case .wrongFormat:
            return try captureLifetimeImageData(
                format: format == .png ? .jpeg : .png,
                width: width,
                height: height,
            )
        case .wrongDimensions:
            return try captureLifetimeImageData(
                format: format,
                width: width + 1,
                height: height,
            )
        }
    }
}

private func captureLifetimeImageData(
    format: Exactmac_V1_ImageFormat,
    width: Int,
    height: Int,
) throws -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
    ), let image = context.makeImage()
    else {
        throw CocoaError(.fileWriteUnknown)
    }
    let type: UTType = switch format {
    case .png:
        .png
    case .jpeg:
        .jpeg
    case .tiff:
        .tiff
    case .unspecified, .UNRECOGNIZED:
        throw CocoaError(.fileWriteUnknown)
    }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data,
        type.identifier as CFString,
        1,
        nil,
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return data as Data
}

private actor CaptureLifetimeProbe {
    private let cancellationSignal = CaptureLifetimeCancellationSignal()
    private var entered = false
    private var releaseRequested = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func run() async {
        await withTaskCancellationHandler {
            entered = true
            guard !releaseRequested else { return }
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        } onCancel: { [cancellationSignal] in
            cancellationSignal.record()
        }
    }

    func waitUntilEntered() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: captureLifetimeWaitBudget)
        while !entered {
            guard clock.now < deadline else {
                throw CaptureLifetimeTestError.timeout("capture sink entry")
            }
            // Sleep (not bare yield) so a busy loaded runner still schedules the
            // producer side instead of spinning the waiter to the deadline.
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    func waitUntilCancellationObserved() async throws {
        try await pollCaptureLifetimeCondition("capture cancellation") { [cancellationSignal] in
            cancellationSignal.isRecorded()
        }
    }

    func release() {
        releaseRequested = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private final class CaptureLifetimeCancellationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded = false

    func record() {
        lock.lock()
        recorded = true
        lock.unlock()
    }

    func isRecorded() -> Bool {
        lock.lock()
        let value = recorded
        lock.unlock()
        return value
    }
}

private final class CaptureSynchronousPreparationProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false

    func run() {
        condition.lock()
        entered = true
        condition.broadcast()
        while !released {
            condition.wait()
        }
        condition.unlock()
    }

    func waitUntilEntered() async throws {
        try await pollCaptureLifetimeCondition("window capture preparation") {
            self.isEntered()
        }
    }

    private func isEntered() -> Bool {
        condition.lock()
        let entered = entered
        condition.unlock()
        return entered
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private func withCaptureLifetimeClient(
    _ composition: ExactMacServiceComposition,
    operation: @escaping @Sendable (
        GRPCClient<HTTP2ClientTransport.Posix>,
        @escaping @Sendable () -> Void,
    ) async throws -> Void,
) async throws {
    let socketPath = "/tmp/exactmac-func004-capture-\(UUID().uuidString).sock"
    let serverTransport = HTTP2ServerTransport.Posix(
        address: .unixDomainSocket(path: socketPath),
        transportSecurity: .plaintext,
    )
    let server = GRPCServer(
        transport: productionServerTransport(serverTransport),
        services: [composition.exactMacService],
        interceptors: handlerContractTestInterceptors(),
    )
    let serverTask = Task { try await server.serve() }
    do {
        try await pollCaptureLifetimeCondition("capture server bind") {
            FileManager.default.fileExists(atPath: socketPath)
        }
    } catch {
        server.beginGracefulShutdown()
        _ = await serverTask.result
        try? FileManager.default.removeItem(atPath: socketPath)
        throw error
    }
    let clientTransport: HTTP2ClientTransport.Posix
    do {
        clientTransport = try HTTP2ClientTransport.Posix(
            target: .unixDomainSocket(path: socketPath),
            transportSecurity: .plaintext,
        )
    } catch {
        server.beginGracefulShutdown()
        _ = await serverTask.result
        try? FileManager.default.removeItem(atPath: socketPath)
        throw error
    }
    let client = GRPCClient(transport: clientTransport)
    let connectionTask = Task { try await client.runConnections() }
    var operationError: (any Error)?
    do {
        try await operation(client) {
            connectionTask.cancel()
        }
    } catch {
        operationError = error
    }

    client.beginGracefulShutdown()
    server.beginGracefulShutdown()
    _ = try? await connectionTask.value
    let serverResult = await serverTask.result
    try? FileManager.default.removeItem(atPath: socketPath)
    if let operationError {
        throw operationError
    }
    try serverResult.get()
}

private func captureLifetimeUnary<
    Request: SwiftProtobuf.Message & Sendable,
    Response: SwiftProtobuf.Message & Sendable,
>(
    client: GRPCClient<HTTP2ClientTransport.Posix>,
    request: Request,
    descriptor: MethodDescriptor,
) async throws -> Response {
    try await client.unary(
        request: ClientRequest(message: request),
        descriptor: descriptor,
        serializer: ProtobufSerializer<Request>(),
        deserializer: ProtobufDeserializer<Response>(),
        options: captureLifetimeCallOptions(),
    ) { response in
        try response.message
    }
}

private func expectCaptureLifetimeRPCError(
    _ code: RPCError.Code,
    operation: () async throws -> Void,
) async {
    do {
        try await operation()
        Issue.record("Expected RPC error \(code)")
    } catch let error as RPCError {
        #expect(error.code == code, Comment(rawValue: String(describing: error)))
    } catch {
        Issue.record("Expected RPCError, got \(error)")
    }
}

private func captureLifetimeCall(
    rpc: CaptureLifetimeRPC,
    fixture: CaptureLifetimeFixture,
    client: GRPCClient<HTTP2ClientTransport.Posix>,
    format: Exactmac_V1_ImageFormat = .unspecified,
    quality: Int32 = 0,
) -> Task<Void, any Error> {
    Task {
        switch rpc {
        case .display:
            let _: Exactmac_V1_CaptureScreenshotResponse = try await captureLifetimeUnary(
                client: client,
                request: Exactmac_V1_CaptureScreenshotRequest.with {
                    $0.format = format
                    $0.quality = quality
                },
                descriptor: Exactmac_V1_ExactMac.Method.CaptureScreenshot.descriptor,
            )
        case .region:
            let _: Exactmac_V1_CaptureRegionScreenshotResponse = try await captureLifetimeUnary(
                client: client,
                request: Exactmac_V1_CaptureRegionScreenshotRequest.with {
                    $0.region = captureLifetimeRegion
                    $0.format = format
                    $0.quality = quality
                },
                descriptor: Exactmac_V1_ExactMac.Method.CaptureRegionScreenshot.descriptor,
            )
        case .window:
            let _: Exactmac_V1_CaptureWindowScreenshotResponse = try await captureLifetimeUnary(
                client: client,
                request: Exactmac_V1_CaptureWindowScreenshotRequest.with {
                    $0.window = fixture.windowName
                    $0.format = format
                    $0.quality = quality
                },
                descriptor: Exactmac_V1_ExactMac.Method.CaptureWindowScreenshot.descriptor,
            )
        case .element:
            let _: Exactmac_V1_CaptureElementScreenshotResponse = try await captureLifetimeUnary(
                client: client,
                request: Exactmac_V1_CaptureElementScreenshotRequest.with {
                    $0.parent = fixture.parent
                    $0.elementID = fixture.elementID
                    $0.format = format
                    $0.quality = quality
                },
                descriptor: Exactmac_V1_ExactMac.Method.CaptureElementScreenshot.descriptor,
            )
        }
    }
}

private let captureLifetimeRegion = captureLifetimeRegionMessage(captureLifetimeDisplay.frame)

/// Fail-closed hang budget for condition waits and capture RPCs.
/// Normal completion is near-instant; this only fires when progress has stopped.
/// Sized so a loaded full-suite run (many parallel packages) does not false-timeout.
private let captureLifetimeWaitBudget = Duration.seconds(30)

/// Call options for capture RPCs: wait for the Unix-socket connection instead of
/// failing while the connection is still establishing under load, and bound the
/// overall RPC so a true hang still fails closed.
private func captureLifetimeCallOptions() -> CallOptions {
    var options = CallOptions.defaults
    options.waitForReady = true
    options.timeout = captureLifetimeWaitBudget
    return options
}

private func captureLifetimeRegionMessage(_ frame: CGRect) -> Exactmac_Type_Region {
    Exactmac_Type_Region.with {
        $0.x = frame.origin.x
        $0.y = frame.origin.y
        $0.width = frame.width
        $0.height = frame.height
    }
}

private func pollCaptureLifetimeCondition(
    _ label: String,
    operation: @escaping @Sendable () async -> Bool,
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: captureLifetimeWaitBudget)
    while await !operation() {
        guard clock.now < deadline else {
            throw CaptureLifetimeTestError.timeout(label)
        }
        // Sleep (not bare yield) so a busy loaded runner still schedules the
        // producer side instead of spinning the waiter to the deadline.
        try await Task.sleep(for: .milliseconds(1))
    }
}

private func expectCancelledCapture<Success: Sendable>(_ task: Task<Success, any Error>) async {
    do {
        _ = try await task.value
        Issue.record("Expected cancelled capture task")
    } catch is CancellationError {
        // Expected.
    } catch let error as RPCError {
        #expect(error.code == .cancelled)
    } catch {
        Issue.record("Expected cancellation, got \(error)")
    }
}

private func expectDisconnectedCapture<Success: Sendable>(_ task: Task<Success, any Error>) async {
    do {
        _ = try await task.value
        Issue.record("Expected disconnected capture task")
    } catch let error as RPCError {
        #expect(error.code == .unavailable)
    } catch {
        Issue.record("Expected unavailable after peer disconnect, got \(error)")
    }
}

private enum CaptureLifetimeTestError: Error {
    case missingWindowBinding
    case missingElement
    case timeout(String)
}
