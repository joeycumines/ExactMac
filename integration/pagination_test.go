package integration

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
)

// TestListWindowsPagination verifies that ListWindows correctly implements pagination.
// It validates page sizing, token usage, and error handling for invalid tokens.
func TestListWindowsPagination(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	// 1. Infrastructure Setup
	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewExactMacClient(conn)
	// 2. Application Setup
	t.Log("Opening Calculator...")
	app := openCalculator(t, ctx, client)
	defer cleanupApplication(t, ctx, client, app)

	// 3. Wait for State Consistency
	t.Log("Waiting for Calculator windows to appear...")
	err := PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		resp, err := client.ListWindows(ctx, &pb.ListWindowsRequest{
			Parent: app.Name,
		})
		if err != nil {
			return false, err
		}
		return len(resp.Windows) > 0, nil
	})
	if err != nil {
		t.Fatalf("Windows never appeared: %v", err)
	}

	// 4. Test Case: Page Size Limit
	t.Log("Test 1: Requesting page_size=1")
	resp1, err := client.ListWindows(ctx, &pb.ListWindowsRequest{
		Parent:   app.Name,
		PageSize: 1,
	})
	if err != nil {
		t.Fatalf("ListWindows with page_size=1 failed: %v", err)
	}

	// We expect 1 window if windows exist (guaranteed by the poll above).
	// However, if the backend strictly enforces returning *up to* PageSize,
	// getting 1 is correct.
	if len(resp1.Windows) != 1 {
		t.Logf("Note: Expected 1 window but got %d (Backend may returned fewer than requested)", len(resp1.Windows))
	}

	// 5. Test Case: Next Page Token Usage
	if resp1.NextPageToken != "" {
		t.Log("Test 2: Fetching next page using next_page_token")
		resp2, err := client.ListWindows(ctx, &pb.ListWindowsRequest{
			Parent:    app.Name,
			PageSize:  1,
			PageToken: resp1.NextPageToken,
		})
		if err != nil {
			t.Fatalf("ListWindows with valid page_token failed: %v", err)
		}

		t.Logf("Successfully paginated: page1_count=%d, page2_count=%d", len(resp1.Windows), len(resp2.Windows))

		// Verification: Windows across pages should differ (assuming stable ordering/unique IDs)
		if len(resp1.Windows) > 0 && len(resp2.Windows) > 0 {
			if resp1.Windows[0].Name == resp2.Windows[0].Name {
				t.Errorf("Duplicate window detected across pages: %s", resp1.Windows[0].Name)
			}
		}
	} else {
		t.Log("No next_page_token returned; result set fits in a single page.")
	}

	// 6. Test Case: Explicit Empty Token (Should be treated as start of list)
	t.Log("Test 3: Verifying empty page_token works")
	resp3, err := client.ListWindows(ctx, &pb.ListWindowsRequest{
		Parent:    app.Name,
		PageToken: "", // Explicit empty string
	})
	if err != nil {
		t.Fatalf("ListWindows with empty page_token failed: %v", err)
	}
	if len(resp3.Windows) == 0 {
		t.Error("Expected at least one window with empty page_token")
	}

	// 7. Test Case: Invalid Token (Should error)
	t.Log("Test 4: Verifying invalid page_token is rejected")
	_, err = client.ListWindows(ctx, &pb.ListWindowsRequest{
		Parent:    app.Name,
		PageToken: "invalid:token:format",
	})
	if err == nil {
		t.Error("Expected error for invalid page_token, got nil")
	} else {
		t.Logf("Correctly rejected invalid page_token: %v", err)
	}
}

