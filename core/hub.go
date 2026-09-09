package main

import (
	"cmp"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/common/convert"
	"github.com/metacubex/mihomo/common/observable"
	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/component/mmdb"
	"github.com/metacubex/mihomo/component/profile/cachefile"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/component/updater"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	cp "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
	"golang.org/x/exp/slices"
	"gopkg.in/yaml.v3"
	"net"
	"os"
	"runtime"
	"runtime/debug"
	"strconv"
	"time"
)

var (
	isInit                = false
	externalProviders     = map[string]cp.Provider{}
	logSubscriber         observable.Subscription[log.Event]
	proxiesCache          ProxiesData
	proxiesCacheRawCount  int
	proxiesCacheProviders map[string]providerCacheVersion
	proxiesCacheDirty     = true
)

const (
	logEventBatchInterval = time.Second
	logEventBatchMaxSize  = 100
)

type providerCacheVersion struct {
	version int
	count   int
}

func handleInitClash(paramsString string) bool {
	runLock.Lock()
	defer runLock.Unlock()
	return initClashLocked(paramsString)
}

func initClashLocked(paramsString string) bool {
	var params = InitParams{}
	err := json.Unmarshal([]byte(paramsString), &params)
	if err != nil {
		return false
	}
	version = params.Version
	constant.SetHomeDir(params.HomeDir)
	isInit = true
	return isInit
}

func handleStartListener() bool {
	runLock.Lock()
	defer runLock.Unlock()
	isRunning = true
	updateListeners()
	resolver.ResetConnection()
	return true
}

func handleStopListener() bool {
	runLock.Lock()
	defer runLock.Unlock()
	isRunning = false
	stopListeners()
	closeConnections()
	resolver.ResetConnection()
	return true
}

func handleGetIsInit() bool {
	runLock.Lock()
	defer runLock.Unlock()
	return isInit
}

func handleForceGC() {
	log.Infoln("[APP] request force GC")
	runtime.GC()
	if runtime.GOOS == "android" {
		debug.FreeOSMemory()
	}
}

func handleShutdown() bool {
	runLock.Lock()
	defer runLock.Unlock()
	isRunning = false
	stopListeners()
	executor.Shutdown()
	invalidateProxiesCacheLocked()
	handleForceGC()
	isInit = false
	return true
}

func handleValidateConfig(path string) string {
	if err := validateConfigFile(path); err != nil {
		return err.Error()
	}
	return ""
}

func handleGetProxies() ProxiesData {
	runLock.Lock()
	defer runLock.Unlock()

	nameList := getProxyNameList()
	rawProxies := tunnel.Proxies()
	providers := tunnel.Providers()
	if !proxiesCacheDirty && !proxiesCacheSourcesChanged(rawProxies, providers) {
		return proxiesCache
	}

	// Merge direct proxies and provider proxies into a single flat map.
	proxies := make(map[string]constant.Proxy, len(rawProxies))
	for name, proxy := range rawProxies {
		if !isFrontendVisibleProxy(proxy) {
			continue
		}
		proxies[name] = proxy
	}
	for _, p := range providers {
		for _, proxy := range p.Proxies() {
			if !isFrontendVisibleProxy(proxy) {
				continue
			}
			proxies[proxy.Name()] = proxy
		}
	}

	hasGlobal := false

	allNames := make([]string, 0, len(nameList)+1)

	for _, name := range nameList {
		if name == "GLOBAL" {
			hasGlobal = true
		}

		p, ok := proxies[name]
		if !ok || p == nil {
			continue
		}
		switch p.Type() {
		case constant.Selector, constant.URLTest, constant.Fallback, constant.Relay, constant.LoadBalance:
			allNames = append(allNames, name)
		default:
		}
	}

	if !hasGlobal {
		if p, ok := proxies["GLOBAL"]; ok && p != nil {
			allNames = append([]string{"GLOBAL"}, allNames...)
		}
	}

	proxiesCache = ProxiesData{
		All:     allNames,
		Proxies: proxies,
	}
	proxiesCacheRawCount = len(rawProxies)
	proxiesCacheProviders = snapshotProviderCacheVersions(providers)
	proxiesCacheDirty = false
	return proxiesCache
}

func isFrontendVisibleProxy(proxy constant.Proxy) bool {
	if proxy == nil {
		return false
	}
	switch proxy.Type() {
	case constant.PassRule:
		return false
	default:
		return true
	}
}

