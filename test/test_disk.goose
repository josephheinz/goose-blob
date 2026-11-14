// The disk backend, and the key rules every backend shares. BLOB_TEST_DIR names an empty scratch folder, which
// test/run.sh makes, with two symlinks in it for test_symlinks.   test/run.sh test_disk
import blob from "..";
import gweb from "../../goose-web";
import net from "../../goose-net";
import std;
import os;

extern fn test_fill(path: const u8[:], size: i64, seed: i64) -> i32 = "gblob_test_fill";
extern fn test_same(a: const u8[:], b: const u8[:]) -> i32 = "gblob_test_same_file";

var failed = 0;
var total = 0;
fn check(name: const u8[:], ok: bool) {
    total += 1;
    if !ok { write_stderr(str("FAIL ", name, " (last_error: ", blob::last_error(), ")\n")); failed += 1; }
}

var dir: u8[>..] = [];
let NONE = blob::PutOptions { .. };

fn p(rel: const u8[:]) -> u8[>..] { return str(dir, "/", rel); }

fn test_keys() {
    let good = ["a", "a/b", "m/ab/0123456789abcdef/photo.jpg", "c/blog/m/x-y_z.png", "a.b", "a..b", "0", "a/b.", "x-"];
    for k in good { check(str("key ok: ", k), blob::key_ok(k)); }
    let bad = ["", "/", "/a", "a/", "a//b", ".", "..", "../a", "a/..", "a/../b", "a/./b", ".hidden", "a/.git/x", "A", "a/B",
               "a b", "a\\b", "a%2e", "a?b", "a#b", "a:b", "caf\xc3\xa9", "a\tb", "~a", "a+b"];
    for k in bad { check(str("key refused: ", k), !blob::key_ok(k)); }
    var nul: u8[>..] = [];
    nul.append("a"); nul.push(0); nul.append("b");
    check("key with NUL refused", !blob::key_ok(nul));
    var long: u8[>..] = [];
    for i in 512 { long.push('a'); }
    check("512 bytes", blob::key_ok(long));
    long.push('a');
    check("513 bytes refused", !blob::key_ok(long));
    var k: u8[>..] = [];
    check("key join", blob::key(k, "c", "blog", "m", "x.png") && k == "c/blog/m/x.png");
    var k2: u8[>..] = [];
    k2.append("keep");
    check("key join refuses traversal", !blob::key(k2, "c", "..", "x") && k2 == "keep");
    var k3: u8[>..] = [];
    check("key join refuses an empty part", !blob::key(k3, "c", "") && k3.len == 0);
}

fn test_open() {
    let s, ok = blob::open(str("file:", dir, "/store/"), "/media");
    check("open makes the folder", ok && is_dir(p("store")) && blob::is_disk(s) && !blob::is_s3(s));
    check("root has no trailing slash", blob::root(s) == p("store"));
    check("public_base gets a slash", s.public_base == "/media/");
    let e, eok = blob::open("file:", "");
    check("empty folder refused", !eok && blob::last_error().len > 0);
    write_file(p("afile"), "x");
    let f, fok = blob::open(str("file:", dir, "/afile/sub"), "");
    check("folder under a file refused", !fok && find(blob::last_error(), "folder") >= 0);
    let g, gok = blob::open("nope:x", "");
    check("bad scheme", !gok);
}

fn store() -> blob::Store {
    let s, ok = blob::open(str("file:", dir, "/store"), "/media/");
    assert(ok);
    return s;
}

