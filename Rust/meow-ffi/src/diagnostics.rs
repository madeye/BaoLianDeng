//! Connectivity diagnostics. Each returns a human-readable `OK: ...` / `FAIL:
//! ...` string (never an error code); the FFI layer wraps them into heap
//! C strings freed by the caller via `bridge_free_string`.

use std::fmt::Write as _;
use std::net::{TcpStream, ToSocketAddrs, UdpSocket};
use std::time::{Duration, Instant};

const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
const IO_TIMEOUT: Duration = Duration::from_secs(10);

/// Direct TCP connect with a 5s timeout; reports elapsed time.
pub fn test_direct_tcp(host: &str, port: i32) -> String {
    if host.is_empty() {
        return "FAIL: host is null".to_string();
    }
    let addr = format!("{host}:{port}");
    let sockaddr = match addr.to_socket_addrs().ok().and_then(|mut it| it.next()) {
        Some(a) => a,
        None => return format!("FAIL: cannot resolve {addr}"),
    };
    let start = Instant::now();
    match TcpStream::connect_timeout(&sockaddr, CONNECT_TIMEOUT) {
        Ok(_) => format!("OK: connected in {:?}", start.elapsed()),
        Err(e) => format!("FAIL after {:?}: {e}", start.elapsed()),
    }
}

/// HTTP GET through our own SOCKS5 at `127.0.0.1:<runtime socks port>`.
pub fn test_proxy_http(target: &str) -> String {
    if target.is_empty() {
        return "FAIL: target is null".to_string();
    }
    let socks_port = crate::current_socks_port();
    if socks_port == 0 {
        return "FAIL: proxy not running (socks port unset)".to_string();
    }
    let target = target.to_string();
    crate::runtime().block_on(async move {
        let proxy = match reqwest::Proxy::all(format!("socks5h://127.0.0.1:{socks_port}")) {
            Ok(p) => p,
            Err(e) => return format!("FAIL: socks5 proxy: {e}"),
        };
        let client = match reqwest::Client::builder()
            .proxy(proxy)
            .timeout(IO_TIMEOUT)
            .build()
        {
            Ok(c) => c,
            Err(e) => return format!("FAIL: build client: {e}"),
        };
        let start = Instant::now();
        match client.get(&target).send().await {
            Ok(resp) => format!(
                "OK: HTTP {} in {:?}",
                resp.status().as_u16(),
                start.elapsed()
            ),
            Err(e) => format!("FAIL after {:?}: {e}", start.elapsed()),
        }
    })
}

/// Hand-built UDP DNS A query for www.google.com; parses the first A record and
/// flags 198.18.0.0/15 as a fake-ip address in the result.
pub fn test_dns_resolver(dns_addr: &str) -> String {
    if dns_addr.is_empty() {
        return "FAIL: dns addr is null".to_string();
    }
    let sock = match UdpSocket::bind("127.0.0.1:0") {
        Ok(s) => s,
        Err(e) => return format!("FAIL: bind: {e}"),
    };
    let _ = sock.set_read_timeout(Some(IO_TIMEOUT));
    if let Err(e) = sock.connect(dns_addr) {
        return format!("FAIL: connect {dns_addr}: {e}");
    }
    let query = build_dns_query("www.google.com");
    if let Err(e) = sock.send(&query) {
        return format!("FAIL: write: {e}");
    }
    let mut buf = [0u8; 512];
    match sock.recv(&mut buf) {
        Ok(n) => match first_a_record(&buf[..n]) {
            Some(ip) => {
                // 198.18.0.0/15 == 198.18.x.x or 198.19.x.x.
                let fake = ip[0] == 198 && (ip[1] == 18 || ip[1] == 19);
                format!(
                    "OK: resolved {}.{}.{}.{} fake-ip={fake}",
                    ip[0], ip[1], ip[2], ip[3]
                )
            }
            None => "FAIL: no A record in response".to_string(),
        },
        Err(e) => format!("FAIL: read: {e}"),
    }
}