func proxiesCacheSourcesChanged(rawProxies map[string]constant.Proxy, providers map[string]cp.ProxyProvider) bool {
	if proxiesCacheRawCount != len(rawProxies) {
		return true
	}
	if len(proxiesCacheProviders) != len(providers) {
		return true
	}
	for name, provider := range providers {
		current := providerCacheVersion{}
		if provider != nil {
			current.version = int(provider.Version())
			current.count = provider.Count()
		}
		if proxiesCacheProviders[name] != current {
			return true
		}
	}
	return false
}

func snapshotProviderCacheVersions(providers map[string]cp.ProxyProvider) map[string]providerCacheVersion {
	versions := make(map[string]providerCacheVersion, len(providers))
	for name, provider := range providers {
		if provider == nil {
			versions[name] = providerCacheVersion{}
			continue
		}
		versions[name] = providerCacheVersion{
			version: int(provider.Version()),
			count:   provider.Count(),
		}
	}
	return versions
}

func invalidateProxiesCache() {
	runLock.Lock()
	defer runLock.Unlock()
	invalidateProxiesCacheLocked()
}

func invalidateProxiesCacheLocked() {
	proxiesCache = ProxiesData{}
	proxiesCacheRawCount = 0
	proxiesCacheProviders = nil
	proxiesCacheDirty = true
}

func handleChangeProxy(data string, fn func(string string)) {
	runLock.Lock()
	go func() {
		defer runLock.Unlock()
		var params = &ChangeProxyParams{}
		err := json.Unmarshal([]byte(data), params)
		if err != nil {
			fn(err.Error())
			return
		}
		groupName := *params.GroupName
		proxyName := *params.ProxyName
		proxies := tunnel.Proxies()
		group, ok := proxies[groupName]
		if !ok {
			fn("Not found group")
			return
		}
		adapterProxy := group.(*adapter.Proxy)
		selector, ok := adapterProxy.ProxyAdapter.(outboundgroup.SelectAble)
		if !ok {
			fn("Group is not selectable")
			return
		}
		if proxyName == "" {
			fn("empty proxy name not allowed")
			return
		}
		err = selector.Set(proxyName)
		if err != nil {
			fn(err.Error())
			return
		}
		cachefile.Cache().SetSelected(groupName, proxyName)
		invalidateProxiesCacheLocked()

		fn("")
		return
	}()
}

func handleGetTraffic(onlyStatisticsProxy bool) string {
	up, down := statistic.DefaultManager.Now()
	if onlyStatisticsProxy {
		up, down = statistic.DefaultManager.ProxyNow()
	}
	traffic := map[string]int64{
		"up":   up,
		"down": down,
	}
	data, err := json.Marshal(traffic)
	if err != nil {
		logError("Error: %s", err)
		return ""
	}
	return string(data)
}

func handleGetTotalTraffic(onlyStatisticsProxy bool) string {
	up, down := statistic.DefaultManager.Total()
	if onlyStatisticsProxy {
		up, down = statistic.DefaultManager.ProxyTotal()
	}
	traffic := map[string]int64{
		"up":   up,
		"down": down,
	}
	data, err := json.Marshal(traffic)
	if err != nil {
		logError("Error: %s", err)
		return ""
	}
	return string(data)
}

func handleGetTrafficSnapshot(onlyStatisticsProxy bool) string {
	up, down := statistic.DefaultManager.Now()
	totalUp, totalDown := statistic.DefaultManager.Total()
	if onlyStatisticsProxy {
		up, down = statistic.DefaultManager.ProxyNow()
		totalUp, totalDown = statistic.DefaultManager.ProxyTotal()
	}
	traffic := map[string]int64{
		"up":        up,
		"down":      down,
		"totalUp":   totalUp,
		"totalDown": totalDown,
	}
	data, err := json.Marshal(traffic)
	if err != nil {
		logError("Error: %s", err)
		return ""
	}
	return string(data)
}

func handleResetTraffic() {
	statistic.DefaultManager.ResetStatistic()
}