fn test_put_get() {
    let s = store();
    check("put", blob::put(s, "a/b/c.txt", "hello", NONE));
    check("put leaves the file", file_exists(p("store/a/b/c.txt")));
    var out: u8[>..] = [];
    check("get", blob::get(s, "a/b/c.txt", out) && out == "hello");
    check("last_error clear", blob::last_error() == "" && !blob::not_found());
    check("overwrite", blob::put(s, "a/b/c.txt", "bye", NONE));
    out.clear();
    check("get new bytes", blob::get(s, "a/b/c.txt", out) && out == "bye");
    check("empty object", blob::put(s, "empty", "", NONE));
    out.clear();
    check("get empty", blob::get(s, "empty", out) && out.len == 0 && file_exists(p("store/empty")));
    var bin: u8[>..] = [];
    for i in 1000 { bin.push((i % 256) as u8); }
    check("binary put", blob::put(s, "bin", bin, NONE));
    out.clear();
    check("binary get", blob::get(s, "bin", out) && out == bin);
    out.clear();
    check("get with a small max refused", !blob::get(s, "bin", out, 999) && out.len == 0 && !blob::not_found());
    check("get with an exact max", blob::get(s, "bin", out, 1000) && out.len == 1000);

    // get appends
    var app: u8[>..] = [];
    app.append(">");
    check("get appends", blob::get(s, "a/b/c.txt", app) && app == ">bye");

    // ranges
    var r: u8[>..] = [];
    check("range", blob::get_range(s, "bin", 10, 5, r) && r.len == 5 && r[0] == 10 && r[4] == 14);
    r.clear();
    check("range across the end", blob::get_range(s, "bin", 995, 100, r) && r.len == 5 && r[0] == 227);
    r.clear();
    check("range past the end", blob::get_range(s, "bin", 5000, 10, r) && r.len == 0);
    check("range of nothing", blob::get_range(s, "bin", 0, 0, r) && r.len == 0);
    check("negative range refused", !blob::get_range(s, "bin", -1, 5, r) && !blob::get_range(s, "bin", 0, -5, r));

    // a key that is a file's folder, or a folder
    check("put under a file fails", !blob::put(s, "empty/x", "y", NONE));
    out.clear();
    check("a folder is not an object", !blob::get(s, "a/b", out) && blob::not_found());
}

fn test_missing() {
    let s = store();
    var out: u8[>..] = [];
    check("get missing", !blob::get(s, "no/such", out) && blob::not_found() && find(blob::last_error(), "no/such") >= 0);
    check("range missing", !blob::get_range(s, "no/such", 0, 4, out) && blob::not_found());
    var info = blob::Info { .. };
    check("head missing", !blob::head(s, "no/such", info) && blob::not_found());
    check("exists missing", !blob::exists(s, "no/such"));
    check("get_to_file missing", !blob::get_to_file(s, "no/such", p("out.bin")) && blob::not_found() && !file_exists(p("out.bin")));
    check("delete missing", blob::delete(s, "no/such"));
    check("ok again", blob::put(s, "x", "1", NONE) && !blob::not_found() && blob::last_error() == "");
}

fn test_bad_keys() {
    let s = store();
    var out: u8[>..] = [];
    var info = blob::Info { .. };
    write_file(p("secret.txt"), "secret");
    let keys = ["../secret.txt", "a/../../secret.txt", "/etc/passwd", "", ".tmp", "a//b"];
    for k in keys {
        check(str("put refuses ", k), !blob::put(s, k, "x", NONE) && find(blob::last_error(), "bad key") >= 0);
        check(str("get refuses ", k), !blob::get(s, k, out) && out.len == 0);
        check(str("head refuses ", k), !blob::head(s, k, info));
        check(str("delete refuses ", k), !blob::delete(s, k));
        check(str("range refuses ", k), !blob::get_range(s, k, 0, 1, out));
        check(str("get_to_file refuses ", k), !blob::get_to_file(s, k, p("o")));
        check(str("put_file refuses ", k), !blob::put_file(s, k, p("secret.txt"), NONE));
        var u: u8[>..] = [];
        check(str("url refuses ", k), !blob::url(s, k, u));
    }
    check("secret untouched", file_exists(p("secret.txt")) && !file_exists(p("store/x.tmp")));
    var page: blob::Entry[..1000] = [];
    check("list refuses a bad prefix", !blob::list(s, "../", "", page));
    check("list refuses a bad after", !blob::list(s, "", "../x", page));
}

