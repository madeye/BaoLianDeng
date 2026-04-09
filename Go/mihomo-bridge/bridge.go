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
)

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

//export bridge_start_with_external_controller
func bridge_start_with_external_controller(addr *C.char, secret *C.char) C.int32_t {
	stateMu.Lock()
	defer stateMu.Unlock()

	if running {
		setLastError("proxy is already running")
		return -1
	}

	addrStr := ""
	if addr != nil {
		addrStr = C.GoString(addr)
	}
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
	// applies the option overrides, then calls hub.ApplyConfig which starts
	// the listeners, DNS server, and REST API.
	err := hub.Parse(nil,
		hub.WithExternalController(addrStr),
		hub.WithSecret(secretStr),
	)
	if err != nil {
		setLastError(fmt.Sprintf("hub.Parse: %v", err))
		return -1
	}

	runtime.GC()
	debug.FreeOSMemory()

	running = true
	bridgeLog("Proxy started, external controller=%s", addrStr)
	log.Infoln("Mihomo proxy engine started with external controller at %s", addrStr)
	return 0
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
	if versionCStr == nil {
		versionCStr = C.CString("mihomo-go " + constant.Version)
	}
	return versionCStr
}

//export bridge_force_gc
func bridge_force_gc() {
	runtime.GC()
	debug.FreeOSMemory()
}
