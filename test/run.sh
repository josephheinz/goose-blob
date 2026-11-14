#!/bin/sh
# Runs the goose-blob tests.
#
#   test/run.sh                  builds and runs every test program
#   test/run.sh test_disk        only the named ones
#
# Needs goose, libcurl, and gweb and goose-net checkouts beside this repo (../goose-web, ../goose-net; or set
# BLOB_GWEB and BLOB_NET). test_s3 runs against a throwaway MinIO (test/s3server.sh), or against BLOB_TEST_S3_URL
# when that is set (with BLOB_ACCESS_KEY_ID and BLOB_SECRET_ACCESS_KEY), and is skipped when neither is there.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
WEB=$(cd "${BLOB_GWEB:-$ROOT/../goose-web}" 2>/dev/null && pwd) || { echo "needs gweb beside this repo (../goose-web) or BLOB_GWEB" >&2; exit 2; }
NET=$(cd "${BLOB_NET:-$ROOT/../goose-net}" 2>/dev/null && pwd) || { echo "needs goose-net beside this repo (../goose-net) or BLOB_NET" >&2; exit 2; }
command -v goose >/dev/null 2>&1 || { echo "goose is not on PATH" >&2; exit 2; }
. "$HERE/s3server.sh"
trap_setup
work_setup || exit 2

if [ $# -gt 0 ]; then tests="$*"; else tests="test_sigv4 test_disk test_s3"; fi

# The test roots name the packages by path relative to test/; a copy in WORK names them absolutely, so other
# gweb and goose-net checkouts can be used.
root_for() {
  sed -e "s|import blob from \"..\";|import blob from \"$ROOT\";|" \
      -e "s|import gweb from \"../../goose-web\";|import gweb from \"$WEB\";|" \
      -e "s|import net from \"../../goose-net\";|import net from \"$NET\";|" "$HERE/$1.goose" >"$WORK/$1.goose"
}

failed=0
for t in $tests; do
  echo "== $t"
  [ -f "$HERE/$t.goose" ] || { echo "FAIL: no test/$t.goose" >&2; failed=1; continue; }
  case "$t" in
    test_s3)
      if [ -n "${BLOB_TEST_S3_URL:-}" ]; then
        echo "against BLOB_TEST_S3_URL"
      else
        s3_start; rc=$?
        if [ "$rc" = 3 ]; then
          echo "SKIP test_s3: no minio found (brew install minio, or set MINIO_BIN or BLOB_TEST_S3_URL)"
          continue
        fi
        [ "$rc" = 0 ] || { echo "FAIL: could not start minio" >&2; failed=1; continue; }
        echo "against a throwaway MinIO over $S3_SCHEME"
      fi ;;
    test_disk)
      mkdir -p "$WORK/disk/store"
      ln -s "$WORK/disk" "$WORK/disk/store/out"
      ln -s "$WORK/disk/secret.txt" "$WORK/disk/store/link.txt"
      BLOB_TEST_DIR="$WORK/disk"; export BLOB_TEST_DIR ;;
  esac
  root_for "$t"
  if goose build --color never -o "$WORK/$t" "$WORK/$t.goose" >"$WORK/$t.build" 2>&1; then
    (cd "$WORK" && "./$t") || failed=1
  else
    cat "$WORK/$t.build" >&2
    echo "FAIL: $t did not build" >&2
    failed=1
  fi
done
[ "$failed" = 0 ] && echo "all tests passed" || echo "TESTS FAILED" >&2
exit "$failed"
