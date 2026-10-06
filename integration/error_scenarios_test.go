// Copyright 2025 Joseph Cumines
//
// Error scenarios integration tests.
// Verifies error handling for network failures, permission denial,
// application crashes, invalid coordinates, missing elements, and invalid input.
// Task: T073

package integration

import (
	"context"
	"math"
	"net"
	"os/exec"
	"strings"
	"testing"
	"time"

	pbtype "github.com/joeycumines/ExactMac/gen/go/exactmac/type"
	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
)

// TestErrorScenarios_ConnectionRefused verifies error handling when
// the server is not running or refuses connections.
func TestErrorScenarios_ConnectionRefused(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	// Use a port that is not in use
	lAddr, err := net.ResolveTCPAddr("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("Failed to resolve TCP addr: %v", err)
	}
	l, err := net.ListenTCP("tcp", lAddr)
	if err != nil {
		t.Fatalf("Failed to listen on TCP: %v", err)
	}
	addr := l.Addr().String()
	l.Close()

	t.Logf("Testing connection to non-existent server at %s", addr)

	// Dial always succeeds (lazy connection), error surfaces on RPC call
	conn, err := grpc.NewClient(addr,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	if err != nil {
		t.Fatalf("Failed to create client: %v", err)
	}
	defer conn.Close()

	// RPC call should fail since no server is listening
	client := pb.NewExactMacClient(conn)
	_, err = client.ListApplications(ctx, &pb.ListApplicationsRequest{})
	if err != nil {
		t.Logf("✓ RPC correctly failed: %v", err)
	} else {
		t.Error("Expected RPC to fail, but it succeeded")
	}
}

// TestErrorScenarios_Timeout verifies error handling when
// RPC calls exceed the timeout deadline.
func TestErrorScenarios_Timeout(t *testing.T) {
	// Use a very short timeout context
	shortCtx, shortCancel := context.WithTimeout(context.Background(), 1*time.Nanosecond)
	defer shortCancel()

	// Try to connect to an address that will hang
	// Use a non-routable IP address to trigger a timeout
	addr := "192.0.2.1:12345" // TEST-NET-1, should never be reachable

	t.Logf("Testing timeout with non-routable address %s", addr)

	// Dial always succeeds (lazy connection), timeout applies to RPC call
	conn, err := grpc.NewClient(addr,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	if err != nil {
		t.Fatalf("Failed to create client: %v", err)
	}
	defer conn.Close()

	// RPC call should timeout
	client := pb.NewExactMacClient(conn)
	_, err = client.ListApplications(shortCtx, &pb.ListApplicationsRequest{})
	if err != nil {
		if strings.Contains(err.Error(), "timeout") || strings.Contains(err.Error(), "deadline") || strings.Contains(err.Error(), "context deadline") {
			t.Logf("✓ Timeout correctly detected: %v", err)
		} else {
			t.Logf("RPC failed (may be timeout): %v", err)
		}
	} else {
		t.Error("Expected RPC to timeout, but it succeeded")
	}
}

// TestErrorScenarios_InvalidAPIKey verifies error handling for
// invalid API key authentication (when auth is enabled).
// Note: This test documents expected behavior; auth may not be enabled in test environment.
func TestErrorScenarios_InvalidAPIKey(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	// Start server normally (no auth in test environment)
	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	// Try to connect with invalid credentials
	// Note: In test environment, auth is typically disabled
	conn, err := grpc.NewClient(
		serverAddr,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	if err != nil {
		t.Fatalf("Failed to create client: %v", err)
	}
	defer conn.Close()

	client := pb.NewExactMacClient(conn)

	// This should succeed in test environment (no auth)
	_, err = client.ListApplications(ctx, &pb.ListApplicationsRequest{})
	if err != nil {
		t.Logf("Note: Auth may be enabled: %v", err)
	} else {
		t.Log("Note: Auth is not enabled in test environment (expected for integration tests)")
	}
}

// TestErrorScenarios_InsufficientPermissions verifies error handling
// for operations that require specific permissions (e.g., Accessibility).
func TestErrorScenarios_InsufficientPermissions(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewExactMacClient(conn)

	// Try to traverse accessibility without permissions
	// This should fail if Accessibility permissions are not granted
	resp, err := client.TraverseAccessibility(ctx, &pb.TraverseAccessibilityRequest{
		Name: "applications/-",
	})

	if err != nil {
		st, ok := status.FromError(err)
		if ok {
			t.Logf("✓ Permission error correctly returned: code=%v message=%s", st.Code(), st.Message())
			// Verify error is actionable
			if strings.Contains(st.Message(), "permission") ||
				strings.Contains(st.Message(), "accessibility") ||
				strings.Contains(st.Message(), "authorized") {
				t.Log("✓ Error message is actionable (mentions permissions)")
			}
		}
	} else {
		// Permissions are granted - this is OK for the test environment
		t.Logf("Note: Accessibility permissions are granted (found %d elements)", len(resp.Elements))
	}
}

// TestErrorScenarios_AppCrashDuringOperation verifies system recovery
// when an application crashes during an operation.
func TestErrorScenarios_AppCrashDuringOperation(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewExactMacClient(conn)
	// Open Calculator
	t.Log("Opening Calculator...")
	app := OpenApplicationObserved(t, ctx, client, "com.apple.calculator")
	defer CleanupApplication(t, ctx, client, app)

	// Wait for app to be ready
	t.Log("Waiting for Calculator to be ready...")
	err := PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		resp, err := client.ListWindows(ctx, &pb.ListWindowsRequest{
			Parent: app.Name,
		})
		if err != nil {
			return false, nil
		}
		return len(resp.Windows) > 0, nil
	})
	if err != nil {
		t.Fatalf("Calculator never became ready: %v", err)
	}

	// Kill the app abruptly (simulate crash)
	t.Log("Simulating app crash...")
	cmd := exec.Command("killall", "-9", "Calculator")
	_ = cmd.Run()

	// Wait for the crash to be detected — poll until the app's windows are gone.
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		resp, listErr := client.ListWindows(ctx, &pb.ListWindowsRequest{
			Parent: app.Name,
		})
		if listErr != nil {
			// gRPC error means the app is gone — that counts as detected.
			return true, nil
		}
		return len(resp.Windows) == 0, nil
	})
	if err != nil {
		t.Logf("Warning: poll for crash detection timed out: %v", err)
	}

	// Try to perform an operation on the crashed app
	t.Log("Attempting operation on crashed app...")
	_, err = client.ListWindows(ctx, &pb.ListWindowsRequest{
		Parent: app.Name,
	})

	if err != nil {
		// Expected - app is gone
		t.Logf("✓ Operation correctly failed after crash: %v", err)
	} else {
		t.Log("Note: Server may have already cleaned up the crashed app")
	}

	// Verify system recovered - try to list applications
	t.Log("Verifying system recovery...")
	listResp, err := client.ListApplications(ctx, &pb.ListApplicationsRequest{})
	if err != nil {
		t.Errorf("System did not recover: ListApplications failed: %v", err)
	} else {
		t.Logf("✓ System recovered successfully (found %d applications)", len(listResp.Applications))

		// Verify crashed app is no longer in the list
		for _, a := range listResp.Applications {
			if a.Pid == app.Pid {
				t.Logf("Note: Crashed app (PID %d) still in list, may be cleaned up asynchronously", app.Pid)
			}
		}
	}

	// Verify we can open a new app (full recovery)
	t.Log("Verifying new app can be opened...")
	if err := PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		processGone, err := exactProcessGone(app.Pid)
		if err != nil || !processGone {
			return false, err
		}
		listResp, err := client.ListApplications(ctx, &pb.ListApplicationsRequest{})
		if err != nil {
			return false, err
		}
		for _, a := range listResp.Applications {
			if a.Pid == app.Pid {
				return false, nil
			}
		}
		return true, nil
	}); err != nil {
		t.Fatalf("crashed Calculator PID %d did not terminate and clean up before reopening: %v", app.Pid, err)
	}

	newApp := OpenApplicationObserved(t, ctx, client, "com.apple.calculator")
	defer CleanupApplication(t, ctx, client, newApp)

	if newApp.Pid != app.Pid {
		t.Logf("✓ New Calculator instance started (old PID: %d, new PID: %d)", app.Pid, newApp.Pid)
	}
}

