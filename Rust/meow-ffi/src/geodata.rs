//! Geodata path pinning.
//!
//! meow-rs resolves GeoIP/GeoSite databases through a process-wide home dir
//! (`meow_common::set_home_dir`, a first-write-wins `OnceLock`) or, failing
//! that, `$HOME/.config/meow`. Two problems for the FFI:
//!
//! 1. The Swift side downloads GeoLite2-Country `Country.mmdb` (meow-rs reads
//!    the `country/iso_code` schema; mihomo's `geoip.metadb` is incompatible)
//!    and `geosite.dat` into the bridge home dir — which is NOT
//!    `$HOME/.config/meow`.
//! 2. meow's home dir is first-write-wins, so once set it can't be repointed;
//!    a `GEOIP`/`GEOSITE` rule whose mmdb isn't found is a HARD error in
//!    `build_config` (mmap open fails), not a warning.
//!
//! So rather than trust the `OnceLock`, we inject explicit `geodata.*-path`
//! overrides (which take precedence over discovery) sourced from the bridge
//! home dir the caller most recently set, into every config we parse — for
//! both validation and engine start.
//!
//! A user (or a merged subscription config) MAY set these paths explicitly,
//! but we only honor a value that stays inside the bridge home dir — passing
//! it straight to meow-config would otherwise let an arbitrary subscription
//! payload make the kernel mmap-open any file readable by the process (path
//! injection). A path that is relative, escapes `home` via `..`, or resolves
//! outside `home` entirely is treated as absent and replaced by the pinned
//! in-home path instead. On any YAML error we return the input untouched so
//! validation still sees (and rejects) malformed configs.

use serde_yaml::{Mapping, Value};
use std::path::{Component, Path};

/// Insert `geodata.{mmdb-path,asn-path,geosite-path}` pointing at `<home>/…`
/// unless the user already set them to a path that is safely contained within
/// `home`. Returns the (possibly rewritten) YAML, or the original string
/// unchanged if it isn't a YAML mapping.
pub fn pin_geodata_paths(yaml: &str, home: &str) -> String {
    let mut root: Value = match serde_yaml::from_str(yaml) {
        Ok(v) => v,
        Err(_) => return yaml.to_string(),
    };
    let Value::Mapping(map) = &mut root else {
        return yaml.to_string();
    };

    let geodata = map
        .entry(Value::String("geodata".to_string()))
        .or_insert_with(|| Value::Mapping(Mapping::new()));
    // `geodata:` with an empty value parses as Null; treat it as an empty
    // mapping so we can still inject paths.
    if geodata.is_null() {
        *geodata = Value::Mapping(Mapping::new());
    }
    let Value::Mapping(geodata) = geodata else {
        // User set `geodata` to a scalar/sequence; leave the config as-is.
        return yaml.to_string();
    };

    set_if_absent_or_unsafe(geodata, "mmdb-path", &format!("{home}/Country.mmdb"), home);
    set_if_absent_or_unsafe(
        geodata,
        "asn-path",
        &format!("{home}/GeoLite2-ASN.mmdb"),
        home,
    );
    set_if_absent_or_unsafe(
        geodata,
        "geosite-path",
        &format!("{home}/geosite.dat"),
        home,
    );

    serde_yaml::to_string(&root).unwrap_or_else(|_| yaml.to_string())
}

/// Conservative allow-list check for a user-supplied geodata path: only an
/// absolute path with no `..` traversal component that lexically resolves
/// inside `home` is trusted. Everything else (relative paths, `..`
/// traversal, or an absolute path outside `home`) is rejected — meow-config
/// mmap-opens this path verbatim, so honoring an attacker-controlled value
/// here would be an arbitrary-file-read primitive.
fn is_safe_geodata_path(existing: &str, home: &str) -> bool {
    let path = Path::new(existing);
    if !path.is_absolute() {
        return false;
    }
    if path.components().any(|c| matches!(c, Component::ParentDir)) {
        return false;
    }
    path.starts_with(Path::new(home))
}