func handleAsyncTestDelay(paramsString string, fn func(string)) {
	mBatch.Go(paramsString, func() (bool, error) {
		var params = &TestDelayParams{}
		err := json.Unmarshal([]byte(paramsString), params)
		if err != nil {
			fn("")
			return false, nil
		}

		expectedStatus, err := utils.NewUnsignedRanges[uint16]("")
		if err != nil {
			fn("")
			return false, nil
		}

		ctx, cancel := context.WithTimeout(context.Background(), time.Millisecond*time.Duration(params.Timeout))
		defer cancel()

		proxy := tunnel.Proxies()[params.ProxyName]
		if proxy == nil {
			for _, p := range tunnel.Providers() {
				for _, pp := range p.Proxies() {
					if pp.Name() == params.ProxyName {
						proxy = pp
						break
					}
				}
				if proxy != nil {
					break
				}
			}
		}

		delayData := &Delay{
			Name: params.ProxyName,
		}

		if proxy == nil {
			delayData.Value = -1
			data, _ := json.Marshal(delayData)
			fn(string(data))
			return false, nil
		}

		testUrl := defaultTestURL

		if params.TestUrl != "" {
			testUrl = params.TestUrl
		}
		delayData.Url = testUrl
		delay, err := proxy.URLTest(ctx, testUrl, expectedStatus)
		if err != nil || delay == 0 {
			delayData.Value = -1
			data, _ := json.Marshal(delayData)
			fn(string(data))
			return false, nil
		}

		delayData.Value = int32(delay)
		data, _ := json.Marshal(delayData)
		fn(string(data))
		return false, nil
	})
}

func getProxyNameList() []string {
	if currentConfig == nil {
		return nil
	}

	if len(currentProxyGroupNames) > 0 {
		return append([]string{}, currentProxyGroupNames...)
	}

	names := make([]string, 0, len(currentConfig.Proxies))
	for name := range currentConfig.Proxies {
		names = append(names, name)
	}
	slices.SortFunc(names, func(a, b string) int {
		return cmp.Compare(a, b)
	})
	return names
}

func handleGetConnections() string {
	runLock.Lock()
	defer runLock.Unlock()
	snapshot := statistic.DefaultManager.Snapshot()
	data, err := json.Marshal(snapshot)
	if err != nil {
		logError("Error: %s", err)
		return ""
	}
	return string(data)
}

func handleCloseConnections() bool {
	runLock.Lock()
	defer runLock.Unlock()
	return closeConnections()
}

func closeConnections() bool {
	success := true
	statistic.DefaultManager.Range(func(c statistic.Tracker) bool {
		err := c.Close()
		if err != nil {
			success = false
		}
		// A single broken tracker must not prevent the remaining connections
		// from being closed during a network handover.
		return true
	})
	return success
}

func handleResetConnections() bool {
	runLock.Lock()
	defer runLock.Unlock()
	resolver.ResetConnection()
	return true
}

func handleCloseConnection(connectionId string) bool {
	runLock.Lock()
	defer runLock.Unlock()
	c := statistic.DefaultManager.Get(connectionId)
	if c == nil {
		return false
	}
	_ = c.Close()
	return true
}

func handleGetExternalProviders() string {
	runLock.Lock()
	defer runLock.Unlock()
	externalProviders = getExternalProvidersRaw()
	eps := make([]ExternalProvider, 0)
	for _, p := range externalProviders {
		externalProvider, err := toExternalProvider(p)
		if err != nil {
			continue
		}
		eps = append(eps, *externalProvider)
	}
	slices.SortFunc(eps, func(a, b ExternalProvider) int {
		return cmp.Compare(a.Name, b.Name)
	})
	data, err := json.Marshal(eps)
	if err != nil {
		return ""
	}
	return string(data)
}

func handleGetExternalProvider(externalProviderName string) string {
	runLock.Lock()
	defer runLock.Unlock()
	externalProvider, exist := externalProviders[externalProviderName]
	if !exist {
		return ""
	}
	e, err := toExternalProvider(externalProvider)
	if err != nil {
		return ""
	}
	data, err := json.Marshal(e)
	if err != nil {
		return ""
	}
	return string(data)
}

func handleUpdateGeoData(geoType string, geoName string, fn func(value string)) {
	go func() {
		_ = geoName
		switch geoType {
		case "MMDB":
			err := updater.UpdateMMDB()
			if err != nil {
				fn(err.Error())
				return
			}
		case "ASN":
			err := updater.UpdateASN()
			if err != nil {
				fn(err.Error())
				return
			}
		case "GEOIP":
			err := updater.UpdateGeoIp()
			if err != nil {
				fn(err.Error())
				return
			}
		case "GEOSITE":
			err := updater.UpdateGeoSite()
			if err != nil {
				fn(err.Error())
				return
			}
		}
		fn("")
	}()
}

