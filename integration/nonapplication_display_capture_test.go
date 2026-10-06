// Copyright 2026 Joseph Cumines

package integration

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"io"
	"math"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	pbtype "github.com/joeycumines/ExactMac/gen/go/exactmac/type"
	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
	"github.com/joeycumines/ExactMac/internal/integrationfixture"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

const maxDisplayCaptureGRPCReceiveBytes = 1<<31 - 1

func TestMCPDisplayCaptureProductionTransports_StrictBackendTruth(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	grpcAddress, backend, stopBackend := startDisplayCaptureBackend(t)
	defer stopBackend()
	overrides := map[string]string{
		"EXACTMAC_SERVER_TLS":        "false",
		"EXACTMAC_SERVER_CERT_FILE":         "",
		"EXACTMAC_REQUEST_TIMEOUT":          "5",
		"EXACTMAC_CONSENT_TIMEOUT_SECONDS":  "1",
		"MCP_SHELL_COMMANDS_ENABLED":        "false",
	}
	_, baseURL, stopHTTP := startMCPTestServerWithOverrides(t, ctx, grpcAddress, overrides)
	defer stopHTTP()
	_, stdin, stdout, stopStdio := startMCPStdioProcessWithOverrides(t, ctx, grpcAddress, overrides)
	defer stopStdio()

	httpClient := &http.Client{Timeout: 10 * time.Second}
	httpSession := initializeHTTPSession(t, ctx, httpClient, baseURL, 1)
	initializeDisplayCaptureStdio(t, ctx, stdin, stdout)

	for _, transport := range []struct {
		name string
		call func(int, string, map[string]any) productionMCPToolResult
	}{
		{
			name: "http",
			call: func(id int, name string, arguments map[string]any) productionMCPToolResult {
				return callDisplayCaptureHTTP(t, ctx, httpClient, baseURL, httpSession, id, name, arguments)
			},
		},
		{
			name: "stdio",
			call: func(id int, name string, arguments map[string]any) productionMCPToolResult {
				return callDisplayCaptureStdio(t, ctx, stdin, stdout, id, name, arguments)
			},
		},
	} {
		t.Run(transport.name+"/display_truth", func(t *testing.T) {
			display := transport.call(10, "get_display", map[string]any{})
			assertDisplayCaptureToolSuccess(t, display)
			assertToolTextContains(t, display, "displays/17", "scale 1.234375", "(-9.125, 20.875)")
		})
		t.Run(transport.name+"/full_capture", func(t *testing.T) {
			full := transport.call(11, "screenshot", map[string]any{"display": "displays/17"})
			assertScreenshotToolImage(t, full, 79, 79, "displays/17", "scale 1.234375")
		})
		t.Run(transport.name+"/region_capture", func(t *testing.T) {
			region := transport.call(12, "screenshot", map[string]any{
				"display": "displays/17",
				"x":       10.25,
				"y":       20.5,
				"width":   4.0,
				"height":  3.0,
			})
			assertScreenshotToolImage(t, region, 5, 4, "displays/17", "10.25", "20.5")
		})
		t.Run(transport.name+"/cursor_failure", func(t *testing.T) {
			backend.setCursorFailure(true)
			defer backend.setCursorFailure(false)
			cursorFailure := transport.call(13, "get_display", map[string]any{})
			assertDisplayCaptureToolFailure(t, cursorFailure, "cursor permission sentinel")
		})
		t.Run(transport.name+"/invalid_image", func(t *testing.T) {
			backend.setInvalidImage(true)
			defer backend.setInvalidImage(false)
			invalidImage := transport.call(14, "screenshot", map[string]any{"display": "displays/17"})
			assertDisplayCaptureToolFailure(t, invalidImage, "Invalid screenshot response")
			assertNoImageContent(t, invalidImage)
		})
		t.Run(transport.name+"/recovery", func(t *testing.T) {
			recovered := transport.call(15, "screenshot", map[string]any{"display": "displays/17"})
			assertScreenshotToolImage(t, recovered, 79, 79, "displays/17", "scale 1.234375")
		})
	}

	backend.assertRequests(t)
}

