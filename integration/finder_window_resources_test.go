package integration

// This filename intentionally avoids the `_windows_test.go` suffix, which Go
// reserves for Windows-only build selection.

import (
	"context"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
)

type ownedFinderWindow struct {
	resource *pb.Window
	title    string
}

// createOwnedFinderWindow creates a uniquely named Finder window backed by a
// temporary directory, then returns only after that exact window is visible in
// ListWindows. Cleanup closes by the unique title and never terminates Finder.
func createOwnedFinderWindow(
	t *testing.T,
	ctx context.Context,
	client pb.ExactMacClient,
	app *pb.Application,
) (ownedFinderWindow, func()) {
	t.Helper()

	directory, err := os.MkdirTemp(t.TempDir(), "exactmac-window-")
	if err != nil {
		t.Fatalf("Create unique Finder fixture directory: %v", err)
	}
	title := filepath.Base(directory)
	pathLiteral := strconv.Quote(directory)
	titleLiteral := strconv.Quote(title)
	created, err := client.ExecuteAppleScript(ctx, &pb.ExecuteAppleScriptRequest{
		Script: fmt.Sprintf(`set targetFolder to POSIX file %s as alias
tell application "Finder"
	set ownedWindow to make new Finder window
	set target of ownedWindow to targetFolder
	set bounds of ownedWindow to {120, 120, 820, 720}
	activate
	return name of ownedWindow
end tell`, pathLiteral),
	})
	if err != nil {
		t.Fatalf("Create owned Finder window for %q: %v", directory, err)
	}
	if created == nil || !created.GetSuccess() || created.GetError() != "" ||
		created.GetOutput() != title {
		t.Fatalf(
			"Create owned Finder window returned inconsistent result: response=%+v want_title=%q",
			created,
			title,
		)
	}

	cleanup := func() {
		cleanupCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_, cleanupErr := client.ExecuteAppleScript(cleanupCtx, &pb.ExecuteAppleScriptRequest{
			Script: fmt.Sprintf(`tell application "Finder"
	repeat with candidateWindow in (every window whose name is %s)
		close candidateWindow
	end repeat
end tell`, titleLiteral),
		})
		if cleanupErr != nil {
			t.Logf("Cleanup owned Finder window %q: %v", title, cleanupErr)
		}
	}

	completed := false
	defer func() {
		if !completed {
			cleanup()
		}
	}()

	var window *pb.Window
	var lastListError error
	var lastWindows []*pb.Window
	readyCtx, cancelReady := context.WithTimeout(ctx, 10*time.Second)
	defer cancelReady()
	err = PollUntilContext(readyCtx, 100*time.Millisecond, func() (bool, error) {
		resp, listErr := client.ListWindows(readyCtx, &pb.ListWindowsRequest{Parent: app.Name})
		lastListError = listErr
		if listErr != nil {
			return false, nil
		}
		lastWindows = resp.GetWindows()
		for _, candidate := range resp.Windows {
			if candidate != nil && candidate.Title == title && candidate.Bounds != nil &&
				candidate.Bounds.Width > 100 && candidate.Bounds.Height > 100 {
				window = candidate
				return true, nil
			}
		}
		return false, nil
	})
	if err != nil {
		t.Fatalf(
			"Owned Finder window %q never appeared: %v; last_list_error=%v last_windows=%+v",
			title,
			err,
			lastListError,
			lastWindows,
		)
	}

	completed = true
	return ownedFinderWindow{resource: window, title: title}, cleanup
}