fn test_files() {
    let s = store();
    let big = p("big.src");
    check("fill", test_fill(big, 20000000 + 7, 1) != 0);
    check("put_file", blob::put_file(s, "media/big.bin", big, NONE));
    check("put_file kept the source", file_exists(big));
    check("same bytes", test_same(big, p("store/media/big.bin")) != 0);
    var info = blob::Info { .. };
    check("head", blob::head(s, "media/big.bin", info) && info.size == 20000007);
    check("head modified", info.modified > 1700000000 && info.modified <= (time() as i64) + 5);
    check("head etag", starts_with(info.etag, "\"20000007-") && ends_with(info.etag, "\""));
    check("head type by extension", info.content_type == "application/octet-stream");
    blob::put(s, "p.png", "x", NONE);
    var pi = blob::Info { .. };
    check("png type", blob::head(s, "p.png", pi) && pi.content_type == "image/png" && pi.size == 1);
    check("exists", blob::exists(s, "p.png"));

    check("get_to_file", blob::get_to_file(s, "media/big.bin", p("out/deep/big.out")));
    check("got the same bytes", test_same(big, p("out/deep/big.out")) != 0);
    write_file(p("out/small"), "old");
    check("get_to_file replaces", blob::get_to_file(s, "p.png", p("out/small")));
    var back: u8[>..] = [];
    read_file(p("out/small"), back);
    check("replaced bytes", back == "x");

    check("put_file missing source", !blob::put_file(s, "nope", p("no-such-file"), NONE) && !blob::exists(s, "nope"));
    check("put_file from a folder", !blob::put_file(s, "nope", dir, NONE));
    // no temp files are left behind, by successes or failures
    var names: u8[>..] = [];
    list_dir(p("store"), names);
    check("no temp files", find(names, ".tmp-") < 0);
    var mnames: u8[>..] = [];
    list_dir(p("store/media"), mnames);
    check("no temp files below", find(mnames, ".tmp-") < 0 && mnames == "big.bin\n");
}

fn test_delete() {
    let s = store();
    blob::put(s, "d/one/two/three.txt", "3", NONE);
    blob::put(s, "d/one/keep.txt", "k", NONE);
    check("delete", blob::delete(s, "d/one/two/three.txt") && !blob::exists(s, "d/one/two/three.txt"));
    check("empty folders pruned", !is_dir(p("store/d/one/two")));
    check("folder with a file kept", is_dir(p("store/d/one")) && blob::exists(s, "d/one/keep.txt"));
    check("delete the last", blob::delete(s, "d/one/keep.txt"));
    check("pruned to the root", !is_dir(p("store/d")) && is_dir(p("store")));
    check("delete twice", blob::delete(s, "d/one/keep.txt"));
    check("delete a folder name is a no-op", blob::delete(s, "media") && blob::exists(s, "media/big.bin"));
    let lone, ok = blob::open(str("file:", dir, "/lone"), "");
    blob::put(lone, "only", "1", NONE);
    check("root survives its last delete", blob::delete(lone, "only") && is_dir(p("lone")));
}

fn keys_of(page: const blob::Entry[..1000]&) -> u8[>..] {
    var out: u8[>..] = [];
    for e in page { out.append(e.key); out.push(' '); }
    return out;
}

