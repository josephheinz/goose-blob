// The S3 backend end to end, against BLOB_TEST_S3_URL (test/run.sh starts a throwaway MinIO and sets it, with
// BLOB_ACCESS_KEY_ID, BLOB_SECRET_ACCESS_KEY and, over HTTPS, BLOB_CA_FILE). Everything goes under a fresh
// run-<random>/ sub-store and is deleted at the end, so a real bucket can be used.   test/run.sh test_s3
import blob from "..";
import blob.s3;
import gweb from "../../goose-web";
import gweb.auth.crypto;
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

let NONE = blob::PutOptions { .. };
var url: u8[>..] = [];
var run: u8[..64] = "";

fn base() -> blob::Store {
    let s, ok = blob::open(url, "https://cdn.example.com/");
    assert(ok);
    return s;
}
fn store() -> blob::Store {
    let b = base();
    let s, ok = blob::sub(b, run);
    assert(ok);
    return s;
}

// A request with no credentials, as a browser would make it.
fn fetch(method: const u8[:], u: const u8[:], headers: const u8[:], body: const u8[:], out: u8[>..]&, heads: u8[>..]&) -> i64 {
    var status = 0;
    var ca: u8[>..] = [];
    env("BLOB_CA_FILE", ca);
    if blob::c_http(1 << 26, method, u, headers, body, "", "", out, heads, status, ca) == 0 { return -1; }
    return status;
}

fn test_put_get() {
    let s = store();
    check("put", blob::put(s, "a/b.txt", "hello", NONE));
    var out: u8[>..] = [];
    check("get", blob::get(s, "a/b.txt", out) && out == "hello" && blob::last_error() == "");
    check("overwrite", blob::put(s, "a/b.txt", "bye", NONE));
    out.clear();
    check("get new", blob::get(s, "a/b.txt", out) && out == "bye");
    check("empty", blob::put(s, "empty", "", NONE));
    out.clear();
    check("get empty", blob::get(s, "empty", out) && out.len == 0);
    var bin: u8[>..] = [];
    for i in 70000 { bin.push((i * 7 % 256) as u8); }
    check("binary", blob::put(s, "bin", bin, NONE));
    out.clear();
    check("get binary", blob::get(s, "bin", out) && out == bin);
    out.clear();
    check("get binary, max 100000", blob::get(s, "bin", out, 100000) && out == bin);
    out.clear();
    check("get over max refused", !blob::get(s, "bin", out, 1000) && out.len == 0);
    var r: u8[>..] = [];
    check("range", blob::get_range(s, "bin", 100, 10, r) && r.len == 10 && r == bin[100..110]);
    r.clear();
    check("range across the end", blob::get_range(s, "bin", 69995, 100, r) && r == bin[69995..]);
    r.clear();
    check("range past the end", blob::get_range(s, "bin", 80000, 10, r) && r.len == 0);
    check("range of nothing", blob::get_range(s, "bin", 0, 0, r) && r.len == 0);
}

fn test_head_options() {
    let s = store();
    let o = blob::PutOptions { content_type: "image/png", cache_control: "public, max-age=60",
                               disposition: "attachment; filename=\"x.png\"", .. };
    check("put with options", blob::put(s, "o/x.png", "png!", o));
    var info = blob::Info { .. };
    check("head", blob::head(s, "o/x.png", info));
    check("head size", info.size == 4);
    check("head type", info.content_type == "image/png");
    check("head etag", info.etag.len > 2 && info.etag[0] == '"');
    let now = time() as i64;
    check("head modified", info.modified > now - 600 && info.modified < now + 600);
    // the headers are on the object: fetch it through a presigned URL and look
    var u: u8[>..] = [];
    check("presign", blob::presign_get(s, "o/x.png", 60, u));
    var body: u8[>..] = [];
    var heads: u8[>..] = [];
    check("presigned GET", fetch("GET", u, "", "", body, heads) == 200 && body == "png!");
    let cc, has_cc = blob::_rhead(heads, "cache-control");
    check("cache-control stored", has_cc && cc == "public, max-age=60");
    let cd, has_cd = blob::_rhead(heads, "content-disposition");
    check("disposition stored", has_cd && cd == "attachment; filename=\"x.png\"");
    let im = blob::PutOptions { immutable: true, .. };
    check("put immutable", blob::put(s, "o/i", "i", im));
    var u2: u8[>..] = [];
    blob::presign_get(s, "o/i", 60, u2);
    var b2: u8[>..] = [];
    var h2: u8[>..] = [];
    fetch("GET", u2, "", "", b2, h2);
    let cc2, _ = blob::_rhead(h2, "cache-control");
    check("immutable cache-control", cc2 == "public, max-age=31536000, immutable");
    var bad = blob::PutOptions { .. };
    bad.content_type.append("text/plain\r\nX-Evil: 1");
    check("header injection refused", !blob::put(s, "o/evil", "x", bad));
    check("exists", blob::exists(s, "o/x.png") && !blob::exists(s, "o/nope"));
}

