// Copyright 2026 Joseph Cumines

package server

import (
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"testing"

	longrunningpb "cloud.google.com/go/longrunning/autogen/longrunningpb"
	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
	"google.golang.org/genproto/googleapis/api/annotations"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protodesc"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/reflect/protoregistry"
	"google.golang.org/protobuf/types/descriptorpb"
)

var expectedPublicQuerySemantics = map[string]string{
	"exactmac.v1.ExactMac.ListApplicationBundles:order_by": "fields=name|display_name|bundle_id|bundle_url; default=name asc; optional direction=desc",
	"exactmac.v1.ExactMac.ListApplicationBundles:filter":   "quoted equality fields=display_name|bundle_id; conjunction=AND; empty=all",
	"exactmac.v1.ExactMac.ListApplications:order_by":       "fields=name|pid|display_name|bundle_id|active; default=name asc; optional direction=desc",
	"exactmac.v1.ExactMac.ListApplications:filter":         "quoted equality fields=display_name|bundle_id; conjunction=AND; empty=all",
	"exactmac.v1.ExactMac.ListInputs:filter":               "state token=PENDING|EXECUTING|COMPLETED|FAILED|CANCELLED; empty=all",
	"exactmac.v1.ExactMac.ListGrants:filter":               "Restrict the listing to grants covering these capability ids, comma-separated. Omit for every capability.",
	"exactmac.v1.ExactMac.GetWindow:read_mask":             "paths=name|title|bounds|visible|layer|bundle_id|*; empty=all; wildcard must be sole path",
	"exactmac.v1.ExactMac.ListWindows:order_by":            "fields=name|title|layer; comma-separated; default=name asc; optional direction=asc|desc; ties=name asc",
	"exactmac.v1.ExactMac.ListWindows:filter":              "clauses=title quoted case-sensitive equality with * wildcard|visible boolean; conjunction=whitespace|AND; empty=all; minimized is unsupported and rejected",
	"exactmac.v1.ExactMac.UpdateMacro:update_mask":         "paths=display_name|description|actions|parameters|tags; empty=replace all mutable fields",
	"google.longrunning.Operations.ListOperations:filter":  "expression=done=true|done=false; empty=all",
}

var expectedPublicQueryDocumentation = map[string][]string{
	"ListApplicationBundlesRequest": {
		"Ordering specification. Supported fields are name, display_name, bundle_id, and bundle_url, optionally followed by \" desc\".",
		"Filter expression. Supported equality fields are display_name and bundle_id; multiple conditions use AND semantics.",
	},
	"ListApplicationsRequest": {
		"Ordering specification. Supported fields are name, pid, display_name, bundle_id, and active, optionally followed by \" desc\".",
		"Filter expression. Supported equality fields are display_name and bundle_id; multiple conditions use AND semantics.",
	},
	"ListInputsRequest": {
		"Filter inputs by state. Valid values: PENDING, EXECUTING, COMPLETED, FAILED, CANCELLED.",
	},
	"GetWindowRequest": {
		"Supported fields: name, title, bounds, visible, layer, bundle_id, or \"*\".",
	},
	"ListWindowsRequest": {
		"Ordering specification. Supported fields are name, title, and layer in a comma-separated list; append \" desc\" for descending order.",
		"Filter expression. Supported clauses are case-sensitive title=\"...\" equality with the * wildcard and visible=true/false; multiple conditions use whitespace or AND semantics.",
	},
	"UpdateMacroRequest": {
		"Supported fields: display_name, description, actions, parameters, and tags. An empty mask replaces all mutable fields.",
	},
	"ListGrantsRequest": {
		"Restrict the listing to grants covering these capability ids, comma-separated. Omit for every capability.",
	},
}

var publicPaginationInputs = map[string]string{
	"exactmac.v1.ExactMac.ListApplicationBundles":  "filter,order_by,view",
	"exactmac.v1.ExactMac.ListApplications":        "filter,order_by,view",
	"exactmac.v1.ExactMac.ListInputs":              "parent,filter",
	"exactmac.v1.ExactMac.FindElements":            "parent,selector,visible_only,cache_bypass",
	"exactmac.v1.ExactMac.FindRegionElements":      "parent,region,selector,cache_bypass",
	"exactmac.v1.ExactMac.ListElements":            "parent",
	"exactmac.v1.ExactMac.ListWindows":             "parent,filter,order_by",
	"exactmac.v1.ExactMac.ListObservations":        "parent",
	"exactmac.v1.ExactMac.ListGrants":              "filter",
	"exactmac.v1.ExactMac.ListSessions":            "",
	"exactmac.v1.ExactMac.ListMacros":              "",
	"exactmac.v1.ExactMac.ListDisplays":            "",
	"google.longrunning.Operations.ListOperations": "name,filter,return_partial_success",
}