func TestDisplayCaptureReleaseSwiftDirectAndProductionTransports(t *testing.T) {
	if external := os.Getenv("INTEGRATION_SERVER_ADDR"); external != "" {
		t.Fatalf("focused display/capture proof requires a fixture-owned release Swift server, got INTEGRATION_SERVER_ADDR=%q", external)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	if serverCmd == nil || serverCmd.Process == nil {
		t.Fatal("startServer did not return an owned release Swift child")
	}

	var (
		conn      *grpc.ClientConn
		stopHTTP  func()
		stopStdio func()
		cleaned   bool
	)
	defer func() {
		if cleaned {
			return
		}
		if stopStdio != nil {
			stopStdio()
		}
		if stopHTTP != nil {
			stopHTTP()
		}
		if conn != nil {
			_ = conn.Close()
		}
		if serverCmd.ProcessState == nil {
			if err := integrationfixture.StopChildGracefully(serverCmd, 15*time.Second); err != nil {
				t.Errorf("fallback graceful Swift cleanup: %v", err)
			}
		}
	}()

	var err error
	conn, err = grpc.NewClient(
		serverAddr,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithDefaultCallOptions(grpc.MaxCallRecvMsgSize(maxDisplayCaptureGRPCReceiveBytes)),
	)
	if err != nil {
		t.Fatalf("construct direct gRPC client: %v", err)
	}
	client := pb.NewExactMacClient(conn)

	listed, err := client.ListDisplays(ctx, &pb.ListDisplaysRequest{PageSize: 1000})
	if err != nil {
		t.Fatalf("ListDisplays direct generated client: %v", err)
	}
	if listed.GetNextPageToken() != "" {
		t.Fatalf("ListDisplays unexpectedly paginated %d physical displays", len(listed.GetDisplays()))
	}
	mainDisplay := requireMainDisplay(t, listed.GetDisplays())
	assertLiveDisplayTruth(t, mainDisplay)

	gotDisplay, err := client.GetDisplay(ctx, &pb.GetDisplayRequest{Name: mainDisplay.GetName()})
	if err != nil {
		t.Fatalf("GetDisplay(%q): %v", mainDisplay.GetName(), err)
	}
	if !proto.Equal(gotDisplay, mainDisplay) {
		t.Fatalf("GetDisplay truth drifted from ListDisplays:\nlist=%+v\nget=%+v", mainDisplay, gotDisplay)
	}

	cursor, err := client.CaptureCursorPosition(ctx, &pb.CaptureCursorPositionRequest{})
	if err != nil {
		t.Fatalf("CaptureCursorPosition: %v", err)
	}
	assertLiveCursorTruth(t, cursor, listed.GetDisplays())

	full, err := client.CaptureScreenshot(ctx, &pb.CaptureScreenshotRequest{
		Display: mainDisplay.GetName(),
		Format:  pb.ImageFormat_IMAGE_FORMAT_PNG,
	})
	if err != nil {
		t.Fatalf("CaptureScreenshot(%q): %v", mainDisplay.GetName(), err)
	}
	assertDirectDisplayCapture(t, full, mainDisplay)

	requestedRegion := liveCaptureRegion(mainDisplay.GetFrame())
	region, err := client.CaptureRegionScreenshot(ctx, &pb.CaptureRegionScreenshotRequest{
		Display: mainDisplay.GetName(),
		Region:  requestedRegion,
		Format:  pb.ImageFormat_IMAGE_FORMAT_PNG,
	})
	if err != nil {
		t.Fatalf("CaptureRegionScreenshot(%q): %v", mainDisplay.GetName(), err)
	}
	assertDirectRegionCapture(t, region, mainDisplay, requestedRegion)

	overrides := map[string]string{
		"EXACTMAC_SERVER_TLS":        "false",
		"EXACTMAC_SERVER_CERT_FILE":  "",
		"EXACTMAC_REQUEST_TIMEOUT":   "135",
		"MCP_SHELL_COMMANDS_ENABLED": "false",
	}
	_, baseURL, httpCleanup := startMCPTestServerWithOverrides(t, ctx, serverAddr, overrides)
	stopHTTP = httpCleanup
	_, stdin, stdout, stdioCleanup := startMCPStdioProcessWithOverrides(t, ctx, serverAddr, overrides)
	stopStdio = stdioCleanup

	httpClient := &http.Client{Timeout: 40 * time.Second}
	httpSession := initializeHTTPSession(t, ctx, httpClient, baseURL, 100)
	initializeDisplayCaptureStdio(t, ctx, stdin, stdout)

	regionArguments := map[string]any{
		"display": mainDisplay.GetName(),
		"x":       requestedRegion.GetX(),
		"y":       requestedRegion.GetY(),
		"width":   requestedRegion.GetWidth(),
		"height":  requestedRegion.GetHeight(),
	}
	for _, transport := range []struct {
		name string
		call func(int, string, map[string]any) productionMCPToolResult
	}{
		{
			name: "http",
			call: func(id int, name string, arguments map[string]any) productionMCPToolResult {
				return callDisplayCaptureHTTP(t, ctx, httpClient, baseURL, httpSession, id, name, arguments)
			},
		},
		{
			name: "stdio",
			call: func(id int, name string, arguments map[string]any) productionMCPToolResult {
				return callDisplayCaptureStdio(t, ctx, stdin, stdout, id, name, arguments)
			},
		},
	} {
		t.Run(transport.name+"/display", func(t *testing.T) {
			displayResult := transport.call(200, "get_display", map[string]any{})
			assertDisplayCaptureToolSuccess(t, displayResult)
			assertToolTextContains(
				t,
				displayResult,
				mainDisplay.GetName(),
				formatExactFloat(mainDisplay.GetScale()),
				formatExactFloat(mainDisplay.GetFrame().GetX()),
				formatExactFloat(mainDisplay.GetVisibleFrame().GetY()),
			)
		})
		t.Run(transport.name+"/full", func(t *testing.T) {
			fullResult := transport.call(201, "screenshot", map[string]any{"display": mainDisplay.GetName()})
			assertLiveScreenshotToolResult(t, fullResult, mainDisplay.GetName(), mainDisplay.GetScale())
		})
		t.Run(transport.name+"/region", func(t *testing.T) {
			regionResult := transport.call(202, "screenshot", regionArguments)
			assertLiveScreenshotToolResult(t, regionResult, mainDisplay.GetName(), region.GetScale())
			assertToolTextContains(
				t,
				regionResult,
				formatExactFloat(region.GetRegion().GetX()),
				formatExactFloat(region.GetRegion().GetY()),
			)
		})
	}

	stopStdio()
	stopStdio = nil
	stopHTTP()
	stopHTTP = nil
	if err := conn.Close(); err != nil {
		t.Errorf("close direct gRPC client: %v", err)
	}
	conn = nil
	if err := integrationfixture.StopChildGracefully(serverCmd, 15*time.Second); err != nil {
		t.Fatalf("gracefully stop release Swift child: %v", err)
	}
	if serverCmd.ProcessState == nil || !serverCmd.ProcessState.Success() {
		t.Fatalf("release Swift child did not exit successfully: %v", serverCmd.ProcessState)
	}
	releaseCtx, releaseCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer releaseCancel()
	if err := waitForPortAvailable(t, releaseCtx, serverAddr); err != nil {
		t.Fatalf("release Swift listener %s was not released: %v", serverAddr, err)
	}
	cleaned = true
}

type displayCaptureBackend struct {
	pb.UnimplementedExactMacServer

	mu             sync.Mutex
	cursorFailure  bool
	invalidImage   bool
	fullRequests   []*pb.CaptureScreenshotRequest
	regionRequests []*pb.CaptureRegionScreenshotRequest
}

func (s *displayCaptureBackend) setCursorFailure(value bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.cursorFailure = value
}

func (s *displayCaptureBackend) setInvalidImage(value bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.invalidImage = value
}

func (s *displayCaptureBackend) ListDisplays(
	context.Context,
	*pb.ListDisplaysRequest,
) (*pb.ListDisplaysResponse, error) {
	return &pb.ListDisplaysResponse{Displays: []*pb.Display{fixtureDisplay()}}, nil
}

func (s *displayCaptureBackend) CaptureCursorPosition(
	context.Context,
	*pb.CaptureCursorPositionRequest,
) (*pb.CaptureCursorPositionResponse, error) {
	s.mu.Lock()
	failure := s.cursorFailure
	s.mu.Unlock()
	if failure {
		return nil, status.Error(codes.PermissionDenied, "cursor permission sentinel")
	}
	return &pb.CaptureCursorPositionResponse{
		X:       -9.125,
		Y:       20.875,
		Display: "displays/17",
	}, nil
}

func (s *displayCaptureBackend) CaptureScreenshot(
	_ context.Context,
	request *pb.CaptureScreenshotRequest,
) (*pb.CaptureScreenshotResponse, error) {
	s.mu.Lock()
	s.fullRequests = append(s.fullRequests, proto.Clone(request).(*pb.CaptureScreenshotRequest))
	invalid := s.invalidImage
	s.mu.Unlock()
	imageData := fixturePNG(79, 79)
	if invalid {
		imageData = []byte("invalid image sentinel")
	}
	return &pb.CaptureScreenshotResponse{
		ImageData: imageData,
		Format:    pb.ImageFormat_IMAGE_FORMAT_PNG,
		Width:     79,
		Height:    79,
		Display:   "displays/17",
		Region:    &pbtype.Region{X: -100.5, Y: -50.25, Width: 64, Height: 64},
		Scale:     1.234375,
	}, nil
}

func (s *displayCaptureBackend) CaptureRegionScreenshot(
	_ context.Context,
	request *pb.CaptureRegionScreenshotRequest,
) (*pb.CaptureRegionScreenshotResponse, error) {
	s.mu.Lock()
	s.regionRequests = append(s.regionRequests, proto.Clone(request).(*pb.CaptureRegionScreenshotRequest))
	invalid := s.invalidImage
	s.mu.Unlock()
	imageData := fixturePNG(5, 4)
	if invalid {
		imageData = []byte("invalid image sentinel")
	}
	return &pb.CaptureRegionScreenshotResponse{
		ImageData: imageData,
		Format:    pb.ImageFormat_IMAGE_FORMAT_PNG,
		Width:     5,
		Height:    4,
		Display:   "displays/17",
		Region:    proto.Clone(request.GetRegion()).(*pbtype.Region),
		Scale:     1.234375,
	}, nil
}

func (s *displayCaptureBackend) assertRequests(t *testing.T) {
	t.Helper()
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.fullRequests) < 6 {
		t.Fatalf("full screenshot requests = %d, want valid, invalid, and recovery through both transports", len(s.fullRequests))
	}
	if len(s.regionRequests) != 2 {
		t.Fatalf("region screenshot requests = %d, want one per transport", len(s.regionRequests))
	}
	for _, request := range s.fullRequests {
		if request.GetDisplay() != "displays/17" ||
			request.GetFormat() != pb.ImageFormat_IMAGE_FORMAT_PNG ||
			request.GetQuality() != 0 {
			t.Fatalf("incoherent full screenshot request: %+v", request)
		}
	}
	for _, request := range s.regionRequests {
		region := request.GetRegion()
		if request.GetDisplay() != "displays/17" ||
			request.GetFormat() != pb.ImageFormat_IMAGE_FORMAT_PNG ||
			request.GetQuality() != 0 ||
			region == nil ||
			region.GetX() != 10.25 ||
			region.GetY() != 20.5 ||
			region.GetWidth() != 4 ||
			region.GetHeight() != 3 {
			t.Fatalf("incoherent region screenshot request: %+v", request)
		}
	}
}

