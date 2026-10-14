// SPDX-License-Identifier: Apache-2.0
#include "eldr_tpm.h"
#include <stdio.h>
#include <string.h>

#if defined(__linux__) && __has_include(<tss2/tss2_esys.h>) && __has_include(<tss2/tss2_tctildr.h>) && __has_include(<tss2/tss2_mu.h>)
#include <dlfcn.h>
#include <tss2/tss2_esys.h>
#include <tss2/tss2_mu.h>
#include <tss2/tss2_tctildr.h>

#define FN(name) static __typeof__(&name) p_##name
FN(Esys_Initialize); FN(Esys_Finalize); FN(Esys_Startup); FN(Esys_CreatePrimary);
FN(Esys_Create); FN(Esys_Load); FN(Esys_Unseal); FN(Esys_FlushContext); FN(Esys_Free);
FN(Esys_StartAuthSession); FN(Esys_TRSess_SetAttributes);
FN(Tss2_TctiLdr_Initialize); FN(Tss2_TctiLdr_Finalize);
FN(Tss2_MU_TPM2B_PUBLIC_Marshal); FN(Tss2_MU_TPM2B_PUBLIC_Unmarshal);
FN(Tss2_MU_TPM2B_PRIVATE_Marshal); FN(Tss2_MU_TPM2B_PRIVATE_Unmarshal);

static int loaded = -1;
static int load_libs(void) {
    if (loaded >= 0) return loaded;
    void *esys = dlopen("libtss2-esys.so.0", RTLD_NOW | RTLD_LOCAL);
    void *ldr = dlopen("libtss2-tctildr.so.0", RTLD_NOW | RTLD_LOCAL);
    void *mu = dlopen("libtss2-mu.so.0", RTLD_NOW | RTLD_LOCAL);
    if (!esys || !ldr || !mu) { loaded = 0; return 0; }
#define LOAD(lib, name) if (!(p_##name = (__typeof__(&name))dlsym(lib, #name))) { loaded = 0; return 0; }
    LOAD(esys, Esys_Initialize) LOAD(esys, Esys_Finalize) LOAD(esys, Esys_Startup)
    LOAD(esys, Esys_CreatePrimary) LOAD(esys, Esys_Create) LOAD(esys, Esys_Load)
    LOAD(esys, Esys_Unseal) LOAD(esys, Esys_FlushContext) LOAD(esys, Esys_Free)
    LOAD(esys, Esys_StartAuthSession) LOAD(esys, Esys_TRSess_SetAttributes)
    LOAD(ldr, Tss2_TctiLdr_Initialize) LOAD(ldr, Tss2_TctiLdr_Finalize)
    LOAD(mu, Tss2_MU_TPM2B_PUBLIC_Marshal) LOAD(mu, Tss2_MU_TPM2B_PUBLIC_Unmarshal)
    LOAD(mu, Tss2_MU_TPM2B_PRIVATE_Marshal) LOAD(mu, Tss2_MU_TPM2B_PRIVATE_Unmarshal)
    loaded = 1;
    return 1;
}

static void seterr(char *err, size_t n, const char *what, TSS2_RC rc) {
    if (err && n) snprintf(err, n, "%s failed (rc=0x%x)", what, (unsigned)rc);
}

typedef struct { TSS2_TCTI_CONTEXT *tcti; ESYS_CONTEXT *ctx; ESYS_TR primary; ESYS_TR session; } Conn;

static void conn_close(Conn *c) {
    if (c->session != ESYS_TR_NONE) p_Esys_FlushContext(c->ctx, c->session);
    if (c->primary != ESYS_TR_NONE) p_Esys_FlushContext(c->ctx, c->primary);
    if (c->ctx) p_Esys_Finalize(&c->ctx);
    if (c->tcti) p_Tss2_TctiLdr_Finalize(&c->tcti);
}