func TestPublicQueryPoliciesAreExactAndDocumented(t *testing.T) {
	_, fieldRows := derivePublicContractLedger(t)
	seen := make(map[string]bool, len(expectedPublicQuerySemantics))
	for _, row := range fieldRows {
		topLevel, _, _ := strings.Cut(row.path, ".")
		key := row.rpc + ":" + topLevel
		expected, ok := expectedPublicQuerySemantics[key]
		if isPublicQueryPolicyField(topLevel) && !ok {
			t.Errorf("live query field has no exact policy: %s", key)
			continue
		}
		if !ok {
			continue
		}
		seen[key] = true
		if row.querySemantics != expected {
			t.Errorf("%s query policy = %q, want exact policy %q", key, row.querySemantics, expected)
		}
	}
	for key := range expectedPublicQuerySemantics {
		if !seen[key] {
			t.Errorf("exact query policy does not resolve to a live request field: %s", key)
		}
	}

	_, thisFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot resolve contract-policy source path")
	}
	protoPath := filepath.Join(filepath.Dir(thisFile), "..", "..", "proto", "exactmac", "v1", "exact_mac.proto")
	protoBytes, err := os.ReadFile(protoPath)
	if err != nil {
		t.Fatalf("read public proto contract: %v", err)
	}
	protoSource := string(protoBytes)
	for message, snippets := range expectedPublicQueryDocumentation {
		block := normalizedProtoMessageDocumentation(t, protoSource, message)
		for _, snippet := range snippets {
			if !strings.Contains(block, snippet) {
				t.Errorf("%s documentation is missing exact query policy %q", message, snippet)
			}
		}
	}
}

func TestGeneratedExactMacFileOptionsUseJavaOnly(t *testing.T) {
	expected := map[string]struct {
		javaPackage string
		goPackage   string
	}{
		"exactmac.v1": {
			javaPackage: "io.github.joeycumines.exactmac.v1",
			goPackage:   "github.com/joeycumines/ExactMac/gen/go/exactmac/v1;exactmacpb",
		},
		"exactmac.type": {
			javaPackage: "io.github.joeycumines.exactmac.type",
			goPackage:   "github.com/joeycumines/ExactMac/gen/go/exactmac/type;exactmactypepb",
		},
	}
	seen := make(map[string]int, len(expected))

	protoregistry.GlobalFiles.RangeFiles(func(file protoreflect.FileDescriptor) bool {
		pkg := string(file.Package())
		want, ok := expected[pkg]
		if !ok {
			return true
		}
		seen[pkg]++

		options, ok := file.Options().(*descriptorpb.FileOptions)
		if !ok || options == nil {
			t.Errorf("%s has no generated FileOptions", file.Path())
			return true
		}
		if got := options.GetJavaPackage(); got != want.javaPackage {
			t.Errorf("%s Java package = %q, want %q", file.Path(), got, want.javaPackage)
		}
		if got := options.GetGoPackage(); got != want.goPackage {
			t.Errorf("%s Go package = %q, want %q", file.Path(), got, want.goPackage)
		}
		if !options.GetJavaMultipleFiles() {
			t.Errorf("%s Java multiple_files is not true", file.Path())
		}
		if options.JavaOuterClassname == nil || options.GetJavaOuterClassname() == "" {
			t.Errorf("%s Java outer classname is missing", file.Path())
		}
		if options.CsharpNamespace != nil {
			t.Errorf("%s unexpectedly has a C# namespace option", file.Path())
		}
		if options.PhpNamespace != nil {
			t.Errorf("%s unexpectedly has a PHP namespace option", file.Path())
		}
		if options.PhpMetadataNamespace != nil {
			t.Errorf("%s unexpectedly has a PHP metadata namespace option", file.Path())
		}
		if options.RubyPackage != nil {
			t.Errorf("%s unexpectedly has a Ruby package option", file.Path())
		}
		if options.ObjcClassPrefix != nil {
			t.Errorf("%s unexpectedly has an Objective-C class prefix option", file.Path())
		}
		return true
	})

	if got := seen["exactmac.v1"]; got != 13 {
		t.Errorf("generated exactmac.v1 descriptor count = %d, want 13", got)
	}
	if got := seen["exactmac.type"]; got != 3 {
		t.Errorf("generated exactmac.type descriptor count = %d, want 3", got)
	}
}

