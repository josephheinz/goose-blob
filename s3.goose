// The S3-compatible backend: requests over libcurl (src/curl.c), signed with SigV4 in the Authorization header.
// A file body is sent as UNSIGNED-PAYLOAD (TLS carries it; nothing hashes the file), a buffer with its SHA-256.
namespace blob;

import std;
import os;
import sigv4;

// The response limit is set by c_set_limit right before each call (max_body 0). Passing it through _s3_call as an
// i64 parameter arrived as a different value on x86-64 Linux (goose 2026.4); see NOTES-FOR-GWEB.md.
extern fn c_http(max_body: i64, method: const u8[:], url: const u8[:], headers: const u8[:], body: const u8[:], body_path: const u8[:],
                 out_path: const u8[:], out_body: u8[>..]&, out_headers: u8[>..]&, status: i64&,
                 ca_file: const u8[:]) -> i32 = "gblob_http";
extern fn c_set_limit(n: i64) = "gblob_set_limit";
extern fn c_cred_put(id: const u8[:], secret: const u8[:], token: const u8[:]) -> i64 = "gblob_cred_put";
extern fn c_cred_get(h: i64, which: i32, out: u8[>..]&) = "gblob_cred_get";

let _ERR_BODY_MAX = 65536;
let _LIST_MAX = 16777216;

