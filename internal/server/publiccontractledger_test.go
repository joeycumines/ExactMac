// Copyright 2026 Joseph Cumines

package server

import (
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"sort"
	"strings"
	"testing"

	longrunningpb "cloud.google.com/go/longrunning/autogen/longrunningpb"
	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
	"google.golang.org/genproto/googleapis/api/annotations"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/types/descriptorpb"
)

// Re-derived because the public contract genuinely changed: the service gained GetGrant,
// ListGrants and PreauthorizeEnvelope, which is a real change to what a caller may ask for
// and not a bookkeeping edit.
const publicContractLedgerDigest = "7d81a1d2d2c7be55776776d2b9fbc68c129caa7fe77a39dedba81f37266285a2"

const (
	publicBoundaryAdmissionProof = "PublicRequestValidationGRPCTests.every descriptor valid public request crosses production validation"
	publicUnknownWireProof       = "PublicRequestValidationGRPCTests.every public request rejects preserved unknown wire fields before side effects"
	publicValidationErrorProof   = "PublicRequestValidationGRPCTests.required fields and real oneofs reject recursively before state or work"
	publicOperationsProof        = "PublicContractBoundaryGRPCTests.all five Operations methods enforce grammar missing resources and producer ownership through grpc"
	publicCollectionProof        = "PublicContractBoundaryGRPCTests.every public collection rejects the legacy query-unbound token family; ServiceCompositionGRPCTests.element resource round trips and rejects a foreign application owner"
	publicStreamProof            = "PublicStreamLifecycleGRPCTests.watch caller cancellation and service drain join the blocked producer; PublicStreamLifecycleGRPCTests.observation caller cancellation producer failure and drain release every owner"
	publicDeferredProof          = "integration.TestFileDialog_FailsClosed"
)

type publicContractRPCRow struct {
	name             string
	provider         string
	lifecycle        string
	successProof     string
	errorProof       string
	behaviorOwner    string
	resourcePolicy   string
	queryPolicy      string
	paginationInputs string
}

type publicContractFieldRow struct {
	rpc               string
	provider          string
	path              string
	disposition       string
	descriptorPolicy  string
	resourceOwnership string
	querySemantics    string
	paginationInputs  string
	lifecycle         string
	successProof      string
	errorProof        string
	behaviorOwner     string
}

func TestPublicContractLedger(t *testing.T) {
	rpcRows, fieldRows := derivePublicContractLedger(t)
	assertPublicContractProofSources(t)
	expectedRPCs, pageCollections := descriptorPublicContractCounts(t)
	if got := len(rpcRows); got != expectedRPCs {
		t.Fatalf("public RPC ledger rows = %d, want descriptor-derived total %d", got, expectedRPCs)
	}

	for _, row := range rpcRows {
		assertCompletePublicRPCRow(t, row)
	}
	if got := len(publicPaginationInputs); got != pageCollections {
		t.Fatalf("pagination policies = %d, want descriptor-derived page collection total %d", got, pageCollections)
	}
	for _, row := range fieldRows {
		assertCompletePublicFieldRow(t, row)
	}
	assertNoStalePublicContractPolicies(t, rpcRows, fieldRows)

	digest := publicContractRowsDigest(rpcRows, fieldRows)
	t.Logf(
		"public contract ledger: rpc_rows=%d field_rows=%d page_collections=%d digest=%s",
		len(rpcRows), len(fieldRows), pageCollections, digest,
	)
	if digest != publicContractLedgerDigest {
		t.Fatalf(
			"public contract ledger drift: rpc_rows=%d field_rows=%d digest=%s want=%s",
			len(rpcRows), len(fieldRows), digest, publicContractLedgerDigest,
		)
	}
}

