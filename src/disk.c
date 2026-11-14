#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
/* goose-blob: the disk side. Atomic writes (a temp file in the target's folder, fsync, rename, fsync of the folder),
   reads at an offset, stat, delete with pruning of empty folders, and a sorted listing. Paths arrive whole; the
   Goose side has checked the key, so nothing here climbs out of the root. Errors are per thread (gblob_error). */
#include "goose.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <limits.h>
#if defined(__APPLE__)
#include <sys/random.h>
#endif

typedef struct { const uint8_t *data; int64_t len; } gb_bytes;

#define GB_PATH 4096
#define GB_WINDOW 262144

static __thread char gb_err[512];

void gblob_set_error(const char *what, const char *detail) {
    if (detail && *detail) snprintf(gb_err, sizeof gb_err, "%s: %s", what, detail);
    else snprintf(gb_err, sizeof gb_err, "%s", what);
}
static void set_errno(const char *what) { gblob_set_error(what, strerror(errno)); }
void gblob_clear_error(void) { gb_err[0] = 0; }
void gblob_error(gs_rref out) { gs_bld_append(out, gb_err, strlen(gb_err)); }

/* A NUL-terminated copy in buf; 0 for an empty, overlong or NUL-holding path. */
int gblob_cpath(char *buf, size_t cap, gb_bytes p) {
    if (p.len <= 0 || (size_t)p.len >= cap || memchr(p.data, 0, (size_t)p.len)) return 0;
    memcpy(buf, p.data, (size_t)p.len);
    buf[p.len] = 0;
    return 1;
}

int gblob_random_hex(char *out, int nbytes) {
    unsigned char r[32];
    if (nbytes > 32) nbytes = 32;
    if (getentropy(r, (size_t)nbytes) != 0) {
        int fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
        if (fd < 0) return 0;
        ssize_t n = read(fd, r, (size_t)nbytes);
        close(fd);
        if (n != nbytes) return 0;
    }
    static const char hex[] = "0123456789abcdef";
    for (int i = 0; i < nbytes; i++) { out[2 * i] = hex[r[i] >> 4]; out[2 * i + 1] = hex[r[i] & 15]; }
    out[2 * nbytes] = 0;
    return 1;
}

/* mkdir -p for every folder above the last '/' of path. */
static int mkdirs_for(const char *path) {
    char tmp[GB_PATH];
    snprintf(tmp, sizeof tmp, "%s", path);
    char *slash = strrchr(tmp, '/');
    if (!slash || slash == tmp) return 1;
    *slash = 0;
    struct stat st;
    if (stat(tmp, &st) == 0) return S_ISDIR(st.st_mode) ? 1 : (errno = ENOTDIR, 0);
    for (char *p = tmp + 1; *p; p++) {
        if (*p != '/') continue;
        *p = 0;
        if (mkdir(tmp, 0755) != 0 && errno != EEXIST) return 0;
        *p = '/';
    }
    if (mkdir(tmp, 0755) != 0 && errno != EEXIST) return 0;
    return stat(tmp, &st) == 0 && S_ISDIR(st.st_mode) ? 1 : (errno = ENOTDIR, 0);
}

static int fsync_dir_of(const char *path) {
    char dir[GB_PATH];
    snprintf(dir, sizeof dir, "%s", path);
    char *slash = strrchr(dir, '/');
    if (slash == dir) dir[1] = 0; else if (slash) *slash = 0; else snprintf(dir, sizeof dir, ".");
    int fd = open(dir, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    int r = fsync(fd);
    close(fd);
    /* Some file systems refuse fsync on a folder; the rename is still done. */
    return r == 0 || errno == EINVAL || errno == ENOTSUP;
}

static int write_all(int fd, const uint8_t *p, size_t n) {
    while (n > 0) {
        ssize_t w = write(fd, p, n);
        if (w < 0) { if (errno == EINTR) continue; return 0; }
        p += w; n -= (size_t)w;
    }
    return 1;
}

/* A temp file beside dst, open for writing: "<dir>/.<name>.tmp-<hex>". A name that starts with '.' is never a key,
   so listings skip it and no key can collide with it. tmp gets its path. Returns the fd or -1. */
int gblob_temp_beside(const char *dst, char *tmp, size_t cap) {
    if (!mkdirs_for(dst)) { set_errno("make folder"); return -1; }
    const char *slash = strrchr(dst, '/');
    size_t dirlen = slash ? (size_t)(slash - dst + 1) : 0;
    const char *base = slash ? slash + 1 : dst;
    for (int tries = 0; tries < 4; tries++) {
        char hex[33];
        if (!gblob_random_hex(hex, 8)) { gblob_set_error("no entropy", NULL); return -1; }
        int n = snprintf(tmp, cap, "%.*s.%s.tmp-%s", (int)dirlen, dst, base, hex);
        if (n < 0 || (size_t)n >= cap) { gblob_set_error("path too long", NULL); return -1; }
        int fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644);
        if (fd >= 0) return fd;
        if (errno == ENOENT && !mkdirs_for(dst)) break;    /* a delete pruned the folder meanwhile */
        if (errno != EEXIST && errno != ENOENT) break;
    }
    set_errno("create temp file");
    return -1;
}

