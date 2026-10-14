// SPDX-License-Identifier: Apache-2.0
// libfido2 is dlopen'd ("libfido2.so.1") so the build never needs it. The few entry points
// are declared here against libfido2's stable public C ABI (opaque pointers), so no header
// or -dev package is required either. Hardware behaviour is UNVERIFIED in CI (mock-tested).
#include "eldr_fido.h"
#include <stdio.h>
#include <string.h>

#if defined(__linux__)
#include <dlfcn.h>

typedef struct fido_dev fido_dev_t;
typedef struct fido_dev_info fido_dev_info_t;
typedef struct fido_cred fido_cred_t;
typedef struct fido_assert fido_assert_t;
#define FIDO_OK 0
#define COSE_ES256 (-7)
#define FIDO_EXT_HMAC_SECRET 0x01
#define FIDO_OPT_TRUE 2

#define DECL(ret, name, args) static ret (*p_##name) args
DECL(void, fido_init, (int));
DECL(const char *, fido_strerr, (int));
DECL(fido_dev_t *, fido_dev_new, (void));
DECL(int, fido_dev_open, (fido_dev_t *, const char *));
DECL(int, fido_dev_close, (fido_dev_t *));
DECL(void, fido_dev_free, (fido_dev_t **));
DECL(fido_dev_info_t *, fido_dev_info_new, (size_t));
DECL(int, fido_dev_info_manifest, (fido_dev_info_t *, size_t, size_t *));
DECL(const fido_dev_info_t *, fido_dev_info_ptr, (const fido_dev_info_t *, size_t));
DECL(const char *, fido_dev_info_path, (const fido_dev_info_t *));
DECL(void, fido_dev_info_free, (fido_dev_info_t **, size_t));
DECL(fido_cred_t *, fido_cred_new, (void));
DECL(void, fido_cred_free, (fido_cred_t **));
DECL(int, fido_cred_set_type, (fido_cred_t *, int));
DECL(int, fido_cred_set_clientdata_hash, (fido_cred_t *, const unsigned char *, size_t));
DECL(int, fido_cred_set_rp, (fido_cred_t *, const char *, const char *));
DECL(int, fido_cred_set_user, (fido_cred_t *, const unsigned char *, size_t, const char *, const char *, const char *));
DECL(int, fido_cred_set_extensions, (fido_cred_t *, int));
DECL(int, fido_dev_make_cred, (fido_dev_t *, fido_cred_t *, const char *));
DECL(const unsigned char *, fido_cred_id_ptr, (const fido_cred_t *));
DECL(size_t, fido_cred_id_len, (const fido_cred_t *));
DECL(fido_assert_t *, fido_assert_new, (void));
DECL(void, fido_assert_free, (fido_assert_t **));
DECL(int, fido_assert_set_clientdata_hash, (fido_assert_t *, const unsigned char *, size_t));
DECL(int, fido_assert_set_rp, (fido_assert_t *, const char *));
DECL(int, fido_assert_allow_cred, (fido_assert_t *, const unsigned char *, size_t));
DECL(int, fido_assert_set_extensions, (fido_assert_t *, int));
DECL(int, fido_assert_set_hmac_salt, (fido_assert_t *, const unsigned char *, size_t));
DECL(int, fido_assert_set_up, (fido_assert_t *, int));
DECL(int, fido_dev_get_assert, (fido_dev_t *, fido_assert_t *, const char *));
DECL(const unsigned char *, fido_assert_hmac_secret_ptr, (const fido_assert_t *, size_t));
DECL(size_t, fido_assert_hmac_secret_len, (const fido_assert_t *, size_t));

