package main

import (
	"github.com/metacubex/mihomo/config"
	"net"
	"testing"
)

func TestAllowLanHotUpdateBothDirections(t *testing.T) {
	previous, running := currentConfig, isRunning
	t.Cleanup(func() { currentConfig, isRunning = previous, running })
	currentConfig = &config.Config{General: &config.General{}}
	isRunning = false // No real sockets in this unit test.
	for _, value := range []bool{true, false, true} {
		updateConfig(&UpdateParams{AllowLan: &value})
		if currentConfig.General.AllowLan != value {
			t.Fatalf("allow-lan hot update: got %v want %v", currentConfig.General.AllowLan, value)
		}
	}
}

func TestHotUpdateReportsOccupiedPort(t *testing.T) {
	occupied, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer occupied.Close()
	port := occupied.Addr().(*net.TCPAddr).Port
	previous, running := currentConfig, isRunning
	currentConfig = &config.Config{General: &config.General{}}
	isRunning = true
	t.Cleanup(func() { stopListeners(); currentConfig, isRunning = previous, running })
	if err := updateConfig(&UpdateParams{MixedPort: &port}); err == nil {
		t.Fatal("occupied listener must fail acknowledgement")
	}
}

func TestDNSListenValidation(t *testing.T) {
	for _, address := range []string{"invalid-address", "127.0.0.1:65536", "::1:1053", "127.0.0.1:http"} {
		if validateDNSListen(address) == nil {
			t.Fatalf("accepted %q", address)
		}
	}
	for _, address := range []string{"127.0.0.1:1053", "[::1]:1053", ":1053"} {
		if err := validateDNSListen(address); err != nil {
			t.Fatal(err)
		}
	}
}