/* Flushes, closes and renames tmp over dst, then flushes the folder. Removes tmp on failure. */
int gblob_commit_temp(int fd, const char *tmp, const char *dst) {
    if (fsync(fd) != 0) { set_errno("fsync"); close(fd); unlink(tmp); return 0; }
    if (close(fd) != 0) { set_errno("close"); unlink(tmp); return 0; }
    if (rename(tmp, dst) != 0) { set_errno("rename"); unlink(tmp); return 0; }
    if (!fsync_dir_of(dst)) { set_errno("fsync folder"); return 0; }
    return 1;
}

/* True when the folder holding path is root or below it, after resolving symlinks: a symlinked folder inside the
   root cannot lead a key outside it. An empty root checks nothing (a caller's own path). */
static int inside_root(gb_bytes root, const char *path) {
    if (root.len <= 0) return 1;
    char r[GB_PATH], dir[GB_PATH], rr[PATH_MAX], rd[PATH_MAX];
    if (!gblob_cpath(r, sizeof r, root)) return 0;
    snprintf(dir, sizeof dir, "%s", path);
    char *slash = strrchr(dir, '/');
    if (!slash) return 0;
    *slash = 0;
    if (!realpath(r, rr) || !realpath(dir, rd)) return 0;
    size_t n = strlen(rr);
    if (n == 1) return 1;   /* root is "/" */
    return strncmp(rr, rd, n) == 0 && (rd[n] == 0 || rd[n] == '/');
}

/* Writes dst atomically from the file src (from_file) or from data. Readers see the old bytes or all of the new. */
int32_t gblob_disk_put(gb_bytes root, gb_bytes dst, gb_bytes src, gb_bytes data, int32_t from_file) {
    gblob_clear_error();
    char d[GB_PATH], s[GB_PATH], tmp[GB_PATH];
    if (!gblob_cpath(d, sizeof d, dst)) { gblob_set_error("bad path", NULL); return 0; }
    int in = -1;
    if (from_file) {
        if (!gblob_cpath(s, sizeof s, src)) { gblob_set_error("bad source path", NULL); return 0; }
        in = open(s, O_RDONLY | O_CLOEXEC);
        if (in < 0) { set_errno("open source"); return 0; }
        struct stat st;
        if (fstat(in, &st) != 0 || !S_ISREG(st.st_mode)) { gblob_set_error("source is not a file", NULL); close(in); return 0; }
    }
    int fd = gblob_temp_beside(d, tmp, sizeof tmp);
    if (fd < 0) { if (in >= 0) close(in); return 0; }
    if (!inside_root(root, d)) { gblob_set_error("path leaves the root", NULL); close(fd); unlink(tmp); if (in >= 0) close(in); return 0; }
    int ok = 1;
    if (from_file) {
        uint8_t *buf = malloc(GB_WINDOW);
        if (!buf) { gblob_set_error("out of memory", NULL); ok = 0; }
        while (ok) {
            ssize_t n = read(in, buf, GB_WINDOW);
            if (n < 0) { if (errno == EINTR) continue; set_errno("read source"); ok = 0; break; }
            if (n == 0) break;
            if (!write_all(fd, buf, (size_t)n)) { set_errno("write"); ok = 0; }
        }
        free(buf);
        close(in);
    } else if (data.len > 0 && !write_all(fd, data.data, (size_t)data.len)) {
        set_errno("write"); ok = 0;
    }
    if (!ok) { close(fd); unlink(tmp); return 0; }
    return gblob_commit_temp(fd, tmp, d);
}

