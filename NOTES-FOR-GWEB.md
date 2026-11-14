# Notes for gweb

Asks of gweb from goose-blob. Nothing here is applied.

## What works today (gweb 1.1)

`package blob josephheinz/goose-blob@v0.1.0` in `gweb.packages` declares the package; `import blob;` then works in
`app/` and `lib/`. `examples/run.sh` builds `examples/media` that way, with `GWEB_PKG_BLOB` pointing at a checkout,
and needs no hand edit of `.gweb/main.goose`. goose-blob imports `gweb.auth.crypto` (`sha256`, `hmac_sha256`) and
`gweb.http.files` (`mime_type`), both stable module paths.

## Asks

1. **Redirects longer than 1,024 bytes** (S): `Ctx.location` is `u8[..1024]` and `gweb::redirect` cuts the URL to fit.
   A presigned S3 URL is about 450 bytes, but with an STS session token (`X-Amz-Security-Token`) it is often 1.5 to
   3 KiB, and the cut URL fails its signature. Raise the field to 4,096, or make `redirect` refuse (500 and a log
   line) rather than cut. Until then, a route can write the `Location` header itself.
2. **Docker image with libcurl** (S): when `gweb.packages` declares `blob`, `gweb new`'s Dockerfile (or the deploy
   docs) needs `libcurl4-openssl-dev` in the build stage and `libcurl4` and `ca-certificates` at run time (CMS-DESIGN
   D15). Same shape as libpq for goose-postgres.
3. **Docs** (S): a "Media storage" section in `docs/site/packages.md` or `building-a-cms.md`:

   > ## Media storage
   >
   > `package blob josephheinz/goose-blob@v0.1.0`, then `import blob;`. `blob::open("file:data/media", "/media/")`
   > or an `s3://` URL. Serve disk media with `gweb::send_file(req, ctx, res, blob::root(s), key, opts)`; on S3,
   > redirect to `blob::presign_get` or use `blob::url` with a public bucket or CDN. Full reference: the
   > [goose-blob README](https://github.com/josephheinz/goose-blob).

Not asked: an HTTPS client in goose-net (libcurl in goose-blob covers it, CMS-DESIGN D13), and a second SHA-256.

## Goose compiler issue seen on x86-64 Linux (not gweb's)

In `s3.goose`, an `i64` limit passed from `_s3_get` through `_s3_call` (13 parameters, slices and refs) reached C as
65536 (the value other call sites pass) instead of the caller's value, whatever its position. macOS arm64 was right.
The library now sets the limit with `c_set_limit` right before each request. Worth a minimal repro for Goose.
