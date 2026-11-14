// blob: object storage for Goose. A disk backend and an S3-compatible backend (AWS S3, Cloudflare R2, MinIO,
// Backblaze B2, Wasabi) over the system libcurl, signed with SigV4.
//
//   let s, ok = blob::open("file:data/media", "/media/");
//   let s, ok = blob::open("s3://bucket/prefix?endpoint=https://...&region=auto", "https://cdn.example.com/");
//
// Needs gweb (gweb.auth.crypto for SHA-256 and HMAC, gweb.http.files for content types), so the root declares
// gweb and net as well; inside a gweb app they already are. Every call is safe from any thread.
namespace blob;

import std;
import os;
import disk;
import s3;
import sigv4;

enum Kind { Disk, S3 }

// Fixed fields only, so a Store copies, crosses thread queues and prints without secrets: S3 keys are held in C.
struct Store {
    kind: Kind = Kind.Disk,
    root: u8[..1024] = "",          // disk: the folder, without a trailing '/'
    bucket: u8[..64] = "",          // s3
    prefix: u8[..512] = "",         // s3: "" or ending in '/'; joined in front of every key
    scheme: u8[..8] = "https",      // s3
    host: u8[..256] = "",           // s3: the endpoint's host[:port]
    region: u8[..32] = "us-east-1", // s3
    path_style: bool = false,       // s3: https://host/bucket/key rather than https://bucket.host/key
    public_base: u8[..512] = "",    // url(): public_base + key; "" for a private store
    ca_file: u8[..512] = "",        // s3: BLOB_CA_FILE at open, a CA bundle to trust instead of the system's
    cred: i64 = 0,                  // s3: the credentials' handle in C
}

struct Info { size: i64 = 0, etag: u8[..80] = "", content_type: u8[..100] = "", modified: i64 = 0 }

struct PutOptions {
    content_type: u8[..100] = "",
    cache_control: u8[..100] = "",
    disposition: u8[..300] = "",
    immutable: bool = false,        // s3 without cache_control: Cache-Control: public, max-age=31536000, immutable
}

struct Entry { key: u8[..512] = "", size: i64 = 0, modified: i64 = 0 }

let MAX_KEY = 512;
let GET_MAX = 67108864;             // get() refuses a bigger object unless given a larger max
let MAX_PRESIGN_TTL = 604800;       // seven days, SigV4's limit

// ---------------------------------------------------------------- errors (per thread: each thread has its globals)

var _err: u8[..600] = "";
var _missing = false;

fn _fail(a: const u8[:]) -> bool { return _fail(a, ""); }
fn _fail(a: const u8[:], b: const u8[:]) -> bool {
    _err.clear();
    _err.append(a[..min(a.len, 280)]);
    if b.len > 0 { _err.append(": "); _err.append(b[..min(b.len, 300)]); }
    _missing = false;
    return false;
}
fn _fail_missing(key: const u8[:]) -> bool {
    _fail("no such key", key);
    _missing = true;
    return false;
}
fn _ok() -> bool { _err.clear(); _missing = false; return true; }

// Why the last call on this thread failed, or "" after one that worked.
fn last_error() -> const u8[:] { return _err; }
// True when the last call failed only because the key does not exist (get, get_range, get_to_file, head).
fn not_found() -> bool { return _missing; }

// Copies src into a limited field; false (field left empty) when it does not fit.
fn _set<B>(dst: B&, src: const u8[:]) -> bool {
    dst.clear();
    if src.len > dst.cap { return false; }
    dst.append(src);
    return true;
}

// ---------------------------------------------------------------- keys

