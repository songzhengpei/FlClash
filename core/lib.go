//go:build cgo

package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"core/platform"
	t "core/tun"
	"encoding/json"
	"errors"
	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/process"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/listener/sing_tun"
	"github.com/metacubex/mihomo/log"
	"golang.org/x/sync/semaphore"
	"net"
	"strings"
	"sync"
	"syscall"
	"unsafe"
)

var (
	eventListener     unsafe.Pointer
	eventListenerLock sync.Mutex
	dnsUpdateLock     sync.Mutex
)

type TunHandler struct {
	listener *sing_tun.Listener
	callback unsafe.Pointer

	limit *semaphore.Weighted
}

func (th *TunHandler) start(fd int, stack, address, dns string) bool {
	runLock.Lock()
	defer runLock.Unlock()
	_ = th.limit.Acquire(context.TODO(), 4)
	defer th.limit.Release(4)
	th.initHook()
	tunListener, err := t.Start(fd, stack, address, dns)
	if err == nil && tunListener != nil {
		log.Infoln("TUN address: %v", tunListener.Address())
		th.listener = tunListener
		return true
	}
	log.Errorln("Start TUN failed: %v", err)
	th.clear()
	return false
}

func (th *TunHandler) close() {
	_ = th.limit.Acquire(context.TODO(), 4)
	defer th.limit.Release(4)
	th.clear()
}

func (th *TunHandler) clear() {
	th.removeHook()
	if th.listener != nil {
		_ = th.listener.Close()
	}
	if th.callback != nil {
		releaseObject(th.callback)
	}
	th.callback = nil
	th.listener = nil
}

func (th *TunHandler) handleProtect(fd int) {
	_ = th.limit.Acquire(context.Background(), 1)
	defer th.limit.Release(1)

	if th.listener == nil || th.callback == nil {
		return
	}

	protect(th.callback, fd)
}

func (th *TunHandler) handleResolveProcess(source, target net.Addr) string {
	_ = th.limit.Acquire(context.Background(), 1)
	defer th.limit.Release(1)

	if th.listener == nil || th.callback == nil {
		return ""
	}
	var protocol int
	uid := -1
	switch source.Network() {
	case "udp", "udp4", "udp6":
		protocol = syscall.IPPROTO_UDP
	case "tcp", "tcp4", "tcp6":
		protocol = syscall.IPPROTO_TCP
	}
	if version < 29 {
		uid = platform.QuerySocketUidFromProcFs(source, target)
	}
	return resolveProcess(th.callback, protocol, source.String(), target.String(), uid)
}

func (th *TunHandler) initHook() {
	dialer.DefaultSocketHook = func(network, address string, conn syscall.RawConn) error {
		if platform.ShouldBlockConnection() {
			return errBlocked
		}
		return conn.Control(func(fd uintptr) {
			tunHandler.handleProtect(int(fd))
		})
	}
	process.DefaultPackageNameResolver = func(metadata *constant.Metadata) (string, error) {
		src, dst := metadata.RawSrcAddr, metadata.RawDstAddr
		if src == nil || dst == nil {
			return "", process.ErrInvalidNetwork
		}
		return tunHandler.handleResolveProcess(src, dst), nil
	}
}

func (th *TunHandler) removeHook() {
	dialer.DefaultSocketHook = nil
	process.DefaultPackageNameResolver = nil
}

var (
	tunLock    sync.Mutex
	errBlocked = errors.New("blocked")
	tunHandler *TunHandler
)

func handleStopTun() {
	tunLock.Lock()
	defer tunLock.Unlock()
	if tunHandler != nil {
		tunHandler.close()
	}
}