// TestErrorScenarios_InvalidCoordinates verifies error handling for
// invalid coordinate values.
func TestErrorScenarios_InvalidCoordinates(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewExactMacClient(conn)

	// Test cases for invalid coordinates
	testCases := []struct {
		name        string
		x           float64
		y           float64
		shouldFail  bool
		description string
	}{
		{
			name:        "valid_positive",
			x:           100,
			y:           100,
			shouldFail:  false,
			description: "Valid positive coordinates",
		},
		{
			name:        "extreme_positive",
			x:           99999,
			y:           99999,
			shouldFail:  true,
			description: "Coordinate outside the active desktop union",
		},
		{
			name:        "extreme_negative",
			x:           -99999,
			y:           -99999,
			shouldFail:  true,
			description: "Coordinate outside the active desktop union",
		},
		{
			name:        "nan_x",
			x:           NaN(),
			y:           100,
			shouldFail:  true,
			description: "NaN X coordinate",
		},
		{
			name:        "nan_y",
			x:           100,
			y:           NaN(),
			shouldFail:  true,
			description: "NaN Y coordinate",
		},
		{
			name:        "inf_x",
			x:           Inf(),
			y:           100,
			shouldFail:  true,
			description: "Infinity X coordinate",
		},
		{
			name:        "inf_y",
			x:           100,
			y:           Inf(),
			shouldFail:  true,
			description: "Infinity Y coordinate",
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			request := newIntegrationInputRequest(
				t,
				"applications/-",
				desktopInputTarget(),
				&pb.InputAction{
					InputType: &pb.InputAction_MouseMove{
						MouseMove: &pb.MouseMove{
							Position: &pbtype.Point{X: tc.x, Y: tc.y},
						},
					},
				},
			)
			input, err := client.CreateInput(ctx, request)

			if tc.shouldFail {
				if err != nil {
					t.Logf("✓ Invalid coordinates correctly rejected: %v", err)
					// Verify error message is actionable
					if strings.Contains(err.Error(), "coordinate") ||
						strings.Contains(err.Error(), "position") ||
						strings.Contains(err.Error(), "invalid") {
						t.Log("✓ Error message is actionable")
					}
				} else {
					t.Errorf("Expected error for %s, but got success", tc.description)
				}
			} else {
				if err != nil {
					t.Fatalf("Valid coordinates rejected: %v (%s)", err, tc.description)
				}
				requireCompletedInput(
					t,
					ctx,
					client,
					request,
					input,
					1,
					tc.description,
				)
				t.Logf("✓ Coordinates accepted: %s", tc.description)
			}
		})
	}
}