fn test_missing() {
    let s = store();
    var out: u8[>..] = [];
    check("get missing", !blob::get(s, "no/such", out) && blob::not_found() && out.len == 0);
    check("range missing", !blob::get_range(s, "no/such", 0, 10, out) && blob::not_found());
    var info = blob::Info { .. };
    check("head missing", !blob::head(s, "no/such", info) && blob::not_found());
    check("get_to_file missing", !blob::get_to_file(s, "no/such", "s3-missing.out") && blob::not_found() && !file_exists("s3-missing.out"));
    check("delete missing", blob::delete(s, "no/such"));
    check("put then delete", blob::put(s, "del", "x", NONE) && blob::delete(s, "del") && !blob::exists(s, "del"));
    check("bad key refused before any request", !blob::put(s, "../x", "x", NONE) && find(blob::last_error(), "bad key") >= 0);
}

fn test_files() {
    let s = store();
    let size = 100 * 1048576 + 3;
    check("fill 100 MiB", test_fill("s3-big.src", size, 7) != 0);
    let t0 = clock();
    check("put_file streams", blob::put_file(s, "big/file.bin", "s3-big.src", NONE));
    let t1 = clock();
    var info = blob::Info { .. };
    check("big head", blob::head(s, "big/file.bin", info) && info.size == size);
    check("get_to_file streams", blob::get_to_file(s, "big/file.bin", "s3-out/deep/big.out"));
    let t2 = clock();
    check("same bytes back", test_same("s3-big.src", "s3-out/deep/big.out") != 0);
    print("  100 MiB: put ", ((t1 - t0) * 1000.0) as i64, " ms, get ", ((t2 - t1) * 1000.0) as i64, " ms");
    var r: u8[>..] = [];
    check("range of a big object", blob::get_range(s, "big/file.bin", size - 3, 10, r) && r.len == 3);
    var names: u8[>..] = [];
    list_dir("s3-out/deep", names);
    check("no temp file left", names == "big.out\n");
    write_file("s3-small.out", "old");
    check("get_to_file replaces", blob::get_to_file(s, "a/b.txt", "s3-small.out"));
    var back: u8[>..] = [];
    read_file("s3-small.out", back);
    check("replaced", back == "bye");
    check("get_to_file of a missing key keeps the old file", !blob::get_to_file(s, "no/such", "s3-small.out") && file_exists("s3-small.out"));
    check("put_file of a missing source", !blob::put_file(s, "x", "no-such-source", NONE) && !blob::exists(s, "x"));
    delete_file("s3-big.src");
    delete_file("s3-out/deep/big.out");
}

fn keys_of(page: const blob::Entry[..1000]&) -> u8[>..] {
    var out: u8[>..] = [];
    for e in page { out.append(e.key); out.push(' '); }
    return out;
}