func TestPublicContractBehaviorOwnersMatchConsolidatedBlueprint(t *testing.T) {
	rpcRows, _ := derivePublicContractLedger(t)
	expectedByProvider := map[string]string{
		"ApplicationMethods.swift": "FUNC-012",
		"WindowMethods.swift":      "FUNC-004/W1",
		"CaptureMethods.swift":     "FUNC-004/W1",
		"DisplayMethods.swift":     "FUNC-004/W1",
		"InputMethods.swift":       "FUNC-004/W2",
		"ElementMethods.swift":     "FUNC-004/W3",
		"ObservationMethods.swift": "FUNC-004/W3",
		"SessionMethods.swift":     "FUNC-004/W3",
		"ClipboardMethods.swift":   "FUNC-004/W4",
		"FileDialogMethods.swift":  "FUNC-004/W4",
		"MacroMethods.swift":       "FUNC-004/W4",
		"ScriptingMethods.swift":   "FUNC-004/W4",
	}
	applicationRows := 0
	for _, row := range rpcRows {
		expected := "FUNC-003"
		if owner, ok := expectedByProvider[row.provider]; ok {
			expected = owner
		}
		if row.behaviorOwner != expected {
			t.Errorf("%s owner = %q, want %q for %s", row.name, row.behaviorOwner, expected, row.provider)
		}
		if row.behaviorOwner == "FUNC-012" {
			applicationRows++
			if row.provider != "ApplicationMethods.swift" {
				t.Errorf("non-application provider %s assigned to FUNC-012", row.provider)
			}
		}
	}
	if applicationRows != 7 {
		t.Errorf("FUNC-012 application RPC rows = %d, want 7", applicationRows)
	}
}

func assertNoStalePublicContractPolicies(
	t *testing.T,
	rpcRows []publicContractRPCRow,
	fieldRows []publicContractFieldRow,
) {
	t.Helper()
	rpcs := make(map[string]bool, len(rpcRows))
	fields := make(map[string]bool, len(fieldRows))
	for _, row := range rpcRows {
		rpcs[row.name] = true
	}
	for _, row := range fieldRows {
		fields[row.rpc+":"+row.path] = true
	}
	for field := range rejectedPublicRequestFields {
		if !fields[field] {
			t.Errorf("stale rejected-field policy for %s", field)
		}
	}
	for method := range deferredPublicMethods {
		fullName := "exactmac.v1.ExactMac." + method
		if !rpcs[fullName] {
			t.Errorf("stale deferred-method policy for %s", fullName)
		}
	}
}

func descriptorPublicContractCounts(t *testing.T) (rpcCount int, pageCollectionCount int) {
	t.Helper()
	services := []protoreflect.ServiceDescriptor{
		pb.File_exactmac_v1_exact_mac_proto.Services().ByName("ExactMac"),
		longrunningpb.File_google_longrunning_operations_proto.Services().ByName("Operations"),
	}
	descriptorPageCollections := make(map[string]bool)
	for _, service := range services {
		if service == nil {
			t.Fatal("public contract descriptor is missing a required service")
		}
		rpcCount += service.Methods().Len()
		for index := 0; index < service.Methods().Len(); index++ {
			method := service.Methods().Get(index)
			pageSize := method.Input().Fields().ByName("page_size")
			pageToken := method.Input().Fields().ByName("page_token")
			nextPageToken := method.Output().Fields().ByName("next_page_token")
			if pageSize == nil && pageToken == nil && nextPageToken == nil {
				continue
			}
			if pageSize == nil || pageToken == nil || nextPageToken == nil {
				t.Fatalf("%s has an incomplete pagination contract", method.FullName())
			}
			fullName := string(method.FullName())
			descriptorPageCollections[fullName] = true
			inputs, ok := publicPaginationInputs[fullName]
			if !ok {
				t.Errorf("%s has descriptor pagination without an explicit query-binding policy", fullName)
				continue
			}
			assertPaginationInputsExist(t, method, inputs)
		}
	}
	for fullName := range publicPaginationInputs {
		if !descriptorPageCollections[fullName] {
			t.Errorf("stale pagination policy for non-collection RPC %s", fullName)
		}
	}
	return rpcCount, len(descriptorPageCollections)
}

