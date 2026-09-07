package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/metacubex/mihomo/config"
)

func writeValidationConfig(t *testing.T, contents string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "profile.yaml")
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestHandleValidateConfigUsesRawYamlOnly(t *testing.T) {
	previous := currentConfig
	sentinel := &config.Config{}
	currentConfig = sentinel
	t.Cleanup(func() { currentConfig = previous })

	valid := writeValidationConfig(t, "proxies:\n  - name: direct\n    type: direct\nrules:\n  - MATCH,direct\n")
	if message := handleValidateConfig(valid); message != "" {
		t.Fatalf("valid config rejected: %s", message)
	}
	if currentConfig != sentinel {
		t.Fatal("parse-only validation replaced the active runtime config")
	}

	// Well-formed YAML with an unknown proxy type is saved; ApplyConfig does the
	// semantic check when the profile actually becomes current.
	unknownType := writeValidationConfig(t, "proxies:\n  - name: broken\n    type: definitely-unsupported\nrules:\n  - MATCH,broken\n")
	if message := handleValidateConfig(unknownType); message != "" {
		t.Fatalf("raw YAML with unknown proxy type should be accepted: %s", message)
	}
	if currentConfig != sentinel {
		t.Fatal("raw YAML validation replaced the active runtime config")
	}

	broken := writeValidationConfig(t, "proxies: [unterminated\n")
	if message := handleValidateConfig(broken); message == "" {
		t.Fatal("broken YAML was accepted")
	}
	if currentConfig != sentinel {
		t.Fatal("failed validation replaced the active runtime config")
	}
}

func TestHandleValidateConfigRejectsZeroLengthFile(t *testing.T) {
	path := writeValidationConfig(t, "")
	message := handleValidateConfig(path)
	if message == "" || !strings.Contains(message, "is empty") {
		t.Fatalf("expected empty-file error, got %q", message)
	}
}
