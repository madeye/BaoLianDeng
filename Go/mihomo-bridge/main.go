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
	// Relaxed GC for macOS — the Network Extension sandbox is more generous
	// than iOS (no 15 MB hard cap), so we don't force aggressive collection.
	debug.SetGCPercent(20)

	// Periodic GC keeps RSS low between traffic bursts. Matches the
	// BridgeForceGC cadence that TransparentProxyProvider already invokes
	// every 10 s, so this is belt-and-suspenders.
	go func() {
		ticker := time.NewTicker(30 * time.Second)
		defer ticker.Stop()
		for range ticker.C {
			runtime.GC()
			debug.FreeOSMemory()
		}
	}()
}
