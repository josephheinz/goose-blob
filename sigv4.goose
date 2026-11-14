// AWS Signature Version 4: canonical request, string to sign, signing key, the Authorization header and
// presigned query strings. One signing path for both. SHA-256 and HMAC come from gweb (gweb.auth.crypto).
// Tested against AWS's published test suite and the S3 examples (test/test_sigv4.goose).
namespace blob;

import std;
import gweb.auth.crypto;

let EMPTY_SHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
let UNSIGNED_PAYLOAD = "UNSIGNED-PAYLOAD";
let _HEX = "0123456789abcdef";
let _HEXU = "0123456789ABCDEF";

fn hex_lower(out: u8[>..]&, data: const u8[:]) {
    for b in data { out.push(_HEX[b >> 4]); out.push(_HEX[b & 15]); }
}

fn sha256_hex(out: u8[>..]&, data: const u8[:]) -> bool {
    var d: u8[..32] = [0; 32];
    if !gweb::sha256(d, data) { return false; }
    hex_lower(out, d);
    return true;
}

fn _unreserved(c: u8) -> bool {
    (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '.' || c == '_' || c == '~'
}

// RFC 3986 encoding as SigV4 wants it: unreserved bytes kept, the rest %XX in capitals; '/' kept when keep_slash.
fn uri_encode(out: u8[>..]&, s: const u8[:], keep_slash: bool) {
    for c in s {
        if _unreserved(c) || (keep_slash && c == '/') { out.push(c); }
        else { out.push('%'); out.push(_HEXU[c >> 4]); out.push(_HEXU[c & 15]); }
    }
}

// Percent-decodes s ('+' stays '+'); a bad escape is kept as it is.
fn _pct_decode(out: u8[>..]&, s: const u8[:]) {
    var i = 0;
    while i < s.len {
        if s[i] == '%' && i + 2 < s.len {
            let a = ascii::hex_value(s[i + 1]);
            let b = ascii::hex_value(s[i + 2]);
            if a >= 0 && b >= 0 { out.push((a * 16 + b) as u8); i += 3; continue; }
        }
        out.push(s[i]);
        i += 1;
    }
}

struct _Pair { k: u8[..1024] = "", v: u8[..4096] = "" }

// The canonical query string: each name and value decoded, then encoded once, sorted by name and then value.
// A name without '=' gets an empty value.
fn canonical_query(out: u8[>..]&, query: const u8[:]) {
    if query.len == 0 { return; }
    var ps: _Pair[>..] = [];
    each_split(query, '&') {
        if it.len > 0 {
            let k, v, _ = split_once(it, '=');
            var dk: u8[>..] = [];
            var dv: u8[>..] = [];
            _pct_decode(dk, k);
            _pct_decode(dv, v);
            var p = _Pair { .. };
            var ek: u8[>..] = [];
            var ev: u8[>..] = [];
            uri_encode(ek, dk, false);
            uri_encode(ev, dv, false);
            if ek.len <= p.k.cap && ev.len <= p.v.cap {
                p.k.append(ek);
                p.v.append(ev);
                ps.push(p);
            }
        }
    };
    sort(ps) { a, b => block { let c = compare(a.k, b.k); if c != 0 { break c < 0; } compare(a.v, b.v) < 0 } };
    for p, i in ps {
        if i > 0 { out.push('&'); }
        out.append(p.k);
        out.push('=');
        out.append(p.v);
    }
}

struct _Header { name: u8[..128] = "", value: u8[..4096] = "", at: i64 = 0 }

// Parses "Name: value" lines (split by '\n'; a '\r' before it is dropped) into lowercase names and values with
// the ends trimmed and runs of spaces collapsed, sorted by name, lines of one name kept in order.
fn _parse_headers(hs: _Header[>..]&, headers: const u8[:]) -> bool {
    var n = 0;
    var bad = false;
    each_split(headers, '\n') {
        var line = it;
        if line.len > 0 && line[line.len - 1] == '\r' { line = line[..line.len - 1]; }
        if trim(line).len > 0 {
            let name, value, has = split_once(line, ':');
            let tn = trim(name);
            if !has || tn.len == 0 || tn.len > 128 { bad = true; }
            else {
                var h = _Header { at: n, .. };
                h.name.append(tn);
                to_lower(h.name);
                var prev_space = false;
                for c in trim(value) {
                    let space = c == ' ' || c == '\t';
                    if space && prev_space { continue; }
                    prev_space = space;
                    if h.value.len == h.value.cap { bad = true; break; }
                    h.value.push(if space { ' ' as u8 } else { c });
                }
                hs.push(h);
                n += 1;
            }
        }
    };
    sort(hs) { a, b => block { let c = compare(a.name, b.name); if c != 0 { break c < 0; } a.at < b.at } };
    return !bad;
}

// The canonical request, and in signed the signed header list ("host;x-amz-date"). path is the URI path as sent
// (already encoded); query as sent, or ""; headers as "Name: value" lines, every one of them signed.
fn canonical_request(out: u8[>..]&, signed: u8[>..]&, method: const u8[:], path: const u8[:], query: const u8[:],
                     headers: const u8[:], payload_hash: const u8[:]) -> bool {
    var hs: _Header[>..] = [];
    if !_parse_headers(hs, headers) { return false; }
    out.append(method);
    out.push('\n');
    out.append(if path.len == 0 { "/" } else { path });
    out.push('\n');
    canonical_query(out, query);
    out.push('\n');
    var i = 0;
    while i < hs.len {
        out.append(hs[i].name);
        out.push(':');
        out.append(hs[i].value);
        var j = i + 1;
        while j < hs.len && hs[j].name == hs[i].name { out.push(','); out.append(hs[j].value); j += 1; }
        out.push('\n');
        if signed.len > 0 { signed.push(';'); }
        signed.append(hs[i].name);
        i = j;
    }
    out.push('\n');
    out.append(signed);
    out.push('\n');
    out.append(payload_hash);
    return true;
}

// "20150830/us-east-1/service/aws4_request"; amz_date is "20150830T123600Z".
fn credential_scope(out: u8[>..]&, amz_date: const u8[:], region: const u8[:], service: const u8[:]) {
    out.append(amz_date[..min(8, amz_date.len)]);
    out.push('/'); out.append(region);
    out.push('/'); out.append(service);
    out.append("/aws4_request");
}

fn string_to_sign(out: u8[>..]&, amz_date: const u8[:], scope: const u8[:], creq: const u8[:]) -> bool {
    out.append("AWS4-HMAC-SHA256\n");
    out.append(amz_date);
    out.push('\n');
    out.append(scope);
    out.push('\n');
    return sha256_hex(out, creq);
}

fn signing_key(key: u8[..32]&, secret: const u8[:], amz_date: const u8[:], region: const u8[:], service: const u8[:]) -> bool {
    var k0: u8[>..] = [];
    k0.append("AWS4");
    k0.append(secret);
    var a: u8[..32] = [0; 32];
    var b: u8[..32] = [0; 32];
    if !gweb::hmac_sha256(a, k0, amz_date[..min(8, amz_date.len)]) { return false; }
    if !gweb::hmac_sha256(b, a, region) { return false; }
    if !gweb::hmac_sha256(a, b, service) { return false; }
    return gweb::hmac_sha256(key, a, "aws4_request");
}

// The hex signature of a canonical request.
fn signature(out: u8[>..]&, secret: const u8[:], amz_date: const u8[:], region: const u8[:], service: const u8[:],
             creq: const u8[:]) -> bool {
    var scope: u8[>..] = [];
    credential_scope(scope, amz_date, region, service);
    var sts: u8[>..] = [];
    if !string_to_sign(sts, amz_date, scope, creq) { return false; }
    var key: u8[..32] = [0; 32];
    if !signing_key(key, secret, amz_date, region, service) { return false; }
    var sig: u8[..32] = [0; 32];
    if !gweb::hmac_sha256(sig, key, sts) { return false; }
    hex_lower(out, sig);
    return true;
}

// The Authorization header's value for a request whose headers (host and x-amz-date among them) are all signed.
fn authorization(out: u8[>..]&, access_id: const u8[:], secret: const u8[:], amz_date: const u8[:], region: const u8[:],
                 service: const u8[:], method: const u8[:], path: const u8[:], query: const u8[:], headers: const u8[:],
                 payload_hash: const u8[:]) -> bool {
    var creq: u8[>..] = [];
    var signed: u8[>..] = [];
    if !canonical_request(creq, signed, method, path, query, headers, payload_hash) { return false; }
    var sig: u8[>..] = [];
    if !signature(sig, secret, amz_date, region, service, creq) { return false; }
    out.append("AWS4-HMAC-SHA256 Credential=");
    out.append(access_id);
    out.push('/');
    credential_scope(out, amz_date, region, service);
    out.append(", SignedHeaders=");
    out.append(signed);
    out.append(", Signature=");
    out.append(sig);
    return true;
}

// A presigned query string (no leading '?'): query (as sent, may be "") plus the X-Amz-* parameters and the
// signature, for a request with these headers (host at least), payload UNSIGNED-PAYLOAD. ttl_s is X-Amz-Expires.
fn presign_query(out: u8[>..]&, access_id: const u8[:], secret: const u8[:], token: const u8[:], amz_date: const u8[:],
                 region: const u8[:], service: const u8[:], ttl_s: i64, method: const u8[:], path: const u8[:],
                 query: const u8[:], headers: const u8[:]) -> bool {
    var hs: _Header[>..] = [];
    if !_parse_headers(hs, headers) { return false; }
    var signed: u8[>..] = [];
    for h, i in hs {
        if i > 0 && h.name == hs[i - 1].name { continue; }
        if signed.len > 0 { signed.push(';'); }
        signed.append(h.name);
    }
    var cred: u8[>..] = [];
    cred.append(access_id);
    cred.push('/');
    credential_scope(cred, amz_date, region, service);
    var q: u8[>..] = [];
    if query.len > 0 { q.append(query); q.push('&'); }
    q.append("X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=");
    uri_encode(q, cred, false);
    q.append("&X-Amz-Date=");
    q.append(amz_date);
    format(q, "&X-Amz-Expires=", ttl_s);
    if token.len > 0 { q.append("&X-Amz-Security-Token="); uri_encode(q, token, false); }
    q.append("&X-Amz-SignedHeaders=");
    uri_encode(q, signed, false);
    var creq: u8[>..] = [];
    var signed2: u8[>..] = [];
    if !canonical_request(creq, signed2, method, path, q, headers, UNSIGNED_PAYLOAD) { return false; }
    var sig: u8[>..] = [];
    if !signature(sig, secret, amz_date, region, service, creq) { return false; }
    out.append(q);
    out.append("&X-Amz-Signature=");
    out.append(sig);
    return true;
}

// ---------------------------------------------------------------- time

fn _pad(out: u8[>..]&, n: i64, width: i64) { format_int(out, n, 10, width, '0'); }

// Days since 1970-01-01 to a civil date (Howard Hinnant's civil_from_days).
fn _civil(days: i64) -> i64, i64, i64 {
    let z = days + 719468;
    let era = div_euclid(z, 146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + (if m <= 2 { 1 } else { 0 });
    return y, m, d;
}

fn _days(y0: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y0 - 1 } else { y0 };
    let era = div_euclid(y, 400);
    let yoe = y - era * 400;
    let mm = if m > 2 { m - 3 } else { m + 9 };
    let doy = (153 * mm + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + doe - 719468;
}

// "20150830T123600Z" for Unix seconds.
fn amz_date(out: u8[>..]&, unix: i64) {
    let y, m, d = _civil(div_euclid(unix, 86400));
    let rem = unix % 86400;
    _pad(out, y, 4); _pad(out, m, 2); _pad(out, d, 2);
    out.push('T');
    _pad(out, rem / 3600, 2); _pad(out, (rem % 3600) / 60, 2); _pad(out, rem % 60, 2);
    out.push('Z');
}

fn _num(s: const u8[:], at: i64, n: i64) -> i64, bool {
    if at + n > s.len { return 0, false; }
    var v = 0;
    for i in at..at + n {
        if !ascii::is_digit(s[i]) { return 0, false; }
        v = v * 10 + (s[i] - '0');
    }
    return v, true;
}

// Unix seconds for "2013-05-24T00:00:00.000Z" (fraction optional).
fn parse_iso_time(s: const u8[:]) -> i64, bool {
    let y, a = _num(s, 0, 4);
    let mo, b = _num(s, 5, 2);
    let d, c = _num(s, 8, 2);
    let h, e = _num(s, 11, 2);
    let mi, f = _num(s, 14, 2);
    let se, g = _num(s, 17, 2);
    if !(a && b && c && e && f && g) || s[4] != '-' || s[7] != '-' || s[10] != 'T' || s[13] != ':' || s[16] != ':' { return 0, false; }
    return _days(y, mo, d) * 86400 + h * 3600 + mi * 60 + se, true;
}

let _MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

// Unix seconds for an HTTP date, "Fri, 24 May 2013 00:00:00 GMT".
fn parse_http_time(text: const u8[:]) -> i64, bool {
    let s = trim(text);
    if s.len != 29 || s[3] != ',' || s[26..] != "GMT" { return 0, false; }
    let d, a = _num(s, 5, 2);
    let y, b = _num(s, 12, 4);
    let h, c = _num(s, 17, 2);
    let mi, e = _num(s, 20, 2);
    let se, f = _num(s, 23, 2);
    var mo = 0;
    for name, i in _MONTHS { if s[8..11] == name { mo = i + 1; } }
    if !(a && b && c && e && f) || mo == 0 { return 0, false; }
    return _days(y, mo, d) * 86400 + h * 3600 + mi * 60 + se, true;
}