func handleStartTun(callback unsafe.Pointer, fd int, stack, address, dns string) bool {
	handleStopTun()
	tunLock.Lock()
	defer tunLock.Unlock()
	if fd == 0 || callback == nil {
		if callback != nil {
			releaseObject(callback)
		}
		if fd != 0 {
			_ = syscall.Close(fd)
		}
		return false
	}
	tunHandler = &TunHandler{
		callback: callback,
		limit:    semaphore.NewWeighted(4),
	}
	if !tunHandler.start(fd, stack, address, dns) {
		tunHandler = nil
		return false
	}
	return true
}

func handleUpdateDns(value string) {
	dnsUpdateLock.Lock()
	defer dnsUpdateLock.Unlock()
	log.Infoln("[DNS] updateDns %s", value)
	servers := []string{}
	if value != "" {
		servers = strings.Split(value, ",")
	}
	dns.UpdateSystemDNS(servers)
	dns.FlushCacheWithDefaultResolver()
}

func (result ActionResult) send() {
	data, err := result.Json()
	if err != nil {
		return
	}
	invokeResult(result.callback, string(data))
	if result.Method != messageMethod {
		releaseObject(result.callback)
	}
}

func nextHandle(action *Action, result ActionResult) bool {
	switch action.Method {
	case updateDnsMethod:
		data := action.Data.(string)
		handleUpdateDns(data)
		result.success(true)
		return true
	}
	return false
}

//export invokeAction
func invokeAction(callback unsafe.Pointer, paramsChar *C.char) {
	params := takeCString(paramsChar)
	var action = &Action{}
	err := json.Unmarshal([]byte(params), action)
	if err != nil {
		invokeResult(callback, err.Error())
		releaseObject(callback)
		return
	}
	result := ActionResult{
		Id:       action.Id,
		Method:   action.Method,
		callback: callback,
	}
	go handleAction(action, result)
}

//export startTUN
func startTUN(callback unsafe.Pointer, fd C.int, stackChar, addressChar, dnsChar *C.char) bool {
	if !handleStartTun(callback, int(fd), takeCString(stackChar), takeCString(addressChar), takeCString(dnsChar)) {
		return false
	}
	if !isRunning {
		handleStartListener()
	} else {
		handleResetConnections()
	}
	return true
}

//export quickSetup
func quickSetup(callback unsafe.Pointer, initParamsChar *C.char, setupParamsChar *C.char) {
	go func() {
		defer releaseObject(callback)
		initParamsString := takeCString(initParamsChar)
		setupParamsString := takeCString(setupParamsChar)
		message := handleQuickSetup(initParamsString, setupParamsString)
		invokeResult(callback, message)
	}()
}

//export setEventListener
func setEventListener(listener unsafe.Pointer) {
	eventListenerLock.Lock()
	defer eventListenerLock.Unlock()
	if eventListener != nil || listener == nil {
		releaseObject(eventListener)
	}
	eventListener = listener
}

//export getTotalTraffic
func getTotalTraffic(onlyStatisticsProxy bool) *C.char {
	return C.CString(handleGetTotalTraffic(onlyStatisticsProxy))
}

//export getTraffic
func getTraffic(onlyStatisticsProxy bool) *C.char {
	return C.CString(handleGetTraffic(onlyStatisticsProxy))
}

//export getTrafficSnapshot
func getTrafficSnapshot(onlyStatisticsProxy bool) *C.char {
	return C.CString(handleGetTrafficSnapshot(onlyStatisticsProxy))
}

func sendMessage(message Message) {
	eventListenerLock.Lock()
	defer eventListenerLock.Unlock()
	if eventListener == nil {
		return
	}
	result := ActionResult{
		Method:   messageMethod,
		callback: eventListener,
		Data:     message,
	}
	result.send()
}

//export stopTun
func stopTun() {
	handleStopTun()
	if isRunning {
		handleStopListener()
	}
}

//export suspend
func suspend(suspended bool) {
	handleSuspend(suspended)
}

//export forceGC
func forceGC() {
	handleForceGC()
}

//export updateDns
func updateDns(s *C.char) {
	handleUpdateDns(takeCString(s))
}
