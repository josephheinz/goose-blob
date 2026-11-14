# Sourced by test/run.sh and examples/run.sh. Starts a throwaway MinIO server and stops it on exit.
#
# The server keeps its data in a temp folder and listens on 127.0.0.1:$BLOB_TEST_PORT (default 59123) only. With
# openssl it serves HTTPS with a self-signed certificate made for the run (BLOB_CA_FILE trusts it); without, plain
# HTTP (BLOB_TEST_PLAIN=1 asks for that). It is never a system service. MINIO_BIN names the binary if it is not
# on PATH or in Homebrew.
#
# Functions: wait_for CMD SECONDS, work_setup, s3_start, trap_setup. A caller may define extra_cleanup, run first on exit.
# After work_setup: WORK. After s3_start: BLOB_TEST_S3_URL, BLOB_ACCESS_KEY_ID, BLOB_SECRET_ACCESS_KEY, BLOB_CA_FILE
# (HTTPS only), S3_SCHEME, S3_ENDPOINT. s3_start returns 3 when there is no minio.

S3STARTED=0
S3PID=""

find_minio() {
  if [ -n "${MINIO_BIN:-}" ] && [ -x "$MINIO_BIN" ]; then echo "$MINIO_BIN"; return; fi
  if command -v minio >/dev/null 2>&1; then command -v minio; return; fi
  for m in /opt/homebrew/bin/minio /usr/local/bin/minio /opt/homebrew/opt/minio/bin/minio; do
    [ -x "$m" ] && { echo "$m"; return; }
  done
}

# Waits up to $2 seconds for the command "$1" to succeed.
wait_for() {
  n=0
  while [ "$n" -lt $(($2 * 10)) ]; do
    if eval "$1"; then return 0; fi
    sleep 0.1
    n=$((n + 1))
  done
  return 1
}

s3_cleanup() {
  status=$?
  trap '' INT TERM HUP
  trap - EXIT
  set +u
  if command -v extra_cleanup >/dev/null 2>&1; then extra_cleanup; fi
  if [ "$S3STARTED" = 1 ] && [ -n "$S3PID" ]; then
    kill "$S3PID" 2>/dev/null
    wait_for "! kill -0 $S3PID 2>/dev/null" 20 || { kill -9 "$S3PID" 2>/dev/null; echo "FAIL: minio $S3PID did not stop" >&2; status=1; }
  fi
  [ -n "${WORK:-}" ] && rm -rf "$WORK"
  exit "$status"
}

trap_setup() {
  trap s3_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
}

work_setup() {
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/gblob.XXXXXX") || return 2
  WORK=$(cd "$WORK" && pwd -P)
}

s3_start() {
  MINIO=$(find_minio)
  [ -n "$MINIO" ] || return 3
  command -v curl >/dev/null 2>&1 || { echo "curl (the command) is needed to make the test bucket" >&2; return 2; }
  port=${BLOB_TEST_PORT:-59123}
  console=$((port + 1))
  mkdir -p "$WORK/minio/data" "$WORK/minio/certs"
  S3_SCHEME=http
  CURL_CA=""
  if [ "${BLOB_TEST_PLAIN:-}" != 1 ] && command -v openssl >/dev/null 2>&1 &&
     openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=127.0.0.1" \
       -addext "subjectAltName=IP:127.0.0.1,DNS:localhost" -addext "basicConstraints=critical,CA:TRUE" \
       -keyout "$WORK/minio/certs/private.key" -out "$WORK/minio/certs/public.crt" >"$WORK/minio/openssl.log" 2>&1; then
    S3_SCHEME=https
    BLOB_CA_FILE="$WORK/minio/certs/public.crt"
    export BLOB_CA_FILE
    CURL_CA="--cacert $BLOB_CA_FILE"
  fi
  BLOB_ACCESS_KEY_ID=gblobtest
  BLOB_SECRET_ACCESS_KEY=gblobtest-secret-key
  export BLOB_ACCESS_KEY_ID BLOB_SECRET_ACCESS_KEY
  S3_ENDPOINT="$S3_SCHEME://127.0.0.1:$port"
  curl -s -o /dev/null $CURL_CA "$S3_ENDPOINT/minio/health/live" && { echo "port $port is in use; set BLOB_TEST_PORT" >&2; return 2; }
  MINIO_ROOT_USER=$BLOB_ACCESS_KEY_ID MINIO_ROOT_PASSWORD=$BLOB_SECRET_ACCESS_KEY MINIO_BROWSER=off \
  MINIO_UPDATE=off MINIO_CI_CD=1 \
    "$MINIO" server --quiet --address "127.0.0.1:$port" --console-address "127.0.0.1:$console" \
    --certs-dir "$WORK/minio/certs" "$WORK/minio/data" >"$WORK/minio/server.log" 2>&1 &
  S3PID=$!
  S3STARTED=1
  wait_for "curl -s -f -o /dev/null $CURL_CA $S3_ENDPOINT/minio/health/live" 30 || { echo "minio did not start" >&2; cat "$WORK/minio/server.log" >&2; return 2; }
  # The bucket, made with curl's own SigV4.
  code=$(curl -s -o "$WORK/minio/mb.log" -w '%{http_code}' $CURL_CA --aws-sigv4 "aws:amz:us-east-1:s3" \
    --user "$BLOB_ACCESS_KEY_ID:$BLOB_SECRET_ACCESS_KEY" -X PUT "$S3_ENDPOINT/gtest")
  [ "$code" = 200 ] || { echo "could not make the bucket (HTTP $code)" >&2; cat "$WORK/minio/mb.log" >&2; return 2; }
  BLOB_TEST_S3_URL="s3://gtest/run?endpoint=$S3_ENDPOINT&region=us-east-1"
  export BLOB_TEST_S3_URL
}
