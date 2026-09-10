package main

import (
	b "bytes"
	"context"
	"core/providerbridge"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/inbound"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/adapter/provider"
	"github.com/metacubex/mihomo/common/batch"
	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	cp "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/hub/route"
	"github.com/metacubex/mihomo/listener"
	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/log"
	rp "github.com/metacubex/mihomo/rules/provider"
	"github.com/metacubex/mihomo/tunnel"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"strconv"
	"sync"
)

var (
	currentConfig          *config.Config
	currentProxyGroupNames []string
	version                = 0
	isRunning              = false
	defaultTestURL         = constant.DefaultTestURL
	runLock                sync.Mutex
	mBatch, _              = batch.New[bool](context.Background(), batch.WithConcurrencyNum[bool](50))
	debugError             = false
)

func getExternalProvidersRaw() map[string]cp.Provider {
	eps := make(map[string]cp.Provider)
	for n, p := range tunnel.Providers() {
		if p.VehicleType() != cp.Compatible {
			eps[n] = p
		}
	}
	for n, p := range tunnel.RuleProviders() {
		if p.VehicleType() != cp.Compatible {
			eps[n] = p
		}
	}
	return eps
}

func toExternalProvider(p cp.Provider) (*ExternalProvider, error) {
	switch p.(type) {
	case *provider.ProxySetProvider:
		psp := p.(*provider.ProxySetProvider)
		return &ExternalProvider{
			Name:             psp.Name(),
			Type:             psp.Type().String(),
			VehicleType:      psp.VehicleType().String(),
			Count:            psp.Count(),
			UpdateAt:         psp.UpdatedAt(),
			Path:             psp.Vehicle().Path(),
			SubscriptionInfo: getProxySetSubscriptionInfo(psp),
		}, nil
	case *rp.RuleSetProvider:
		rsp := p.(*rp.RuleSetProvider)
		return &ExternalProvider{
			Name:        rsp.Name(),
			Type:        rsp.Type().String(),
			VehicleType: rsp.VehicleType().String(),
			Count:       rsp.Count(),
			UpdateAt:    rsp.UpdatedAt(),
			Path:        rsp.Vehicle().Path(),
		}, nil
	default:
		return nil, errors.New("not external provider")
	}
}

func sideUpdateExternalProvider(p cp.Provider, bytes []byte) error {
	return providerbridge.SideUpdateExternalProvider(p, bytes)
}

func updateListeners() {
	if !isRunning {
		return
	}
	if currentConfig == nil {
		return
	}
	listeners := currentConfig.Listeners
	general := currentConfig.General
	listener.PatchInboundListeners(listeners, tunnel.Tunnel, true)

	allowLan := general.AllowLan
	listener.SetAllowLan(allowLan)
	inbound.SetSkipAuthPrefixes(general.SkipAuthPrefixes)
	inbound.SetAllowedIPs(general.LanAllowedIPs)
	inbound.SetDisAllowedIPs(general.LanDisAllowedIPs)

	bindAddress := general.BindAddress
	listener.SetBindAddress(bindAddress)
	listener.ReCreateHTTP(general.Port, tunnel.Tunnel)
	listener.ReCreateSocks(general.SocksPort, tunnel.Tunnel)
	listener.ReCreateRedir(general.RedirPort, tunnel.Tunnel)
	listener.ReCreateTProxy(general.TProxyPort, tunnel.Tunnel)
	listener.ReCreateMixed(general.MixedPort, tunnel.Tunnel)
	listener.ReCreateShadowSocks(general.ShadowSocksConfig, tunnel.Tunnel)
	listener.ReCreateVmess(general.VmessConfig, tunnel.Tunnel)
	listener.ReCreateTuic(general.TuicServer, tunnel.Tunnel)
	if runtime.GOOS != "android" {
		listener.ReCreateTun(general.Tun, tunnel.Tunnel)
	}
}