func startDisplayCaptureBackend(t *testing.T) (string, *displayCaptureBackend, func()) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen for display/capture backend: %v", err)
	}
	backend := &displayCaptureBackend{}
	server := grpc.NewServer()
	pb.RegisterExactMacServer(server, backend)
	serveResult := make(chan error, 1)
	go func() {
		serveResult <- server.Serve(listener)
	}()
	var stopOnce sync.Once
	stop := func() {
		stopOnce.Do(func() {
			server.Stop()
			if err := <-serveResult; err != nil && !errors.Is(err, grpc.ErrServerStopped) {
				t.Errorf("stop display/capture backend: %v", err)
			}
		})
	}
	return listener.Addr().String(), backend, stop
}

func fixtureDisplay() *pb.Display {
	return &pb.Display{
		Name:         "displays/17",
		DisplayId:    17,
		Frame:        &pbtype.Region{X: -100.5, Y: -50.25, Width: 300.75, Height: 200.5},
		VisibleFrame: &pbtype.Region{X: -100.125, Y: -49.75, Width: 299.5, Height: 199.25},
		Main:         true,
		Scale:        1.234375,
	}
}

func fixturePNG(width, height int) []byte {
	pixels := image.NewRGBA(image.Rect(0, 0, width, height))
	pixels.Set(0, 0, color.RGBA{R: 1, G: 2, B: 3, A: 255})
	var encoded bytes.Buffer
	if err := png.Encode(&encoded, pixels); err != nil {
		panic(err)
	}
	return encoded.Bytes()
}

