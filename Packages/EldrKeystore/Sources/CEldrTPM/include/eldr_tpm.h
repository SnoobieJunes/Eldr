// SPDX-License-Identifier: Apache-2.0
// Thin TPM 2.0 seal/unseal shim over the SYSTEM tpm2-tss libraries (ESAPI), loaded with
// dlopen at runtime. Builds everywhere: without <tss2/tss2_esys.h> at build time, or without
// libtss2-esys.so.0 at run time, every call reports "unavailable" (DEVIATIONS AC218).
#ifndef ELDR_TPM_H
#define ELDR_TPM_H
#include <stddef.h>
#include <stdint.h>

#define ELDR_TPM_OK 0
#define ELDR_TPM_UNAVAILABLE 1
#define ELDR_TPM_ERROR 2

/// 1 if tpm2-tss headers were present when this was compiled.
int eldr_tpm_compiled_in(void);
/// Seals `secret` under a deterministic owner-hierarchy ECC P-256 storage primary (SRK
/// template) as a fixedTPM|fixedParent keyed-hash object. `blob` receives
/// TPM2B_PUBLIC || TPM2B_PRIVATE (marshalled). `tcti` may be NULL (tctildr default).
int eldr_tpm_seal(const char *tcti, const uint8_t *secret, size_t secret_len,
                  uint8_t *blob, size_t *blob_len, char *err, size_t err_len);
/// Loads `blob` under the same primary and unseals it into `out` (capacity *out_len).
int eldr_tpm_unseal(const char *tcti, const uint8_t *blob, size_t blob_len,
                    uint8_t *out, size_t *out_len, char *err, size_t err_len);
#endif
