package main

/*
#include <stdint.h>
#include <stdlib.h>
*/
import "C"

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"

	"golang.org/x/net/proxy"
)

const (
	diagConnectTimeout = 5 * time.Second
	diagIOTimeout      = 10 * time.Second
)

//export bridge_test_direct_tcp
func bridge_test_direct_tcp(host *C.char, port C.int32_t) *C.char {
	if host == nil {
		return C.CString("FAIL: host is null")
	}
	h := C.GoString(host)
	addr := net.JoinHostPort(h, fmt.Sprintf("%d", int(port)))
	start := time.Now()
	conn, err := net.DialTimeout("tcp", addr, diagConnectTimeout)
	elapsed := time.Since(start)
	if err != nil {
		return C.CString(fmt.Sprintf("FAIL after %s: %v", elapsed, err))
	}
	_ = conn.Close()
	return C.CString(fmt.Sprintf("OK: connected in %s", elapsed))
}

//export bridge_test_proxy_http
func bridge_test_proxy_http(target *C.char) *C.char {
	if target == nil {
		return C.CString("FAIL: target is null")
	}
	t := C.GoString(target)

	dialer, err := proxy.SOCKS5("tcp", "127.0.0.1:7890", nil, &net.Dialer{Timeout: diagConnectTimeout})
	if err != nil {
		return C.CString(fmt.Sprintf("FAIL: socks5 dialer: %v", err))
	}
	client := &http.Client{
		Timeout: diagIOTimeout,
		Transport: &http.Transport{
			Dial: dialer.Dial,
		},
	}
	start := time.Now()
	req, err := http.NewRequest("GET", t, nil)
	if err != nil {
		return C.CString(fmt.Sprintf("FAIL: new request: %v", err))
	}
	resp, err := client.Do(req)
	elapsed := time.Since(start)
	if err != nil {
		return C.CString(fmt.Sprintf("FAIL after %s: %v", elapsed, err))
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1024))
	return C.CString(fmt.Sprintf("OK: HTTP/%d.%d %d %s in %s",
		resp.ProtoMajor, resp.ProtoMinor, resp.StatusCode, resp.Status, elapsed))
}

//export bridge_test_dns_resolver
func bridge_test_dns_resolver(dnsAddr *C.char) *C.char {
	if dnsAddr == nil {
		return C.CString("FAIL: dns addr is null")
	}
	addr := C.GoString(dnsAddr)

	// Minimal DNS A query for "www.google.com"
	query := buildDNSQuery("www.google.com")
	conn, err := net.DialTimeout("udp", addr, diagConnectTimeout)
	if err != nil {
		return C.CString(fmt.Sprintf("FAIL: dial %s: %v", addr, err))
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(diagIOTimeout))

	if _, err := conn.Write(query); err != nil {
		return C.CString(fmt.Sprintf("FAIL: write: %v", err))
	}
	buf := make([]byte, 512)
	n, err := conn.Read(buf)
	if err != nil {
		return C.CString(fmt.Sprintf("FAIL: read: %v", err))
	}
	ip := firstAFromDNSResponse(buf[:n])
	if ip == nil {
		return C.CString("FAIL: no A record in response")
	}
	isFake := ip[0] == 198 && ip[1] == 18
	return C.CString(fmt.Sprintf("OK: resolved %s fake-ip=%v", ip, isFake))
}

// buildDNSQuery constructs a minimal DNS query packet for a single A record.
func buildDNSQuery(name string) []byte {
	buf := make([]byte, 0, 64)
	// Header: id=0x1234, flags=0x0100 (standard query, RD), QDCOUNT=1
	buf = append(buf, 0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)
	for _, label := range strings.Split(name, ".") {
		buf = append(buf, byte(len(label)))
		buf = append(buf, label...)
	}
	buf = append(buf, 0x00) // root
	// QTYPE=A, QCLASS=IN
	buf = append(buf, 0x00, 0x01, 0x00, 0x01)
	return buf
}