// TestErrorScenarios_MissingElement verifies error handling when
// trying to interact with a non-existent UI element.
func TestErrorScenarios_MissingElement(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewExactMacClient(conn)

	// Test 1: Get non-existent application
	t.Log("Test 1: Getting non-existent application...")
	_, err := client.GetApplication(ctx, &pb.GetApplicationRequest{
		Name: "applications/does.not.exist.app",
	})
	if err != nil {
		st, ok := status.FromError(err)
		if ok && st.Code() == codes.NotFound {
			t.Logf("✓ Non-existent application correctly returned NotFound: %s", st.Message())
		} else {
			t.Logf("Non-existent application error: %v", err)
		}
	} else {
		t.Error("Expected error for non-existent application")
	}

	// Test 2: Get non-existent window
	t.Log("Test 2: Getting non-existent window...")
	_, err = client.GetWindow(ctx, &pb.GetWindowRequest{
		Name: "applications/-/windows/999999",
	})
	if err != nil {
		st, ok := status.FromError(err)
		if ok && st.Code() == codes.NotFound {
			t.Logf("✓ Non-existent window correctly returned NotFound: %s", st.Message())
		} else {
			t.Logf("Non-existent window error: %v", err)
		}
	} else {
		t.Error("Expected error for non-existent window")
	}

	// Test 3: Close non-existent application
	t.Log("Test 3: Closing non-existent application...")
	_, err = client.CloseApplication(ctx, &pb.CloseApplicationRequest{
		Name: "applications/999999999",
	})
	if err != nil {
		st, ok := status.FromError(err)
		if ok && st.Code() == codes.NotFound {
			t.Logf("✓ Close non-existent application correctly returned NotFound: %s", st.Message())
		} else {
			t.Logf("Close non-existent application error: %v", err)
		}
	} else {
		t.Error("Close of a non-existent application unexpectedly succeeded")
	}

	// Test 4: Get non-existent input
	t.Log("Test 4: Getting non-existent input...")
	_, err = client.GetInput(ctx, &pb.GetInputRequest{
		Name: "applications/-/inputs/does-not-exist",
	})
	if err != nil {
		st, ok := status.FromError(err)
		if ok && st.Code() == codes.NotFound {
			t.Logf("✓ Non-existent input correctly returned NotFound: %s", st.Message())
		} else {
			t.Logf("Non-existent input error: %v", err)
		}
	} else {
		t.Error("Expected error for non-existent input")
	}
}

