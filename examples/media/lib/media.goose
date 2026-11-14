// The store, opened once per worker thread (each thread has its own globals), and one sub-store per channel.
// EXAMPLE_BLOB_URL picks the backend: "file:data/media" (the default) or an s3:// URL.
namespace media;

import std;
import os;
import blob;

var _store: blob::Store;
var _opened = false;

fn store() -> blob::Store, bool {
    if !_opened {
        var url: u8[>..] = [];
        if !env("EXAMPLE_BLOB_URL", url) || url.len == 0 { url.append("file:data/media"); }
        let s, ok = blob::open(url, "/media/");
        if !ok { return s, false; }
        _store = s;
        _opened = true;
    }
    return _store, true;
}

// Channel codes are short lowercase names: "main", "blog".
fn channel_ok(c: const u8[:]) -> bool {
    if c.len == 0 || c.len > 32 { return false; }
    for b in c { if !((b >= 'a' && b <= 'z') || (b >= '0' && b <= '9')) { return false; } }
    return true;
}

// The channel's media: every key under c/<channel>/, so channels never see each other's files.
fn channel(code: const u8[:]) -> blob::Store, bool {
    let s, ok = store();
    if !ok || !channel_ok(code) { return s, false; }
    var name: u8[>..] = [];
    if !blob::key(name, "c", code) { return s, false; }
    return blob::sub(s, name);
}