fn _bucket_ok(b: const u8[:]) -> bool {
    if b.len < 3 || b.len > 63 { return false; }
    for c in b { if !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' || c == '-') { return false; } }
    return b[0] != '.' && b[0] != '-' && b[b.len - 1] != '.' && b[b.len - 1] != '-';
}

fn _loopback(host: const u8[:]) -> bool {
    var h = host;
    if starts_with(h, "[") { let e = find(h, "]"); if e > 0 { h = h[1..e]; } }
    else { let c = find(h, ":"); if c >= 0 { h = h[..c]; } }
    return h == "localhost" || h == "127.0.0.1" || h == "::1" || ends_with(h, ".localhost");
}

fn _s3_open(s: Store&, rest: const u8[:], access_id: const u8[:], secret: const u8[:], token: const u8[:]) -> bool {
    let place, query, _ = split_once(rest, '?');
    let bucket, prefix, _ = split_once(place, '/');
    if !_bucket_ok(bucket) { return _fail("bad bucket name", bucket); }
    _set(s.bucket, bucket);
    var pre = prefix;
    while pre.len > 0 && pre[pre.len - 1] == '/' { pre = pre[..pre.len - 1]; }
    if pre.len > 0 {
        if !key_ok(pre) || pre.len > MAX_KEY - 2 { return _fail("bad prefix", pre); }
        s.prefix.append(pre);
        s.prefix.push('/');
    }
    var endpoint: u8[>..] = [];
    var style: u8[>..] = [];
    var plain_http = false;
    var region_set = false;
    var bad = false;
    each_split(query, '&') {
        if it.len > 0 {
            let k, v0, _ = split_once(it, '=');
            var v: u8[>..] = [];
            _pct_decode(v, v0);
            if k == "endpoint" { endpoint.append(v); }
            else if k == "region" { if v.len == 0 || !_set(s.region, v) { bad = true; } region_set = true; }
            else if k == "style" { style.append(v); }
            else if k == "plain_http" { plain_http = v == "1"; }
            else { bad = true; _fail("unknown parameter", k); }
        }
    };
    if bad { if _err.len == 0 { _fail("bad region"); } return false; }
    for c in s.region { if !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-') { return _fail("bad region", s.region); } }
    if endpoint.len == 0 {
        s.scheme.clear(); s.scheme.append("https");
        s.host.clear();
        format(s.host, "s3.", s.region, ".amazonaws.com");
        s.path_style = false;
    } else {
        var e: const u8[:] = endpoint;
        if starts_with(e, "https://") { s.scheme.clear(); s.scheme.append("https"); e = e[8..]; }
        else if starts_with(e, "http://") { s.scheme.clear(); s.scheme.append("http"); e = e[7..]; }
        else { return _fail("endpoint must start with https:// or http://"); }
        while e.len > 0 && e[e.len - 1] == '/' { e = e[..e.len - 1]; }
        if e.len == 0 || find(e, "/") >= 0 || find(e, "?") >= 0 || find(e, "@") >= 0 { return _fail("endpoint must be a scheme and host[:port] only"); }
        for c in e { if c <= ' ' || c >= 127 { return _fail("bad endpoint"); } }
        if !_set(s.host, e) { return _fail("endpoint too long"); }
        if s.scheme == "http" && !_loopback(s.host) && !plain_http {
            return _fail("http:// endpoints are for localhost; add plain_http=1 to send keys and data unencrypted");
        }
        s.path_style = true;
    }
    if style == "path" { s.path_style = true; }
    else if style == "virtual" { s.path_style = false; }
    else if style.len > 0 { return _fail("style must be path or virtual"); }
    if access_id.len == 0 || secret.len == 0 {
        return _fail("no S3 credentials: set BLOB_ACCESS_KEY_ID and BLOB_SECRET_ACCESS_KEY (or AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY)");
    }
    for c in access_id { if c <= ' ' || c >= 127 { return _fail("bad access key id"); } }
    s.cred = c_cred_put(access_id, secret, token);
    if s.cred == 0 { return _fail("too many distinct S3 credentials in one process (64)"); }
    var ca: u8[>..] = [];
    env("BLOB_CA_FILE", ca);
    if !_set(s.ca_file, ca) { return _fail("BLOB_CA_FILE is too long"); }
    return true;
}

// ---------------------------------------------------------------- requests

fn _authority(out: u8[>..]&, s: const Store&) {
    if !s.path_style { out.append(s.bucket); out.push('.'); }
    out.append(s.host);
}

// The URI path of an object (key "" for the bucket itself): /bucket/prefix/key or /prefix/key.
fn _uri_path(out: u8[>..]&, s: const Store&, key: const u8[:]) {
    out.push('/');
    if s.path_style { out.append(s.bucket); out.push('/'); }
    var full: u8[>..] = [];
    if key.len > 0 { full.append(s.prefix); full.append(key); }
    uri_encode(out, full, true);
}

fn _header_value_ok(v: const u8[:]) -> bool {
    for c in v { if c < ' ' || c == 127 { return false; } }
    return true;
}

// The signed header block for a request at unix time t: Host, x-amz-date, x-amz-content-sha256, the session token,
// the extra lines, and Authorization.
fn _s3_sign(out: u8[>..]&, s: const Store&, method: const u8[:], path: const u8[:], query: const u8[:],
            extra: const u8[:], payload: const u8[:], t: i64) -> bool {
    var id: u8[>..] = [];
    var secret: u8[>..] = [];
    var token: u8[>..] = [];
    c_cred_get(s.cred, 0, id);
    c_cred_get(s.cred, 1, secret);
    c_cred_get(s.cred, 2, token);
    var date: u8[>..] = [];
    amz_date(date, t);
    var hs: u8[>..] = [];
    hs.append("Host: "); _authority(hs, s); hs.push('\n');
    hs.append(extra);
    format(hs, "x-amz-content-sha256: ", payload, "\nx-amz-date: ", date, "\n");
    if token.len > 0 { format(hs, "x-amz-security-token: ", token, "\n"); }
    var auth: u8[>..] = [];
    if !authorization(auth, id, secret, date, s.region, "s3", method, path, query, hs, payload) { return _fail("signing failed"); }
    out.append(hs);
    format(out, "Authorization: ", auth, "\n");
    return true;
}

// The text of <tag>...</tag> in xml, or "".
fn _xml(xml: const u8[:], tag: const u8[:]) -> const u8[:] {
    var open: u8[..80] = "<";
    open.append(tag); open.push('>');
    var close: u8[..80] = "</";
    close.append(tag); close.push('>');
    let a = find(xml, open);
    if a < 0 { return ""; }
    let rest = xml[a + open.len..];
    let b = find(rest, close);
    if b < 0 { return ""; }
    return rest[..b];
}

fn _xml_unescape(out: u8[>..]&, s: const u8[:]) {
    var i = 0;
    while i < s.len {
        if s[i] == '&' {
            let r = s[i..];
            if starts_with(r, "&amp;") { out.push('&'); i += 5; continue; }
            if starts_with(r, "&lt;") { out.push('<'); i += 4; continue; }
            if starts_with(r, "&gt;") { out.push('>'); i += 4; continue; }
            if starts_with(r, "&quot;") { out.push('"'); i += 6; continue; }
            if starts_with(r, "&apos;") { out.push('\''); i += 6; continue; }
        }
        out.push(s[i]);
        i += 1;
    }
}

// A response header's value (the name in lowercase), or "" and false.
fn _rhead(heads: const u8[:], name: const u8[:]) -> const u8[:], bool {
    var found: const u8[:] = heads[0..0];
    var has = false;
    each_split(heads, '\n') {
        if !has {
            let k, v, colon = split_once(it, ':');
            if colon && k.len == name.len {
                var same = true;
                for c, i in k {
                    let l = if c >= 'A' && c <= 'Z' { c + 32 } else { c };
                    if l != name[i] { same = false; break; }
                }
                if same { found = trim(v); has = true; }
            }
        }
    };
    return found, has;
}

fn _status_fail(op: const u8[:], key: const u8[:], status: i64, body: const u8[:]) -> bool {
    let code = _xml(body, "Code");
    let msg = _xml(body, "Message");
    if status == 404 && (code.len == 0 || code == "NoSuchKey") { return _fail_missing(key); }
    var m: u8[>..] = [];
    format(m, "HTTP ", status);
    if code.len > 0 { m.append(" "); m.append(code[..min(code.len, 60)]); }
    if msg.len > 0 { m.append(": "); m.append(msg[..min(msg.len, 200)]); }
    return _fail(op, m);
}

// One signed request. The payload hash is UNSIGNED-PAYLOAD for a file body, else the SHA-256 of body.
fn _s3_call(s: const Store&, op: const u8[:], method: const u8[:], key: const u8[:], query: const u8[:],
            extra: const u8[:], body: const u8[:], body_path: const u8[:], out_path: const u8[:],
            out: u8[>..]&, heads: u8[>..]&, status: i64&) -> bool {
    var path: u8[>..] = [];
    _uri_path(path, s, key);
    var payload: u8[>..] = [];
    if body_path.len > 0 { payload.append(UNSIGNED_PAYLOAD); }
    else if !sha256_hex(payload, body) { return _fail("sha256 failed"); }
    var hs: u8[>..] = [];
    if !_s3_sign(hs, s, method, path, query, extra, payload, time() as i64) { return false; }
    var u: u8[>..] = [];
    u.append(s.scheme); u.append("://"); _authority(u, s); u.append(path);
    if query.len > 0 { u.push('?'); u.append(query); }
    if c_http(0, method, u, hs, body, body_path, out_path, out, heads, status, s.ca_file) == 0 {
        var e: u8[>..] = [];
        c_error(e);
        return _fail(op, e);
    }
    return true;
}

fn _put_headers(out: u8[>..]&, o: PutOptions) -> bool {
    if !_header_value_ok(o.content_type) || !_header_value_ok(o.cache_control) || !_header_value_ok(o.disposition) {
        return _fail("PutOptions holds a control character");
    }
    if o.content_type.len > 0 { format(out, "Content-Type: ", o.content_type, "\n"); }
    if o.cache_control.len > 0 { format(out, "Cache-Control: ", o.cache_control, "\n"); }
    else if o.immutable { out.append("Cache-Control: public, max-age=31536000, immutable\n"); }
    if o.disposition.len > 0 { format(out, "Content-Disposition: ", o.disposition, "\n"); }
    return true;
}

fn _s3_put(s: const Store&, key: const u8[:], path: const u8[:], data: const u8[:], from_file: bool, o: PutOptions) -> bool {
    var extra: u8[>..] = [];
    if !_put_headers(extra, o) { return false; }
    if from_file && path.len == 0 { return _fail("put_file needs a path"); }
    var body: u8[>..] = [];
    var heads: u8[>..] = [];
    var status = 0;
    c_set_limit(_ERR_BODY_MAX);
    if !_s3_call(s, "put", "PUT", key, "", extra, data, if from_file { path } else { "" }, "", body, heads, status) { return false; }
    if status != 200 { return _status_fail("put", key, status, body); }
    return _ok();
}

fn _s3_get(s: const Store&, key: const u8[:], off: i64, n: i64, max: i64, out: u8[>..]&) -> bool {
    var extra: u8[>..] = [];
    if n > 0 { format(extra, "Range: bytes=", off, "-", off + n - 1, "\n"); }
    var body: u8[>..] = [];
    var heads: u8[>..] = [];
    var status = 0;
    var cap: i64 = _ERR_BODY_MAX;
    if max > cap { cap = max; }
    c_set_limit(cap);
    if !_s3_call(s, "get", "GET", key, "", extra, "", "", "", body, heads, status) { return false; }
    if status == 416 && n > 0 { return _ok(); }                 // the range starts past the end
    if status != 200 && status != 206 { return _status_fail("get", key, status, body); }
    if body.len > max { return _fail("object larger than the limit", key); }
    out.append(body);
    return _ok();
}

fn _s3_get_file(s: const Store&, key: const u8[:], path: const u8[:]) -> bool {
    var body: u8[>..] = [];
    var heads: u8[>..] = [];
    var status = 0;
    c_set_limit(_ERR_BODY_MAX);
    if !_s3_call(s, "get_to_file", "GET", key, "", "", "", "", path, body, heads, status) { return false; }
    if status != 200 { return _status_fail("get_to_file", key, status, body); }
    return _ok();
}

fn _s3_head(s: const Store&, key: const u8[:], info: Info&) -> bool {
    var body: u8[>..] = [];
    var heads: u8[>..] = [];
    var status = 0;
    c_set_limit(_ERR_BODY_MAX);
    if !_s3_call(s, "head", "HEAD", key, "", "", "", "", "", body, heads, status) { return false; }
    if status == 404 { return _fail_missing(key); }
    if status != 200 { return _status_fail("head", key, status, body); }
    let len, _ = _rhead(heads, "content-length");
    let size, ok = parse_int(len);
    info.size = if ok { size } else { 0 };
    let etag, _ = _rhead(heads, "etag");
    _set(info.etag, etag[..min(etag.len, info.etag.cap)]);
    let ct, _ = _rhead(heads, "content-type");
    _set(info.content_type, ct[..min(ct.len, info.content_type.cap)]);
    let lm, _ = _rhead(heads, "last-modified");
    let t, tok = parse_http_time(lm);
    info.modified = if tok { t } else { 0 };
    return _ok();
}

fn _s3_delete(s: const Store&, key: const u8[:]) -> bool {
    var body: u8[>..] = [];
    var heads: u8[>..] = [];
    var status = 0;
    c_set_limit(_ERR_BODY_MAX);
    if !_s3_call(s, "delete", "DELETE", key, "", "", "", "", "", body, heads, status) { return false; }
    if status != 204 && status != 200 && status != 404 { return _status_fail("delete", key, status, body); }
    return _ok();
}

// ListObjectsV2 pages until out is full or the listing ends. Keys outside key_ok (written by something else) are
// skipped; the next page starts after the last key seen.
fn _s3_list(s: const Store&, prefix: const u8[:], after: const u8[:], out: Entry[..1000]&) -> bool {
    var start: u8[>..] = [];
    if after.len > 0 { start.append(s.prefix); start.append(after); }
    loop {
        let room = out.cap - out.len;
        if room <= 0 { break; }
        var q: u8[>..] = [];
        format(q, "list-type=2&max-keys=", room, "&prefix=");
        var full: u8[>..] = [];
        full.append(s.prefix); full.append(prefix);
        uri_encode(q, full, false);
        if start.len > 0 { q.append("&start-after="); uri_encode(q, start, false); }
        var body: u8[>..] = [];
        var heads: u8[>..] = [];
        var status = 0;
        c_set_limit(_LIST_MAX);
        if !_s3_call(s, "list", "GET", "", q, "", "", "", "", body, heads, status) { return false; }
        if status != 200 { return _status_fail("list", prefix, status, body); }
        var rest: const u8[:] = body;
        var seen = 0;
        loop {
            let a = find(rest, "<Contents>");
            if a < 0 { break; }
            let b = find(rest[a..], "</Contents>");
            if b < 0 { break; }
            let item = rest[a..a + b];
            rest = rest[a + b + 11..];
            var k: u8[>..] = [];
            _xml_unescape(k, _xml(item, "Key"));
            seen += 1;
            start.clear();
            start.append(k);
            if !starts_with(k, s.prefix) { continue; }
            let rel = k[s.prefix.len..];
            if !key_ok(rel) || out.len == out.cap { continue; }
            var e = Entry { .. };
            e.key.append(rel);
            let sz, _ = parse_int(_xml(item, "Size"));
            e.size = sz;
            let t, _ = parse_iso_time(_xml(item, "LastModified"));
            e.modified = t;
            out.push(e);
        }
        if _xml(body, "IsTruncated") != "true" || seen == 0 { break; }
    }
    return _ok();
}

// ---------------------------------------------------------------- presigning

fn _presign(s: const Store&, method: const u8[:], key: const u8[:], extra: const u8[:], ttl_s: i64, t: i64, out: u8[>..]&) -> bool {
    if ttl_s < 1 || ttl_s > MAX_PRESIGN_TTL { return _fail("ttl must be 1 to 604800 seconds"); }
    var id: u8[>..] = [];
    var secret: u8[>..] = [];
    var token: u8[>..] = [];
    c_cred_get(s.cred, 0, id);
    c_cred_get(s.cred, 1, secret);
    c_cred_get(s.cred, 2, token);
    var date: u8[>..] = [];
    amz_date(date, t);
    var path: u8[>..] = [];
    _uri_path(path, s, key);
    var hs: u8[>..] = [];
    hs.append("Host: "); _authority(hs, s); hs.push('\n');
    hs.append(extra);
    var q: u8[>..] = [];
    if !presign_query(q, id, secret, token, date, s.region, "s3", ttl_s, method, path, "", hs) { return _fail("signing failed"); }
    out.append(s.scheme); out.append("://"); _authority(out, s); out.append(path);
    out.push('?'); out.append(q);
    return _ok();
}

fn _s3_presign_get(s: const Store&, key: const u8[:], ttl_s: i64, t: i64, out: u8[>..]&) -> bool {
    return _presign(s, "GET", key, "", ttl_s, t, out);
}

fn _s3_presign_put(s: const Store&, key: const u8[:], o: PutOptions, size: i64, ttl_s: i64, t: i64,
                   url: u8[>..]&, headers: u8[>..]&) -> bool {
    var extra: u8[>..] = [];
    if size >= 0 { format(extra, "Content-Length: ", size, "\n"); }
    if !_put_headers(extra, o) { return false; }
    if !_presign(s, "PUT", key, extra, ttl_s, t, url) { return false; }
    headers.append(extra);
    return true;
}