func initializeDisplayCaptureStdio(
	t *testing.T,
	ctx context.Context,
	stdin io.Writer,
	stdout *stdioResponsePump,
) {
	t.Helper()
	response, err := sendStdioRequest(ctx, stdin, stdout, validMCPInitializeRequest(1))
	if err != nil || response == nil || response.Error != nil {
		t.Fatalf("initialize display/capture stdio response=%+v error=%v", response, err)
	}
	if err := writeStdioMessage(stdin, map[string]any{
		"jsonrpc": "2.0",
		"method":  "notifications/initialized",
	}); err != nil {
		t.Fatalf("send display/capture stdio initialized notification: %v", err)
	}
}

func callDisplayCaptureHTTP(
	t *testing.T,
	ctx context.Context,
	client *http.Client,
	baseURL string,
	sessionID string,
	id int,
	name string,
	arguments map[string]any,
) productionMCPToolResult {
	t.Helper()
	payload, err := json.Marshal(map[string]any{
		"jsonrpc": "2.0",
		"id":      id,
		"method":  "tools/call",
		"params": map[string]any{
			"name":      name,
			"arguments": arguments,
		},
	})
	if err != nil {
		t.Fatalf("marshal HTTP %s call: %v", name, err)
	}
	response := sendSessionMCP(t, ctx, client, baseURL, http.MethodPost, sessionID, string(payload))
	if response.Err != nil || response.Status != http.StatusOK {
		t.Fatalf("HTTP %s status=%d body=%q error=%v", name, response.Status, response.Body, response.Err)
	}
	var envelope mcpResponse
	if err := json.Unmarshal(response.Body, &envelope); err != nil {
		t.Fatalf("decode HTTP %s envelope %q: %v", name, response.Body, err)
	}
	if envelope.Error != nil || string(envelope.ID) != fmt.Sprint(id) {
		t.Fatalf("HTTP %s envelope=%+v, want correlated tool result", name, envelope)
	}
	return decodeDisplayCaptureToolResult(t, name, envelope.Result)
}