/* 1 for a regular file (size in bytes, mtime in Unix nanoseconds), 0 when there is none, -1 on another error. */
int32_t gblob_disk_stat(gb_bytes root, gb_bytes path, int64_t *size, int64_t *mtime_ns) {
    gblob_clear_error();
    char p[GB_PATH];
    if (!gblob_cpath(p, sizeof p, path)) { gblob_set_error("bad path", NULL); return -1; }
    struct stat st;
    if (lstat(p, &st) != 0) {
        if (errno == ENOENT || errno == ENOTDIR) return 0;
        set_errno("stat"); return -1;
    }
    if (!inside_root(root, p)) return 0;
    if (!S_ISREG(st.st_mode)) return 0;
    *size = (int64_t)st.st_size;
#if defined(__APPLE__)
    *mtime_ns = (int64_t)st.st_mtimespec.tv_sec * 1000000000 + st.st_mtimespec.tv_nsec;
#else
    *mtime_ns = (int64_t)st.st_mtim.tv_sec * 1000000000 + st.st_mtim.tv_nsec;
#endif
    return 1;
}

/* Appends up to n bytes from off (n < 0: to the end, but at most max). 1 ok, 0 no such file, -1 error
   (also when the whole file is asked for and it is larger than max). */
int32_t gblob_disk_read(gb_bytes root, gb_bytes path, int64_t off, int64_t n, int64_t max, gs_rref out) {
    gblob_clear_error();
    char p[GB_PATH];
    if (!gblob_cpath(p, sizeof p, path)) { gblob_set_error("bad path", NULL); return -1; }
    int fd = open(p, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) {
        if (errno == ENOENT || errno == ENOTDIR || errno == ELOOP) return 0;
        set_errno("open"); return -1;
    }
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || !inside_root(root, p)) { close(fd); return 0; }
    int64_t size = (int64_t)st.st_size;
    if (off < 0) off = 0;
    if (off > size) off = size;
    int64_t want = n < 0 ? size - off : (n < size - off ? n : size - off);
    if (n < 0 && want > max) { close(fd); gblob_set_error("object larger than the limit", NULL); return -1; }
    uint8_t *buf = malloc(GB_WINDOW);
    if (!buf) { close(fd); gblob_set_error("out of memory", NULL); return -1; }
    int ok = 1;
    while (want > 0) {
        ssize_t r = pread(fd, buf, (size_t)(want < GB_WINDOW ? want : GB_WINDOW), (off_t)off);
        if (r < 0) { if (errno == EINTR) continue; set_errno("read"); ok = 0; break; }
        if (r == 0) break;
        gs_bld_append(out, buf, (size_t)r);
        off += r; want -= r;
    }
    free(buf);
    close(fd);
    return ok ? 1 : -1;
}