fn test_list() {
    let s, ok = blob::open(str("file:", dir, "/list"), "");
    for k in ["b", "a/2", "a/1", "a/10", "ab", "a-b", "c/d/e/f", "z"] { blob::put(s, k, k, NONE); }
    // things that are not keys: a dot file, a temp-looking file, an uppercase name, a symlink
    write_file(p("list/.DS_Store"), "x");
    write_file(p("list/a/.a.tmp-0011"), "x");
    write_file(p("list/Upper"), "x");
    var page: blob::Entry[..1000] = [];
    check("list all", blob::list(s, "", "", page));
    check("byte order", keys_of(page) == "a-b a/1 a/10 a/2 ab b c/d/e/f z ");
    check("entry size", page[0].key == "a-b" && page[0].size == 3 && page[0].modified > 1700000000);
    var pa: blob::Entry[..1000] = [];
    blob::list(s, "a/", "", pa);
    check("prefix a/", keys_of(pa) == "a/1 a/10 a/2 ");
    var pb: blob::Entry[..1000] = [];
    blob::list(s, "a", "", pb);
    check("prefix a", keys_of(pb) == "a-b a/1 a/10 a/2 ab ");
    var pc: blob::Entry[..1000] = [];
    blob::list(s, "a/1", "", pc);
    check("prefix a/1", keys_of(pc) == "a/1 a/10 ");
    var pd: blob::Entry[..1000] = [];
    blob::list(s, "", "a/2", pd);
    check("after", keys_of(pd) == "ab b c/d/e/f z ");
    var pe: blob::Entry[..1000] = [];
    blob::list(s, "c/d/", "", pe);
    check("deep prefix", keys_of(pe) == "c/d/e/f ");
    var pf: blob::Entry[..1000] = [];
    check("no match", blob::list(s, "q/", "", pf) && pf.len == 0);
    var pg: blob::Entry[..1000] = [];
    check("prefix and after", blob::list(s, "a/", "a/1", pg) && keys_of(pg) == "a/10 a/2 ");

    // paging over 1,000
    let m, mok = blob::open(str("file:", dir, "/many"), "");
    for i in 1205 {
        var k: u8[>..] = [];
        format(k, "k/");
        format_int(k, i, 10, 5, '0');
        blob::put(m, k, "x", NONE);
    }
    var p1: blob::Entry[..1000] = [];
    check("page 1", blob::list(m, "k/", "", p1) && p1.len == 1000 && p1[0].key == "k/00000" && p1[999].key == "k/00999");
    var p2: blob::Entry[..1000] = [];
    check("page 2", blob::list(m, "k/", p1[999].key, p2) && p2.len == 205 && p2[0].key == "k/01000" && p2[204].key == "k/01204");
    var p3: blob::Entry[..1000] = [];
    check("page 3 empty", blob::list(m, "k/", p2[204].key, p3) && p3.len == 0);
    // list fills only the room left
    var part: blob::Entry[..1000] = [];
    for i in 997 { part.push(blob::Entry { key: "x", .. }); }
    check("room left", blob::list(m, "k/", "", part) && part.len == 1000 && part[997].key == "k/00000");
    check("full page is a no-op", blob::list(m, "k/", "", part) && part.len == 1000);
}

fn test_sub() {
    let s = store();
    let c, ok = blob::sub(s, "c/blog");
    check("sub", ok && blob::root(c) == p("store/c/blog") && c.public_base == "/media/c/blog/");
    check("sub put", blob::put(c, "m/ab/x.png", "png", NONE) && file_exists(p("store/c/blog/m/ab/x.png")));
    var out: u8[>..] = [];
    check("sub get", blob::get(c, "m/ab/x.png", out) && out == "png");
    check("parent sees the full key", blob::exists(s, "c/blog/m/ab/x.png"));
    var page: blob::Entry[..1000] = [];
    check("sub list has short keys", blob::list(c, "", "", page) && keys_of(page) == "m/ab/x.png ");
    var u: u8[>..] = [];
    check("sub url", blob::url(c, "m/ab/x.png", u) && u == "/media/c/blog/m/ab/x.png");
    let other, ook = blob::sub(s, "c/shop");
    check("another channel does not see it", ook && !blob::exists(other, "m/ab/x.png"));
    let bad, bok = blob::sub(s, "../x");
    check("sub refuses traversal", !bok);
    let bad2, bok2 = blob::sub(s, "c/");
    check("sub refuses a trailing slash", !bok2);
    let priv, pok = blob::open(str("file:", dir, "/priv"), "");
    var pu: u8[>..] = [];
    check("private store has no url", pok && !blob::url(priv, "a", pu) && find(blob::last_error(), "private") >= 0);
    var x: u8[>..] = [];
    check("disk does not presign", !blob::presign_get(s, "a", 60, x) && x.len == 0);
    var h: u8[>..] = [];
    check("disk does not presign put", !blob::presign_put(s, "a", NONE, 1, 60, x, h));
}