static int loaded = -1;
static int load_lib(void) {
    if (loaded >= 0) return loaded;
    void *h = dlopen("libfido2.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!h) { loaded = 0; return 0; }
#define L(name) if (!(p_##name = dlsym(h, #name))) { loaded = 0; return 0; }
    L(fido_init) L(fido_strerr) L(fido_dev_new) L(fido_dev_open) L(fido_dev_close) L(fido_dev_free)
    L(fido_dev_info_new) L(fido_dev_info_manifest) L(fido_dev_info_ptr) L(fido_dev_info_path) L(fido_dev_info_free)
    L(fido_cred_new) L(fido_cred_free) L(fido_cred_set_type) L(fido_cred_set_clientdata_hash) L(fido_cred_set_rp)
    L(fido_cred_set_user) L(fido_cred_set_extensions) L(fido_dev_make_cred) L(fido_cred_id_ptr) L(fido_cred_id_len)
    L(fido_assert_new) L(fido_assert_free) L(fido_assert_set_clientdata_hash) L(fido_assert_set_rp)
    L(fido_assert_allow_cred) L(fido_assert_set_extensions) L(fido_assert_set_hmac_salt) L(fido_assert_set_up)
    L(fido_dev_get_assert) L(fido_assert_hmac_secret_ptr) L(fido_assert_hmac_secret_len)
    p_fido_init(0);
    loaded = 1;
    return 1;
}

static void seterr(char *err, size_t n, const char *what, int rc) {
    if (err && n) snprintf(err, n, "%s: %s", what, p_fido_strerr ? p_fido_strerr(rc) : "error");
}

// Opens `path`, or the first enumerated security key.
static int open_dev(const char *path, fido_dev_t **out, char *err, size_t n) {
    if (!load_lib()) { if (err && n) snprintf(err, n, "libfido2.so.1 not found"); return ELDR_FIDO_UNAVAILABLE; }
    char found[512] = {0};
    if (!path) {
        size_t olen = 0;
        fido_dev_info_t *list = p_fido_dev_info_new(8);
        if (!list) return ELDR_FIDO_ERROR;
        if (p_fido_dev_info_manifest(list, 8, &olen) == FIDO_OK && olen > 0) {
            const char *pp = p_fido_dev_info_path(p_fido_dev_info_ptr(list, 0));
            if (pp) snprintf(found, sizeof found, "%s", pp);
        }
        p_fido_dev_info_free(&list, 8);
        if (!found[0]) { if (err && n) snprintf(err, n, "no security key found"); return ELDR_FIDO_UNAVAILABLE; }
        path = found;
    }
    fido_dev_t *d = p_fido_dev_new();
    if (!d) return ELDR_FIDO_ERROR;
    int rc = p_fido_dev_open(d, path);
    if (rc != FIDO_OK) { seterr(err, n, "fido_dev_open", rc); p_fido_dev_free(&d); return ELDR_FIDO_UNAVAILABLE; }
    *out = d;
    return ELDR_FIDO_OK;
}

static void close_dev(fido_dev_t *d) { p_fido_dev_close(d); p_fido_dev_free(&d); }

// Fixed client-data hash: hmac-secret does not need a server challenge (local KEK only).
static const unsigned char CDH[32] = "eldr/keystore/fido-hmac/v1......";

int eldr_fido_compiled_in(void) { return 1; }

int eldr_fido_enroll(const char *path, const char *rp_id, const char *pin,
                     uint8_t *cred_id, size_t *cred_id_len, char *err, size_t n) {
    fido_dev_t *d = NULL;
    int r = open_dev(path, &d, err, n);
    if (r) return r;
    fido_cred_t *c = p_fido_cred_new();
    static const unsigned char uid[16] = "eldr-keystore...";
    int rc = FIDO_OK;
    if ((rc = p_fido_cred_set_type(c, COSE_ES256)) || (rc = p_fido_cred_set_clientdata_hash(c, CDH, 32))
        || (rc = p_fido_cred_set_rp(c, rp_id, "Eldr keystore"))
        || (rc = p_fido_cred_set_user(c, uid, sizeof uid, "eldr", "Eldr keystore", NULL))
        || (rc = p_fido_cred_set_extensions(c, FIDO_EXT_HMAC_SECRET))
        || (rc = p_fido_dev_make_cred(d, c, pin))) {
        seterr(err, n, "make credential", rc); r = ELDR_FIDO_ERROR;
    } else {
        size_t len = p_fido_cred_id_len(c);
        if (len == 0 || len > *cred_id_len) { if (err && n) snprintf(err, n, "credential id size"); r = ELDR_FIDO_ERROR; }
        else { memcpy(cred_id, p_fido_cred_id_ptr(c), len); *cred_id_len = len; }
    }
    p_fido_cred_free(&c);
    close_dev(d);
    return r;
}

int eldr_fido_hmac(const char *path, const char *rp_id, const char *pin,
                   const uint8_t *cred_id, size_t cred_id_len, const uint8_t *salt32,
                   uint8_t *out32, char *err, size_t n) {
    fido_dev_t *d = NULL;
    int r = open_dev(path, &d, err, n);
    if (r) return r;
    fido_assert_t *a = p_fido_assert_new();
    int rc = FIDO_OK;
    if ((rc = p_fido_assert_set_clientdata_hash(a, CDH, 32)) || (rc = p_fido_assert_set_rp(a, rp_id))
        || (rc = p_fido_assert_allow_cred(a, cred_id, cred_id_len))
        || (rc = p_fido_assert_set_extensions(a, FIDO_EXT_HMAC_SECRET))
        || (rc = p_fido_assert_set_hmac_salt(a, salt32, 32))
        || (rc = p_fido_assert_set_up(a, FIDO_OPT_TRUE))
        || (rc = p_fido_dev_get_assert(d, a, pin))) {
        seterr(err, n, "get assertion", rc); r = ELDR_FIDO_ERROR;
    } else if (p_fido_assert_hmac_secret_len(a, 0) != 32) {
        if (err && n) snprintf(err, n, "no hmac-secret in assertion"); r = ELDR_FIDO_ERROR;
    } else {
        memcpy(out32, p_fido_assert_hmac_secret_ptr(a, 0), 32);
    }
    p_fido_assert_free(&a);
    close_dev(d);
    return r;
}

#else
int eldr_fido_compiled_in(void) { return 0; }
int eldr_fido_enroll(const char *p, const char *r, const char *pin, uint8_t *c, size_t *l, char *e, size_t n) {
    (void)p; (void)r; (void)pin; (void)c; (void)l;
    if (e && n) snprintf(e, n, "FIDO2 not supported on this platform");
    return ELDR_FIDO_UNAVAILABLE;
}
int eldr_fido_hmac(const char *p, const char *r, const char *pin, const uint8_t *c, size_t l,
                   const uint8_t *s, uint8_t *o, char *e, size_t n) {
    (void)p; (void)r; (void)pin; (void)c; (void)l; (void)s; (void)o;
    if (e && n) snprintf(e, n, "FIDO2 not supported on this platform");
    return ELDR_FIDO_UNAVAILABLE;
}
#endif