// waitForOwnedWindowsAbsent proves that no AX-live window carrying any of the
// owned fixture titles remains reachable through the application. It reconciles
// the CG-vs-AX convergence race that DIRECTIVE documents: after CloseWindow
// succeeds (confirmed absent in the AX tree by waitForWindowDisappearance),
// CGWindowList can retain a stale ghost entry — same title, regenerated
// resource name — that has NO live AX window behind it. Such a ghost is not a
// real window: GetWindow (AX-backed) returns NotFound for it. Listing-only
// queries therefore over-report presence, so the authoritative closure proof
// polls until every same-title candidate is AX-confirmed gone.
//
// The titles are the stable fixture identities (resource IDs regenerate), and
// the parent scopes enumeration to the exact owned application, so unrelated
// Finder state is never mutated or miscounted.
func waitForOwnedWindowsAbsent(
	ctx context.Context,
	client pb.ExactMacClient,
	parent string,
	titles ...string,
) error {
	want := make(map[string]struct{}, len(titles))
	for _, title := range titles {
		want[title] = struct{}{}
	}
	return PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		resp, err := client.ListWindows(ctx, &pb.ListWindowsRequest{Parent: parent})
		if err != nil {
			return false, nil
		}
		for _, candidate := range resp.GetWindows() {
			if candidate == nil {
				continue
			}
			if _, owned := want[candidate.GetTitle()]; !owned {
				continue
			}
			// A same-title CG entry may be a stale ghost with no live AX window.
			// GetWindow is AX-backed: success means the window is genuinely still
			// open; an error means the CG entry is a ghost and cannot count as
			// present. Only an AX-live match keeps this verification waiting.
			if _, getErr := client.GetWindow(ctx, &pb.GetWindowRequest{Name: candidate.GetName()}); getErr == nil {
				return false, nil
			}
		}
		return true, nil
	})
}

// TestFinderWindows_Lifecycle verifies complete window lifecycle using Finder:
// - Open Finder window
// - List windows (verify present)
// - Get window metadata (title, bounds)
// - Move window
// - Verify new position
// - Close window
// - Verify removed from list
func TestFinderWindows_Lifecycle(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	// Start server
	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	// Connect to server
	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewExactMacClient(conn)
	// Open Finder
	t.Log("Opening Finder...")
	app := OpenApplicationObserved(t, ctx, client, "com.apple.finder")

	// Step 1: Create and list an exact owned window. The unique temporary
	// directory title prevents selection or closure of unrelated Finder windows.
	t.Log("Step 1: Creating and listing owned Finder window...")
	ownedWindow, cleanupOwnedWindow := createOwnedFinderWindow(t, ctx, client, app)
	defer cleanupOwnedWindow()
	finderWindow := ownedWindow.resource
	t.Logf("✓ Found Finder window: %s", finderWindow.Name)

	// Step 2: Get window metadata
	t.Log("Step 2: Getting window metadata...")
	getResp, err := client.GetWindow(ctx, &pb.GetWindowRequest{
		Name: finderWindow.Name,
	})
	if err != nil {
		t.Fatalf("GetWindow failed: %v", err)
	}

	initialBounds := getResp.Bounds
	t.Logf("✓ Window title: %s", getResp.Title)
	t.Logf("✓ Window bounds: %.0fx%.0f at (%.0f, %.0f)",
		initialBounds.Width, initialBounds.Height, initialBounds.X, initialBounds.Y)

	// Store window name (may change during mutations due to ID regeneration)
	currentWindowName := finderWindow.Name

	// Step 3: Move window to new position
	// Use distinctive coordinates to avoid conflicts
	targetX := 234.0
	targetY := 156.0
	// Ensure they're different from initial position
	if math.Abs(initialBounds.X-targetX) < 10 {
		targetX = 345.0
	}
	if math.Abs(initialBounds.Y-targetY) < 10 {
		targetY = 267.0
	}

	t.Logf("Step 3: Moving window to (%.0f, %.0f)...", targetX, targetY)
	moveResp, err := client.MoveWindow(ctx, &pb.MoveWindowRequest{
		Name: currentWindowName,
		X:    &targetX,
		Y:    &targetY,
	})
	if err != nil {
		t.Fatalf("MoveWindow failed: %v", err)
	}

	// Update window name if it changed
	if moveResp.Name != currentWindowName {
		t.Logf("Window name changed after move: %s → %s", currentWindowName, moveResp.Name)
		currentWindowName = moveResp.Name
	}
	t.Log("✓ MoveWindow completed")

	// Step 4: Verify new position (state-delta assertion)
	t.Log("Step 4: Verifying new position...")
	var newBounds *pb.Bounds
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		getResp, err := client.GetWindow(ctx, &pb.GetWindowRequest{
			Name: currentWindowName,
		})
		if err != nil {
			// Window ID may have regenerated, try to find it again
			listResp, listErr := client.ListWindows(ctx, &pb.ListWindowsRequest{
				Parent: app.Name,
			})
			if listErr != nil {
				return false, nil
			}
			// Find window near target position
			for _, w := range listResp.Windows {
				if w.Title == ownedWindow.title && w.Bounds != nil {
					if math.Abs(w.Bounds.X-targetX) < 50 && math.Abs(w.Bounds.Y-targetY) < 50 {
						currentWindowName = w.Name
						newBounds = w.Bounds
						return true, nil
					}
				}
			}
			return false, nil
		}

		newBounds = getResp.Bounds
		// Check if position changed toward target (within tolerance)
		xMoved := math.Abs(newBounds.X-targetX) < 50
		yMoved := math.Abs(newBounds.Y-targetY) < 50
		return xMoved && yMoved, nil
	})
	if err != nil {
		t.Errorf("Window did not move to target position: %v", err)
	} else {
		t.Logf("✓ Window at new position: (%.0f, %.0f)", newBounds.X, newBounds.Y)
	}

	// Step 5: Close window
	t.Log("Step 5: Closing window...")
	_, err = client.CloseWindow(ctx, &pb.CloseWindowRequest{
		Name: currentWindowName,
	})
	if err != nil {
		t.Fatalf("CloseWindow failed: %v", err)
	}
	t.Log("✓ CloseWindow completed")

	// Step 6: Verify window removed (state-delta assertion via AX-authoritative
	// truth). Listing-only checks over-report presence because CGWindowList can
	// retain a stale ghost entry after CloseWindow; GetWindow is AX-backed and
	// proves the owned window is genuinely gone. See waitForOwnedWindowsAbsent.
	t.Log("Step 6: Verifying window removed from list...")
	err = waitForOwnedWindowsAbsent(ctx, client, app.Name, ownedWindow.title)
	if err != nil {
		t.Errorf("Window was not removed from list: %v", err)
	} else {
		t.Log("✓ Window removed from list")
	}

	t.Log("Finder window lifecycle test passed ✓")
}