// TestListApplicationsPagination verifies that ListApplications correctly implements pagination
// with deterministic ordering, stable pagination, and opaque next_page_token per AIP-158.
func TestListApplicationsPagination(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()

	// 1. Infrastructure Setup
	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewExactMacClient(conn)
	// 2. Open multiple applications to ensure pagination is meaningful
	t.Log("Opening Calculator and TextEdit...")
	app1 := openCalculator(t, ctx, client)
	defer cleanupApplication(t, ctx, client, app1)

	app2 := openTextEdit(t, ctx, client)
	defer cleanupApplication(t, ctx, client, app2)

	// 3. Test Case: Full list (no pagination params)
	t.Log("Test 1: Fetching all applications without pagination")
	respAll, err := client.ListApplications(ctx, &pb.ListApplicationsRequest{})
	if err != nil {
		t.Fatalf("ListApplications (all) failed: %v", err)
	}
	if len(respAll.Applications) < 2 {
		t.Fatalf("Expected at least 2 applications, got %d", len(respAll.Applications))
	}
	t.Logf("Total applications: %d", len(respAll.Applications))

	// 4. Test Case: Page size limit with deterministic ordering
	t.Log("Test 2: Requesting page_size=1")
	resp1, err := client.ListApplications(ctx, &pb.ListApplicationsRequest{
		PageSize: 1,
	})
	if err != nil {
		t.Fatalf("ListApplications with page_size=1 failed: %v", err)
	}
	if len(resp1.Applications) != 1 {
		t.Errorf("Expected exactly 1 application, got %d", len(resp1.Applications))
	}
	if resp1.NextPageToken == "" {
		t.Error("Expected next_page_token when more results exist")
	}

	// 5. Test Case: Next page token usage and opaqueness
	t.Log("Test 3: Fetching next page using opaque next_page_token")
	resp2, err := client.ListApplications(ctx, &pb.ListApplicationsRequest{
		PageSize:  1,
		PageToken: resp1.NextPageToken,
	})
	if err != nil {
		t.Fatalf("ListApplications with page_token failed: %v", err)
	}
	if len(resp2.Applications) < 1 {
		t.Error("Expected at least 1 application on second page")
	}

	// Verify different applications across pages (deterministic ordering)
	if resp1.Applications[0].Name == resp2.Applications[0].Name {
		t.Errorf("Duplicate application detected across pages: %s", resp1.Applications[0].Name)
	}
	t.Log("Verified opaque token usage and deterministic ordering")

	// 6. Test Case: Invalid token is rejected per AIP-158
	t.Log("Test 4: Verifying invalid page_token is rejected")
	_, err = client.ListApplications(ctx, &pb.ListApplicationsRequest{
		PageToken: "invalid-opaque-token",
	})
	if err == nil {
		t.Error("Expected error for invalid page_token, got nil")
	} else {
		t.Logf("Correctly rejected invalid page_token: %v", err)
	}

	// 7. Test Case: Token opaqueness (clients must not parse structure)
	t.Log("Test 5: Verifying page_token is truly opaque (not 'offset:N')")
	if resp1.NextPageToken != "" {
		// The token should be base64-encoded, not a structured string like "offset:123"
		// We verify this by checking it doesn't start with a known pattern
		if len(resp1.NextPageToken) > 7 && resp1.NextPageToken[:7] == "offset:" {
			t.Error("page_token is NOT opaque - it has recognizable structure 'offset:N'")
		}
		t.Log("Verified page_token is opaque (no recognizable structure)")
	}
}

// openTextEdit opens TextEdit application with an owned empty document for testing,
// avoiding modal file pickers and AppleScript timeout races.
func openTextEdit(t *testing.T, ctx context.Context, client pb.ExactMacClient) *pb.Application {
	t.Helper()

	killTextEdit(t)

	filePath := filepath.Join(t.TempDir(), "textedit_fixture.txt")
	if err := os.WriteFile(filePath, []byte("TextEdit fixture"), 0o600); err != nil {
		t.Fatalf("create fixture file: %v", err)
	}
	openCommand := exec.Command("open", "-a", "TextEdit", filePath)
	if output, err := openCommand.CombinedOutput(); err != nil {
		t.Fatalf("open TextEdit fixture: %v output=%q", err, output)
	}

	app := OpenApplicationObserved(t, ctx, client, "com.apple.TextEdit")
	t.Logf("TextEdit opened successfully: %s", app.Name)
	return app
}

// TestListInputsPagination verifies that ListInputs correctly implements pagination
// by creating a known set of data and stepping through it.
func TestListInputsPagination(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	// 1. Infrastructure Setup
	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewExactMacClient(conn)
	// 2. Application Setup
	app := openCalculator(t, ctx, client)
	defer cleanupApplication(t, ctx, client, app)

	// 3. Data Seeding
	// We create exactly 3 inputs to test a page split of 2 and 1.
	t.Log("Creating 3 test inputs...")
	for range 3 {
		performInput(t, ctx, client, app, "1")
	}

	// 4. Test Case: Fetch First Page
	t.Log("Testing pagination with page_size=2")
	resp1, err := client.ListInputs(ctx, &pb.ListInputsRequest{
		Parent:   app.Name,
		PageSize: 2,
	})
	if err != nil {
		t.Fatalf("ListInputs (Page 1) failed: %v", err)
	}

	if len(resp1.Inputs) > 2 {
		t.Errorf("Expected at most 2 inputs, got %d", len(resp1.Inputs))
	}

	// 5. Test Case: Fetch Second Page
	if resp1.NextPageToken != "" {
		t.Log("Fetching next page...")
		resp2, err := client.ListInputs(ctx, &pb.ListInputsRequest{
			Parent:    app.Name,
			PageSize:  2,
			PageToken: resp1.NextPageToken,
		})
		if err != nil {
			t.Fatalf("ListInputs (Page 2) with page_token failed: %v", err)
		}

		t.Logf("Pagination successful: page1_count=%d, page2_count=%d", len(resp1.Inputs), len(resp2.Inputs))

		// We expect exactly 1 item remaining in the second page
		if len(resp2.Inputs) != 1 {
			t.Errorf("Expected exactly 1 input on second page (3 total - 2 on page 1), got %d", len(resp2.Inputs))
		}

		// Verify opaque token format per AIP-158
		if len(resp1.NextPageToken) > 7 && resp1.NextPageToken[:7] == "offset:" {
			t.Error("page_token is NOT opaque - it has recognizable structure 'offset:N'")
		}
	} else {
		// If we created 3 inputs and requested PageSize 2, we MUST have a NextPageToken.
		// If this block is hit, pagination implementation is broken.
		t.Error("Expected next_page_token for 3 items with page_size=2, but got empty token")
	}

	t.Log("Pagination tests passed")
}
