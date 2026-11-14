// The disk backend: an object is the file <root>/<key>. Writes go to a temp file beside it (".<name>.tmp-<hex>",
// which no key can name), are flushed and renamed over it, so readers see the old bytes or all of the new.
namespace blob;

import std;
import gweb.http.files;

extern fn c_disk_put(root: const u8[:], dst: const u8[:], src: const u8[:], data: const u8[:], from_file: i32) -> i32 = "gblob_disk_put";
extern fn c_disk_stat(root: const u8[:], path: const u8[:], size: i64&, mtime_ns: i64&) -> i32 = "gblob_disk_stat";
extern fn c_disk_read(root: const u8[:], path: const u8[:], off: i64, n: i64, max: i64, out: u8[>..]&) -> i32 = "gblob_disk_read";
extern fn c_disk_copy_out(root: const u8[:], src: const u8[:], dst: const u8[:]) -> i32 = "gblob_disk_copy_out";
extern fn c_disk_delete(path: const u8[:], root: const u8[:]) -> i32 = "gblob_disk_delete";
extern fn c_disk_list(root: const u8[:], prefix: const u8[:], after: const u8[:], max: i64, out: u8[>..]&) -> i64 = "gblob_disk_list";
extern fn c_disk_mkroot(root: const u8[:]) -> i32 = "gblob_disk_mkroot";
extern fn c_error(out: u8[>..]&) = "gblob_error";

fn _c_fail(what: const u8[:]) -> bool {
    var e: u8[>..] = [];
    c_error(e);
    return _fail(what, e);
}

fn _disk_open(s: Store&, path: const u8[:]) -> bool {
    var p = path;
    while p.len > 1 && p[p.len - 1] == '/' { p = p[..p.len - 1]; }
    if p.len == 0 { return _fail("file: needs a folder"); }
    if !_set(s.root, p) { return _fail("folder path too long"); }
    if c_disk_mkroot(s.root) == 0 { return _c_fail("cannot make the folder"); }
    return true;
}

fn _path(out: u8[>..]&, s: const Store&, key: const u8[:]) {
    out.append(s.root);
    out.push('/');
    out.append(key);
}

fn _disk_put(s: const Store&, key: const u8[:], src: const u8[:], data: const u8[:], from_file: bool) -> bool {
    var p: u8[>..] = [];
    _path(p, s, key);
    if c_disk_put(s.root, p, src, data, if from_file { 1 } else { 0 }) == 0 { return _c_fail("put"); }
    return _ok();
}

fn _disk_read(s: const Store&, key: const u8[:], off: i64, n: i64, max: i64, out: u8[>..]&) -> bool {
    var p: u8[>..] = [];
    _path(p, s, key);
    let r = c_disk_read(s.root, p, off, n, max, out);
    if r == 0 { return _fail_missing(key); }
    if r < 0 { return _c_fail("get"); }
    return _ok();
}

fn _disk_get_file(s: const Store&, key: const u8[:], path: const u8[:]) -> bool {
    var p: u8[>..] = [];
    _path(p, s, key);
    let r = c_disk_copy_out(s.root, p, path);
    if r == 0 { return _fail_missing(key); }
    if r < 0 { return _c_fail("get_to_file"); }
    return _ok();
}

fn _disk_head(s: const Store&, key: const u8[:], info: Info&) -> bool {
    var p: u8[>..] = [];
    _path(p, s, key);
    var size = 0;
    var mtime = 0;
    let r = c_disk_stat(s.root, p, size, mtime);
    if r == 0 { return _fail_missing(key); }
    if r < 0 { return _c_fail("head"); }
    info.size = size;
    info.modified = div_euclid(mtime, 1000000000);
    info.etag.clear();
    format(info.etag, "\"", size, "-", mtime, "\"");
    _set(info.content_type, gweb::mime_type(key));
    return _ok();
}

fn _disk_delete(s: const Store&, key: const u8[:]) -> bool {
    var p: u8[>..] = [];
    _path(p, s, key);
    if c_disk_delete(p, s.root) == 0 { return _c_fail("delete"); }
    return _ok();
}

fn _disk_list(s: const Store&, prefix: const u8[:], after: const u8[:], out: Entry[..1000]&) -> bool {
    var lines: u8[>..] = [];
    let n = c_disk_list(s.root, prefix, after, out.cap - out.len, lines);
    if n < 0 { return _c_fail("list"); }
    each_split(lines, '\n') {
        if it.len > 0 {
            let parts = split(it, '\t');
            if parts.len == 3 && key_ok(parts[0]) {
                var e = Entry { .. };
                e.key.append(parts[0]);
                let sz, a = parse_int(parts[1]);
                let mt, b = parse_int(parts[2]);
                e.size = sz;
                e.modified = mt;
                out.push(e);
            }
        }
    };
    return _ok();
}
