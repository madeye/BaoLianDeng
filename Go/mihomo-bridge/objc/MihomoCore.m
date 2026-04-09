#import "MihomoCore.h"
#include <stdbool.h>

// C FFI declarations (from Rust staticlib)
extern void bridge_set_home_dir(const char *dir);
extern int32_t bridge_set_log_file(const char *path);
extern int32_t bridge_start_with_external_controller(const char *addr, const char *secret);
extern void bridge_stop_proxy(void);
extern bool bridge_is_running(void);
extern char *bridge_read_config(void);
extern int32_t bridge_validate_config(const char *yaml);
extern void bridge_update_log_level(const char *level);
extern int64_t bridge_get_upload_traffic(void);
extern int64_t bridge_get_download_traffic(void);
extern void bridge_force_gc(void);
extern const char *bridge_version(void);
extern char *bridge_test_direct_tcp(const char *host, int32_t port);
extern char *bridge_test_proxy_http(const char *url);
extern char *bridge_test_dns_resolver(const char *addr);
extern char *bridge_test_selected_proxy(const char *api_addr);
extern void bridge_free_string(char *ptr);
extern const char *bridge_get_last_error(void);

static NSError *makeError(void) {
    const char *msg = bridge_get_last_error();
    NSString *desc = msg ? [NSString stringWithUTF8String:msg] : @"Unknown error";
    return [NSError errorWithDomain:@"MihomoCore" code:-1
                           userInfo:@{NSLocalizedDescriptionKey: desc}];
}

void BridgeSetHomeDir(NSString * _Nullable dir) {
    bridge_set_home_dir([dir UTF8String]);
}

void BridgeSetLogFile(NSString * _Nullable path) {
    bridge_set_log_file([path UTF8String]);
}

BOOL BridgeStartWithExternalController(NSString * _Nullable addr, NSString * _Nullable secret, NSError * _Nullable * _Nullable error) {
    int32_t rc = bridge_start_with_external_controller([addr UTF8String], [secret UTF8String]);
    if (rc != 0) {
        if (error) *error = makeError();
        return NO;
    }
    return YES;
}

void BridgeStopProxy(void) {
    bridge_stop_proxy();
}

BOOL BridgeIsRunning(void) {
    return bridge_is_running() ? YES : NO;
}

BOOL BridgeValidateConfig(NSString * _Nullable yamlContent, NSError * _Nullable * _Nullable error) {
    int32_t rc = bridge_validate_config([yamlContent UTF8String]);
    if (rc != 0) {
        if (error) *error = makeError();
        return NO;
    }
    return YES;
}

void BridgeUpdateLogLevel(NSString * _Nullable level) {
    bridge_update_log_level([level UTF8String]);
}

int64_t BridgeGetUploadTraffic(void) {
    return bridge_get_upload_traffic();
}

int64_t BridgeGetDownloadTraffic(void) {
    return bridge_get_download_traffic();
}

void BridgeForceGC(void) {
    bridge_force_gc();
}

NSString * _Nonnull BridgeVersion(void) {
    const char *v = bridge_version();
    return [NSString stringWithUTF8String:v];
}

NSString * _Nonnull BridgeTestDirectTCP(NSString * _Nullable host, int32_t port) {
    char *result = bridge_test_direct_tcp([host UTF8String], port);
    NSString *str = [NSString stringWithUTF8String:result];
    bridge_free_string(result);
    return str;
}

NSString * _Nonnull BridgeTestProxyHTTP(NSString * _Nullable targetURL) {
    char *result = bridge_test_proxy_http([targetURL UTF8String]);
    NSString *str = [NSString stringWithUTF8String:result];
    bridge_free_string(result);
    return str;
}

NSString * _Nonnull BridgeTestDNSResolver(NSString * _Nullable dnsAddr) {
    char *result = bridge_test_dns_resolver([dnsAddr UTF8String]);
    NSString *str = [NSString stringWithUTF8String:result];
    bridge_free_string(result);
    return str;
}

NSString * _Nonnull BridgeTestSelectedProxy(NSString * _Nullable apiAddr) {
    char *result = bridge_test_selected_proxy([apiAddr UTF8String]);
    NSString *str = [NSString stringWithUTF8String:result];
    bridge_free_string(result);
    return str;
}