func stopListeners() {
	listener.PatchInboundListeners(map[string]constant.InboundListener{}, tunnel.Tunnel, true)
	listener.PatchTunnel(nil, tunnel.Tunnel)
	listener.ReCreateHTTP(0, tunnel.Tunnel)
	listener.ReCreateSocks(0, tunnel.Tunnel)
	listener.ReCreateRedir(0, tunnel.Tunnel)
	listener.ReCreateTProxy(0, tunnel.Tunnel)
	listener.ReCreateMixed(0, tunnel.Tunnel)
	listener.ReCreateShadowSocks("", tunnel.Tunnel)
	listener.ReCreateVmess("", tunnel.Tunnel)
	listener.ReCreateTuic(LC.TuicServer{}, tunnel.Tunnel)
	listener.Cleanup()
}

func patchSelectGroup(mapping map[string]string) {
	for name, proxy := range tunnel.Proxies() {
		outbound, ok := proxy.(*adapter.Proxy)
		if !ok {
			continue
		}

		selector, ok := outbound.ProxyAdapter.(outboundgroup.SelectAble)
		if !ok {
			continue
		}

		selected, exist := mapping[name]
		if !exist {
			continue
		}

		selector.ForceSet(selected)
	}
}

func defaultSetupParams() *SetupParams {
	return &SetupParams{
		TestURL:     "https://www.gstatic.com/generate_204",
		SelectedMap: map[string]string{},
	}
}

func readFile(path string) ([]byte, error) {
	if _, err := os.Stat(path); os.IsNotExist(err) {
		return nil, err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}

	return data, err
}

func updateConfig(params *UpdateParams) error {
	runLock.Lock()
	defer runLock.Unlock()
	general := currentConfig.General
	if params.AllowLan != nil {
		general.AllowLan = *params.AllowLan
	}
	if params.MixedPort != nil {
		general.MixedPort = *params.MixedPort
	}
	if params.Sniffing != nil {
		general.Sniffing = *params.Sniffing
		tunnel.SetSniffing(general.Sniffing)
	}
	if params.FindProcessMode != nil {
		general.FindProcessMode = *params.FindProcessMode
		tunnel.SetFindProcessMode(general.FindProcessMode)
	}
	if params.TCPConcurrent != nil {
		general.TCPConcurrent = *params.TCPConcurrent
		dialer.SetTcpConcurrent(general.TCPConcurrent)
	}
	if params.Interface != nil {
		general.Interface = *params.Interface
		dialer.DefaultInterface.Store(general.Interface)
	}
	if params.UnifiedDelay != nil {
		general.UnifiedDelay = *params.UnifiedDelay
		adapter.UnifiedDelay.Store(general.UnifiedDelay)
	}
	if params.Mode != nil {
		general.Mode = *params.Mode
		tunnel.SetMode(general.Mode)
	}
	if params.LogLevel != nil {
		general.LogLevel = *params.LogLevel
		log.SetLevel(general.LogLevel)
	}
	if params.IPv6 != nil {
		general.IPv6 = *params.IPv6
		resolver.DisableIPv6 = !general.IPv6
	}
	if params.ExternalController != nil {
		currentConfig.Controller.ExternalController = *params.ExternalController
		route.ReCreateServer(&route.Config{
			Addr: currentConfig.Controller.ExternalController,
		})
	}

	if params.Tun != nil {
		general.Tun.Enable = params.Tun.Enable
		general.Tun.AutoRoute = *params.Tun.AutoRoute
		general.Tun.Device = *params.Tun.Device
		general.Tun.RouteAddress = *params.Tun.RouteAddress
		general.Tun.DNSHijack = *params.Tun.DNSHijack
		general.Tun.Stack = *params.Tun.Stack
	}

	updateListeners()
	return verifyConfiguredListeners()
}