func assertPaginationInputsExist(
	t *testing.T,
	method protoreflect.MethodDescriptor,
	inputs string,
) {
	t.Helper()
	if inputs == "" || inputs == "<collection>" {
		return
	}
	for input := range strings.SplitSeq(inputs, ",") {
		if method.Input().Fields().ByName(protoreflect.Name(input)) == nil {
			t.Errorf("%s pagination policy references missing request field %s", method.FullName(), input)
		}
	}
}

func derivePublicContractLedger(t *testing.T) ([]publicContractRPCRow, []publicContractFieldRow) {
	t.Helper()
	exactMacContracts := flattenRPCContracts(t)
	explicitFieldDispositions, fixtureErr := loadExplicitPublicFieldDispositions()
	services := []protoreflect.ServiceDescriptor{
		pb.File_exactmac_v1_exact_mac_proto.Services().ByName("ExactMac"),
		longrunningpb.File_google_longrunning_operations_proto.Services().ByName("Operations"),
	}

	var rpcRows []publicContractRPCRow
	var fieldRows []publicContractFieldRow
	for _, service := range services {
		if service == nil {
			t.Fatal("public contract descriptor is missing a required service")
		}
		for index := 0; index < service.Methods().Len(); index++ {
			method := service.Methods().Get(index)
			rpc := publicContractRPCPolicy(t, method, exactMacContracts)
			rpcRows = append(rpcRows, rpc)
			ancestors := map[protoreflect.FullName]bool{method.Input().FullName(): true}
			walkPublicRequestOccurrences(
				method,
				method.Input(),
				nil,
				ancestors,
				rpc,
				explicitFieldDispositions,
				&fieldRows,
			)
		}
	}

	sort.Slice(rpcRows, func(i, j int) bool { return rpcRows[i].name < rpcRows[j].name })
	sort.Slice(fieldRows, func(i, j int) bool {
		if fieldRows[i].rpc == fieldRows[j].rpc {
			return fieldRows[i].path < fieldRows[j].path
		}
		return fieldRows[i].rpc < fieldRows[j].rpc
	})
	if fixtureErr != nil {
		for _, row := range fieldRows {
			if strings.Contains(row.path, "<reserved-") {
				continue
			}
			t.Logf("PUBLIC_FIELD_POLICY|%s:%s|%s", row.rpc, row.path, row.disposition)
		}
		t.Fatalf("load explicit public field-policy fixture: %v", fixtureErr)
	}
	assertExactPublicFieldDispositionCoverage(t, fieldRows, explicitFieldDispositions)
	return rpcRows, fieldRows
}

func loadExplicitPublicFieldDispositions() (map[string]string, error) {
	_, thisFile, _, ok := runtime.Caller(0)
	if !ok {
		return nil, fmt.Errorf("resolve contract-ledger source path")
	}
	fixturePath := filepath.Join(
		filepath.Dir(thisFile),
		"testdata",
		"public_contract_field_policies.txt",
	)
	data, err := os.ReadFile(fixturePath)
	if err != nil {
		return nil, err
	}
	policies := make(map[string]string)
	for lineNumber, rawLine := range strings.Split(string(data), "\n") {
		line := strings.TrimSpace(rawLine)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, disposition, ok := strings.Cut(line, "|")
		if !ok || key == "" || !isPublicFieldDisposition(disposition) {
			return nil, fmt.Errorf("invalid policy fixture line %d: %q", lineNumber+1, rawLine)
		}
		if _, duplicate := policies[key]; duplicate {
			return nil, fmt.Errorf("duplicate policy fixture key on line %d: %s", lineNumber+1, key)
		}
		policies[key] = disposition
	}
	if len(policies) == 0 {
		return nil, fmt.Errorf("explicit public field-policy fixture is empty")
	}
	return policies, nil
}