fn test_list() {
    let all = store();
    let s, ok = blob::sub(all, "list");
    for k in ["b", "a/2", "a/1", "a/10", "ab", "a-b", "c/d/e/f", "z"] { blob::put(s, k, k, NONE); }
    var page: blob::Entry[..1000] = [];
    check("list", blob::list(s, "", "", page));
    check("byte order, keys without the store prefix", keys_of(page) == "a-b a/1 a/10 a/2 ab b c/d/e/f z ");
    check("entry fields", page[0].size == 3 && page[0].modified > 1700000000);
    var pa: blob::Entry[..1000] = [];
    blob::list(s, "a/", "", pa);
    check("prefix a/", keys_of(pa) == "a/1 a/10 a/2 ");
    var pb: blob::Entry[..1000] = [];
    blob::list(s, "a", "", pb);
    check("prefix a", keys_of(pb) == "a-b a/1 a/10 a/2 ab ");
    var pc: blob::Entry[..1000] = [];
    blob::list(s, "", "a/2", pc);
    check("after", keys_of(pc) == "ab b c/d/e/f z ");
    var pd: blob::Entry[..1000] = [];
    check("prefix and after", blob::list(s, "a/", "a/1", pd) && keys_of(pd) == "a/10 a/2 ");
    var pe: blob::Entry[..1000] = [];
    check("no match", blob::list(s, "q/", "", pe) && pe.len == 0);

    let m, mok = blob::sub(all, "many");
    for i in 1105 {
        var k: u8[>..] = [];
        format(k, "k/");
        format_int(k, i, 10, 5, '0');
        blob::put(m, k, "x", NONE);
    }
    var p1: blob::Entry[..1000] = [];
    check("page 1", blob::list(m, "k/", "", p1) && p1.len == 1000 && p1[999].key == "k/00999");
    var p2: blob::Entry[..1000] = [];
    check("page 2", blob::list(m, "k/", p1[999].key, p2) && p2.len == 105 && p2[0].key == "k/01000");
    var part: blob::Entry[..1000] = [];
    for i in 990 { part.push(blob::Entry { key: "x", .. }); }
    check("room left", blob::list(m, "", "", part) && part.len == 1000 && part[990].key == "k/00000");
}

fn test_presign() {
    let s = store();
    blob::put(s, "p/x.txt", "presigned", NONE);
    var u: u8[>..] = [];
    check("presign get", blob::presign_get(s, "p/x.txt", 300, u));
    var body: u8[>..] = [];
    var heads: u8[>..] = [];
    check("presigned GET works without keys", fetch("GET", u, "", "", body, heads) == 200 && body == "presigned");
    var tampered: u8[>..] = [];
    format_replaced(tampered, u, "p/x.txt", "p/y.txt");
    var tb: u8[>..] = [];
    var th: u8[>..] = [];
    check("another key with the same signature refused", fetch("GET", tampered, "", "", tb, th) == 403);
    var short: u8[>..] = [];
    blob::presign_get(s, "p/x.txt", 1, short);
    sleep(2.5);
    var eb: u8[>..] = [];
    var eh: u8[>..] = [];
    check("expired URL refused", fetch("GET", short, "", "", eb, eh) == 403);

    // presigned PUT: the client must send exactly the signed headers
    let o = blob::PutOptions { content_type: "text/plain", .. };
    var pu: u8[>..] = [];
    var ph: u8[>..] = [];
    check("presign put", blob::presign_put(s, "p/up.txt", o, 6, 300, pu, ph));
    var b: u8[>..] = [];
    var h: u8[>..] = [];
    check("presigned PUT works", fetch("PUT", pu, ph, "upload", b, h) == 200);
    var got: u8[>..] = [];
    var info = blob::Info { .. };
    check("uploaded", blob::get(s, "p/up.txt", got) && got == "upload" && blob::head(s, "p/up.txt", info) && info.content_type == "text/plain");
    var b2: u8[>..] = [];
    var h2: u8[>..] = [];
    check("presigned PUT with another type refused", fetch("PUT", pu, "Content-Type: text/html\nContent-Length: 6\n", "upload", b2, h2) == 403);
    var b3: u8[>..] = [];
    var h3: u8[>..] = [];
    check("presigned PUT with another length refused", fetch("PUT", pu, "Content-Type: text/plain\nContent-Length: 7\n", "upload!", b3, h3) == 403);
}