func handleUpdateExternalProvider(providerName string, fn func(value string)) {
	go func() {
		externalProvider, exist := externalProviders[providerName]
		if !exist {
			fn("external provider is not exist")
			return
		}
		err := externalProvider.Update()
		if err != nil {
			fn(err.Error())
			return
		}
		invalidateProxiesCache()
		fn("")
	}()
}

func handleSideLoadExternalProvider(providerName string, data []byte, fn func(value string)) {
	go func() {
		runLock.Lock()
		defer runLock.Unlock()
		externalProvider, exist := externalProviders[providerName]
		if !exist {
			fn("external provider is not exist")
			return
		}
		err := sideUpdateExternalProvider(externalProvider, data)
		if err != nil {
			fn(err.Error())
			return
		}
		invalidateProxiesCacheLocked()
		fn("")
	}()
}

func handleSuspend(suspended bool) bool {
	if suspended {
		tunnel.OnSuspend()
	} else {
		tunnel.OnRunning()
	}
	return true
}

func handleStartLog() {
	if logSubscriber != nil {
		log.UnSubscribe(logSubscriber)
		logSubscriber = nil
	}
	logSubscriber = log.Subscribe()
	subscriber := logSubscriber
	go func() {
		ticker := time.NewTicker(logEventBatchInterval)
		defer ticker.Stop()

		batch := make([]log.Event, 0, logEventBatchMaxSize)
		flush := func() {
			if len(batch) == 0 {
				return
			}
			message := &Message{
				Type: LogMessage,
				Data: batch,
			}
			sendMessage(*message)
			batch = make([]log.Event, 0, logEventBatchMaxSize)
		}

		for {
			select {
			case logData, ok := <-subscriber:
				if !ok {
					flush()
					return
				}
				if logData.LogLevel < log.Level() {
					continue
				}
				batch = append(batch, logData)
				if len(batch) >= logEventBatchMaxSize {
					flush()
				}
			case <-ticker.C:
				flush()
			}
		}
	}()
}

func handleStopLog() {
	if logSubscriber != nil {
		log.UnSubscribe(logSubscriber)
		logSubscriber = nil
	}
}

func handleGetCountryCode(ip string, fn func(value string)) {
	go func() {
		runLock.Lock()
		defer runLock.Unlock()
		codes := mmdb.IPInstance().LookupCode(net.ParseIP(ip))
		if len(codes) == 0 {
			fn("")
			return
		}
		fn(codes[0])
	}()
}

func handleGetMemory(fn func(value string)) {
	go func() {
		fn(strconv.FormatUint(statistic.DefaultManager.Memory(), 10))
	}()
}

// normalizeRawConfig is the single normalization entry for the config API so
// path-based reads and any future callers produce identical RawConfig.
func normalizeRawConfig(buf []byte) (*config.RawConfig, error) {
	return config.UnmarshalRawConfig(buf)
}

func handleGetConfig(path string) (*config.RawConfig, error) {
	bytes, err := readFile(path)
	if err != nil {
		return nil, err
	}
	return normalizeRawConfig(bytes)
}

func handleCrash() {
	panic("handle invoke crash")
}

func handleUpdateConfig(bytes []byte) string {
	var params = &UpdateParams{}
	err := json.Unmarshal(bytes, params)
	if err != nil {
		return err.Error()
	}
	updateConfig(params)
	return ""
}

func handleDelFile(path string, result ActionResult) {
	handleDelFileWithStat(path, result, os.Stat)
}

func handleDelFileWithStat(
	path string,
	result ActionResult,
	stat func(string) (os.FileInfo, error),
) {
	go func() {
		fileInfo, err := stat(path)
		if err != nil {
			if !os.IsNotExist(err) {
				result.success(err.Error())
				return
			}
			result.success("")
			return
		}
		if fileInfo.IsDir() {
			err = os.RemoveAll(path)
			if err != nil {
				result.success(err.Error())
				return
			}
		} else {
			err = os.Remove(path)
			if err != nil {
				result.success(err.Error())
				return
			}
		}
		result.success("")
	}()
}

func handleSetupConfig(bytes []byte) string {
	runLock.Lock()
	defer releaseUnusedOSMemory()
	defer runLock.Unlock()
	return setupConfigLocked(bytes)
}