func assertExactPublicFieldDispositionCoverage(
	t *testing.T,
	fieldRows []publicContractFieldRow,
	policies map[string]string,
) {
	t.Helper()
	liveFields := make(map[string]bool, len(fieldRows))
	for _, row := range fieldRows {
		if strings.Contains(row.path, "<reserved-") {
			continue
		}
		key := row.rpc + ":" + row.path
		liveFields[key] = true
		if row.disposition == "unclassified" {
			t.Errorf("live public request-field occurrence has no explicit policy: %s", key)
		}
		if rejectedPublicRequestFields[key] && row.disposition != "rejected" {
			t.Errorf("known fail-closed field policy is not rejected: %s = %s", key, row.disposition)
		}
		if strings.Contains(row.descriptorPolicy, "output-only") && row.disposition != "output-only" {
			t.Errorf("descriptor output-only field policy is not output-only: %s = %s", key, row.disposition)
		}
	}
	for key := range policies {
		if !liveFields[key] {
			t.Errorf("stale explicit public request-field policy: %s", key)
		}
	}
}

func publicContractRPCPolicy(
	t *testing.T,
	method protoreflect.MethodDescriptor,
	exactMacContracts map[string]rpcContract,
) publicContractRPCRow {
	t.Helper()
	fullName := string(method.FullName())
	provider := "OperationsProvider.swift"
	successProof := publicOperationsProof
	behaviorOwner := "FUNC-003"
	resourcePolicy := "canonical operations/{operation} names; global operation collection ownership"
	queryPolicy := publicRPCQueryPolicy(fullName)

	if method.Parent().FullName() == "exactmac.v1.ExactMac" {
		contract, ok := exactMacContracts[string(method.Name())]
		if !ok {
			t.Fatalf("missing provider contract for %s", method.FullName())
		}
		provider = contract.provider
		behaviorOwner = behaviorCampaignForProvider(provider)
		resourcePolicy = "descriptor resource references plus provider ownership validation"
	}
	successProof = publicBoundarySuccessProof(method, successProof, behaviorOwner)

	lifecycle := "unary"
	if method.IsStreamingServer() || method.IsStreamingClient() {
		lifecycle = "stream"
	} else if method.Parent().FullName() == "exactmac.v1.ExactMac" &&
		method.Output().FullName() == "google.longrunning.Operation" {
		lifecycle = "lro"
	}

	return publicContractRPCRow{
		name:             fullName,
		provider:         provider,
		lifecycle:        lifecycle,
		successProof:     successProof,
		errorProof:       publicBoundaryErrorProof(method),
		behaviorOwner:    behaviorOwner,
		resourcePolicy:   resourcePolicy,
		queryPolicy:      queryPolicy,
		paginationInputs: publicPaginationInputs[fullName],
	}
}

func publicBoundarySuccessProof(
	method protoreflect.MethodDescriptor,
	operationsProof string,
	behaviorOwner string,
) string {
	if method.Parent().FullName() == "google.longrunning.Operations" {
		return publicBoundaryAdmissionProof + "; " + operationsProof
	}
	if method.IsStreamingServer() || method.IsStreamingClient() {
		return publicBoundaryAdmissionProof + "; " + publicStreamProof
	}
	if deferredPublicMethods[string(method.Name())] {
		return publicBoundaryAdmissionProof + "; " + publicDeferredProof +
			"; functional success owned by " + behaviorOwner
	}
	if _, ok := publicPaginationInputs[string(method.FullName())]; ok {
		return publicBoundaryAdmissionProof + "; " + publicCollectionProof +
			"; domain result semantics owned by " + behaviorOwner
	}
	return publicBoundaryAdmissionProof + "; domain success owned by " + behaviorOwner
}

func publicBoundaryErrorProof(method protoreflect.MethodDescriptor) string {
	if method.Parent().FullName() == "google.longrunning.Operations" {
		return publicUnknownWireProof + "; " + publicOperationsProof
	}
	if method.IsStreamingServer() || method.IsStreamingClient() {
		return publicUnknownWireProof + "; " + publicStreamProof
	}
	if _, ok := publicPaginationInputs[string(method.FullName())]; ok {
		return publicUnknownWireProof + "; " + publicCollectionProof
	}
	return publicUnknownWireProof + "; " + publicValidationErrorProof
}

