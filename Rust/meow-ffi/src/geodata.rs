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
//! both validation and engine start. User-specified paths are never
//! overwritten; on any YAML error we return the input untouched so validation
//! still sees (and rejects) malformed configs.

use serde_yaml::{Mapping, Value};

/// Insert `geodata.{mmdb-path,asn-path,geosite-path}` pointing at `<home>/…`
/// unless the user already set them. Returns the (possibly rewritten) YAML, or
/// the original string unchanged if it isn't a YAML mapping.
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

    set_if_absent(geodata, "mmdb-path", &format!("{home}/Country.mmdb"));
    set_if_absent(geodata, "asn-path", &format!("{home}/GeoLite2-ASN.mmdb"));
    set_if_absent(geodata, "geosite-path", &format!("{home}/geosite.dat"));

    serde_yaml::to_string(&root).unwrap_or_else(|_| yaml.to_string())
}

fn set_if_absent(map: &mut Mapping, key: &str, value: &str) {
    let key = Value::String(key.to_string());
    if !map.contains_key(&key) {
        map.insert(key, Value::String(value.to_string()));
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
    fn preserves_user_paths() {
        let out = pin_geodata_paths("geodata:\n  mmdb-path: /custom/C.mmdb\n", "/home/x");
        assert!(out.contains("/custom/C.mmdb"));
        assert!(!out.contains("/home/x/Country.mmdb"));
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