/// Query the REST controller: find the first non-GLOBAL Selector group with a
/// real node selected, then probe that node's delay.
pub fn test_selected_proxy(api_addr: &str) -> String {
    if api_addr.is_empty() {
        return "FAIL: api addr is null".to_string();
    }
    let base = format!("http://{api_addr}");
    crate::runtime().block_on(async move {
        let client = match reqwest::Client::builder().timeout(IO_TIMEOUT).build() {
            Ok(c) => c,
            Err(e) => return format!("FAIL: build client: {e}"),
        };

        let top: serde_json::Value = match client.get(format!("{base}/proxies")).send().await {
            Ok(r) => match r.json().await {
                Ok(v) => v,
                Err(e) => return format!("FAIL: decode /proxies: {e}"),
            },
            Err(e) => return format!("FAIL: GET /proxies: {e}"),
        };
        let proxies = match top.get("proxies").and_then(|v| v.as_object()) {
            Some(p) => p,
            None => return "FAIL: no proxies object".to_string(),
        };

        let mut group_name = String::new();
        let mut selected = String::new();
        for (name, info) in proxies {
            if info.get("type").and_then(|v| v.as_str()) != Some("Selector") {
                continue;
            }
            if name == "GLOBAL" {
                continue;
            }
            let now = info.get("now").and_then(|v| v.as_str()).unwrap_or("");
            if now.is_empty() || now == "DIRECT" || now == "REJECT" {
                continue;
            }
            group_name = name.clone();
            selected = now.to_string();
            break;
        }
        if group_name.is_empty() {
            return "FAIL: no Selector group with a real proxy selected".to_string();
        }
        let proxy_type = proxies
            .get(&selected)
            .and_then(|p| p.get("type"))
            .and_then(|v| v.as_str())
            .unwrap_or("unknown")
            .to_string();

        let delay_url = format!("{base}/proxies/{}/delay", encode_path_segment(&selected));
        let delay: serde_json::Value = match client
            .get(&delay_url)
            .query(&[
                ("url", "http://www.gstatic.com/generate_204"),
                ("timeout", "5000"),
            ])
            .send()
            .await
        {
            Ok(r) => match r.json().await {
                Ok(v) => v,
                Err(e) => return format!("FAIL: decode delay: {e}"),
            },
            Err(e) => return format!("FAIL: GET delay: {e}"),
        };
        let message = delay.get("message").and_then(|v| v.as_str()).unwrap_or("");
        if !message.is_empty() {
            return format!(
                "FAIL: group={group_name} selected={selected} type={proxy_type} error={message}"
            );
        }
        let ms = delay.get("delay").and_then(|v| v.as_i64()).unwrap_or(0);
        format!("OK: group={group_name} selected={selected} type={proxy_type} delay={ms}ms")
    })
}

// --- DNS wire helpers (mirrors the Go bridge) ---

fn build_dns_query(name: &str) -> Vec<u8> {
    let mut buf = Vec::with_capacity(64);
    // id=0x1234, flags=0x0100 (RD), QDCOUNT=1
    buf.extend_from_slice(&[
        0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]);
    for label in name.split('.') {
        buf.push(label.len() as u8);
        buf.extend_from_slice(label.as_bytes());
    }
    buf.push(0x00); // root
    buf.extend_from_slice(&[0x00, 0x01, 0x00, 0x01]); // QTYPE=A, QCLASS=IN
    buf
}

fn first_a_record(msg: &[u8]) -> Option<[u8; 4]> {
    if msg.len() < 12 {
        return None;
    }
    let qdcount = ((msg[4] as usize) << 8) | msg[5] as usize;
    let ancount = ((msg[6] as usize) << 8) | msg[7] as usize;
    if ancount == 0 {
        return None;
    }
    let mut pos = 12;
    // Skip question section.
    for _ in 0..qdcount {
        while pos < msg.len() {
            let len = msg[pos] as usize;
            pos += 1;
            if len == 0 {
                break;
            }
            if len & 0xc0 == 0xc0 {
                pos += 1;
                break;
            }
            pos += len;
        }
        pos += 4; // QTYPE + QCLASS
    }
    // Answer records.
    for _ in 0..ancount {
        if pos >= msg.len() {
            return None;
        }
        if msg[pos] & 0xc0 == 0xc0 {
            pos += 2;
        } else {
            while pos < msg.len() {
                let len = msg[pos] as usize;
                pos += 1;
                if len == 0 {
                    break;
                }
                pos += len;
            }
        }
        if pos + 10 > msg.len() {
            return None;
        }
        let atype = ((msg[pos] as usize) << 8) | msg[pos + 1] as usize;
        let rdlen = ((msg[pos + 8] as usize) << 8) | msg[pos + 9] as usize;
        pos += 10;
        if pos + rdlen > msg.len() {
            return None;
        }
        if atype == 1 && rdlen == 4 {
            return Some([msg[pos], msg[pos + 1], msg[pos + 2], msg[pos + 3]]);
        }
        pos += rdlen;
    }
    None
}

/// Percent-encode a proxy name for use as a single URL path segment.
fn encode_path_segment(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char);
            }
            _ => {
                let _ = write!(out, "%{b:02X}");
            }
        }
    }
    out
}
