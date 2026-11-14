# goose-blob

Object storage for [Goose](https://aardappel.github.io/goose/): a disk backend and an S3-compatible backend
(AWS S3, Cloudflare R2, MinIO, Backblaze B2, Wasabi) over the system libcurl. Package `blob`.

```goose
import blob;

let s, ok = blob::open("file:data/media", "/media/");
guard ok else { print(blob::last_error()); return; }
let o = blob::PutOptions { content_type: "image/png", immutable: true, .. };
blob::put_file(s, "m/ab/abcdef/photo.png", "/tmp/upload-1", o);
var url: u8[>..] = [];
blob::url(s, "m/ab/abcdef/photo.png", url);          // /media/m/ab/abcdef/photo.png
```

## Install

In a gweb app (gweb 1.1 or newer), one line in `gweb.packages`:

```
package blob josephheinz/goose-blob@v0.1.0
```

Then any `app/` or `lib/` file writes `import blob;`. `GWEB_PKG_BLOB=/path/to/goose-blob` uses a checkout instead.

Outside gweb, the root declares blob and the two packages it needs: gweb (`gweb.auth.crypto` for SHA-256 and HMAC,
`gweb.http.files` for content types) and goose-net, which gweb needs.

```goose
import blob from "josephheinz/goose-blob@v0.1.0";
import gweb from "josephheinz/gweb@v1.1.0";
import net from "josephheinz/goose-net@v1.1.0";
```

libcurl and its headers:

| OS | Install |
|---|---|
| macOS | nothing: the SDK has them |
| Debian, Ubuntu | `sudo apt install libcurl4-openssl-dev` (run time: `libcurl4`) |
| Fedora | `sudo dnf install libcurl-devel` |

## Open

```goose
let s, ok = blob::open("file:data/media", "/media/");
let s, ok = blob::open("s3://my-bucket/site?endpoint=https://ACCOUNT.r2.cloudflarestorage.com&region=auto", "https://cdn.example.com/");
let s, ok = blob::open("s3://my-bucket", "");                    // AWS, us-east-1, private
```

- `file:PATH`: a folder, relative to the working directory or absolute. Made if missing.
- `s3://BUCKET[/PREFIX][?PARAMS]`. Every key goes under `PREFIX/`. Parameters:
  - `endpoint=https://host[:port]`. Default `https://s3.REGION.amazonaws.com`.
  - `region=R`. Default `us-east-1`; R2 takes `auto`.
  - `style=path|virtual`. Default virtual-host (`https://bucket.host/key`) on AWS, path (`https://host/bucket/key`)
    with an endpoint.
  - `http://` endpoints work for localhost only, unless `plain_http=1`.
- Keys come from `BLOB_ACCESS_KEY_ID`, `BLOB_SECRET_ACCESS_KEY` and `BLOB_SESSION_TOKEN`, or else `AWS_ACCESS_KEY_ID`,
  `AWS_SECRET_ACCESS_KEY` and `AWS_SESSION_TOKEN`. Never from the URL. `open(url, base, id, secret, token)` takes
  them directly.
- TLS verification is always on. `BLOB_CA_FILE` names a CA bundle to trust instead of the system's (a private MinIO).
- `public_base` is what `url()` puts before a key; `""` makes a private store.
- `Store` holds fixed fields only, so it copies and crosses thread queues. Secrets stay in C, so printing a `Store`
  shows none. Opening is cheap; a worker may open its own.

## Keys

`key_ok(key)`: 1 to 512 bytes of `[a-z0-9._-]` in segments split by `/`. No empty segment and no segment starting
with `.`, so no `..`, no absolute path, no dot files. Every call checks its key, so a key cannot leave a disk root
or an S3 prefix. `key(out, "c", channel, "m", name)` joins parts and checks the result.

### Channels

`sub(s, name)` is the same store with every key under `name/`. Its `url()` and `list()` work in that space, and
`list` gives keys without the name.

```goose
let blog, ok = blob::sub(store, "c/blog");          // c/blog/m/ab/... on disk or in the bucket
```

## Operations

All return `bool`. On false, `last_error()` says why, and `not_found()` is true when the key does not exist.
Both are per thread.

| Call | Does |
|---|---|
| `put_file(s, key, path, o)` | Stores a file, streamed. |
| `put(s, key, data, o)` | Stores bytes. |
| `get(s, key, out, max = 64 MiB)` | Appends the object to `out`; false when it is bigger than `max`. |
| `get_range(s, key, off, n, out)` | Appends up to `n` bytes from `off`; none past the end. |
| `get_to_file(s, key, path)` | Writes the object to a file, streamed and atomically. |
| `head(s, key, info)` | `Info { size, etag, content_type, modified }`, Unix seconds. |
| `exists(s, key)` | `head` without the info. |
| `delete(s, key)` | True when the key is gone, also when it never was. |
| `list(s, prefix, after, out)` | Appends `Entry { key, size, modified }` in byte order until `out` (`Entry[..1000]`) is full. |
| `url(s, key, out)` | `public_base + key`; false for a private store. |
| `presign_get(s, key, ttl_s, out)` | A URL that reads the object for `ttl_s` seconds (up to 7 days). S3 only. |
| `presign_put(s, key, o, size, ttl_s, url, headers)` | A URL a client PUTs to, and the header lines it must send. S3 only. |
| `root(s)`, `is_disk(s)`, `is_s3(s)` | The disk folder (`""` for S3), the backend. |

`PutOptions { content_type, cache_control, disposition, immutable }` become `Content-Type`, `Cache-Control` and
`Content-Disposition` on S3 objects. `immutable` without `cache_control` is `public, max-age=31536000, immutable`.
A presigned PUT signs `Content-Length` and these headers, so a client cannot change them.

Paging: fewer entries than `out` had room for means the end; the next page starts `after` the last key.

```goose
var after: u8[..512] = "";
loop {
    var page: blob::Entry[..1000] = [];
    guard blob::list(s, "m/", after, page) else { break; }
    for e in page { sweep(e); }
    if page.len < 1000 { break; }
    after.clear(); after.append(page[999].key);
}
```

## Disk

An object is the file `ROOT/KEY`.

- Writes go to `.NAME.tmp-HEX` beside the target, then fsync, rename and an fsync of the folder. Readers see the old
  bytes or all of the new. A temp name starts with `.`, so no key names it and `list` skips it.
- `delete` removes folders it leaves empty, up to the root.
- Reads, writes and deletes refuse a path whose folder resolves outside the root (a symlinked folder). A symlinked
  file is not an object, and `list` skips symlinks.
- `head`: the ETag is `gweb::send_file`'s (`"SIZE-MTIME_NS"`), and the type comes from the key's extension.
  `PutOptions` are not stored.
- `presign_*` return false. Serve files with `gweb::send_file(req, ctx, res, blob::root(s), key, opts)`.
- `list` walks the folder the prefix names and sorts in memory.

## S3

- One request per call, SigV4 in the `Authorization` header. A file body is sent as `UNSIGNED-PAYLOAD` over TLS, so
  no file is hashed; a buffer is sent with its SHA-256.
- One PUT per object: up to 5 GiB. Multipart upload is not in 0.1.
- Each thread keeps one libcurl handle, so connections are reused.
- Timeouts: 15 s to connect; a transfer that moves no byte for 60 s fails.
- `list` is ListObjectsV2. Keys that are not `key_ok` (written by other tools) are skipped.

## Serving media in gweb

```goose
// app/media/[...path]/route.goose
fn GET(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    let s, ok = media::store();
    var key: u8[>..] = [];
    if !ok || !gweb::path_decode(key, gweb::param(ctx, "path")) || !blob::key_ok(key) { http::text(res, http::Status.NotFound, "Not Found"); return; }
    if blob::is_disk(s) { var opts = gweb::FileOptions { .. }; gweb::send_file(req, ctx, res, blob::root(s), key, opts); return; }
    var url: u8[>..] = [];
    if blob::presign_get(s, key, 3600, url) { http::set_header(res, "Cache-Control", "no-store"); gweb::redirect(ctx, url); }
}
```

`examples/media` is a whole app: per-channel uploads, listing, deletes and serving on either backend.

## SigV4

`import blob.sigv4;` has the signer: `canonical_request`, `string_to_sign`, `signing_key`, `signature`,
`authorization`, `presign_query`, `uri_encode`, `amz_date`. It is tested against AWS's SigV4 test suite and the S3
API reference examples.

## Tests

```
test/run.sh                 # all
test/run.sh test_disk       # one
examples/run.sh             # the gweb example
```

They need gweb and goose-net checkouts beside this repo (`../goose-web`, `../goose-net`, or `BLOB_GWEB` and
`BLOB_NET`). `test_s3` starts a throwaway MinIO over HTTPS with a certificate made for the run, when `minio` is on
PATH, in Homebrew or at `MINIO_BIN`; otherwise it is skipped with a message. `BLOB_TEST_S3_URL` (with keys in the
environment) runs it against another store, under a fresh `run-HEX/` prefix that it deletes afterwards.

## License

Apache 2.0.
