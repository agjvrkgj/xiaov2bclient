//go:build android && cgo

package main

/*
#include <stdlib.h>

typedef int (*protect_func)(void *callback, int fd);
typedef void (*release_func)(void *callback);

static int call_protect(protect_func fn, void *callback, int fd) {
    return fn == NULL ? 1 : fn(callback, fd);
}

static void call_release(release_func fn, void *callback) {
    if (fn != NULL && callback != NULL) {
        fn(callback);
    }
}
*/
import "C"

import (
	"errors"
	"fmt"
	"os"
	"runtime/debug"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"github.com/metacubex/mihomo/component/dialer"
	M "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/hub/route"
	"github.com/metacubex/mihomo/listener"
)

var lifecycle = struct {
	sync.Mutex
	running  bool
	callback unsafe.Pointer
}{}

var callbacks struct {
	protect C.protect_func
	release C.release_func
}

//export registerCallbacks
func registerCallbacks(protect C.protect_func, release C.release_func) {
	callbacks.protect = protect
	callbacks.release = release
}

func protectSocket(callback unsafe.Pointer, fd int) bool {
	return C.call_protect(callbacks.protect, callback, C.int(fd)) != 0
}

func releaseCallback(callback unsafe.Pointer) {
	C.call_release(callbacks.release, callback)
}

func releaseResourcesLocked() {
	dialer.DefaultSocketHook = nil
	if lifecycle.callback != nil {
		releaseCallback(lifecycle.callback)
		lifecycle.callback = nil
	}
	lifecycle.running = false
}

func closeCoreLocked() {
	defer releaseResourcesLocked()
	defer func() {
		// Shutdown is best-effort during Android service teardown. The app must
		// still release the Java callback even if an upstream cleanup panics.
		_ = recover()
	}()

	// Applying an empty config closes mixed/SOCKS/HTTP/custom listeners and
	// providers that executor.Shutdown does not tear down by itself.
	rawConfig := config.DefaultRawConfig()
	rawConfig.IPv6 = false
	rawConfig.DNS.Enable = false
	rawConfig.Tun.Enable = false
	if shutdownConfig, err := config.ParseRawConfig(rawConfig); err == nil {
		hub.ApplyConfig(shutdownConfig)
	}
	executor.Shutdown()
	// ReCreateServer with empty addresses closes the local controller servers.
	route.ReCreateServer(&route.Config{})
	time.Sleep(100 * time.Millisecond)
}

func startCore(homeDirectory, configPath string, tunFD int, callback unsafe.Pointer) (err error) {
	lifecycle.Lock()
	defer lifecycle.Unlock()

	if callback == nil {
		return errors.New("missing Android VPN callback")
	}
	if lifecycle.running {
		releaseCallback(callback)
		return errors.New("Mihomo is already running")
	}
	if tunFD <= 0 {
		releaseCallback(callback)
		return errors.New("invalid Android TUN file descriptor")
	}

	// Ownership of callback and tunFD is transferred to this function. Every
	// failure path releases both before returning to Kotlin.
	lifecycle.callback = callback
	tunHandedToCore := false
	defer func() {
		if recovered := recover(); recovered != nil {
			err = fmt.Errorf("Mihomo panic: %v\n%s", recovered, debug.Stack())
		}
		if err != nil {
			if tunHandedToCore {
				closeCoreLocked()
			} else {
				releaseResourcesLocked()
				_ = syscall.Close(tunFD)
			}
		}
	}()

	configBytes, err := os.ReadFile(configPath)
	if err != nil {
		return fmt.Errorf("read Mihomo config: %w", err)
	}
	M.SetHomeDir(homeDirectory)
	rawConfig, err := config.UnmarshalRawConfig(configBytes)
	if err != nil {
		return fmt.Errorf("parse Mihomo config: %w", err)
	}

	// Android owns routing through VpnService. Mihomo consumes the supplied
	// descriptor, while sing-tun handles the userspace TCP/IP stack.
	rawConfig.IPv6 = false
	rawConfig.DNS.Enable = true
	rawConfig.DNS.IPv6 = false
	rawConfig.DNS.FakeIPRange = "198.18.0.1/16"
	rawConfig.Tun.Enable = true
	rawConfig.Tun.Stack = M.TunMixed
	rawConfig.Tun.AutoRoute = false
	rawConfig.Tun.AutoRedirect = false
	rawConfig.Tun.AutoDetectInterface = false
	rawConfig.Tun.DNSHijack = []string{"any:53"}
	rawConfig.Tun.MTU = 9000
	rawConfig.Tun.FileDescriptor = tunFD

	dialer.DefaultSocketHook = func(_, _ string, connection syscall.RawConn) error {
		protected := false
		if err := connection.Control(func(fd uintptr) {
			protected = protectSocket(callback, int(fd))
		}); err != nil {
			return err
		}
		if !protected {
			return errors.New("VpnService.protect rejected Mihomo socket")
		}
		return nil
	}

	parsedConfig, err := config.ParseRawConfig(rawConfig)
	if err != nil {
		return fmt.Errorf("validate Mihomo config: %w", err)
	}
	tunHandedToCore = true
	hub.ApplyConfig(parsedConfig)
	if !listener.GetTunConf().Enable {
		return errors.New("Mihomo could not attach to the Android TUN interface")
	}

	lifecycle.running = true
	return nil
}

//export startMihomo
func startMihomo(homeDirectory *C.char, configPath *C.char, tunFD C.int, callback unsafe.Pointer) *C.char {
	err := startCore(
		C.GoString(homeDirectory),
		C.GoString(configPath),
		int(tunFD),
		callback,
	)
	if err == nil {
		return nil
	}
	return C.CString(err.Error())
}

//export stopMihomo
func stopMihomo() {
	lifecycle.Lock()
	defer lifecycle.Unlock()
	closeCoreLocked()
}

//export isMihomoRunning
func isMihomoRunning() C.int {
	lifecycle.Lock()
	defer lifecycle.Unlock()
	if lifecycle.running {
		return 1
	}
	return 0
}

//export freeCString
func freeCString(value *C.char) {
	C.free(unsafe.Pointer(value))
}

func main() {}