func callDisplayCaptureStdio(
	t *testing.T,
	ctx context.Context,
	stdin io.Writer,
	stdout *stdioResponsePump,
	id int,
	name string,
	arguments map[string]any,
) productionMCPToolResult {
	t.Helper()
	response, err := sendStdioRequest(ctx, stdin, stdout, map[string]any{
		"jsonrpc": "2.0",
		"id":      id,
		"method":  "tools/call",
		"params": map[string]any{
			"name":      name,
			"arguments": arguments,
		},
	})
	if err != nil || response == nil || response.Error != nil || string(response.ID) != fmt.Sprint(id) {
		t.Fatalf("stdio %s response=%+v error=%v, want correlated tool result", name, response, err)
	}
	return decodeDisplayCaptureToolResult(t, name, response.Result)
}

func decodeDisplayCaptureToolResult(t *testing.T, name string, raw json.RawMessage) productionMCPToolResult {
	t.Helper()
	var result productionMCPToolResult
	if err := json.Unmarshal(raw, &result); err != nil {
		t.Fatalf("decode %s result %q: %v", name, raw, err)
	}
	return result
}

func assertDisplayCaptureToolSuccess(t *testing.T, result productionMCPToolResult) {
	t.Helper()
	if result.IsError || len(result.Content) == 0 {
		t.Fatalf("tool result is not a nonempty success: %+v", result)
	}
}

