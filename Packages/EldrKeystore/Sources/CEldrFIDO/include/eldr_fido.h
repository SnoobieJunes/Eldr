// SPDX-License-Identifier: Apache-2.0
// FIDO2 hmac-secret over the SYSTEM libfido2 (dlopen'd at run time; DEVIATIONS AC224).
#pragma once
#include <stddef.h>
#include <stdint.h>

#define ELDR_FIDO_OK 0
#define ELDR_FIDO_UNAVAILABLE 1  // libfido2 or a security key not found
#define ELDR_FIDO_ERROR 2

int eldr_fido_compiled_in(void);
/// Enrolls a new hmac-secret credential for `rp_id` on the device (`path` NULL = first found).
int eldr_fido_enroll(const char *path, const char *rp_id, const char *pin,
                     uint8_t *cred_id, size_t *cred_id_len, char *err, size_t err_len);
/// hmac-secret(salt) for the credential; requires user presence (a touch). out is 32 bytes.
int eldr_fido_hmac(const char *path, const char *rp_id, const char *pin,
                   const uint8_t *cred_id, size_t cred_id_len, const uint8_t *salt32,
                   uint8_t *out32, char *err, size_t err_len);
