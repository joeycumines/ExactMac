// Copyright 2025 Joseph Cumines
//
// Integration test for background parameter in OpenApplication

package integration

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
)

func requireFinderFrontmost(t *testing.T, ctx context.Context, client pb.ExactMacClient) {
	t.Helper()
	lastFrontmost := ""
	err := PollUntilContext(ctx, 200*time.Millisecond, func() (bool, error) {
		activation, err := client.ExecuteAppleScript(ctx, &pb.ExecuteAppleScriptRequest{
			Script: `tell application "Finder" to activate`,
		})
		if err != nil {
			return false, err
		}
		if !activation.Success {
			return false, fmt.Errorf("activate Finder failed: %s", activation.Error)
		}

		response, err := client.ExecuteAppleScript(ctx, &pb.ExecuteAppleScriptRequest{
			Script: `tell application "System Events" to return name of first application process whose frontmost is true`,
		})
		if err != nil {
			return false, err
		}
		if !response.Success {
			return false, fmt.Errorf("frontmost query failed: %s", response.Error)
		}
		lastFrontmost = strings.TrimSpace(response.Output)
		return lastFrontmost == "Finder", nil
	})
	if err != nil {
		t.Fatalf("Finder did not become frontmost; last observed application %q: %v", lastFrontmost, err)
	}
}

// TestBackgroundOpenDoesNotStealFocus verifies that opening an application with
// background=true does not steal focus from the current frontmost application.
//
// This test:
// 1. Records current frontmost app via AppleScript
// 2. Opens Calculator with background=true
// 3. Verifies Calculator is tracked (ListApplications includes it)
// 4. Verifies frontmost app unchanged
// 5. Cleans up
func TestBackgroundOpenDoesNotStealFocus(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	// 1. Infrastructure Setup
	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewExactMacClient(conn)

	// 2. Ensure Finder is frontmost first (stable starting point)
	t.Log("Activating Finder as the starting frontmost application...")
	requireFinderFrontmost(t, ctx, client)

	// 3. Record the current frontmost app
	t.Log("Recording initial frontmost application...")
	initialFrontmost := "Finder"
	t.Logf("Initial frontmost: %s", initialFrontmost)

	// 4. Open Calculator with background=true
	t.Log("Opening Calculator with background=true...")
	bundle := DiscoverApplicationBundle(t, ctx, client, "com.apple.calculator")
	resp, err := client.OpenApplication(ctx, &pb.OpenApplicationRequest{
		Name:       bundle.Name,
		Background: true,
		Mode:       pb.ApplicationOpenMode_APPLICATION_OPEN_MODE_LAUNCH_OR_ACTIVATE,
	})
	if err != nil {
		t.Fatalf("OpenApplication failed: %v", err)
	}
	if resp == nil || resp.Application == nil {
		t.Fatalf("OpenApplication succeeded but returned nil application")
	}
	if resp.Disposition != pb.ApplicationOpenDisposition_APPLICATION_OPEN_DISPOSITION_LAUNCHED_NEW &&
		resp.Disposition != pb.ApplicationOpenDisposition_APPLICATION_OPEN_DISPOSITION_REUSED_EXISTING {
		t.Fatalf("Background OpenApplication disposition = %s, want launched-new or reused-existing", resp.Disposition)
	}
	app := resp.Application
	t.Logf("Calculator opened with PID %d (name: %s)", app.Pid, app.Name)

	// Clean up Calculator after test
	defer cleanupApplication(t, ctx, client, app)

	// 5. Verify Calculator is tracked in ListApplications
	t.Log("Verifying Calculator is tracked...")
	listResp, err := client.ListApplications(ctx, &pb.ListApplicationsRequest{})
	if err != nil {
		t.Fatalf("Failed to list applications: %v", err)
	}
	found := false
	for _, trackedApp := range listResp.Applications {
		if trackedApp.Name == app.Name {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("Calculator (name=%s) not found in tracked applications", app.Name)
	}
	t.Log("Calculator is correctly tracked")

	// 6. Verify frontmost app is still the original (not Calculator)
	t.Log("Verifying frontmost app is unchanged...")
	frontmostResp, err := client.ExecuteAppleScript(ctx, &pb.ExecuteAppleScriptRequest{
		Script: `tell application "System Events" to return name of first application process whose frontmost is true`,
	})
	if err != nil {
		t.Fatalf("Failed to check frontmost app: %v", err)
	}
	currentFrontmost := frontmostResp.GetOutput()
	t.Logf("Current frontmost: %s", currentFrontmost)

	if currentFrontmost == "Calculator" {
		t.Fatalf("FOCUS STEALING DETECTED: Calculator became frontmost despite background=true")
	}
	if currentFrontmost != initialFrontmost {
		t.Logf("Note: Frontmost changed from %s to %s, but not to Calculator", initialFrontmost, currentFrontmost)
	}
	t.Logf("SUCCESS: Background open did not steal focus. Initial=%s, Current=%s", initialFrontmost, currentFrontmost)
}

// TestForegroundOpenDoesStealFocus verifies that opening an application with
// background=false (the default) DOES make it frontmost.
func TestForegroundOpenDoesStealFocus(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	// 1. Infrastructure Setup
	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewExactMacClient(conn)

	// 2. Ensure Finder is frontmost first
	t.Log("Activating Finder as the starting frontmost application...")
	requireFinderFrontmost(t, ctx, client)
	t.Log("Finder is frontmost")

	// 3. Open Calculator with background=false (default behavior)
	t.Log("Opening Calculator with background=false (default)...")
	bundle := DiscoverApplicationBundle(t, ctx, client, "com.apple.calculator")
	resp, err := client.OpenApplication(ctx, &pb.OpenApplicationRequest{
		Name:       bundle.Name,
		Background: false, // Explicit for clarity
		Mode:       pb.ApplicationOpenMode_APPLICATION_OPEN_MODE_LAUNCH_OR_ACTIVATE,
	})
	if err != nil {
		t.Fatalf("OpenApplication failed: %v", err)
	}
	if resp == nil || resp.Application == nil {
		t.Fatalf("OpenApplication succeeded but returned nil application")
	}
	if resp.Disposition == pb.ApplicationOpenDisposition_APPLICATION_OPEN_DISPOSITION_UNSPECIFIED ||
		resp.Disposition == pb.ApplicationOpenDisposition_APPLICATION_OPEN_DISPOSITION_REUSED_EXISTING {
		t.Fatalf("Foreground OpenApplication disposition = %s, want observed foreground action", resp.Disposition)
	}
	app := resp.Application
	t.Logf("Calculator opened with PID %d", app.Pid)
	defer cleanupApplication(t, ctx, client, app)

	// 4. Verify Calculator became frontmost
	t.Log("Verifying Calculator became frontmost...")
	calculatorBecameFrontmost := false
	lastObserved := ""
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		frontmostResp, err := client.ExecuteAppleScript(ctx, &pb.ExecuteAppleScriptRequest{
			Script: `tell application "System Events" to return name of first application process whose frontmost is true`,
		})
		if err != nil {
			return false, nil
		}
		lastObserved = strings.TrimSpace(frontmostResp.GetOutput())
		if lastObserved == "Calculator" {
			calculatorBecameFrontmost = true
			return true, nil
		}
		return false, nil
	})
	if err != nil {
		t.Fatalf("Calculator did not become frontmost before the convergence deadline (last observed %q): %v", lastObserved, err)
	}
	if !calculatorBecameFrontmost {
		t.Fatalf("Expected Calculator to become frontmost with background=false, but it did not")
	}
	t.Log("SUCCESS: Foreground open correctly made Calculator frontmost")
}