func assertPublicContractProofSources(t *testing.T) {
	t.Helper()
	root := filepath.Join(repositoryDirectory(t), "..", "..")
	proofs := []struct {
		path   string
		needle string
	}{
		{
			path:   "Server/Tests/ExactMacServerTests/PublicRequestValidationGRPCTests.swift",
			needle: "func `every descriptor valid public request crosses production validation`()",
		},
		{
			path:   "Server/Tests/ExactMacServerTests/PublicRequestValidationGRPCTests.swift",
			needle: "func `every public request rejects preserved unknown wire fields before side effects`()",
		},
		{
			path:   "Server/Tests/ExactMacServerTests/PublicRequestValidationGRPCTests.swift",
			needle: "func `required fields and real oneofs reject recursively before state or work`()",
		},
		{
			path:   "Server/Tests/ExactMacServerTests/PublicContractBoundaryGRPCTests.swift",
			needle: "func `all five Operations methods enforce grammar missing resources and producer ownership through grpc`()",
		},
		{
			path:   "Server/Tests/ExactMacServerTests/PublicContractBoundaryGRPCTests.swift",
			needle: "func `every public collection rejects the legacy query-unbound token family`()",
		},
		{
			path:   "Server/Tests/ExactMacServerTests/ServiceCompositionGRPCTests.swift",
			needle: "func `element resource round trips and rejects a foreign application owner`()",
		},
		{
			path:   "Server/Tests/ExactMacServerTests/PublicStreamLifecycleGRPCTests.swift",
			needle: "func `watch caller cancellation and service drain join the blocked producer`()",
		},
		{
			path:   "Server/Tests/ExactMacServerTests/PublicStreamLifecycleGRPCTests.swift",
			needle: "func `observation caller cancellation producer failure and drain release every owner`()",
		},
		{
			path:   "integration/file_dialog_test.go",
			needle: "func TestFileDialog_FailsClosed(",
		},
	}
	for _, proof := range proofs {
		data, err := os.ReadFile(filepath.Join(root, proof.path))
		if err != nil {
			t.Fatalf("read public contract proof source %s: %v", proof.path, err)
		}
		if !strings.Contains(string(data), proof.needle) {
			t.Errorf("public contract proof selector is stale: %s:%s", proof.path, proof.needle)
		}
	}
}

func repositoryDirectory(t *testing.T) string {
	t.Helper()
	_, thisFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot resolve contract-ledger source path")
	}
	return filepath.Dir(thisFile)
}

func walkPublicRequestOccurrences(
	method protoreflect.MethodDescriptor,
	message protoreflect.MessageDescriptor,
	path []protoreflect.FieldDescriptor,
	ancestors map[protoreflect.FullName]bool,
	rpc publicContractRPCRow,
	explicitFieldDispositions map[string]string,
	rows *[]publicContractFieldRow,
) {
	appendReservedRequestRows(method, message, path, rpc, rows)
	for index := 0; index < message.Fields().Len(); index++ {
		field := message.Fields().Get(index)
		fieldPath := append(append([]protoreflect.FieldDescriptor(nil), path...), field)
		*rows = append(*rows, publicContractFieldPolicy(
			method,
			fieldPath,
			rpc,
			explicitFieldDispositions,
		))
		if field.Kind() != protoreflect.MessageKind && field.Kind() != protoreflect.GroupKind {
			continue
		}
		nested := field.Message()
		if ancestors[nested.FullName()] {
			continue
		}
		nextAncestors := make(map[protoreflect.FullName]bool, len(ancestors)+1)
		for name := range ancestors {
			nextAncestors[name] = true
		}
		nextAncestors[nested.FullName()] = true
		walkPublicRequestOccurrences(
			method,
			nested,
			fieldPath,
			nextAncestors,
			rpc,
			explicitFieldDispositions,
			rows,
		)
	}
}

