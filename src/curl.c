#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
/* goose-blob: the libcurl shim. One request function: a method, a URL, header lines, a body from a buffer or a
   file, and a response into a buffer or (atomically) into a file. TLS peer and host verification are always on.
   Each thread keeps one easy handle, so connections are reused; it is cleaned up when the thread ends.
   Also the credential table: S3 secrets live here, not in the Goose Store struct. */
#include "goose.h"
#include <curl/curl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/stat.h>

typedef struct { const uint8_t *data; int64_t len; } gb_bytes;

#define GB_PATH 4096
#define GB_ERRBODY 65536

/* From disk.c. */
void gblob_set_error(const char *what, const char *detail);
void gblob_clear_error(void);
int gblob_cpath(char *buf, size_t cap, gb_bytes p);
int gblob_temp_beside(const char *dst, char *tmp, size_t cap);
int gblob_commit_temp(int fd, const char *tmp, const char *dst);

/* ---------------------------------------------------------------- per-thread handle */

static pthread_once_t init_once = PTHREAD_ONCE_INIT;
static pthread_key_t handle_key;
static int init_ok;
static __thread CURL *tl_curl;

static void handle_destroy(void *p) { if (p) curl_easy_cleanup((CURL *)p); }
static void global_init(void) {
    init_ok = curl_global_init(CURL_GLOBAL_DEFAULT) == CURLE_OK;
    pthread_key_create(&handle_key, handle_destroy);
}
static CURL *handle(void) {
    pthread_once(&init_once, global_init);
    if (!init_ok) return NULL;
    if (!tl_curl) {
        tl_curl = curl_easy_init();
        if (tl_curl) pthread_setspecific(handle_key, tl_curl);
    } else {
        curl_easy_reset(tl_curl);
    }
    return tl_curl;
}

/* ---------------------------------------------------------------- one request */

typedef struct {
    CURL *c;
    /* request body */
    const uint8_t *buf; int64_t len, off;
    int in_fd;
    /* response */
    int to_file, out_fd;              /* to_file: a 2xx body goes to out_fd */
    gs_rref out;                      /* else the body is appended here */
    int64_t max, got;
    char *errbody; size_t errlen;     /* a non-2xx body when to_file */
    int too_big, write_failed;
    char *heads; size_t hlen, hcap;   /* the last header block */
} gb_req;

static size_t read_cb(char *dst, size_t size, size_t n, void *ud) {
    gb_req *r = ud;
    size_t want = size * n;
    if (r->in_fd >= 0) {
        for (;;) {
            ssize_t got = read(r->in_fd, dst, want);
            if (got < 0 && errno == EINTR) continue;
            if (got < 0) return CURL_READFUNC_ABORT;
            return (size_t)got;
        }
    }
    int64_t left = r->len - r->off;
    if ((int64_t)want > left) want = (size_t)left;
    if (want) memcpy(dst, r->buf + r->off, want);
    r->off += (int64_t)want;
    return want;
}

static long status_now(gb_req *r) { long code = 0; curl_easy_getinfo(r->c, CURLINFO_RESPONSE_CODE, &code); return code; }

static size_t write_cb(char *src, size_t size, size_t n, void *ud) {
    gb_req *r = ud;
    size_t len = size * n;
    long code = status_now(r);
    if (r->to_file && code >= 200 && code < 300) {
        size_t done = 0;
        while (done < len) {
            ssize_t w = write(r->out_fd, src + done, len - done);
            if (w < 0) { if (errno == EINTR) continue; r->write_failed = 1; return 0; }
            done += (size_t)w;
        }
        r->got += (int64_t)len;
        return len;
    }
    if (r->to_file) {
        size_t room = GB_ERRBODY - r->errlen;
        size_t k = len < room ? len : room;
        if (!r->errbody) r->errbody = malloc(GB_ERRBODY);
        if (r->errbody && k) { memcpy(r->errbody + r->errlen, src, k); r->errlen += k; }
        return len;
    }
    if (r->got + (int64_t)len > r->max) { r->too_big = 1; return 0; }
    gs_bld_append(r->out, src, len);
    r->got += (int64_t)len;
    return len;
}

static size_t header_cb(char *src, size_t size, size_t n, void *ud) {
    gb_req *r = ud;
    size_t len = size * n;
    if (len >= 5 && memcmp(src, "HTTP/", 5) == 0) r->hlen = 0;   /* a new block: 100 Continue came first */
    if (r->hlen + len > r->hcap) {
        size_t nc = r->hcap ? r->hcap * 2 : 2048;
        while (nc < r->hlen + len) nc *= 2;
        if (nc > 262144) return len;                              /* keep what fits */
        char *nh = realloc(r->heads, nc);
        if (!nh) return len;
        r->heads = nh; r->hcap = nc;
    }
    memcpy(r->heads + r->hlen, src, len);
    r->hlen += len;
    return len;
}

