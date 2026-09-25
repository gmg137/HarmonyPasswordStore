/* rpgp_wrapper FFI header */
#ifndef HPS_RPGP_WRAPPER_H
#define HPS_RPGP_WRAPPER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct FfiResult {
    int32_t success;   /* 0=success, 1=failure */
    char *error;       /* null on success */
    char *data;        /* null on failure */
} FfiResult;

FfiResult hps_pgp_encrypt(const char *plaintext, const char *pubkey_armored);
FfiResult hps_pgp_decrypt(const char *ciphertext_armored, const char *seckey_armored, const char *passphrase);
/* GnuPG algo 8（ky768_cv25519 = ML-KEM-768 + X25519）互通：pgp 0.20 丢弃 v5 子密钥，
 * 该算法由独立模块 gpg_pqc 解析与解密 */
FfiResult hps_pgp_decrypt_gpg_pqc(const char *ciphertext, const char *seckey_armored, const char *passphrase);
FfiResult hps_pgp_encrypt_gpg_pqc(const char *plaintext, const char *pubkey_armored);
FfiResult hps_pgp_encrypt_mixed(const char *plaintext, const char *gpgpqc_pubkeys_armored, const char *normal_pubkeys_armored);
FfiResult hps_pgp_gpg_pqc_supported(const char *seckey_armored);
FfiResult hps_pgp_recipient_keyids(const char *ciphertext);
FfiResult hps_pgp_gpg_pqc_verify_passphrase(const char *seckey_armored, const char *passphrase);
FfiResult hps_pgp_list_keys(const char *keyring_armored);
FfiResult hps_pgp_verify_passphrase(const char *seckey_armored, const char *passphrase);
FfiResult hps_pgp_extract_public_key(const char *seckey_armored);
FfiResult hps_pgp_generate_key(const char *user_id, const char *key_type, const char *passphrase);
FfiResult hps_pgp_change_passphrase(const char *seckey_armored, const char *old_passphrase,
                                    const char *new_passphrase);
FfiResult hps_pgp_backup_key(const char *key_armored, const char *backup_password);
FfiResult hps_pgp_restore_backup(const char *backup_armored, const char *backup_password);
FfiResult hps_pgp_split_keyring(const char *keyring_armored);
FfiResult hps_pgp_key_as_ssh(const char *seckey_armored, const char *passphrase);
FfiResult hps_ssh_test_auth(const char *host, uint16_t port, const char *username,
                            const char *private_key_pem, const char *passphrase,
                            const char *expected_fingerprint);
FfiResult hps_ssh_test_password(const char *host, uint16_t port, const char *username,
                                const char *password, const char *expected_fingerprint);
FfiResult hps_ssh_fingerprint(const char *host, uint16_t port);

/**
 * 生成 Ed25519 SSH 密钥 -> data = JSON { privateKeyPem, publicKey }
 *
 * 必须在 native 侧生成：ArkTS 的 cryptoFramework 生成的 Ed25519 私钥**导不出来**
 * （getEncoded / getEncodedDer('PKCS8') 均不支持），重启后私钥即丢失、只剩公钥，
 * 用户注册到远端的公钥再也无法配对。
 */
FfiResult hps_ssh_generate_key(const char *comment);
FfiResult hps_ssh_public_from_private(const char *private_key_pem, const char *passphrase);
FfiResult hps_ssh_key_status(const char *private_key_pem);
void hps_pgp_result_free(FfiResult *result);

#ifdef __cplusplus
}
#endif

#endif /* HPS_RPGP_WRAPPER_H */