/// Set `map[key] = value` unless `map[key]` is already present AND is a safe
/// in-home path (see [`is_safe_geodata_path`]). An absent key, a non-string
/// value, or an unsafe path are all overridden with the pinned `value`.
fn set_if_absent_or_unsafe(map: &mut Mapping, key: &str, value: &str, home: &str) {
    let key_v = Value::String(key.to_string());
    let is_safe = map
        .get(&key_v)
        .and_then(Value::as_str)
        .is_some_and(|existing| is_safe_geodata_path(existing, home));
    if !is_safe {
        map.insert(key_v, Value::String(value.to_string()));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn injects_paths_when_absent() {
        let out = pin_geodata_paths("mode: rule\nrules:\n  - MATCH,DIRECT\n", "/home/x");
        assert!(out.contains("mmdb-path: /home/x/Country.mmdb"));
        assert!(out.contains("geosite-path: /home/x/geosite.dat"));
    }

    #[test]
    fn preserves_user_path_inside_home() {
        let out = pin_geodata_paths("geodata:\n  mmdb-path: /home/x/custom.mmdb\n", "/home/x");
        assert!(out.contains("/home/x/custom.mmdb"));
        assert!(!out.contains("mmdb-path: /home/x/Country.mmdb"));
    }

    #[test]
    fn overrides_user_path_outside_home() {
        // A path outside the bridge home dir must never be trusted — it would
        // let meow-config mmap-open an arbitrary file on disk.
        let out = pin_geodata_paths("geodata:\n  mmdb-path: /custom/C.mmdb\n", "/home/x");
        assert!(!out.contains("/custom/C.mmdb"), "{out}");
        assert!(out.contains("mmdb-path: /home/x/Country.mmdb"), "{out}");
    }

    #[test]
    fn overrides_path_traversal_escaping_home() {
        let out = pin_geodata_paths(
            "geodata:\n  mmdb-path: /home/x/../../etc/passwd\n",
            "/home/x",
        );
        assert!(!out.contains("/etc/passwd"), "{out}");
        assert!(out.contains("mmdb-path: /home/x/Country.mmdb"), "{out}");
    }

    #[test]
    fn overrides_relative_user_path() {
        let out = pin_geodata_paths("geodata:\n  mmdb-path: Country.mmdb\n", "/home/x");
        assert!(out.contains("mmdb-path: /home/x/Country.mmdb"), "{out}");
    }

    #[test]
    fn passthrough_on_invalid_yaml() {
        let bad = "proxies: [[[invalid";
        assert_eq!(pin_geodata_paths(bad, "/home/x"), bad);
    }

    #[test]
    fn injects_into_merged_subscription_config() {
        // Mirrors ConfigManager.mergeSubscription output (default header +
        // subscription proxies/groups + default rules incl. GEOIP,CN).
        let merged = "mixed-port: 0\nmode: rule\nexternal-controller: 127.0.0.1:0\ngeo-auto-update: false\n\ndns:\n  enable: true\n  enhanced-mode: redir-host\n\nproxies:\n  - name: \"TestNode\"\n    type: vless\n    server: \"1.2.3.4\"\n    port: 443\n    network: ws\n    ws-opts:\n      path: \"/ws\"\n\nproxy-groups:\n  - name: PROXY\n    type: select\n    proxies:\n      - \"TestNode\"\n\nrules:\n  - GEOIP,CN,DIRECT\n  - MATCH,PROXY\n";
        let out = pin_geodata_paths(merged, "/home/x");
        assert!(out.contains("mmdb-path: /home/x/Country.mmdb"), "{out}");
    }

    #[test]
    fn injects_into_null_geodata_block() {
        let out = pin_geodata_paths("geodata:\nrules:\n  - GEOIP,CN,DIRECT\n", "/home/x");
        assert!(out.contains("mmdb-path: /home/x/Country.mmdb"), "{out}");
    }
}
