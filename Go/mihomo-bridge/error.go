package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"sync"
	"unsafe"
)

// Bridge calls from Swift are serialized at the call-site (TransparentProxyProvider
// invokes them from a single queue, ConfigManager from the main thread), so a
// single mutex-guarded string is sufficient. We keep the last error as a C string
// so bridge_get_last_error can return a pointer the caller does NOT need to free.
var (
	lastErrorMu  sync.Mutex
	lastErrorPtr *C.char
)

func setLastError(msg string) {
	lastErrorMu.Lock()
	defer lastErrorMu.Unlock()
	if lastErrorPtr != nil {
		C.free(unsafe.Pointer(lastErrorPtr))
		lastErrorPtr = nil
	}
	if msg != "" {
		lastErrorPtr = C.CString(msg)
	}
}

//export bridge_get_last_error
func bridge_get_last_error() *C.char {
	lastErrorMu.Lock()
	defer lastErrorMu.Unlock()
	return lastErrorPtr
}

//export bridge_free_string
func bridge_free_string(ptr *C.char) {
	if ptr != nil {
		C.free(unsafe.Pointer(ptr))
	}
}