func appendReservedRequestRows(
	method protoreflect.MethodDescriptor,
	message protoreflect.MessageDescriptor,
	path []protoreflect.FieldDescriptor,
	rpc publicContractRPCRow,
	rows *[]publicContractFieldRow,
) {
	prefix := publicFieldPath(path)
	if prefix != "" {
		prefix += "."
	}
	for index := 0; index < message.ReservedNames().Len(); index++ {
		*rows = append(*rows, publicReservedFieldRow(
			method, rpc, prefix+"<reserved-name:"+string(message.ReservedNames().Get(index))+">",
		))
	}
	for index := 0; index < message.ReservedRanges().Len(); index++ {
		reserved := message.ReservedRanges().Get(index)
		*rows = append(*rows, publicReservedFieldRow(
			method,
			rpc,
			fmt.Sprintf("%s<reserved-numbers:%d-%d>", prefix, reserved[0], reserved[1]-1),
		))
	}
}

func publicReservedFieldRow(
	method protoreflect.MethodDescriptor,
	rpc publicContractRPCRow,
	path string,
) publicContractFieldRow {
	return publicContractFieldRow{
		rpc:               string(method.FullName()),
		provider:          rpc.provider,
		path:              path,
		disposition:       "removed/reserved",
		descriptorPolicy:  "removed/reserved",
		resourceOwnership: "not applicable",
		querySemantics:    "preserved wire intent is rejected as unknown",
		paginationInputs:  rpc.paginationInputs,
		lifecycle:         rpc.lifecycle,
		successProof:      rpc.successProof,
		errorProof:        rpc.errorProof,
		behaviorOwner:     rpc.behaviorOwner,
	}
}

func publicContractFieldPolicy(
	method protoreflect.MethodDescriptor,
	path []protoreflect.FieldDescriptor,
	rpc publicContractRPCRow,
	explicitFieldDispositions map[string]string,
) publicContractFieldRow {
	fieldPath := publicFieldPath(path)
	return publicContractFieldRow{
		rpc:               string(method.FullName()),
		provider:          rpc.provider,
		path:              fieldPath,
		disposition:       publicFieldDisposition(method, path, explicitFieldDispositions),
		descriptorPolicy:  publicDescriptorFieldPolicy(path),
		resourceOwnership: publicResourceOwnership(method, path),
		querySemantics:    publicQuerySemantics(string(method.FullName()), fieldPath, rpc.paginationInputs),
		paginationInputs:  rpc.paginationInputs,
		lifecycle:         rpc.lifecycle,
		successProof:      rpc.successProof,
		errorProof:        rpc.errorProof,
		behaviorOwner:     rpc.behaviorOwner,
	}
}

func publicFieldDisposition(
	method protoreflect.MethodDescriptor,
	path []protoreflect.FieldDescriptor,
	explicitFieldDispositions map[string]string,
) string {
	fullPath := string(method.FullName()) + ":" + publicFieldPath(path)
	if explicitFieldDispositions != nil {
		if disposition, ok := explicitFieldDispositions[fullPath]; ok {
			return disposition
		}
		return "unclassified"
	}
	return inferredPublicFieldDisposition(method, path)
}

func inferredPublicFieldDisposition(
	method protoreflect.MethodDescriptor,
	path []protoreflect.FieldDescriptor,
) string {
	fullPath := string(method.FullName()) + ":" + publicFieldPath(path)
	if rejectedPublicRequestFields[fullPath] {
		return "rejected"
	}
	if publicPathHasBehavior(path, annotations.FieldBehavior_OUTPUT_ONLY) {
		return "output-only"
	}
	if strings.HasPrefix(string(method.FullName()), "exactmac.v1.ExactMac.") &&
		deferredPublicMethods[string(method.Name())] {
		return "deliberately deferred"
	}
	if publicFieldHasBehavior(path[len(path)-1], annotations.FieldBehavior_OPTIONAL) {
		return "defaulted"
	}
	return "consumed"
}