func TestGeneratedExactMacDescriptorsMatchSourceDescriptorSet(t *testing.T) {
	_, thisFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot resolve descriptor-test source path")
	}
	descriptorPath := filepath.Join(
		filepath.Dir(thisFile),
		"..", "..", "Server", "Sources", "ExactMacServer", "DescriptorSets", "exactmac_descriptors.pb",
	)
	descriptorBytes, err := os.ReadFile(descriptorPath)
	if err != nil {
		t.Fatalf("read source descriptor set: %v", err)
	}
	var sourceSet descriptorpb.FileDescriptorSet
	if err := proto.Unmarshal(descriptorBytes, &sourceSet); err != nil {
		t.Fatalf("decode source descriptor set: %v", err)
	}
	sourceFiles := make(map[string]*descriptorpb.FileDescriptorProto, len(sourceSet.File))
	for _, file := range sourceSet.File {
		sourceFiles[file.GetName()] = file
	}

	seen := 0
	protoregistry.GlobalFiles.RangeFiles(func(file protoreflect.FileDescriptor) bool {
		if !strings.HasPrefix(string(file.Package()), "exactmac.") {
			return true
		}
		seen++
		source, ok := sourceFiles[file.Path()]
		if !ok {
			t.Errorf("generated descriptor %s is missing from source descriptor set", file.Path())
			return true
		}
		source.SourceCodeInfo = nil
		generated := protodesc.ToFileDescriptorProto(file)
		generated.SourceCodeInfo = nil
		if !proto.Equal(source, generated) {
			t.Errorf("generated descriptor %s differs from source descriptor set", file.Path())
		}
		return true
	})
	if seen != 16 {
		t.Errorf("generated ExactMac descriptor count = %d, want 16", seen)
	}
}

func isPublicQueryPolicyField(field string) bool {
	switch field {
	case "filter", "order_by", "read_mask", "update_mask":
		return true
	default:
		return false
	}
}

func normalizedProtoMessageDocumentation(t *testing.T, source, message string) string {
	t.Helper()
	marker := "message " + message + " {"
	start := strings.Index(source, marker)
	if start < 0 {
		t.Fatalf("public proto is missing %s", marker)
	}
	remainder := source[start+len(marker):]
	before, _, ok := strings.Cut(remainder, "\n}")
	if !ok {
		t.Fatalf("public proto message %s has no closing brace", message)
	}
	return strings.Join(strings.Fields(strings.ReplaceAll(before, "//", " ")), " ")
}

func publicRPCQueryPolicy(rpc string) string {
	prefix := rpc + ":"
	policies := make([]string, 0, 2)
	for key, policy := range expectedPublicQuerySemantics {
		if after, ok := strings.CutPrefix(key, prefix); ok {
			policies = append(policies, after+"="+policy)
		}
	}
	if len(policies) == 0 {
		return "no filter, ordering, or field-mask fields"
	}
	sort.Strings(policies)
	return strings.Join(policies, "; ")
}

func publicQuerySemantics(rpc, path, paginationInputs string) string {
	topLevel, _, _ := strings.Cut(path, ".")
	if policy, ok := expectedPublicQuerySemantics[rpc+":"+topLevel]; ok {
		return policy
	}
	switch topLevel {
	case "page_size":
		return "bounded shared page-size policy excluded from page-token query binding and honored on continuation"
	case "skip":
		return "non-negative pagination control excluded from query binding and added to the token position"
	case "page_token":
		return "opaque authenticated-encrypted token bound to all non-pagination semantic query inputs"
	}
	if paginationInputs != "" && strings.Contains(","+paginationInputs+",", ","+topLevel+",") {
		return "result-shaping input included in page-token query binding"
	}
	return "not a filter/order/mask/pagination field"
}

func TestPublicFieldDispositionFixtureClassifiesRejectedCreateNames(t *testing.T) {
	policies, err := loadExplicitPublicFieldDispositions()
	if err != nil {
		t.Fatalf("load explicit public field dispositions: %v", err)
	}
	for _, field := range []string{
		"exactmac.v1.ExactMac.CreateInput:input.name",
		"exactmac.v1.ExactMac.CreateMacro:macro.name",
		"exactmac.v1.ExactMac.CreateObservation:observation.name",
		"exactmac.v1.ExactMac.CreateSession:session.name",
	} {
		if got := policies[field]; got != "rejected" {
			t.Errorf("%s disposition = %q, want rejected", field, got)
		}
	}
}

