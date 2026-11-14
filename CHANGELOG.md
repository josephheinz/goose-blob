# Changelog

## v0.1.0

First release: object storage for Goose, on disk or S3-compatible, over the system libcurl.

- Stores: `open` (`file:PATH`, `s3://BUCKET/PREFIX?endpoint=&region=&style=`), keys from `BLOB_*` or `AWS_*`
  variables or given; `sub` for a channel's key space; `root`, `is_disk`, `is_s3`.
- Operations: `put_file` and `get_to_file` (streamed), `put`, `get`, `get_range`, `head`, `exists`, `delete`,
  `list` (byte order, paged), `url`, `presign_get`, `presign_put`; `last_error`, `not_found`.
- Keys: `key_ok` (`[a-z0-9._-]`, `/` segments, no dot segments, 512 bytes), checked on every call; `key` joins parts.
- Disk: atomic writes (temp file, fsync, rename, folder fsync); empty folders pruned on delete; symlinked folders
  cannot lead outside the root; ETags match `gweb::send_file`.
- S3: AWS S3, R2, MinIO and others; path or virtual-host style; TLS verification always on, `BLOB_CA_FILE` for a
  private CA; `http://` only for localhost unless `plain_http=1`; `PutOptions` become object headers.
- SigV4 (`blob.sigv4`) on gweb's SHA-256 and HMAC, tested against AWS's test suite and the S3 examples.
- Needs gweb 1.1 (and goose-net); a gweb app declares it with `package blob josephheinz/goose-blob@v0.1.0`.