func publicDescriptorFieldPolicy(path []protoreflect.FieldDescriptor) string {
	field := path[len(path)-1]
	var policies []string
	for _, behavior := range []struct {
		value annotations.FieldBehavior
		name  string
	}{
		{annotations.FieldBehavior_REQUIRED, "required"},
		{annotations.FieldBehavior_OPTIONAL, "optional"},
		{annotations.FieldBehavior_OUTPUT_ONLY, "output-only"},
		{annotations.FieldBehavior_INPUT_ONLY, "input-only"},
		{annotations.FieldBehavior_IMMUTABLE, "immutable"},
		{annotations.FieldBehavior_IDENTIFIER, "identifier"},
	} {
		if publicFieldHasBehavior(field, behavior.value) {
			policies = append(policies, behavior.name)
		}
	}
	if len(policies) == 0 {
		return "unannotated descriptor field"
	}
	return "descriptor behaviors: " + strings.Join(policies, ",")
}

func publicFieldHasBehavior(field protoreflect.FieldDescriptor, want annotations.FieldBehavior) bool {
	options, ok := field.Options().(*descriptorpb.FieldOptions)
	if !ok || !proto.HasExtension(options, annotations.E_FieldBehavior) {
		return false
	}
	behaviors, ok := proto.GetExtension(options, annotations.E_FieldBehavior).([]annotations.FieldBehavior)
	if !ok {
		return false
	}
	return slices.Contains(behaviors, want)
}

func isPublicFieldDisposition(disposition string) bool {
	switch disposition {
	case "consumed", "defaulted", "rejected", "output-only", "deliberately deferred":
		return true
	default:
		return false
	}
}

func publicPathHasBehavior(path []protoreflect.FieldDescriptor, want annotations.FieldBehavior) bool {
	for _, field := range path {
		options, ok := field.Options().(*descriptorpb.FieldOptions)
		if !ok || !proto.HasExtension(options, annotations.E_FieldBehavior) {
			continue
		}
		behaviors, ok := proto.GetExtension(options, annotations.E_FieldBehavior).([]annotations.FieldBehavior)
		if !ok {
			continue
		}
		if slices.Contains(behaviors, want) {
			return true
		}
	}
	return false
}

func publicResourceOwnership(
	method protoreflect.MethodDescriptor,
	path []protoreflect.FieldDescriptor,
) string {
	for _, field := range slices.Backward(path) {

		if options, ok := field.Options().(*descriptorpb.FieldOptions); ok &&
			proto.HasExtension(options, annotations.E_ResourceReference) {
			reference, _ := proto.GetExtension(options, annotations.E_ResourceReference).(*annotations.ResourceReference)
			if reference != nil {
				resource := reference.GetType()
				if resource == "" {
					resource = "child-type:" + reference.GetChildType()
				}
				return "descriptor reference " + resource + "; exact owner validated before lookup"
			}
		}
		if field.Message() != nil {
			if options, ok := field.Message().Options().(*descriptorpb.MessageOptions); ok &&
				proto.HasExtension(options, annotations.E_Resource) {
				resource, _ := proto.GetExtension(options, annotations.E_Resource).(*annotations.ResourceDescriptor)
				if resource != nil {
					return "nested resource " + resource.GetType() + "; identifiers are request-policy checked"
				}
			}
		}
	}
	if method.Parent().FullName() == "google.longrunning.Operations" &&
		strings.HasSuffix(publicFieldPath(path), "name") {
		return "canonical operations/{operation} global owner"
	}
	return "not a resource-name field"
}

func publicFieldPath(path []protoreflect.FieldDescriptor) string {
	parts := make([]string, len(path))
	for index, field := range path {
		parts[index] = string(field.Name())
	}
	return strings.Join(parts, ".")
}

func behaviorCampaignForProvider(provider string) string {
	switch provider {
	case "ApplicationMethods.swift":
		return "FUNC-012"
	case "WindowMethods.swift", "CaptureMethods.swift", "DisplayMethods.swift":
		return "FUNC-004/W1"
	case "InputMethods.swift":
		return "FUNC-004/W2"
	case "ElementMethods.swift", "ObservationMethods.swift", "SessionMethods.swift":
		return "FUNC-004/W3"
	case "ClipboardMethods.swift", "FileDialogMethods.swift", "MacroMethods.swift", "ScriptingMethods.swift":
		return "FUNC-004/W4"
	default:
		return "FUNC-003"
	}
}