// TestFinderWindows_Resize verifies window resize operation.
func TestFinderWindows_Resize(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	// Start server
	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	// Connect to server
	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewExactMacClient(conn)
	// Open Finder
	t.Log("Opening Finder...")
	app := OpenApplicationObserved(t, ctx, client, "com.apple.finder")

	ownedWindow, cleanupOwnedWindow := createOwnedFinderWindow(t, ctx, client, app)
	defer cleanupOwnedWindow()
	finderWindow := ownedWindow.resource
	t.Logf("Found Finder window: %s (%.0fx%.0f)", finderWindow.Name,
		finderWindow.Bounds.Width, finderWindow.Bounds.Height)

	currentWindowName := finderWindow.Name
	initialWidth := finderWindow.Bounds.Width
	initialHeight := finderWindow.Bounds.Height

	// Calculate target size (different from initial, respecting Finder minimum window width)
	targetWidth := 850.0
	targetHeight := 500.0
	if math.Abs(initialWidth-targetWidth) < 50 {
		targetWidth = 950.0
	}
	if math.Abs(initialHeight-targetHeight) < 50 {
		targetHeight = 600.0
	}

	t.Logf("Resizing window to %.0fx%.0f...", targetWidth, targetHeight)
	resizeResp, err := client.ResizeWindow(ctx, &pb.ResizeWindowRequest{
		Name:   currentWindowName,
		Width:  targetWidth,
		Height: targetHeight,
	})
	if err != nil {
		t.Fatalf("ResizeWindow failed: %v", err)
	}

	// Update window name if changed
	if resizeResp.Name != currentWindowName {
		t.Logf("Window name changed after resize: %s → %s", currentWindowName, resizeResp.Name)
		currentWindowName = resizeResp.Name
	}

	// Verify new size
	t.Log("Verifying new size...")
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		getResp, err := client.GetWindow(ctx, &pb.GetWindowRequest{
			Name: currentWindowName,
		})
		if err != nil {
			return false, nil // Retry
		}

		widthMatch := math.Abs(getResp.Bounds.Width-targetWidth) < 20
		heightMatch := math.Abs(getResp.Bounds.Height-targetHeight) < 20

		t.Logf("Current size: %.0fx%.0f (target: %.0fx%.0f)",
			getResp.Bounds.Width, getResp.Bounds.Height, targetWidth, targetHeight)

		return widthMatch && heightMatch, nil
	})
	if err != nil {
		t.Errorf("Window did not resize to target: %v", err)
	} else {
		t.Log("✓ Window resized successfully")
	}

	// Close only the owned window and prove it disappeared via AX-authoritative
	// truth (waitForOwnedWindowsAbsent reconciles the CG ghost-entry race).
	_, err = client.CloseWindow(ctx, &pb.CloseWindowRequest{Name: currentWindowName})
	if err != nil {
		t.Fatalf("Close owned resized Finder window: %v", err)
	}
	err = waitForOwnedWindowsAbsent(ctx, client, app.Name, ownedWindow.title)
	if err != nil {
		t.Fatalf("Owned resized Finder window remained listed: %v", err)
	}

	t.Log("Finder window resize test passed ✓")
}