fn test_symlinks() {
    let s = store();
    // A symlinked folder inside the root must not lead outside it. The link is made by test/run.sh beforehand
    // (Goose's os module cannot make one): store/out -> the scratch folder, and store/link.txt -> secret.txt.
    if !is_dir(p("store/out")) { print("  (no symlinks made; skipping)"); return; }
    var out: u8[>..] = [];
    check("read through a folder link refused", !blob::get(s, "out/secret.txt", out) && out.len == 0);
    var info = blob::Info { .. };
    check("head through a folder link refused", !blob::head(s, "out/secret.txt", info));
    check("write through a folder link refused", !blob::put(s, "out/new.txt", "x", NONE) && !file_exists(p("new.txt")));
    check("delete through a folder link refused", !blob::delete(s, "out/secret.txt") && file_exists(p("secret.txt")));
    check("a file link is not an object", !blob::get(s, "link.txt", out) && blob::not_found());
    var page: blob::Entry[..1000] = [];
    blob::list(s, "", "", page);
    check("links are not listed", find(keys_of(page), "out/") < 0 && find(keys_of(page), "link.txt") < 0);
}

// Readers never see half an object: a writer thread replaces one key with 2 MiB of 'a' or 'b' over and over.
struct Go { n: i64 }
struct Done { ok: bool }

thread_fn writer() {
    let job = qget<Go>();
    var d: u8[>..] = [];
    env("BLOB_TEST_DIR", d);
    let s, ok = blob::open(str("file:", d, "/store"), "");
    var a: u8[>..] = [];
    var b: u8[>..] = [];
    for i in 2097152 { a.push('a'); b.push('b'); }
    var good = ok;
    for i in job.n { if !blob::put(s, "race", if i % 2 == 0 { b } else { a }, blob::PutOptions { .. }) { good = false; } }
    qput(Done { ok: good });
}

fn test_atomic() {
    let s = store();
    var a: u8[>..] = [];
    for i in 2097152 { a.push('a'); }
    check("seed", blob::put(s, "race", a, NONE));
    let id = thread_spawn(writer);
    qput(Go { n: 60 });
    var torn = 0;
    var reads = 0;
    for i in 300 {
        var out: u8[>..] = [];
        if blob::get(s, "race", out) {
            reads += 1;
            if out.len != 2097152 || out[0] != out[out.len - 1] || (out[0] != 'a' && out[0] != 'b') { torn += 1; }
        }
    }
    let done = qget<Done>();
    thread_wait(id);
    check("writer ok", done.ok);
    check("every read whole", torn == 0 && reads == 300);
    var names: u8[>..] = [];
    list_dir(p("store"), names);
    check("no temp files after the race", find(names, ".tmp-") < 0);
}

fn main() {
    guard env("BLOB_TEST_DIR", dir) && dir.len > 0 else { write_stderr("set BLOB_TEST_DIR\n"); exit(2); }
    test_keys();
    test_open();
    test_put_get();
    test_missing();
    test_bad_keys();
    test_files();
    test_delete();
    test_list();
    test_sub();
    test_symlinks();
    test_atomic();
    print("test_disk: ", total - failed, " of ", total, " checks passed");
    if failed > 0 { exit(1); }
}
