package main

/*
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
*/
import "C"

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"sync"

	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

var (
	stateMu sync.Mutex
	running bool

	logFile    *os.File
	logFileMu  sync.Mutex
	logSubOnce sync.Once

	versionCStr *C.char // cached, never freed
	versionOnce sync.Once

	// Ports/addr actually bound by mihomo this run. Reset on stop.
	// Picked dynamically (port 0) to avoid colliding with other mihomo
	// instances on the host. Read by Swift via the bridge_get_*_port /
	// bridge_get_external_controller_addr accessors.
	runtimeSocksPort      int
	runtimeDNSPort        int
	runtimeControllerAddr string
)

// (port picking lives in the main app — see VPNManager.swift —
// because it needs to share the chosen numbers with the extension via
// providerConfiguration AND with the app's own REST clients via its
// UserDefaults. Picking on the Go side leaves the app process blind.)

func bridgeLog(format string, args ...interface{}) {
	logFileMu.Lock()
	defer logFileMu.Unlock()
	if logFile != nil {
		fmt.Fprintf(logFile, "[Bridge] "+format+"\n", args...)
	}
}

//export bridge_set_home_dir
func bridge_set_home_dir(dir *C.char) {
	if dir == nil {
		return
	}
	d := C.GoString(dir)
	constant.SetHomeDir(d)
	constant.SetConfig(filepath.Join(d, "config.yaml"))
	bridgeLog("SetHomeDir: %s", d)
}