func assertCompletePublicRPCRow(t *testing.T, row publicContractRPCRow) {
	t.Helper()
	if row.name == "" || row.provider == "" || row.lifecycle == "" || row.successProof == "" ||
		row.errorProof == "" || row.behaviorOwner == "" || row.resourcePolicy == "" || row.queryPolicy == "" {
		t.Errorf("incomplete public RPC contract row: %+v", row)
	}
	if !publicProofReferencesExecutableTest(row.successProof) {
		t.Errorf("public RPC success proof has no executable selector: %+v", row)
	}
	if !publicProofReferencesExecutableTest(row.errorProof) {
		t.Errorf("public RPC error proof has no executable selector: %+v", row)
	}
}

func publicProofReferencesExecutableTest(proof string) bool {
	for _, selector := range []string{
		publicBoundaryAdmissionProof,
		publicUnknownWireProof,
		publicValidationErrorProof,
		publicOperationsProof,
		publicCollectionProof,
		publicStreamProof,
		publicDeferredProof,
	} {
		if strings.Contains(proof, selector) {
			return true
		}
	}
	return false
}

func assertCompletePublicFieldRow(t *testing.T, row publicContractFieldRow) {
	t.Helper()
	if row.rpc == "" || row.provider == "" || row.path == "" || row.disposition == "" ||
		row.descriptorPolicy == "" || row.resourceOwnership == "" || row.querySemantics == "" || row.lifecycle == "" ||
		row.successProof == "" || row.errorProof == "" || row.behaviorOwner == "" {
		t.Errorf("incomplete public request-field contract row: %+v", row)
	}
	switch row.disposition {
	case "consumed", "defaulted", "rejected", "output-only", "removed/reserved", "deliberately deferred":
	default:
		t.Errorf("unknown public request-field disposition %q: %+v", row.disposition, row)
	}
}

func publicContractRowsDigest(rpcRows []publicContractRPCRow, fieldRows []publicContractFieldRow) string {
	lines := make([]string, 0, len(rpcRows)+len(fieldRows))
	for _, row := range rpcRows {
		lines = append(lines, fmt.Sprintf(
			"rpc|%s|%s|%s|%s|%s|%s|%s|%s|%s",
			row.name, row.provider, row.lifecycle, row.successProof, row.errorProof,
			row.behaviorOwner, row.resourcePolicy, row.queryPolicy, row.paginationInputs,
		))
	}
	for _, row := range fieldRows {
		lines = append(lines, fmt.Sprintf(
			"field|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s",
			row.rpc, row.provider, row.path, row.disposition, row.resourceOwnership,
			row.descriptorPolicy, row.querySemantics, row.paginationInputs, row.lifecycle, row.successProof,
			row.errorProof, row.behaviorOwner,
		))
	}
	sort.Strings(lines)
	return fmt.Sprintf("%x", sha256.Sum256([]byte(strings.Join(lines, "\n"))))
}

var rejectedPublicRequestFields = map[string]bool{
	"exactmac.v1.ExactMac.CreateInput:input.name":                         true,
	"exactmac.v1.ExactMac.CreateMacro:macro.name":                         true,
	"exactmac.v1.ExactMac.CreateObservation:observation.name":             true,
	"exactmac.v1.ExactMac.CreateSession:session.name":                     true,
	"exactmac.v1.ExactMac.CloseWindow:force":                              true,
	"exactmac.v1.ExactMac.DeleteSession:force":                            true,
	"exactmac.v1.ExactMac.DeleteMacro:force":                              true,
	"exactmac.v1.ExactMac.BeginTransaction:timeout":                       true,
	"google.longrunning.Operations.ListOperations:return_partial_success": true,
}

var deferredPublicMethods = map[string]bool{
	"AutomateOpenFileDialog": true,
	"AutomateSaveFileDialog": true,
}