// TCG "SRK" template: ECC NIST P-256 restricted decrypt storage key, AES-128-CFB.
// Deterministic from the owner seed, so it is re-derived each time (never persisted).
static int conn_open(Conn *c, const char *tcti, char *err, size_t n) {
    memset(c, 0, sizeof *c);
    c->primary = ESYS_TR_NONE; c->session = ESYS_TR_NONE;
    TSS2_RC rc = p_Tss2_TctiLdr_Initialize(tcti, &c->tcti);
    if (rc) { seterr(err, n, "TctiLdr_Initialize", rc); return ELDR_TPM_UNAVAILABLE; }
    rc = p_Esys_Initialize(&c->ctx, c->tcti, NULL);
    if (rc) { seterr(err, n, "Esys_Initialize", rc); conn_close(c); return ELDR_TPM_UNAVAILABLE; }
    rc = p_Esys_Startup(c->ctx, TPM2_SU_CLEAR);  // fresh simulators need it; hardware says INITIALIZE
    if (rc && rc != TPM2_RC_INITIALIZE) { seterr(err, n, "Esys_Startup", rc); conn_close(c); return ELDR_TPM_ERROR; }

    TPM2B_SENSITIVE_CREATE sens = {0};
    TPM2B_PUBLIC pub = { .publicArea = {
        .type = TPM2_ALG_ECC, .nameAlg = TPM2_ALG_SHA256,
        .objectAttributes = TPMA_OBJECT_FIXEDTPM | TPMA_OBJECT_FIXEDPARENT | TPMA_OBJECT_SENSITIVEDATAORIGIN
            | TPMA_OBJECT_USERWITHAUTH | TPMA_OBJECT_NODA | TPMA_OBJECT_RESTRICTED | TPMA_OBJECT_DECRYPT,
        .parameters.eccDetail = {
            .symmetric = { .algorithm = TPM2_ALG_AES, .keyBits.aes = 128, .mode.aes = TPM2_ALG_CFB },
            .scheme = { .scheme = TPM2_ALG_NULL }, .curveID = TPM2_ECC_NIST_P256,
            .kdf = { .scheme = TPM2_ALG_NULL } } } };
    TPM2B_DATA outside = {0};
    TPML_PCR_SELECTION pcrs = {0};
    rc = p_Esys_CreatePrimary(c->ctx, ESYS_TR_RH_OWNER, ESYS_TR_PASSWORD, ESYS_TR_NONE, ESYS_TR_NONE,
                              &sens, &pub, &outside, &pcrs, &c->primary, NULL, NULL, NULL, NULL);
    if (rc) { seterr(err, n, "CreatePrimary (owner auth must be empty)", rc); conn_close(c); return ELDR_TPM_ERROR; }

    // Salted, parameter-encrypting HMAC session: the secret never crosses the bus in clear.
    TPMT_SYM_DEF sym = { .algorithm = TPM2_ALG_AES, .keyBits.aes = 128, .mode.aes = TPM2_ALG_CFB };
    rc = p_Esys_StartAuthSession(c->ctx, c->primary, ESYS_TR_NONE, ESYS_TR_NONE, ESYS_TR_NONE, ESYS_TR_NONE,
                                 NULL, TPM2_SE_HMAC, &sym, TPM2_ALG_SHA256, &c->session);
    if (rc) { seterr(err, n, "StartAuthSession", rc); conn_close(c); return ELDR_TPM_ERROR; }
    rc = p_Esys_TRSess_SetAttributes(c->ctx, c->session,
        TPMA_SESSION_DECRYPT | TPMA_SESSION_ENCRYPT | TPMA_SESSION_CONTINUESESSION, 0xff);
    if (rc) { seterr(err, n, "TRSess_SetAttributes", rc); conn_close(c); return ELDR_TPM_ERROR; }
    return ELDR_TPM_OK;
}

int eldr_tpm_compiled_in(void) { return 1; }