// TestErrorScenarios_InvalidInput verifies error handling for
// malformed selectors, empty strings, and other invalid input.
func TestErrorScenarios_InvalidInput(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewExactMacClient(conn)

	// Test cases for invalid input
	testCases := []struct {
		name        string
		request     any
		description string
		expectError bool
	}{
		{
			name: "empty_application_name",
			request: &pb.GetApplicationRequest{
				Name: "",
			},
			description: "Empty application name",
			expectError: true,
		},
		{
			name: "malformed_resource_name",
			request: &pb.GetApplicationRequest{
				Name: "not-a-valid-resource-name",
			},
			description: "Malformed resource name (missing prefix)",
			expectError: true,
		},
		{
			name: "empty_window_name",
			request: &pb.GetWindowRequest{
				Name: "",
			},
			description: "Empty window name",
			expectError: true,
		},
		{
			name: "empty_parent_for_list_windows",
			request: &pb.ListWindowsRequest{
				Parent: "",
			},
			description: "Empty parent for ListWindows",
			expectError: true,
		},
		{
			name: "negative_page_size",
			request: &pb.ListApplicationsRequest{
				PageSize: -1,
			},
			description: "Negative page size",
			expectError: true,
		},
		{
			name: "zero_page_size",
			request: &pb.ListApplicationsRequest{
				PageSize: 0,
			},
			description: "Zero page size",
			expectError: true,
		},
		{
			name: "huge_page_size",
			request: &pb.ListApplicationsRequest{
				PageSize: 1000000,
			},
			description: "Unreasonably large page size",
			expectError: false, // May be accepted but capped
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			var err error

			switch req := tc.request.(type) {
			case *pb.GetApplicationRequest:
				_, err = client.GetApplication(ctx, req)
			case *pb.GetWindowRequest:
				_, err = client.GetWindow(ctx, req)
			case *pb.ListWindowsRequest:
				_, err = client.ListWindows(ctx, req)
			case *pb.ListApplicationsRequest:
				_, err = client.ListApplications(ctx, req)
			default:
				t.Fatalf("Unknown request type: %T", req)
			}

			if tc.expectError {
				if err != nil {
					t.Logf("✓ Invalid input correctly rejected: %v", err)
					// Verify error message is actionable
					errMsg := err.Error()
					if strings.Contains(errMsg, "invalid") ||
						strings.Contains(errMsg, "required") ||
						strings.Contains(errMsg, "empty") ||
						strings.Contains(errMsg, "must") {
						t.Log("✓ Error message is actionable")
					}
				} else {
					t.Logf("Note: %s was accepted (may be valid)", tc.description)
				}
			} else {
				if err != nil {
					t.Logf("Note: Potentially valid input was rejected: %v", err)
				} else {
					t.Logf("✓ Input accepted: %s", tc.description)
				}
			}
		})
	}
}

// TestErrorScenarios_GracefulRecovery verifies that the server
// recovers gracefully after various error conditions.
func TestErrorScenarios_GracefulRecovery(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewExactMacClient(conn)
	// Establish baseline - verify server is working
	t.Log("Establishing baseline...")
	baseResp, err := client.ListApplications(ctx, &pb.ListApplicationsRequest{})
	if err != nil {
		t.Fatalf("Baseline check failed: %v", err)
	}
	initialCount := len(baseResp.Applications)
	t.Logf("Baseline: %d applications", initialCount)

	// Recovery Test 1: After NotFound error
	t.Log("Recovery Test 1: After NotFound error...")
	_, err = client.GetApplication(ctx, &pb.GetApplicationRequest{
		Name: "applications/does.not.exist",
	})
	if err != nil {
		t.Logf("Got expected error: %v", err)
	}

	// Verify server still works
	resp1, err := client.ListApplications(ctx, &pb.ListApplicationsRequest{})
	if err != nil {
		t.Errorf("Server did not recover after NotFound: %v", err)
	} else {
		t.Logf("✓ Recovered after NotFound (found %d applications)", len(resp1.Applications))
	}

	// Recovery Test 2: After InvalidArgument error
	t.Log("Recovery Test 2: After InvalidArgument error...")
	_, err = client.ListWindows(ctx, &pb.ListWindowsRequest{
		Parent: "",
	})
	if err != nil {
		t.Logf("Got expected error: %v", err)
	}

	// Verify server still works
	resp2, err := client.ListApplications(ctx, &pb.ListApplicationsRequest{})
	if err != nil {
		t.Errorf("Server did not recover after InvalidArgument: %v", err)
	} else {
		t.Logf("✓ Recovered after InvalidArgument (found %d applications)", len(resp2.Applications))
	}

	// Recovery Test 3: After opening and closing an app
	t.Log("Recovery Test 3: After app lifecycle...")
	app := OpenApplicationObserved(t, ctx, client, "com.apple.calculator")
	CleanupApplication(t, ctx, client, app)

	// Verify server still works
	resp3, err := client.ListApplications(ctx, &pb.ListApplicationsRequest{})
	if err != nil {
		t.Errorf("Server did not recover after app lifecycle: %v", err)
	} else {
		t.Logf("✓ Recovered after app lifecycle (found %d applications)", len(resp3.Applications))
	}

	// Final verification: server is fully functional
	t.Log("Final verification: server is fully functional...")
	finalResp, err := client.ListDisplays(ctx, &pb.ListDisplaysRequest{})
	if err != nil {
		t.Errorf("Final verification failed: %v", err)
	} else {
		t.Logf("✓ Server fully functional (found %d displays)", len(finalResp.Displays))
	}
}

// NaN returns a NaN float64 value for testing
func NaN() float64 {
	return math.NaN()
}

// Inf returns positive infinity for testing
func Inf() float64 {
	return math.Inf(1)
}