func TestInputResourceDescriptorSupportsApplicationAndDesktopWildcard(t *testing.T) {
	message := pb.File_exactmac_v1_input_proto.Messages().ByName("Input")
	if message == nil {
		t.Fatal("Input descriptor is missing")
	}
	options, ok := message.Options().(*descriptorpb.MessageOptions)
	if !ok || !proto.HasExtension(options, annotations.E_Resource) {
		t.Fatal("Input descriptor has no google.api.resource annotation")
	}
	resource, ok := proto.GetExtension(options, annotations.E_Resource).(*annotations.ResourceDescriptor)
	if !ok {
		t.Fatal("Input google.api.resource annotation has an unexpected type")
	}
	want := "applications/{application}/inputs/{input}"
	if len(resource.GetPattern()) != 1 || resource.GetPattern()[0] != want {
		t.Fatalf("Input resource patterns = %v, want exact wildcard-capable pattern %q", resource.GetPattern(), want)
	}
}

func TestPaginationPoliciesCoverEveryCollectionAndExcludePageSize(t *testing.T) {
	_, pageCollections := descriptorPublicContractCounts(t)
	if pageCollections != len(publicPaginationInputs) {
		t.Fatalf(
			"descriptor-derived collection count = %d, policy count = %d",
			pageCollections,
			len(publicPaginationInputs),
		)
	}
	inputs := publicPaginationInputs["exactmac.v1.ExactMac.ListWindows"]
	if strings.Contains(","+inputs+",", ",page_size,") {
		t.Errorf("ListWindows token inputs = %q, page_size must be honored rather than query-bound", inputs)
	}
	for method, inputs := range publicPaginationInputs {
		hasPageSize := strings.Contains(","+inputs+",", ",page_size,")
		hasSkip := strings.Contains(","+inputs+",", ",skip,")
		if hasPageSize || hasSkip {
			t.Errorf("%s token inputs = %q, pagination controls must be excluded from query binding", method, inputs)
		}
	}
}

func TestPaginationPoliciesCoverAllNonPaginationRequestFields(t *testing.T) {
	services := []protoreflect.ServiceDescriptor{
		pb.File_exactmac_v1_exact_mac_proto.Services().ByName("ExactMac"),
		longrunningpb.File_google_longrunning_operations_proto.Services().ByName("Operations"),
	}
	methods := make(map[string]protoreflect.MethodDescriptor)
	for _, service := range services {
		if service == nil {
			t.Fatal("public contract descriptor is missing a required service")
		}
		for index := 0; index < service.Methods().Len(); index++ {
			method := service.Methods().Get(index)
			methods[string(method.FullName())] = method
		}
	}

	for fullName, policy := range publicPaginationInputs {
		t.Run(fullName, func(t *testing.T) {
			method, ok := methods[fullName]
			if !ok {
				t.Fatalf("pagination policy references missing RPC %s", fullName)
			}

			var fields []string
			for index := 0; index < method.Input().Fields().Len(); index++ {
				name := string(method.Input().Fields().Get(index).Name())
				if name != "page_size" && name != "page_token" && name != "skip" {
					fields = append(fields, name)
				}
			}
			sort.Strings(fields)

			var declared []string
			if policy != "" {
				declared = strings.Split(policy, ",")
				sort.Strings(declared)
			}
			if strings.Join(fields, ",") != strings.Join(declared, ",") {
				t.Errorf(
					"non-pagination fields = %q, policy = %q; all semantic request fields must be bound",
					fields,
					declared,
				)
			}
		})
	}
}

func TestWriteClipboardClearExistingIsRemovedAndReserved(t *testing.T) {
	message := pb.File_exactmac_v1_exact_mac_proto.Messages().ByName("WriteClipboardRequest")
	if message == nil {
		t.Fatal("WriteClipboardRequest descriptor is missing")
	}
	if field := message.Fields().ByName("clear_existing"); field != nil {
		t.Fatalf("clear_existing remains live at field %d", field.Number())
	}

	if message.ReservedNames().Len() != 0 || message.ReservedRanges().Len() != 0 {
		t.Error("WriteClipboardRequest must not retain reservations after the final declaration-order contract")
	}

	policies, err := loadExplicitPublicFieldDispositions()
	if err != nil {
		t.Fatalf("load explicit public field dispositions: %v", err)
	}
	if disposition, ok := policies["exactmac.v1.ExactMac.WriteClipboard:clear_existing"]; ok {
		t.Errorf("removed clear_existing remains a live field policy with disposition %q", disposition)
	}
}

func TestPublicContractDigestIncludesDescriptorPolicy(t *testing.T) {
	row := publicContractFieldRow{
		rpc:              "example.Service.Method",
		path:             "field",
		descriptorPolicy: "optional scalar",
	}
	first := publicContractRowsDigest(nil, []publicContractFieldRow{row})
	row.descriptorPolicy = "output-only scalar"
	second := publicContractRowsDigest(nil, []publicContractFieldRow{row})
	if first == second {
		t.Fatal("contract digest ignores descriptorPolicy changes")
	}
}