int eldr_tpm_seal(const char *tcti, const uint8_t *secret, size_t secret_len,
                  uint8_t *blob, size_t *blob_len, char *err, size_t n) {
    if (!load_libs()) { if (err && n) snprintf(err, n, "tpm2-tss libraries not installed"); return ELDR_TPM_UNAVAILABLE; }
    if (secret_len == 0 || secret_len > 128) { if (err && n) snprintf(err, n, "bad secret length"); return ELDR_TPM_ERROR; }
    Conn c; int r = conn_open(&c, tcti, err, n); if (r) return r;
    TPM2B_SENSITIVE_CREATE sens = {0};
    sens.sensitive.data.size = (UINT16)secret_len;
    memcpy(sens.sensitive.data.buffer, secret, secret_len);
    TPM2B_PUBLIC pub = { .publicArea = {
        .type = TPM2_ALG_KEYEDHASH, .nameAlg = TPM2_ALG_SHA256,
        .objectAttributes = TPMA_OBJECT_FIXEDTPM | TPMA_OBJECT_FIXEDPARENT | TPMA_OBJECT_USERWITHAUTH,
        .parameters.keyedHashDetail.scheme.scheme = TPM2_ALG_NULL } };
    TPM2B_DATA outside = {0};
    TPML_PCR_SELECTION pcrs = {0};
    TPM2B_PRIVATE *outPriv = NULL; TPM2B_PUBLIC *outPub = NULL;
    TSS2_RC rc = p_Esys_Create(c.ctx, c.primary, c.session, ESYS_TR_NONE, ESYS_TR_NONE,
                               &sens, &pub, &outside, &pcrs, &outPriv, &outPub, NULL, NULL, NULL);
    memset(&sens, 0, sizeof sens);
    if (rc) { seterr(err, n, "Esys_Create", rc); conn_close(&c); return ELDR_TPM_ERROR; }
    size_t off = 0;
    rc = p_Tss2_MU_TPM2B_PUBLIC_Marshal(outPub, blob, *blob_len, &off);
    if (!rc) rc = p_Tss2_MU_TPM2B_PRIVATE_Marshal(outPriv, blob, *blob_len, &off);
    p_Esys_Free(outPriv); p_Esys_Free(outPub);
    conn_close(&c);
    if (rc) { seterr(err, n, "marshal", rc); return ELDR_TPM_ERROR; }
    *blob_len = off;
    return ELDR_TPM_OK;
}

int eldr_tpm_unseal(const char *tcti, const uint8_t *blob, size_t blob_len,
                    uint8_t *out, size_t *out_len, char *err, size_t n) {
    if (!load_libs()) { if (err && n) snprintf(err, n, "tpm2-tss libraries not installed"); return ELDR_TPM_UNAVAILABLE; }
    TPM2B_PUBLIC pub = {0}; TPM2B_PRIVATE priv = {0};
    size_t off = 0;
    TSS2_RC rc = p_Tss2_MU_TPM2B_PUBLIC_Unmarshal(blob, blob_len, &off, &pub);
    if (!rc) rc = p_Tss2_MU_TPM2B_PRIVATE_Unmarshal(blob, blob_len, &off, &priv);
    if (rc || off != blob_len) { seterr(err, n, "unmarshal sealed blob", rc); return ELDR_TPM_ERROR; }
    Conn c; int r = conn_open(&c, tcti, err, n); if (r) return r;
    ESYS_TR obj = ESYS_TR_NONE;
    rc = p_Esys_Load(c.ctx, c.primary, c.session, ESYS_TR_NONE, ESYS_TR_NONE, &priv, &pub, &obj);
    if (rc) { seterr(err, n, "Esys_Load (sealed by a different TPM?)", rc); conn_close(&c); return ELDR_TPM_ERROR; }
    TPM2B_SENSITIVE_DATA *data = NULL;
    rc = p_Esys_Unseal(c.ctx, obj, c.session, ESYS_TR_NONE, ESYS_TR_NONE, &data);
    p_Esys_FlushContext(c.ctx, obj);
    if (rc) { seterr(err, n, "Esys_Unseal", rc); conn_close(&c); return ELDR_TPM_ERROR; }
    int result = ELDR_TPM_OK;
    if (data->size > *out_len) { seterr(err, n, "output buffer", 0); result = ELDR_TPM_ERROR; }
    else { memcpy(out, data->buffer, data->size); *out_len = data->size; }
    memset(data->buffer, 0, sizeof data->buffer);
    p_Esys_Free(data);
    conn_close(&c);
    return result;
}

#else
int eldr_tpm_compiled_in(void) { return 0; }
int eldr_tpm_seal(const char *t, const uint8_t *s, size_t sl, uint8_t *b, size_t *bl, char *e, size_t n) {
    (void)t; (void)s; (void)sl; (void)b; (void)bl;
    if (e && n) snprintf(e, n, "built without tpm2-tss headers (install libtss2-dev and rebuild)");
    return ELDR_TPM_UNAVAILABLE;
}
int eldr_tpm_unseal(const char *t, const uint8_t *b, size_t bl, uint8_t *o, size_t *ol, char *e, size_t n) {
    (void)t; (void)b; (void)bl; (void)o; (void)ol;
    if (e && n) snprintf(e, n, "built without tpm2-tss headers (install libtss2-dev and rebuild)");
    return ELDR_TPM_UNAVAILABLE;
}
#endif