func assertDisplayCaptureToolFailure(t *testing.T, result productionMCPToolResult, expected string) {
	t.Helper()
	if !result.IsError || len(result.Content) == 0 {
		t.Fatalf("tool result is not an explanatory failure: %+v", result)
	}
	assertToolTextContains(t, result, expected)
}

func assertToolTextContains(t *testing.T, result productionMCPToolResult, expected ...string) {
	t.Helper()
	var combined strings.Builder
	for _, content := range result.Content {
		if content.Text != "" {
			combined.WriteString(content.Text)
			combined.WriteByte('\n')
		}
	}
	text := combined.String()
	for _, value := range expected {
		if !strings.Contains(text, value) {
			t.Fatalf("tool text %q does not contain %q", text, value)
		}
	}
}

func assertNoImageContent(t *testing.T, result productionMCPToolResult) {
	t.Helper()
	for _, content := range result.Content {
		if content.Type == "image" || content.Data != "" {
			t.Fatalf("failed tool result leaked image content: %+v", result)
		}
	}
}

func assertScreenshotToolImage(
	t *testing.T,
	result productionMCPToolResult,
	width int,
	height int,
	expectedText ...string,
) {
	t.Helper()
	assertDisplayCaptureToolSuccess(t, result)
	var imageCount int
	for _, content := range result.Content {
		if content.Type != "image" {
			continue
		}
		imageCount++
		if content.MimeType != "image/png" {
			t.Fatalf("image MIME = %q, want image/png", content.MimeType)
		}
		encoded, err := base64.StdEncoding.DecodeString(content.Data)
		if err != nil {
			t.Fatalf("decode image base64: %v", err)
		}
		config, err := png.DecodeConfig(bytes.NewReader(encoded))
		if err != nil {
			t.Fatalf("decode PNG config: %v", err)
		}
		if config.Width != width || config.Height != height {
			t.Fatalf("PNG dimensions = %dx%d, want %dx%d", config.Width, config.Height, width, height)
		}
	}
	if imageCount != 1 {
		t.Fatalf("image content count = %d, want 1: %+v", imageCount, result)
	}
	assertToolTextContains(t, result, expectedText...)
}

func assertLiveDisplayTruth(t *testing.T, display *pb.Display) {
	t.Helper()
	if display == nil ||
		display.GetName() == "" ||
		display.GetDisplayId() <= 0 ||
		!finitePositiveRegion(display.GetFrame()) ||
		!finitePositiveRegion(display.GetVisibleFrame()) ||
		!regionContainsRegion(display.GetFrame(), display.GetVisibleFrame(), 0.001) ||
		math.IsNaN(display.GetScale()) ||
		math.IsInf(display.GetScale(), 0) ||
		display.GetScale() <= 0 {
		t.Fatalf("invalid live display truth: %+v", display)
	}
}

func assertLiveCursorTruth(t *testing.T, cursor *pb.CaptureCursorPositionResponse, displays []*pb.Display) {
	t.Helper()
	if cursor == nil || math.IsNaN(cursor.GetX()) || math.IsInf(cursor.GetX(), 0) ||
		math.IsNaN(cursor.GetY()) || math.IsInf(cursor.GetY(), 0) {
		t.Fatalf("invalid live cursor truth: %+v", cursor)
	}
	for _, display := range displays {
		if display.GetName() != cursor.GetDisplay() {
			continue
		}
		frame := display.GetFrame()
		if cursor.GetX() >= frame.GetX() &&
			cursor.GetX() < frame.GetX()+frame.GetWidth() &&
			cursor.GetY() >= frame.GetY() &&
			cursor.GetY() < frame.GetY()+frame.GetHeight() {
			return
		}
		t.Fatalf("cursor %+v lies outside claimed display %+v", cursor, display)
	}
	t.Fatalf("cursor names unknown display: %+v", cursor)
}

