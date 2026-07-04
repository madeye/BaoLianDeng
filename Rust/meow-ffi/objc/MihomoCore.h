#import <Foundation/Foundation.h>

FOUNDATION_EXPORT void BridgeSetHomeDir(NSString * _Nullable dir);
FOUNDATION_EXPORT void BridgeSetLogFile(NSString * _Nullable path);
/// Starts the mihomo proxy engine on the caller-supplied 127.0.0.1
/// ports. The caller (main app) picks the ports up-front so its REST
/// clients know the controller endpoint without an IPC round-trip.
/// `controllerAddr` is `host:port`.
FOUNDATION_EXPORT BOOL BridgeStartWithPorts(int32_t socksPort, int32_t dnsPort, NSString * _Nonnull controllerAddr, NSString * _Nullable secret, NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT void BridgeStopProxy(void);
FOUNDATION_EXPORT BOOL BridgeIsRunning(void);

/// Returns 0 if the proxy is not running.
FOUNDATION_EXPORT int32_t BridgeGetSocksPort(void);
FOUNDATION_EXPORT int32_t BridgeGetDNSPort(void);
/// Returns nil if the proxy is not running.
FOUNDATION_EXPORT NSString * _Nullable BridgeGetExternalControllerAddr(void);

FOUNDATION_EXPORT BOOL BridgeValidateConfig(NSString * _Nullable yamlContent, NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT void BridgeUpdateLogLevel(NSString * _Nullable level);

FOUNDATION_EXPORT int64_t BridgeGetUploadTraffic(void);
FOUNDATION_EXPORT int64_t BridgeGetDownloadTraffic(void);

FOUNDATION_EXPORT void BridgeForceGC(void);
FOUNDATION_EXPORT NSString * _Nonnull BridgeVersion(void);

FOUNDATION_EXPORT NSString * _Nonnull BridgeTestDirectTCP(NSString * _Nullable host, int32_t port);
FOUNDATION_EXPORT NSString * _Nonnull BridgeTestProxyHTTP(NSString * _Nullable targetURL);
FOUNDATION_EXPORT NSString * _Nonnull BridgeTestDNSResolver(NSString * _Nullable dnsAddr);
FOUNDATION_EXPORT NSString * _Nonnull BridgeTestSelectedProxy(NSString * _Nullable apiAddr);

