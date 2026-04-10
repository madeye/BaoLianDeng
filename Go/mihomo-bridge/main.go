// Package main is the Go bridge between Swift/ObjC code and the upstream
// MetaCubeX/mihomo proxy engine. It is compiled with
// `go build -buildmode=c-archive` into libmihomo_bridge.a, which is then
// merged with the hand-written ObjC wrapper (objc/MihomoCore.m) to form
// MihomoCore.xcframework.
//
// The exported symbol surface is intentionally identical to the previous
// Rust FFI that lived under Rust/mihomo-ffi/, so that the ObjC wrapper
// (objc/MihomoCore.m) and all Swift call sites (TransparentProxyProvider,
// ConfigManager) work without modification.
package main

/*
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
*/
import "C"

import (
	"runtime"
	"runtime/debug"
	"time"
)

// main is required by `-buildmode=c-archive`; never executed.
func main() {}

func init() {
	// Aggressive GC to stay under the ~15 MB memory limit imposed on
	// Network Extension processes. SetMemoryLimit is a soft limit that
	// makes the GC work harder to keep total Go heap under the target;
	// SetGCPercent(10) triggers collection when the heap grows 10% over
	// the live set, keeping allocation headroom minimal.
	debug.SetMemoryLimit(10 * 1024 * 1024) // 10 MB soft limit
	debug.SetGCPercent(10)

	// Periodic forced GC + return memory to OS every 10 s.
	// Belt-and-suspenders with TransparentProxyProvider's BridgeForceGC timer.
	go func() {
		ticker := time.NewTicker(10 * time.Second)
		defer ticker.Stop()
		for range ticker.C {
			runtime.GC()
			debug.FreeOSMemory()
		}
	}()
}