static char *dup_z(gb_bytes b) {
    char *p = malloc((size_t)(b.len > 0 ? b.len : 0) + 1);
    if (!p) return NULL;
    if (b.len > 0) memcpy(p, b.data, (size_t)b.len);
    p[b.len > 0 ? b.len : 0] = 0;
    return p;
}

/* Sends one request. method: GET, HEAD, PUT, DELETE, POST. headers: "Name: value" lines split by '\n'.
   The body is body_path's file when that is set, else the bytes of body (PUT and POST only).
   The response body goes to out_path atomically when that is set and the status is 2xx (a temp file beside it,
   fsync, rename); a non-2xx body then goes to out_body (up to 64 KiB). Without out_path, the body is appended to
   out_body, and more than max_body bytes fail the call. Response header lines (the last block) are appended to
   out_headers. ca_file, when set, replaces the CA bundle; verification stays on.
   Returns 1 when a response came (any status, in *status), 0 for a transport error (gblob_error says why). */
int32_t gblob_http(gb_bytes method, gb_bytes url, gb_bytes headers, gb_bytes body, gb_bytes body_path,
                   gb_bytes out_path, int64_t max_body, gs_rref out_body, gs_rref out_headers, int64_t *status,
                   gb_bytes ca_file) {
    gblob_clear_error();
    *status = 0;
    CURL *c = handle();
    if (!c) { gblob_set_error("libcurl did not start", NULL); return 0; }
    char *m = dup_z(method), *u = dup_z(url), *ca = ca_file.len > 0 ? dup_z(ca_file) : NULL;
    struct curl_slist *hl = NULL;
    gb_req r = { 0 };
    r.c = c; r.in_fd = -1; r.out_fd = -1; r.out = out_body; r.max = max_body;
    char tmp[GB_PATH], dst[GB_PATH];
    int ok = 0;
    if (!m || !u || (ca_file.len > 0 && !ca)) { gblob_set_error("out of memory", NULL); goto done; }
    if (memchr(url.data, 0, (size_t)url.len)) { gblob_set_error("bad URL", NULL); goto done; }

    /* Header lines; "Expect:" turns off 100-continue, which costs a round trip on every PUT. */
    {
        int64_t i = 0;
        while (i < headers.len) {
            int64_t j = i;
            while (j < headers.len && headers.data[j] != '\n') j++;
            if (j > i) {
                gb_bytes line = { headers.data + i, j - i };
                char *z = dup_z(line);
                if (!z || memchr(line.data, 0, (size_t)line.len) || memchr(line.data, '\r', (size_t)line.len)) {
                    free(z); gblob_set_error("bad header", NULL); goto done;
                }
                struct curl_slist *nl = curl_slist_append(hl, z);
                free(z);
                if (!nl) { gblob_set_error("out of memory", NULL); goto done; }
                hl = nl;
            }
            i = j + 1;
        }
        struct curl_slist *nl = curl_slist_append(hl, "Expect:");
        if (nl) hl = nl;
    }

    curl_easy_setopt(c, CURLOPT_URL, u);
#if LIBCURL_VERSION_NUM >= 0x075500
    curl_easy_setopt(c, CURLOPT_PROTOCOLS_STR, "https,http");
#else
    curl_easy_setopt(c, CURLOPT_PROTOCOLS, (long)(CURLPROTO_HTTPS | CURLPROTO_HTTP));
#endif
    curl_easy_setopt(c, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(c, CURLOPT_SSL_VERIFYHOST, 2L);
    if (ca) curl_easy_setopt(c, CURLOPT_CAINFO, ca);
    curl_easy_setopt(c, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(c, CURLOPT_FOLLOWLOCATION, 0L);
    curl_easy_setopt(c, CURLOPT_CONNECTTIMEOUT, 15L);
    curl_easy_setopt(c, CURLOPT_LOW_SPEED_LIMIT, 1L);     /* no byte for 60 s: give up */
    curl_easy_setopt(c, CURLOPT_LOW_SPEED_TIME, 60L);
    curl_easy_setopt(c, CURLOPT_HTTPHEADER, hl);
    curl_easy_setopt(c, CURLOPT_HEADERFUNCTION, header_cb);
    curl_easy_setopt(c, CURLOPT_HEADERDATA, &r);
    curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, write_cb);
    curl_easy_setopt(c, CURLOPT_WRITEDATA, &r);

    int is_put = strcmp(m, "PUT") == 0, is_post = strcmp(m, "POST") == 0;
    if (strcmp(m, "HEAD") == 0) curl_easy_setopt(c, CURLOPT_NOBODY, 1L);
    else if (strcmp(m, "GET") == 0) curl_easy_setopt(c, CURLOPT_HTTPGET, 1L);
    else if (is_put || is_post) {
        int64_t size = body.len;
        if (body_path.len > 0) {
            char bp[GB_PATH];
            if (!gblob_cpath(bp, sizeof bp, body_path)) { gblob_set_error("bad source path", NULL); goto done; }
            r.in_fd = open(bp, O_RDONLY | O_CLOEXEC);
            struct stat st;
            if (r.in_fd < 0) { gblob_set_error("open source", strerror(errno)); goto done; }
            if (fstat(r.in_fd, &st) != 0 || !S_ISREG(st.st_mode)) { gblob_set_error("source is not a file", NULL); goto done; }
            size = (int64_t)st.st_size;
        } else {
            r.buf = body.data; r.len = body.len;
        }
        curl_easy_setopt(c, CURLOPT_UPLOAD, 1L);
        curl_easy_setopt(c, CURLOPT_READFUNCTION, read_cb);
        curl_easy_setopt(c, CURLOPT_READDATA, &r);
        curl_easy_setopt(c, CURLOPT_INFILESIZE_LARGE, (curl_off_t)size);
        if (is_post) curl_easy_setopt(c, CURLOPT_CUSTOMREQUEST, "POST");
    } else {
        curl_easy_setopt(c, CURLOPT_CUSTOMREQUEST, m);
    }

    if (out_path.len > 0) {
        if (!gblob_cpath(dst, sizeof dst, out_path)) { gblob_set_error("bad path", NULL); goto done; }
        r.out_fd = gblob_temp_beside(dst, tmp, sizeof tmp);
        if (r.out_fd < 0) goto done;
        r.to_file = 1;
    }

    char ebuf[CURL_ERROR_SIZE];
    ebuf[0] = 0;
    curl_easy_setopt(c, CURLOPT_ERRORBUFFER, ebuf);
    CURLcode rc = curl_easy_perform(c);
    curl_easy_setopt(c, CURLOPT_ERRORBUFFER, NULL);
    long code = status_now(&r);
    if (rc != CURLE_OK) {
        if (r.too_big) gblob_set_error("response larger than the limit", NULL);
        else if (r.write_failed) gblob_set_error("write", strerror(errno));
        else gblob_set_error(curl_easy_strerror(rc), ebuf);
        goto done;
    }
    *status = code;
    if (r.heads && r.hlen) gs_bld_append(out_headers, r.heads, r.hlen);
    if (r.to_file) {
        if (code >= 200 && code < 300) {
            int fd = r.out_fd;
            r.out_fd = -1;
            if (!gblob_commit_temp(fd, tmp, dst)) goto done;
        } else if (r.errlen) {
            gs_bld_append(out_body, r.errbody, r.errlen);
        }
    }
    ok = 1;
done:
    if (r.out_fd >= 0) { close(r.out_fd); unlink(tmp); }
    if (r.in_fd >= 0) close(r.in_fd);
    curl_slist_free_all(hl);
    /* The handle keeps pointers to these until the next reset: clear them first. */
    if (c) { curl_easy_setopt(c, CURLOPT_HTTPHEADER, NULL); curl_easy_setopt(c, CURLOPT_URL, NULL); }
    free(m); free(u); free(ca); free(r.errbody); free(r.heads);
    return ok;
}

/* ---------------------------------------------------------------- credentials */

#define GB_CREDS 64
typedef struct { char *id, *secret, *token; } gb_cred;
static gb_cred creds[GB_CREDS];
static int ncreds;
static pthread_mutex_t creds_mu = PTHREAD_MUTEX_INITIALIZER;

static int same(const char *a, gb_bytes b) { return strlen(a) == (size_t)b.len && memcmp(a, b.data, (size_t)b.len) == 0; }

/* A handle (1..64) for these credentials; the same three strings give the same handle. 0 when the table is full. */
int64_t gblob_cred_put(gb_bytes id, gb_bytes secret, gb_bytes token) {
    pthread_mutex_lock(&creds_mu);
    int64_t h = 0;
    for (int i = 0; i < ncreds; i++)
        if (same(creds[i].id, id) && same(creds[i].secret, secret) && same(creds[i].token, token)) { h = i + 1; break; }
    if (!h && ncreds < GB_CREDS) {
        gb_cred c = { dup_z(id), dup_z(secret), dup_z(token) };
        if (c.id && c.secret && c.token) { creds[ncreds++] = c; h = ncreds; }
        else { free(c.id); free(c.secret); free(c.token); }
    }
    pthread_mutex_unlock(&creds_mu);
    return h;
}

/* which: 0 the key id, 1 the secret, 2 the session token. */
void gblob_cred_get(int64_t h, int32_t which, gs_rref out) {
    pthread_mutex_lock(&creds_mu);
    if (h >= 1 && h <= ncreds) {
        const char *s = which == 0 ? creds[h - 1].id : which == 1 ? creds[h - 1].secret : creds[h - 1].token;
        gs_bld_append(out, s, strlen(s));
    }
    pthread_mutex_unlock(&creds_mu);
}