//export bridge_set_log_file
func bridge_set_log_file(path *C.char) C.int32_t {
	if path == nil {
		setLastError("log file path is null")
		return -1
	}
	p := C.GoString(path)

	logFileMu.Lock()
	if logFile != nil {
		_ = logFile.Close()
		logFile = nil
	}
	f, err := os.OpenFile(p, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	if err != nil {
		logFileMu.Unlock()
		setLastError(fmt.Sprintf("open log file: %v", err))
		return -1
	}
	logFile = f
	logFileMu.Unlock()

	// Subscribe to Mihomo's internal log stream once. Further calls to
	// bridge_set_log_file just swap the sink underneath.
	logSubOnce.Do(func() {
		sub := log.Subscribe()
		go func() {
			for ev := range sub {
				if ev.LogLevel < log.Level() {
					continue
				}
				logFileMu.Lock()
				if logFile != nil {
					fmt.Fprintf(logFile, "[Mihomo/%s] %s\n", ev.LogLevel, ev.Payload)
				}
				logFileMu.Unlock()
			}
		}()
	})

	bridgeLog("Log file opened: %s", p)
	return 0
}

//export bridge_validate_config
func bridge_validate_config(yaml *C.char) C.int32_t {
	if yaml == nil {
		setLastError("config is null")
		return -1
	}
	buf := []byte(C.GoString(yaml))
	if _, err := config.Parse(buf); err != nil {
		setLastError(err.Error())
		return -1
	}
	return 0
}

// bridge_start_with_ports starts the engine on the caller-supplied
// 127.0.0.1 ports. The main app picks them (via NWListener with port 0)
// and forwards them here through the system extension; that way the
// app's own REST clients know the controller port without needing an
// IPC round-trip. Pass `controller_addr` as `host:port`.
//
//export bridge_start_with_ports
func bridge_start_with_ports(
	socks_port C.int32_t,
	dns_port C.int32_t,
	controller_addr *C.char,
	secret *C.char,
) C.int32_t {
	stateMu.Lock()
	defer stateMu.Unlock()

	if running {
		setLastError("proxy is already running")
		return -1
	}
	if socks_port <= 0 || dns_port <= 0 {
		setLastError("socks_port and dns_port must be > 0")
		return -1
	}
	if controller_addr == nil {
		setLastError("controller_addr is null")
		return -1
	}

	socksPort := int(socks_port)
	dnsPort := int(dns_port)
	addrStr := C.GoString(controller_addr)
	dnsListen := fmt.Sprintf("127.0.0.1:%d", dnsPort)
	secretStr := ""
	if secret != nil {
		secretStr = C.GoString(secret)
	}

	configPath := constant.Path.Config()
	if _, err := os.Stat(configPath); os.IsNotExist(err) {
		setLastError(fmt.Sprintf("config.yaml not found at %s", configPath))
		return -1
	}

	// hub.Parse(nil, ...) reads the config file from constant.Path.Config(),
	// applies the option overrides (which run AFTER the YAML is parsed but
	// BEFORE listeners start), then calls hub.ApplyConfig which starts
	// the listeners, DNS server, and REST API. The custom option below
	// overrides whatever ports the user wrote in config.yaml so we land
	// on the caller-supplied ones.
	err := hub.Parse(nil,
		hub.WithExternalController(addrStr),
		hub.WithSecret(secretStr),
		func(cfg *config.Config) {
			if cfg.General != nil {
				cfg.General.MixedPort = socksPort
				// Disable other inbound ports we don't use; if the user's
				// config sets one we don't want it bound on a fixed port.
				cfg.General.Port = 0
				cfg.General.SocksPort = 0
				cfg.General.RedirPort = 0
				cfg.General.TProxyPort = 0
			}
			if cfg.DNS != nil {
				cfg.DNS.Listen = dnsListen
			}
		},
	)
	if err != nil {
		setLastError(fmt.Sprintf("hub.Parse: %v", err))
		return -1
	}

	runtimeSocksPort = socksPort
	runtimeDNSPort = dnsPort
	runtimeControllerAddr = addrStr

	runtime.GC()
	debug.FreeOSMemory()

	running = true
	bridgeLog("Proxy started: socks=%d dns=%d controller=%s", socksPort, dnsPort, addrStr)
	log.Infoln("Mihomo proxy engine started: socks=%d dns=%d controller=%s",
		socksPort, dnsPort, addrStr)
	return 0
}

//export bridge_get_socks_port
func bridge_get_socks_port() C.int32_t {
	stateMu.Lock()
	defer stateMu.Unlock()
	return C.int32_t(runtimeSocksPort)
}

//export bridge_get_dns_port
func bridge_get_dns_port() C.int32_t {
	stateMu.Lock()
	defer stateMu.Unlock()
	return C.int32_t(runtimeDNSPort)
}

// bridge_get_external_controller_addr returns the live controller addr
// (e.g. "127.0.0.1:54321"). Caller owns the returned C string and must
// release it via bridge_free_string.
//
//export bridge_get_external_controller_addr
func bridge_get_external_controller_addr() *C.char {
	stateMu.Lock()
	defer stateMu.Unlock()
	if runtimeControllerAddr == "" {
		return nil
	}
	return C.CString(runtimeControllerAddr)
}

//export bridge_stop_proxy
func bridge_stop_proxy() {
	stateMu.Lock()
	defer stateMu.Unlock()

	if !running {
		return
	}
	bridgeLog("StopProxy called")
	executor.Shutdown()
	running = false
	runtimeSocksPort = 0
	runtimeDNSPort = 0
	runtimeControllerAddr = ""

	runtime.GC()
	debug.FreeOSMemory()
	bridgeLog("Proxy engine stopped")
}

//export bridge_is_running
func bridge_is_running() C.bool {
	stateMu.Lock()
	defer stateMu.Unlock()
	return C.bool(running)
}

//export bridge_get_upload_traffic
func bridge_get_upload_traffic() C.int64_t {
	up, _ := statistic.DefaultManager.Now()
	return C.int64_t(up)
}

//export bridge_get_download_traffic
func bridge_get_download_traffic() C.int64_t {
	_, down := statistic.DefaultManager.Now()
	return C.int64_t(down)
}

//export bridge_update_log_level
func bridge_update_log_level(level *C.char) {
	if level == nil {
		return
	}
	l := C.GoString(level)
	if lvl, ok := log.LogLevelMapping[l]; ok {
		log.SetLevel(lvl)
		bridgeLog("Log level updated to %s", l)
	}
}

//export bridge_version
func bridge_version() *C.char {
	versionOnce.Do(func() {
		versionCStr = C.CString("mihomo-go " + constant.Version)
	})
	return versionCStr
}

//export bridge_force_gc
func bridge_force_gc() {
	runtime.GC()
	debug.FreeOSMemory()
}
