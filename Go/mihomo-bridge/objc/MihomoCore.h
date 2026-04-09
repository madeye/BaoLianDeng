#import <Foundation/Foundation.h>

FOUNDATION_EXPORT void BridgeSetHomeDir(NSString * _Nullable dir);
FOUNDATION_EXPORT void BridgeSetLogFile(NSString * _Nullable path);
FOUNDATION_EXPORT BOOL BridgeStartWithExternalController(NSString * _Nullable addr, NSString * _Nullable secret, NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT void BridgeStopProxy(void);
FOUNDATION_EXPORT BOOL BridgeIsRunning(void);

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