fn test_errors() {
    let s = store();
    // wrong secret: the server refuses the signature
    var id: u8[>..] = [];
    env("BLOB_ACCESS_KEY_ID", id);
    let w, wok = blob::open(url, "", id, "not-the-secret", "");
    let ws, _ = blob::sub(w, run);
    check("wrong secret refused", wok && !blob::put(ws, "w", "x", NONE) && find(blob::last_error(), "403") >= 0);
    check("wrong secret is not 'not found'", !blob::not_found());
    // a bucket that is not there
    var nb: u8[>..] = [];
    format_replaced(nb, url, "s3://gtest", "s3://gtest-no-such-bucket");
    if nb != url {
        let n, nok = blob::open(nb, "");
        var out: u8[>..] = [];
        check("missing bucket", nok && !blob::get(n, "x", out) && find(blob::last_error(), "NoSuchBucket") >= 0 && !blob::not_found());
    }
    // TLS verification is always on: without the CA file the self-signed server is refused
    if s.scheme == "https" && s.ca_file.len > 0 {
        var t = s;
        t.ca_file.clear();
        check("unknown certificate refused", !blob::put(t, "tls", "x", NONE) && blob::last_error().len > 0);
        print("  TLS refused: ", blob::last_error());
        check("nothing was written", !blob::exists(s, "tls"));
    } else {
        print("  (plain HTTP server: TLS checks skipped)");
    }
    // a server that is not there
    let d, dok = blob::open("s3://gtest?endpoint=http://127.0.0.1:1", "", "id", "secret", "");
    var out: u8[>..] = [];
    check("connection refused", dok && !blob::get(d, "x", out) && blob::last_error().len > 0 && !blob::not_found());
}

// Several threads at once, each with its own connection.
struct Job { n: i64, worker: i64, run: u8[..64] }
struct Res { ok: i64 }

thread_fn worker() {
    let j = qget<Job>();
    var u: u8[>..] = [];
    env("BLOB_TEST_S3_URL", u);
    let b, ok = blob::open(u, "");
    let s, sok = blob::sub(b, j.run);
    var good = 0;
    for i in j.n {
        var k: u8[>..] = [];
        format(k, "t/", j.worker, "/", i);
        var v: u8[>..] = [];
        format(v, "worker ", j.worker, " item ", i);
        var back: u8[>..] = [];
        if ok && sok && blob::put(s, k, v, blob::PutOptions { .. }) && blob::get(s, k, back) && back == v { good += 1; }
    }
    qput(Res { ok: good });
}

fn test_threads() {
    var ids: i64[>..] = [];
    for w in 6 { ids.push(thread_spawn(worker)); }
    for w in 6 { qput(Job { n: 25, worker: w, run: run }); }
    var good = 0;
    for w in 6 { good += qget<Res>().ok; }
    for id in ids { thread_wait(id); }
    check("150 puts and gets on 6 threads", good == 150);
}

fn cleanup() {
    let s = store();
    var deleted = 0;
    loop {
        var page: blob::Entry[..1000] = [];
        if !blob::list(s, "", "", page) || page.len == 0 { break; }
        for e in page { if blob::delete(s, e.key) { deleted += 1; } }
    }
    var left: blob::Entry[..1000] = [];
    check("cleaned up", blob::list(s, "", "", left) && left.len == 0);
}

fn main() {
    if !env("BLOB_TEST_S3_URL", url) || url.len == 0 { print("test_s3: BLOB_TEST_S3_URL is not set; skipped"); return; }
    var rnd: u8[..8] = [0; 8];
    gweb::random_bytes(rnd);
    run.append("run-");
    for c in rnd { format_int(run, c, 16, 2, '0'); }
    let b = base();
    check("open", b.cred != 0);
    test_put_get();
    test_head_options();
    test_missing();
    test_files();
    test_list();
    test_presign();
    test_errors();
    test_threads();
    cleanup();
    print("test_s3: ", total - failed, " of ", total, " checks passed");
    if failed > 0 { exit(1); }
}
