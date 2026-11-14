#!/bin/sh
# Builds the gweb example (examples/media) against the sibling ../goose-web and ../goose-net checkouts and curls
# its routes, first on the disk backend, then on S3 against a throwaway MinIO (test/s3server.sh) when one is found.
# Needs goose, curl and libcurl.
#
#   examples/run.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
# goose-web and goose-net are read from beside this repo; EXAMPLE_WEB and EXAMPLE_NET name other checkouts.
WEB=$(cd "${EXAMPLE_WEB:-$ROOT/../goose-web}" 2>/dev/null && pwd) || { echo "needs goose-web beside this repo (or EXAMPLE_WEB)" >&2; exit 2; }
NET=$(cd "${EXAMPLE_NET:-$ROOT/../goose-net}" 2>/dev/null && pwd) || { echo "needs goose-net beside this repo (or EXAMPLE_NET)" >&2; exit 2; }
WEBPORT=${EXAMPLE_PORT:-3995}
. "$ROOT/test/s3server.sh"

SERVER_PID=""
stop_server() {
  [ -n "$SERVER_PID" ] || return 0
  kill "$SERVER_PID" 2>/dev/null
  wait_for "! kill -0 $SERVER_PID 2>/dev/null" 20
  SERVER_PID=""
}
extra_cleanup() { stop_server; }
trap_setup
work_setup || exit 2

echo "building gweb"
goose build --color never -o "$WORK/gweb" "$WEB/cli/gweb.goose" >"$WORK/gweb.log" 2>&1 || { cat "$WORK/gweb.log" >&2; exit 2; }
cp -R "$HERE/media" "$WORK/site"
# gweb.packages says josephheinz/goose-blob@v0.1.0; GWEB_PKG_BLOB points the root at this checkout instead.
export GWEB_HOME="$WEB" GWEB_SRC="$WEB" GWEB_NET="$NET" GWEB_PKG_BLOB="$ROOT"
echo "building the site"
(cd "$WORK/site" && "$WORK/gweb" build >"$WORK/build.log" 2>&1) || { cat "$WORK/build.log" >&2; exit 1; }
grep -q "^import blob from \"$ROOT\";" "$WORK/site/.gweb/main.goose" || { echo "the root does not declare blob" >&2; exit 1; }

URL="http://127.0.0.1:$WEBPORT"
curl -s -o /dev/null "$URL/" && { echo "port $WEBPORT is in use; set EXAMPLE_PORT" >&2; exit 2; }
start_server() {
  (cd "$WORK/site" && GWEB_WORKERS=4 GWEB_MAX_BODY=8388608 exec ./.gweb/server --port "$WEBPORT" --host 127.0.0.1 >"$WORK/server.log" 2>&1) &
  SERVER_PID=$!
  wait_for "curl -s -o /dev/null $URL/api/main/files" 30 || { echo "server did not start" >&2; cat "$WORK/server.log" >&2; exit 1; }
}

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $1: got '$2', want '$3'"; fi; }
TOKEN=0123456789abcdef0123456789abcdef       # the CSRF token is a cookie and a header with the same value
send() { curl -s -o "$WORK/body" -w '%{http_code}' -H "Cookie: gw_csrf=$TOKEN" -H "X-CSRF-Token: $TOKEN" "$@"; }

# The checks both backends pass. $1 names the backend.
routes() {
  b=$1
  check "$b empty list" "$(curl -s "$URL/api/main/files")" "[]"
  printf 'hello from main' >"$WORK/hello.txt"
  check "$b upload" "$(send --data-binary "@$WORK/hello.txt" -H 'Content-Type: application/octet-stream' "$URL/api/main/files?name=hello.txt")" "201"
  check "$b upload reply" "$(cat "$WORK/body")" '{"key":"hello.txt","url":"/media/c/main/hello.txt"}'
  check "$b list" "$(curl -s "$URL/api/main/files")" '[{"key":"hello.txt","size":15,"url":"/media/c/main/hello.txt"}]'
  check "$b other channel is empty" "$(curl -s "$URL/api/blog/files")" "[]"
  check "$b same name in another channel" "$(send --data-binary 'blog copy' "$URL/api/blog/files?name=hello.txt")" "201"
  check "$b served" "$(curl -s -L $CURL_CA "$URL/media/main/hello.txt")" "hello from main"
  check "$b served other channel" "$(curl -s -L $CURL_CA "$URL/media/blog/hello.txt")" "blog copy"
  head -c 3000000 /dev/urandom >"$WORK/big.bin"
  check "$b big upload" "$(send --data-binary "@$WORK/big.bin" "$URL/api/main/files?name=big.bin")" "201"
  curl -s -L $CURL_CA -o "$WORK/big.out" "$URL/media/main/big.bin"
  check "$b big download" "$(cmp -s "$WORK/big.bin" "$WORK/big.out" && echo same)" "same"
  check "$b traversal name" "$(send --data-binary x "$URL/api/main/files?name=..%2Fx")" "400"
  check "$b dot name" "$(send --data-binary x "$URL/api/main/files?name=.env")" "400"
  check "$b bad channel" "$(send --data-binary x "$URL/api/Main/files?name=x")" "404"
  check "$b traversal download" "$(curl -s -o /dev/null -w '%{http_code}' "$URL/media/main/..%2F..%2Fsecret")" "404"
  check "$b missing download" "$(curl -s -L $CURL_CA -o /dev/null -w '%{http_code}' "$URL/media/main/nope.txt")" "404"
  check "$b no csrf" "$(curl -s -o /dev/null -w '%{http_code}' --data-binary x "$URL/api/main/files?name=x")" "403"
  check "$b delete" "$(send -X DELETE "$URL/api/main/files/hello.txt")" "204"
  check "$b delete again" "$(send -X DELETE "$URL/api/main/files/hello.txt")" "204"
  check "$b after delete" "$(curl -s "$URL/api/main/files")" '[{"key":"big.bin","size":3000000,"url":"/media/c/main/big.bin"}]'
  check "$b blog kept" "$(curl -s -L $CURL_CA "$URL/media/blog/hello.txt")" "blog copy"
}

echo "disk backend"
CURL_CA=""
start_server
routes disk
check "disk file on disk" "$(cat "$WORK/site/data/media/c/blog/hello.txt")" "blog copy"
check "disk etag" "$(curl -s -o /dev/null -w '%{http_code}' -H "If-None-Match: $(curl -s -D - -o /dev/null "$URL/media/blog/hello.txt" | tr -d '\r' | sed -n 's/^[Ee][Tt]ag: //p')" "$URL/media/blog/hello.txt")" "304"
stop_server

s3_start; rc=$?
if [ "$rc" = 3 ]; then
  echo "SKIP the S3 half: no minio found (brew install minio, or set MINIO_BIN)"
elif [ "$rc" != 0 ]; then
  echo "FAIL: could not start minio"; fail=$((fail + 1))
else
  echo "S3 backend (MinIO over $S3_SCHEME)"
  EXAMPLE_BLOB_URL="s3://gtest/site?endpoint=$S3_ENDPOINT&region=us-east-1"
  export EXAMPLE_BLOB_URL
  start_server
  routes s3
  loc=$(curl -s -o /dev/null -w '%{redirect_url}' "$URL/media/blog/hello.txt")
  case "$loc" in "$S3_ENDPOINT/gtest/site/c/blog/hello.txt?X-Amz-Algorithm="*) check "s3 presigned redirect" ok ok ;; *) check "s3 presigned redirect" "$loc" "a presigned URL" ;; esac
  stop_server
fi
echo "example: $pass passed, $fail failed"
[ "$fail" = 0 ]