func setupConfigLocked(bytes []byte) string {
	if !isInit {
		return "not initialized"
	}
	var params = defaultSetupParams()
	err := UnmarshalJson(bytes, params)
	if err != nil {
		logError("unmarshalRawConfig error %v", err)
		_ = applyConfigLocked(defaultSetupParams())
		return err.Error()
	}
	err = applyConfigLocked(params)
	if err != nil {
		return err.Error()
	}
	return ""
}

type materializeProfileSnapshotParams struct {
	ProfilePath    string            `json:"profilePath"`
	SelectedMap    map[string]string `json:"selectedMap"`
	DefaultTestUrl string            `json:"defaultTestUrl"`
}

func handleMaterializeProfileSnapshot(paramsString string) (ProxiesData, string) {
	var params materializeProfileSnapshotParams
	if err := json.Unmarshal([]byte(paramsString), &params); err != nil {
		return ProxiesData{}, err.Error()
	}

	if params.ProfilePath == "" {
		return ProxiesData{}, "profilePath is empty"
	}

	buf, err := readFile(params.ProfilePath)
	if err != nil {
		return ProxiesData{}, err.Error()
	}

	// 解析 raw config 获取 proxy group names
	rawCfg, err := config.UnmarshalRawConfig(buf)
	if err != nil {
		return ProxiesData{}, err.Error()
	}

	// 解析完整 config（包含 provider 展开），但不 ApplyConfig
	cfg, err := config.Parse(buf)
	if err != nil {
		return ProxiesData{}, err.Error()
	}

	// 从 raw config 提取 proxy group names
	nameList := make([]string, 0, len(rawCfg.ProxyGroup))
	for _, mapping := range rawCfg.ProxyGroup {
		name, ok := mapping["name"].(string)
		if !ok || name == "" {
			continue
		}
		nameList = append(nameList, name)
	}

	// 构建 proxies map：合并 direct proxies + provider proxies
	proxies := make(map[string]constant.Proxy, len(cfg.Proxies))
	for name, proxy := range cfg.Proxies {
		if !isFrontendVisibleProxy(proxy) {
			continue
		}
		proxies[name] = proxy
	}
	for _, p := range cfg.Providers {
		for _, proxy := range p.Proxies() {
			if !isFrontendVisibleProxy(proxy) {
				continue
			}
			proxies[proxy.Name()] = proxy
		}
	}

	// 构建 allNames：只包含 group 类型的 proxy
	hasGlobal := false
	allNames := make([]string, 0, len(nameList)+1)
	for _, name := range nameList {
		if name == "GLOBAL" {
			hasGlobal = true
		}
		p, ok := proxies[name]
		if !ok || p == nil {
			continue
		}
		switch p.Type() {
		case constant.Selector, constant.URLTest, constant.Fallback, constant.Relay, constant.LoadBalance:
			allNames = append(allNames, name)
		}
	}
	if !hasGlobal {
		if p, ok := proxies["GLOBAL"]; ok && p != nil {
			allNames = append([]string{"GLOBAL"}, allNames...)
		}
	}

	if len(allNames) == 0 || len(proxies) == 0 {
		return ProxiesData{}, "materialized proxies empty"
	}

	return ProxiesData{
		All:     allNames,
		Proxies: proxies,
	}, ""
}

type providerContentSchema struct {
	Proxies []map[string]any `yaml:"proxies"`
}

func handleNormalizeProviderContent(encoded string) ([]map[string]any, error) {
	buf, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return nil, err
	}
	schema := &providerContentSchema{}
	if err = yaml.Unmarshal(buf, schema); err != nil || schema.Proxies == nil {
		proxies, convertErr := convert.ConvertsV2Ray(buf)
		if convertErr != nil {
			if err != nil {
				return nil, fmt.Errorf("invalid provider content: %w; %v", err, convertErr)
			}
			return nil, fmt.Errorf("invalid provider content: %w", convertErr)
		}
		schema.Proxies = proxies
	}
	if len(schema.Proxies) == 0 {
		return nil, errors.New("provider content has no proxy nodes")
	}
	return schema.Proxies, nil
}

// Quick setup and listener lifecycle share one lock. Setup does not express a
// start intent: only the native session owner may open listeners afterwards.
func handleQuickSetup(initParams, setupParams string) string {
	runLock.Lock()
	defer releaseUnusedOSMemory()
	defer runLock.Unlock()
	if !initClashLocked(initParams) {
		return "init failed"
	}
	return setupConfigLocked([]byte(setupParams))
}