/* Copies the file src to dst atomically (get_to_file on disk). 1 ok, 0 no such src, -1 error. */
int32_t gblob_disk_copy_out(gb_bytes root, gb_bytes src, gb_bytes dst) {
    gblob_clear_error();
    char s[GB_PATH];
    if (!gblob_cpath(s, sizeof s, src)) { gblob_set_error("bad path", NULL); return -1; }
    int in = open(s, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (in < 0) {
        if (errno == ENOENT || errno == ENOTDIR || errno == ELOOP) return 0;
        set_errno("open"); return -1;
    }
    struct stat st;
    int reg = fstat(in, &st) == 0 && S_ISREG(st.st_mode);
    close(in);
    if (!reg || !inside_root(root, s)) return 0;
    gb_bytes none = { NULL, 0 };
    return gblob_disk_put(none, dst, src, none, 1) ? 1 : -1;
}

/* Removes path, then each folder above it that is left empty, up to (not including) root. Missing is fine. */
int32_t gblob_disk_delete(gb_bytes path, gb_bytes root) {
    gblob_clear_error();
    char p[GB_PATH], r[GB_PATH];
    if (!gblob_cpath(p, sizeof p, path) || !gblob_cpath(r, sizeof r, root)) { gblob_set_error("bad path", NULL); return 0; }
    struct stat st;
    if (lstat(p, &st) != 0) return 1;                           /* gone already */
    if (S_ISDIR(st.st_mode)) return 1;                          /* a folder is not an object */
    if (!inside_root(root, p)) { gblob_set_error("path leaves the root", NULL); return 0; }
    if (unlink(p) != 0 && errno != ENOENT && errno != ENOTDIR) { set_errno("delete"); return 0; }
    size_t rl = strlen(r);
    while (rl > 1 && r[rl - 1] == '/') r[--rl] = 0;
    for (;;) {
        char *slash = strrchr(p, '/');
        if (!slash) break;
        *slash = 0;
        if (strlen(p) <= rl || strncmp(p, r, rl) != 0) break;
        if (rmdir(p) != 0) break;   /* not empty, or gone: stop */
    }
    return 1;
}

/* ---------------------------------------------------------------- listing */

typedef struct { char *key; int64_t size; int64_t mtime; } gb_entry;
typedef struct { gb_entry *v; size_t n, cap; int err; } gb_list;

static int key_char(unsigned char c) {
    return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-';
}
static int name_ok(const char *name) {
    if (!name[0] || name[0] == '.') return 0;
    for (const unsigned char *c = (const unsigned char *)name; *c; c++) if (!key_char(*c)) return 0;
    return 1;
}

static void walk(gb_list *L, char *path, size_t plen, char *key, size_t klen, const char *prefix, const char *after, int depth) {
    if (depth > 64 || L->err) return;
    DIR *d = opendir(path);
    if (!d) { if (errno != ENOENT && errno != ENOTDIR) L->err = errno; return; }
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (!name_ok(e->d_name)) continue;
        size_t nl = strlen(e->d_name);
        if (plen + 1 + nl + 1 >= GB_PATH || klen + nl + 2 >= 1024) continue;
        path[plen] = '/'; memcpy(path + plen + 1, e->d_name, nl + 1);
        memcpy(key + klen, e->d_name, nl + 1);
        /* Prune: the key so far must agree with the prefix as far as both go. */
        size_t kl = klen + nl, pl = strlen(prefix), m = kl < pl ? kl : pl;
        struct stat st;
        if (strncmp(key, prefix, m) == 0 && lstat(path, &st) == 0) {
            if (S_ISDIR(st.st_mode)) {
                key[kl] = '/'; key[kl + 1] = 0;
                walk(L, path, plen + 1 + nl, key, kl + 1, prefix, after, depth + 1);
            } else if (S_ISREG(st.st_mode) && kl >= pl && strcmp(key, after) > 0 && kl <= 512) {
                if (L->n == L->cap) {
                    size_t nc = L->cap ? L->cap * 2 : 256;
                    gb_entry *nv = realloc(L->v, nc * sizeof *nv);
                    if (!nv) { L->err = ENOMEM; break; }
                    L->v = nv; L->cap = nc;
                }
                gb_entry *x = &L->v[L->n];
                x->key = strdup(key);
                if (!x->key) { L->err = ENOMEM; break; }
                x->size = (int64_t)st.st_size;
#if defined(__APPLE__)
                x->mtime = (int64_t)st.st_mtimespec.tv_sec;
#else
                x->mtime = (int64_t)st.st_mtim.tv_sec;
#endif
                L->n++;
            }
        }
        path[plen] = 0; key[klen] = 0;
    }
    closedir(d);
}

static int cmp_entry(const void *a, const void *b) { return strcmp(((const gb_entry *)a)->key, ((const gb_entry *)b)->key); }

/* Appends "key\tsize\tmtime\n" for up to max keys under root that start with prefix and sort after `after`,
   in byte order. Only names a key can have are seen: dot files, temp files and other names are skipped,
   and so are symlinks. Returns the count, or -1. The walk starts in the folder the prefix names. */