// firstAFromDNSResponse extracts the first A record from a DNS response. Returns
// nil if parsing fails or no A record is present.
func firstAFromDNSResponse(resp []byte) net.IP {
	if len(resp) < 12 {
		return nil
	}
	ancount := int(resp[6])<<8 | int(resp[7])
	if ancount == 0 {
		return nil
	}
	// Skip header
	pos := 12
	// Skip question section (1 question)
	for pos < len(resp) && resp[pos] != 0 {
		pos += int(resp[pos]) + 1
	}
	pos += 1 + 4 // null terminator + QTYPE + QCLASS
	// Parse answer records
	for i := 0; i < ancount && pos+12 <= len(resp); i++ {
		// Skip NAME (assume compression pointer 0xc0xx or full labels)
		if resp[pos]&0xc0 == 0xc0 {
			pos += 2
		} else {
			for pos < len(resp) && resp[pos] != 0 {
				pos += int(resp[pos]) + 1
			}
			pos++
		}
		if pos+10 > len(resp) {
			return nil
		}
		atype := int(resp[pos])<<8 | int(resp[pos+1])
		rdlen := int(resp[pos+8])<<8 | int(resp[pos+9])
		pos += 10
		if pos+rdlen > len(resp) {
			return nil
		}
		if atype == 1 && rdlen == 4 {
			return net.IPv4(resp[pos], resp[pos+1], resp[pos+2], resp[pos+3])
		}
		pos += rdlen
	}
	return nil
}

//export bridge_test_selected_proxy
func bridge_test_selected_proxy(apiAddr *C.char) *C.char {
	if apiAddr == nil {
		return C.CString("FAIL: api addr is null")
	}
	base := "http://" + C.GoString(apiAddr)

	client := &http.Client{Timeout: diagIOTimeout}

	// 1. List all proxies
	resp, err := client.Get(base + "/proxies")
	if err != nil {
		return C.CString(fmt.Sprintf("FAIL: GET /proxies: %v", err))
	}
	var top struct {
		Proxies map[string]struct {
			Type string   `json:"type"`
			Now  string   `json:"now"`
			All  []string `json:"all"`
		} `json:"proxies"`
	}
	err = json.NewDecoder(resp.Body).Decode(&top)
	resp.Body.Close()
	if err != nil {
		return C.CString(fmt.Sprintf("FAIL: decode /proxies: %v", err))
	}

	// 2. Find first Selector group with a non-trivial selection
	var groupName, selected, proxyType string
	for name, p := range top.Proxies {
		if p.Type != "Selector" {
			continue
		}
		if name == "GLOBAL" {
			continue
		}
		if p.Now == "" || p.Now == "DIRECT" || p.Now == "REJECT" {
			continue
		}
		groupName = name
		selected = p.Now
		break
	}
	if groupName == "" {
		return C.CString("FAIL: no Selector group with a real proxy selected")
	}
	if p, ok := top.Proxies[selected]; ok {
		proxyType = p.Type
	}

	// 3. Measure delay for the selected node
	delayURL := fmt.Sprintf("%s/proxies/%s/delay?url=%s&timeout=5000",
		base, url.PathEscape(selected),
		url.QueryEscape("http://www.gstatic.com/generate_204"))
	resp, err = client.Get(delayURL)
	if err != nil {
		return C.CString(fmt.Sprintf("FAIL: GET delay: %v", err))
	}
	var delayResp struct {
		Delay   int    `json:"delay"`
		Message string `json:"message"`
	}
	err = json.NewDecoder(resp.Body).Decode(&delayResp)
	resp.Body.Close()
	if err != nil {
		return C.CString(fmt.Sprintf("FAIL: decode delay: %v", err))
	}
	if delayResp.Message != "" {
		return C.CString(fmt.Sprintf("FAIL: group=%s selected=%s type=%s error=%s",
			groupName, selected, proxyType, delayResp.Message))
	}
	return C.CString(fmt.Sprintf("OK: group=%s selected=%s type=%s delay=%dms",
		groupName, selected, proxyType, delayResp.Delay))
}
