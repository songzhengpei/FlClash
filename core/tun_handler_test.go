//go:build cgo

package main

import (
	"net"
	"testing"

	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/process"
	"github.com/metacubex/mihomo/constant"
	"golang.org/x/sync/semaphore"
)

func TestTunHooksRemainBoundToInstallingHandler(t *testing.T) {
	previousHandler := tunHandler
	previousSocketHook := dialer.DefaultSocketHook
	previousResolver := process.DefaultPackageNameResolver
	defer func() {
		tunHandler = previousHandler
		dialer.DefaultSocketHook = previousSocketHook
		process.DefaultPackageNameResolver = previousResolver
	}()

	handler := &TunHandler{limit: semaphore.NewWeighted(4)}
	tunHandler = handler
	handler.initHook()

	// Simulate stop clearing the global while an outbound connection still owns
	// the resolver function copied from the previous TUN generation.
	tunHandler = nil
	got, err := process.DefaultPackageNameResolver(&constant.Metadata{
		RawSrcAddr: &net.TCPAddr{},
		RawDstAddr: &net.TCPAddr{},
	})
	if err != nil {
		t.Fatalf("resolver returned an error after stop: %v", err)
	}
	if got != "" {
		t.Fatalf("resolver returned %q for a closed handler, want empty", got)
	}
}