int64_t gblob_disk_list(gb_bytes root, gb_bytes prefix, gb_bytes after, int64_t max, gs_rref out) {
    gblob_clear_error();
    char path[GB_PATH], key[1024], pre[1024], aft[1024];
    if (!gblob_cpath(path, sizeof path, root)) { gblob_set_error("bad root", NULL); return -1; }
    pre[0] = aft[0] = 0;
    if (prefix.len > 0 && !gblob_cpath(pre, sizeof pre, prefix)) { gblob_set_error("bad prefix", NULL); return -1; }
    if (after.len > 0 && !gblob_cpath(aft, sizeof aft, after)) { gblob_set_error("bad after", NULL); return -1; }
    size_t plen = strlen(path);
    while (plen > 1 && path[plen - 1] == '/') path[--plen] = 0;
    /* Start below the last '/' of the prefix: "c/blog/m/ab" walks <root>/c/blog/m only. */
    size_t klen = 0;
    const char *slash = strrchr(pre, '/');
    if (slash) {
        klen = (size_t)(slash - pre + 1);
        if (plen + 1 + klen >= GB_PATH) { gblob_set_error("path too long", NULL); return -1; }
        path[plen] = '/'; memcpy(path + plen + 1, pre, klen - 1); plen += klen; path[plen] = 0;
        memcpy(key, pre, klen);
    }
    key[klen] = 0;
    gb_list L = { 0 };
    walk(&L, path, plen, key, klen, pre, aft, 0);
    int64_t count = -1;
    if (L.err) { errno = L.err; set_errno("list"); }
    else {
        qsort(L.v, L.n, sizeof *L.v, cmp_entry);
        count = 0;
        char line[1100];
        for (size_t i = 0; i < L.n && count < max; i++, count++) {
            int n = snprintf(line, sizeof line, "%s\t%lld\t%lld\n", L.v[i].key, (long long)L.v[i].size, (long long)L.v[i].mtime);
            gs_bld_append(out, line, (size_t)n);
        }
    }
    for (size_t i = 0; i < L.n; i++) free(L.v[i].key);
    free(L.v);
    return count;
}

/* mkdir -p root itself. */
int32_t gblob_disk_mkroot(gb_bytes root) {
    gblob_clear_error();
    char p[GB_PATH];
    if (!gblob_cpath(p, sizeof p, root)) { gblob_set_error("bad root", NULL); return 0; }
    size_t n = strlen(p);
    if (n + 2 >= sizeof p) { gblob_set_error("path too long", NULL); return 0; }
    p[n] = '/'; p[n + 1] = 'x'; p[n + 2] = 0;
    if (!mkdirs_for(p)) { set_errno("make root"); return 0; }
    return 1;
}

/* For the tests, which declare these themselves: Goose's os module has no streaming read or write. */
int32_t gblob_test_same_file(gb_bytes a, gb_bytes b) {
    char pa[GB_PATH], pb[GB_PATH];
    if (!gblob_cpath(pa, sizeof pa, a) || !gblob_cpath(pb, sizeof pb, b)) return 0;
    FILE *fa = fopen(pa, "rb"), *fb = fopen(pb, "rb");
    int same = fa && fb;
    static __thread unsigned char ba[65536], bb[65536];
    while (same) {
        size_t na = fread(ba, 1, sizeof ba, fa), nb = fread(bb, 1, sizeof bb, fb);
        if (na != nb || memcmp(ba, bb, na) != 0) same = 0;
        if (na == 0) break;
    }
    if (fa) fclose(fa);
    if (fb) fclose(fb);
    return same;
}
/* Writes size bytes of a seeded pattern to path, in windows. */
int32_t gblob_test_fill(gb_bytes path, int64_t size, int64_t seed) {
    char p[GB_PATH];
    if (!gblob_cpath(p, sizeof p, path)) return 0;
    FILE *f = fopen(p, "wb");
    if (!f) return 0;
    static __thread unsigned char buf[65536];
    uint64_t x = (uint64_t)seed * 0x9E3779B97F4A7C15ull + 1;
    int ok = 1;
    while (size > 0 && ok) {
        size_t n = size < (int64_t)sizeof buf ? (size_t)size : sizeof buf;
        for (size_t i = 0; i < n; i++) { x ^= x << 13; x ^= x >> 7; x ^= x << 17; buf[i] = (unsigned char)x; }
        ok = fwrite(buf, 1, n, f) == n;
        size -= (int64_t)n;
    }
    return fclose(f) == 0 && ok;
}