fn _key_char(c: u8) -> bool { (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-' }

// A key is 1 to 512 bytes of [a-z0-9._-] in segments split by '/': no empty segment (so no leading, trailing or
// double '/') and no segment that starts with '.' (so no "." or ".." and no dot files). Every call checks it,
// so a key cannot leave a disk root or an S3 prefix.
fn key_ok(key: const u8[:]) -> bool {
    if key.len == 0 || key.len > MAX_KEY { return false; }
    var start = true;
    for c in key {
        if c == '/' {
            if start { return false; }
            start = true;
            continue;
        }
        if !_key_char(c) || (start && c == '.') { return false; }
        start = false;
    }
    return !start;
}

// A list prefix is "" or a key, optionally with a trailing '/'.
fn _prefix_ok(p: const u8[:]) -> bool {
    if p.len == 0 { return true; }
    if p[p.len - 1] == '/' { return key_ok(p[..p.len - 1]); }
    return key_ok(p);
}

// Joins parts with '/' into out as a key, false when the result is not key_ok: key(out, "c", channel, "m", name).
fn key(out: u8[>..]&, a: const u8[:], b: const u8[:]) -> bool { return _join(out, [a, b]); }
fn key(out: u8[>..]&, a: const u8[:], b: const u8[:], c: const u8[:]) -> bool { return _join(out, [a, b, c]); }
fn key(out: u8[>..]&, a: const u8[:], b: const u8[:], c: const u8[:], d: const u8[:]) -> bool { return _join(out, [a, b, c, d]); }
fn _join(out: u8[>..]&, parts: const u8[:][:]) -> bool {
    let start = out.len;
    for p, i in parts {
        if i > 0 { out.push('/'); }
        out.append(p);
    }
    if key_ok(out[start..]) { return true; }
    out.resize(start);
    return false;
}

// ---------------------------------------------------------------- opening

// "file:PATH" (relative to the working directory, or absolute), made if missing; or
// "s3://BUCKET[/PREFIX][?endpoint=URL&region=R&style=path|virtual&plain_http=1]".
// S3 keys come from BLOB_ACCESS_KEY_ID, BLOB_SECRET_ACCESS_KEY and BLOB_SESSION_TOKEN, or else the AWS_* names,
// never from the URL. public_base is what url() puts in front of a key ("" for a private store).
fn open(url: const u8[:], public_base: const u8[:]) -> Store, bool {
    if starts_with(url, "s3://") {
        var id: u8[>..] = [];
        var secret: u8[>..] = [];
        var token: u8[>..] = [];
        if !env("BLOB_ACCESS_KEY_ID", id) || id.len == 0 {
            id.clear(); secret.clear(); token.clear();
            env("AWS_ACCESS_KEY_ID", id);
            env("AWS_SECRET_ACCESS_KEY", secret);
            env("AWS_SESSION_TOKEN", token);
        } else {
            env("BLOB_SECRET_ACCESS_KEY", secret);
            env("BLOB_SESSION_TOKEN", token);
        }
        return open(url, public_base, id, secret, token);
    }
    return open(url, public_base, "", "", "");
}

// open, with S3 keys given rather than read from the environment.
fn open(url: const u8[:], public_base: const u8[:], access_id: const u8[:], secret: const u8[:], token: const u8[:]) -> Store, bool {
    var s = Store { .. };
    if !_set(s.public_base, public_base) { _fail("public_base is too long"); return s, false; }
    if s.public_base.len > 0 && s.public_base[s.public_base.len - 1] != '/' {
        if s.public_base.len == s.public_base.cap { _fail("public_base is too long"); return s, false; }
        s.public_base.push('/');
    }
    if starts_with(url, "file:") {
        s.kind = Kind.Disk;
        if !_disk_open(s, url[5..]) { return s, false; }
        _ok();
        return s, true;
    }
    if starts_with(url, "s3://") {
        s.kind = Kind.S3;
        if !_s3_open(s, url[5..], access_id, secret, token) { return s, false; }
        _ok();
        return s, true;
    }
    _fail("store URL must start with file: or s3://");
    return s, false;
}

// The same store with every key under name/: a channel's media is sub(store, "c/blog"). name is a key.
// url() and list() then work in that space too: list() gives keys without the name.
fn sub(s: const Store&, name: const u8[:]) -> Store, bool {
    var t = s;
    if !key_ok(name) { _fail("bad sub-store name", name); return t, false; }
    if s.kind == Kind.Disk {
        if t.root.len + 1 + name.len > t.root.cap { _fail("path too long"); return t, false; }
        t.root.push('/');
        t.root.append(name);
    } else {
        if t.prefix.len + name.len + 1 > MAX_KEY - 1 { _fail("prefix too long"); return t, false; }
        t.prefix.append(name);
        t.prefix.push('/');
    }
    if t.public_base.len > 0 {
        if t.public_base.len + name.len + 1 > t.public_base.cap { _fail("public_base is too long"); return t, false; }
        t.public_base.append(name);
        t.public_base.push('/');
    }
    _ok();
    return t, true;
}

// The disk folder (for gweb::send_file(req, ctx, res, blob::root(s), key, opts)); "" for S3.
fn root(s: const Store&) -> const u8[:] { if s.kind == Kind.Disk { return s.root; } return ""; }

fn is_disk(s: const Store&) -> bool { s.kind == Kind.Disk }
fn is_s3(s: const Store&) -> bool { s.kind == Kind.S3 }

// ---------------------------------------------------------------- operations

// Stores the file at path under key. Streams: the file is never held in memory. Disk: a copy into a temp file,
// fsync, rename. S3: one PUT (up to 5 GiB).
fn put_file(s: const Store&, key: const u8[:], path: const u8[:], o: PutOptions) -> bool {
    if !key_ok(key) { return _fail("bad key", key); }
    if s.kind == Kind.Disk { return _disk_put(s, key, path, "", true); }
    return _s3_put(s, key, path, "", true, o);
}

fn put(s: const Store&, key: const u8[:], data: const u8[:], o: PutOptions) -> bool {
    if !key_ok(key) { return _fail("bad key", key); }
    if s.kind == Kind.Disk { return _disk_put(s, key, "", data, false); }
    return _s3_put(s, key, "", data, false, o);
}

// Appends the whole object to out; false for one larger than max bytes. For small objects.
fn get(s: const Store&, key: const u8[:], out: u8[>..]&, max: i64 = GET_MAX) -> bool {
    if !key_ok(key) { return _fail("bad key", key); }
    if s.kind == Kind.Disk { return _disk_read(s, key, 0, -1, max, out); }
    return _s3_get(s, key, 0, -1, max, out);
}

// Appends up to n bytes from offset off (fewer at the end of the object, none past it).
fn get_range(s: const Store&, key: const u8[:], off: i64, n: i64, out: u8[>..]&) -> bool {
    if !key_ok(key) { return _fail("bad key", key); }
    if off < 0 || n < 0 { return _fail("bad range"); }
    if n == 0 { return _ok(); }
    if s.kind == Kind.Disk { return _disk_read(s, key, off, n, n, out); }
    return _s3_get(s, key, off, n, n, out);
}

// Writes the object to the file at path, streaming, atomically (a temp file beside it, fsync, rename).
fn get_to_file(s: const Store&, key: const u8[:], path: const u8[:]) -> bool {
    if !key_ok(key) { return _fail("bad key", key); }
    if s.kind == Kind.Disk { return _disk_get_file(s, key, path); }
    return _s3_get_file(s, key, path);
}

// Size, ETag, content type and modification time (Unix seconds). False when missing (not_found()) or on error.
// Disk: the ETag is gweb::send_file's ("size-mtime_ns", quoted) and the type comes from the key's extension.
fn head(s: const Store&, key: const u8[:], info: Info&) -> bool {
    if !key_ok(key) { return _fail("bad key", key); }
    if s.kind == Kind.Disk { return _disk_head(s, key, info); }
    return _s3_head(s, key, info);
}

fn exists(s: const Store&, key: const u8[:]) -> bool {
    var info = Info { .. };
    return head(s, key, info);
}

// True when the key is gone afterwards, also when it was never there.
fn delete(s: const Store&, key: const u8[:]) -> bool {
    if !key_ok(key) { return _fail("bad key", key); }
    if s.kind == Kind.Disk { return _disk_delete(s, key); }
    return _s3_delete(s, key);
}

// Appends keys that start with prefix and sort after `after` (byte order), until out is full. Fewer than the room
// out had means the end. Page with after = the last key of the previous page.
fn list(s: const Store&, prefix: const u8[:], after: const u8[:], out: Entry[..1000]&) -> bool {
    if !_prefix_ok(prefix) { return _fail("bad prefix", prefix); }
    if after.len > 0 && !key_ok(after) { return _fail("bad after", after); }
    if out.len == out.cap { return _ok(); }
    if s.kind == Kind.Disk { return _disk_list(s, prefix, after, out); }
    return _s3_list(s, prefix, after, out);
}

// The public URL of key: public_base + key. False for a private store (no public_base).
fn url(s: const Store&, key: const u8[:], out: u8[>..]&) -> bool {
    if !key_ok(key) { return _fail("bad key", key); }
    if s.public_base.len == 0 { return _fail("private store: no public URL"); }
    out.append(s.public_base);
    out.append(key);
    return _ok();
}

// A URL that GETs the object without credentials for ttl_s seconds (1 to 604800). S3 only.
fn presign_get(s: const Store&, key: const u8[:], ttl_s: i64, out: u8[>..]&) -> bool {
    if !key_ok(key) { return _fail("bad key", key); }
    if s.kind != Kind.S3 { return _fail("presign needs an S3 store"); }
    return _s3_presign_get(s, key, ttl_s, time() as i64, out);
}

// A URL a client PUTs to directly, and in headers the "Name: value" lines it must send with it: Content-Length
// (when size >= 0) and the PutOptions headers are signed, so the client cannot change them. S3 only.
fn presign_put(s: const Store&, key: const u8[:], o: PutOptions, size: i64, ttl_s: i64, url: u8[>..]&, headers: u8[>..]&) -> bool {
    if !key_ok(key) { return _fail("bad key", key); }
    if s.kind != Kind.S3 { return _fail("presign needs an S3 store"); }
    return _s3_presign_put(s, key, o, size, ttl_s, time() as i64, url, headers);
}