// TestFinderWindows_ListMultiple verifies listing multiple windows.
func TestFinderWindows_ListMultiple(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	// Start server
	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	// Connect to server
	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewExactMacClient(conn)
	// Open Finder
	t.Log("Opening Finder...")
	app := OpenApplicationObserved(t, ctx, client, "com.apple.finder")

	// Create two uniquely identifiable windows and leave unrelated Finder state
	// untouched.
	t.Log("Creating first owned Finder window...")
	firstOwned, cleanupFirst := createOwnedFinderWindow(t, ctx, client, app)
	defer cleanupFirst()
	t.Log("Creating second owned Finder window...")
	secondOwned, cleanupSecond := createOwnedFinderWindow(t, ctx, client, app)
	defer cleanupSecond()

	// Wait until both exact owned resources appear in the same listing.
	t.Log("Waiting for both owned windows in one listing...")
	var windows []*pb.Window
	err := PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		resp, err := client.ListWindows(ctx, &pb.ListWindowsRequest{
			Parent: app.Name,
		})
		if err != nil {
			return false, err
		}

		windows = nil
		for _, w := range resp.Windows {
			if w.Title == firstOwned.title || w.Title == secondOwned.title {
				windows = append(windows, w)
			}
		}
		return len(windows) >= 2, nil
	})
	if err != nil {
		t.Fatalf("Did not find both owned windows: found %d, error=%v", len(windows), err)
	}

	t.Logf("✓ Found %d Finder windows", len(windows))
	for i, w := range windows {
		t.Logf("  Window %d: %s at (%.0f, %.0f)", i+1, w.Name, w.Bounds.X, w.Bounds.Y)
	}

	// Close only the two owned windows, then prove both are gone via
	// AX-authoritative truth (waitForOwnedWindowsAbsent reconciles the CG
	// ghost-entry race for each title).
	for _, w := range windows {
		if _, err := client.CloseWindow(ctx, &pb.CloseWindowRequest{Name: w.Name}); err != nil {
			t.Fatalf("Close owned Finder window %q: %v", w.Title, err)
		}
	}
	err = waitForOwnedWindowsAbsent(ctx, client, app.Name, firstOwned.title, secondOwned.title)
	if err != nil {
		t.Fatalf("Owned Finder windows remained listed after close: %v", err)
	}

	t.Log("Finder multiple windows test passed ✓")
}