func liveCaptureRegion(frame *pbtype.Region) *pbtype.Region {
	width := math.Min(32, frame.GetWidth()/4)
	height := math.Min(32, frame.GetHeight()/4)
	return &pbtype.Region{
		X:      frame.GetX() + math.Min(16, frame.GetWidth()/8),
		Y:      frame.GetY() + math.Min(16, frame.GetHeight()/8),
		Width:  width,
		Height: height,
	}
}

func assertDirectDisplayCapture(
	t *testing.T,
	response *pb.CaptureScreenshotResponse,
	display *pb.Display,
) {
	t.Helper()
	if response == nil ||
		response.GetDisplay() != display.GetName() ||
		response.GetFormat() != pb.ImageFormat_IMAGE_FORMAT_PNG ||
		!finitePositiveRegion(response.GetRegion()) ||
		!regionContainsRegion(display.GetFrame(), response.GetRegion(), 0.001) {
		t.Fatalf("invalid direct full-display capture: %+v display=%+v", response, display)
	}
	assertDirectPNGTruth(t, response.GetImageData(), response.GetWidth(), response.GetHeight(), response.GetRegion(), response.GetScale())
}

func assertDirectRegionCapture(
	t *testing.T,
	response *pb.CaptureRegionScreenshotResponse,
	display *pb.Display,
	requested *pbtype.Region,
) {
	t.Helper()
	if response == nil ||
		response.GetDisplay() != display.GetName() ||
		response.GetFormat() != pb.ImageFormat_IMAGE_FORMAT_PNG ||
		!finitePositiveRegion(response.GetRegion()) ||
		!regionContainsRegion(response.GetRegion(), requested, 0.001) ||
		!regionContainsRegion(display.GetFrame(), response.GetRegion(), 0.001) {
		t.Fatalf(
			"invalid direct region capture: %+v display=%+v requested=%+v",
			response,
			display,
			requested,
		)
	}
	assertDirectPNGTruth(t, response.GetImageData(), response.GetWidth(), response.GetHeight(), response.GetRegion(), response.GetScale())
}

func assertDirectPNGTruth(
	t *testing.T,
	data []byte,
	width int32,
	height int32,
	region *pbtype.Region,
	scale float64,
) {
	t.Helper()
	config, err := png.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		t.Fatalf("capture is not valid PNG: %v", err)
	}
	if width <= 0 || height <= 0 ||
		config.Width != int(width) ||
		config.Height != int(height) ||
		math.IsNaN(scale) ||
		math.IsInf(scale, 0) ||
		scale <= 0 ||
		math.Abs(float64(width)-region.GetWidth()*scale) >= 1 ||
		math.Abs(float64(height)-region.GetHeight()*scale) >= 1 {
		t.Fatalf(
			"capture pixels/geometry disagree: config=%+v response=%dx%d region=%+v scale=%v",
			config,
			width,
			height,
			region,
			scale,
		)
	}
}

func assertLiveScreenshotToolResult(
	t *testing.T,
	result productionMCPToolResult,
	display string,
	scale float64,
) {
	t.Helper()
	assertDisplayCaptureToolSuccess(t, result)
	var imageCount int
	for _, content := range result.Content {
		if content.Type != "image" {
			continue
		}
		imageCount++
		if content.MimeType != "image/png" {
			t.Fatalf("live screenshot MIME = %q, want image/png", content.MimeType)
		}
		data, err := base64.StdEncoding.DecodeString(content.Data)
		if err != nil {
			t.Fatalf("decode live screenshot base64: %v", err)
		}
		config, err := png.DecodeConfig(bytes.NewReader(data))
		if err != nil || config.Width <= 0 || config.Height <= 0 {
			t.Fatalf("decode live screenshot PNG config=%+v error=%v", config, err)
		}
	}
	if imageCount != 1 {
		t.Fatalf("live screenshot image count = %d, want 1: %+v", imageCount, result)
	}
	assertToolTextContains(t, result, display, formatExactFloat(scale))
}

func formatExactFloat(value float64) string {
	return strconv.FormatFloat(value, 'g', -1, 64)
}
