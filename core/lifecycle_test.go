package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestQuickSetupPreparesConfigWithoutStartingListeners(t *testing.T) {
	home := os.Getenv("SLCLASH_LIFECYCLE_TEST_HOME")
	if home == "" {
		binary, err := os.Executable()
		if err != nil {
			t.Fatal(err)
		}
		command := exec.Command(binary, "-test.run=^TestQuickSetupPreparesConfigWithoutStartingListeners$")
		command.Env = append(os.Environ(), "SLCLASH_LIFECYCLE_TEST_HOME="+t.TempDir())
		if output, err := command.CombinedOutput(); err != nil {
			t.Fatalf("%v: %s", err, output)
		}
		return
	}
	// Isolate Mihomo's process-wide cache, background tasks and configuration.
	// Process exit closes cache.db before the parent removes its temporary home.
	if err := os.WriteFile(filepath.Join(home, "config.yaml"), []byte("mode: rule\nport: 0\nsocks-port: 0\nmixed-port: 0\n"), 0600); err != nil {
		t.Fatal(err)
	}
	params, err := json.Marshal(InitParams{HomeDir: home})
	if err != nil {
		t.Fatal(err)
	}
	handleStopListener()
	if message := handleQuickSetup(string(params), "{}"); message != "" {
		t.Fatal(message)
	}
	runLock.Lock()
	running := isRunning
	runLock.Unlock()
	if running {
		t.Fatal("config preparation unexpectedly opened listeners")
	}
	if !handleGetIsInit() {
		t.Fatal("config preparation did not initialize core")
	}
	if !handleStartListener() {
		t.Fatal("native start failed")
	}
	if !handleStopListener() {
		t.Fatal("native stop failed")
	}
	runLock.Lock()
	running = isRunning
	runLock.Unlock()
	if running {
		t.Fatal("stop did not clear running flag")
	}
}