// Mihomo's listener setters log bind failures instead of returning them.
// A successful settings transaction must also acknowledge its actual ports.
func verifyConfiguredListeners() error {
	if !isRunning || currentConfig == nil {
		return nil
	}
	actual := listener.GetPorts()
	wanted := currentConfig.General
	for _, port := range []struct {
		name           string
		actual, wanted int
	}{
		{"http", actual.Port, wanted.Port},
		{"socks", actual.SocksPort, wanted.SocksPort},
		{"mixed", actual.MixedPort, wanted.MixedPort},
		{"redir", actual.RedirPort, wanted.RedirPort},
		{"tproxy", actual.TProxyPort, wanted.TProxyPort},
	} {
		if port.actual != port.wanted {
			return fmt.Errorf("%s listener not applied: wanted %d, actual %d", port.name, port.wanted, port.actual)
		}
	}
	return nil
}

func validateConfigFile(path string) error {
	buf, err := readFile(path)
	if err != nil {
		return err
	}
	if len(buf) == 0 {
		return fmt.Errorf("configuration file %s is empty", path)
	}
	raw, err := config.UnmarshalRawConfig(buf)
	if err != nil {
		return err
	}
	if raw.DNS.Enable && raw.DNS.Listen != "" {
		if err := validateDNSListen(raw.DNS.Listen); err != nil {
			return err
		}
	}
	return nil
}

func validateDNSListen(address string) error {
	_, portText, err := net.SplitHostPort(address)
	if err != nil {
		return fmt.Errorf("invalid DNS listen address: %w", err)
	}
	port, err := strconv.Atoi(portText)
	if err != nil || port < 0 || port > 65535 {
		return fmt.Errorf("invalid DNS listen port: %s", portText)
	}
	return nil
}

func releaseUnusedOSMemory() {
	runtime.GC()
	debug.FreeOSMemory()
}

func applyConfig(params *SetupParams) error {
	runLock.Lock()
	err := applyConfigLocked(params)
	runLock.Unlock()
	releaseUnusedOSMemory()
	return err
}

func applyConfigLocked(params *SetupParams) error {
	var err error
	defaultTestURL = params.TestURL
	if defaultTestURL == "" {
		defaultTestURL = constant.DefaultTestURL
	}
	configPath := filepath.Join(constant.Path.HomeDir(), "config.yaml")
	if err := validateConfigFile(configPath); err != nil {
		return err
	}
	nextConfig, err := executor.ParseWithPath(configPath)
	if err != nil {
		return err
	}
	currentConfig = nextConfig
	currentProxyGroupNames = getRawProxyGroupNames(configPath)
	hub.ApplyConfig(currentConfig)
	invalidateProxiesCacheLocked()
	patchSelectGroup(params.SelectedMap)
	updateListeners()
	return verifyConfiguredListeners()
}

func getRawProxyGroupNames(path string) []string {
	buf, err := readFile(path)
	if err != nil {
		return nil
	}
	rawConfig, err := config.UnmarshalRawConfig(buf)
	if err != nil {
		return nil
	}
	names := make([]string, 0, len(rawConfig.ProxyGroup))
	for _, mapping := range rawConfig.ProxyGroup {
		name, ok := mapping["name"].(string)
		if !ok || name == "" {
			continue
		}
		names = append(names, name)
	}
	return names
}

func getProxySetSubscriptionInfo(psp *provider.ProxySetProvider) *provider.SubscriptionInfo {
	var raw struct {
		SubscriptionInfo *provider.SubscriptionInfo `json:"subscriptionInfo,omitempty"`
	}
	data, err := json.Marshal(psp)
	if err != nil {
		return nil
	}
	if err = json.Unmarshal(data, &raw); err != nil {
		return nil
	}
	return raw.SubscriptionInfo
}

func UnmarshalJson(data []byte, v any) error {
	decoder := json.NewDecoder(b.NewReader(data))
	decoder.UseNumber()
	err := decoder.Decode(v)
	return err
}

func logError(format string, args ...interface{}) {
	log.Errorln(format, args...)
	if debugError {
		fmt.Fprintf(os.Stderr, "[ERROR] "+format+"\n", args...)
	}
}
