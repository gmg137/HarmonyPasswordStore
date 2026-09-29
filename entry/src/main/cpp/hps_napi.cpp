/*
 * HarmonyPasswordStore native 模块入口
 *
 * 注册 NAPI 模块 "harmonypasswordstore"，
 * 导出 PGP 与 Git 桥接函数。
 * Git 函数已链接 libgit2（aarch64-ohos 交叉编译）；
 * PGP 函数待 rpgp 就绪后填充。
 */
#include "napi/native_api.h"
#include <cstring>
#include <string>
#include <unistd.h>
#include <mutex>   // std::call_once：libgit2 的进程级初始化只能做一次（见 InitLibgit2Once）
#include <atomic>  // 克隆进度：回调跑在 TaskPool 工作线程，UI 主线程经 gitCloneProgress 轮询读取
#include <git2.h>
#include <git2/sys/errors.h>   // git_error_set_str：错误信息要能被上层按关键字识别（host key mismatch）
#include "rpgp_wrapper.h"

// LOG_DOMAIN/LOG_TAG 必须在**被包含的头文件之前**定义：hilog/log.h 只在首次被
// 包含时取当时的 LOG_TAG/LOG_DOMAIN（未定义则取默认 LOG_TAG=NULL、LOG_DOMAIN=0）。
// 曾把 git_ssh_creds.h 放在这两行之前，于是该头文件里的 OH_LOG_* 全部落到
// domain 0 + NULL tag，在 hilog 里根本看不到——排查「主机密钥校验为何失败」时
// 白绕一大圈（回调其实一直在执行，只是它打的日志不可见）。
#define LOG_DOMAIN 0x0001
#define LOG_TAG "HpsNative"
#include "hilog/log.h"
#include "git_ssh_creds.h"

// ========== 工具函数 ==========

/**
 * 从 napi 值读取 UTF-8 字符串
 */
static bool GetStdString(napi_env env, napi_value value, std::string &out) {
    size_t size = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &size) != napi_ok) {
        return false;
    }
    out.resize(size);
    if (size > 0 && napi_get_value_string_utf8(env, value, &out[0], size + 1, &size) != napi_ok) {
        return false;
    }
    return true;
}

/**
 * 构造结果对象 { success: bool, error: string, data: string }
 */
static napi_value MakeResult(napi_env env, bool success, const char *error, const char *data) {
    napi_value result;
    napi_create_object(env, &result);

    napi_value successVal;
    napi_get_boolean(env, success, &successVal);
    napi_set_named_property(env, result, "success", successVal);

    napi_value errorVal;
    napi_create_string_utf8(env, error, NAPI_AUTO_LENGTH, &errorVal);
    napi_set_named_property(env, result, "error", errorVal);

    napi_value dataVal;
    napi_create_string_utf8(env, data, NAPI_AUTO_LENGTH, &dataVal);
    napi_set_named_property(env, result, "data", dataVal);

    return result;
}

// ========== 参数解析辅助 ==========

/**
 * 远端 URL 脱敏：去掉 userinfo 段
 *
 * 用户常把 token 直接嵌进 URL（https://oauth2:token@host/...），
 * 完整打印会把凭据写进 hilog，任何能读系统日志的组件都能取到仓库写权限。
 * 日志里只需 host + path。
 */
static std::string SanitizeRemoteUrl(const std::string &url) {
    size_t at = url.find('@');
    if (at == std::string::npos) {
        return url;
    }
    // 只在 '@' 位于协议之后、下一个 '/' 之前时才视作 userinfo
    size_t scheme = url.find("://");
    if (scheme == std::string::npos || at < scheme + 3) {
        return url;
    }
    size_t slash = url.find('/', scheme + 3);
    if (slash != std::string::npos && at > slash) {
        return url; // '@' 在路径里（如 git@host 之外的用户名形式），非凭据
    }
    return url.substr(0, scheme + 3) + "***@" + url.substr(at + 1);
}

/**
 * 读取前 n 个字符串参数
 */
static bool GetArgs(napi_env env, napi_callback_info info, size_t argc, std::string *out) {
    size_t actual = argc;
    napi_value argv[8] = { nullptr };
    if (napi_get_cb_info(env, info, &actual, argv, nullptr, nullptr) != napi_ok) {
        return false;
    }
    if (actual < argc) {
        // 参数个数不够：必须打出来，否则调用方只看到「invalid arguments」无从下手
        OH_LOG_ERROR(LOG_APP, "GetArgs: expected %{public}zu args, got %{public}zu", argc, actual);
        return false;
    }
    for (size_t i = 0; i < argc; i++) {
        napi_valuetype type = napi_undefined;
        if (napi_typeof(env, argv[i], &type) != napi_ok || type != napi_string) {
            // 明确指出是第几个参数、实际是什么类型（undefined 通常是 ArkTS 侧字段缺失：
            // 曾因落盘配置缺 proxyUrl 传入 undefined，只报「invalid arguments」难以定位）
            OH_LOG_ERROR(LOG_APP, "GetArgs: arg %{public}zu is type %{public}d, expected string",
                         i, static_cast<int>(type));
            return false;
        }
        if (!GetStdString(env, argv[i], out[i])) {
            OH_LOG_ERROR(LOG_APP, "GetArgs: arg %{public}zu read failed", i);
            return false;
        }
    }
    return true;
}

/**
 * 读取混合类型参数：stringParams 位图为 1 的位置要求 string，
 * 否则接受 number（转为十进制字符串存入 out）。
 * 例如 stringParams=0b11111 表示 5 个参数全是 string；
 * stringParams=0b11101 表示 index 1（第 2 个）接受 number。
 */
static bool GetArgsMixed(napi_env env, napi_callback_info info, size_t argc,
                         std::string *out, uint32_t stringParams) {
    size_t actual = argc;
    napi_value argv[8] = { nullptr };
    if (napi_get_cb_info(env, info, &actual, argv, nullptr, nullptr) != napi_ok) {
        return false;
    }
    if (actual < argc) {
        return false;
    }
    for (size_t i = 0; i < argc; i++) {
        napi_valuetype type = napi_undefined;
        if (napi_typeof(env, argv[i], &type) != napi_ok) {
            return false;
        }
        if (type == napi_string) {
            if (!GetStdString(env, argv[i], out[i])) {
                return false;
            }
        } else if (type == napi_number && !(stringParams & (1u << i))) {
            double num = 0;
            if (napi_get_value_double(env, argv[i], &num) != napi_ok) {
                return false;
            }
            out[i] = std::to_string(static_cast<long long>(num));
        } else {
            return false;
        }
    }
    return true;
}

// ========== libgit2 辅助 ==========

/**
 * 将 git_error 最后一条转为错误消息
 */
static std::string GitLastErr() {
    const git_error *e = git_error_last();
    if (e && e->message) {
        return std::string(e->message);
    }
    return "unknown git error";
}

// ========== PGP 桥接（rpgp_wrapper） ==========

/**
 * pgpEncrypt(plaintext, publicKeyArmored) -> { success, error, data }
 */
static napi_value PgpEncrypt(napi_env env, napi_callback_info info) {
    std::string args[2];
    if (!GetArgs(env, info, 2, args)) {
        return MakeResult(env, false, "invalid arguments: expected (plaintext, publicKeyArmored)", "");
    }
    OH_LOG_INFO(LOG_APP, "pgpEncrypt: %{public}zu bytes plaintext, %{public}zu bytes key",
                args[0].size(), args[1].size());

    FfiResult result = hps_pgp_encrypt(args[0].c_str(), args[1].c_str());
    napi_value napiResult;
    if (result.success == 0) {
        napiResult = MakeResult(env, true, "", result.data ? result.data : "");
    } else {
        napiResult = MakeResult(env, false, result.error ? result.error : "unknown error", "");
    }
    hps_pgp_result_free(&result);
    return napiResult;
}

/**
 * pgpDecrypt(ciphertextArmored, secretKeyArmored, passphrase) -> { success, error, data }
 */
static napi_value PgpDecrypt(napi_env env, napi_callback_info info) {
    std::string args[3];
    if (!GetArgs(env, info, 3, args)) {
        return MakeResult(env, false, "invalid arguments: expected (ciphertextArmored, secretKeyArmored, passphrase)", "");
    }
    OH_LOG_INFO(LOG_APP, "pgpDecrypt: %{public}zu bytes ciphertext", args[0].size());

    FfiResult result = hps_pgp_decrypt(args[0].c_str(), args[1].c_str(), args[2].c_str());
    napi_value napiResult;
    if (result.success == 0) {
        napiResult = MakeResult(env, true, "", result.data ? result.data : "");
    } else {
        napiResult = MakeResult(env, false, result.error ? result.error : "unknown error", "");
    }
    hps_pgp_result_free(&result);
    return napiResult;
}

/**
 * pgpEncryptGpgPqc(plaintext, publicKeyArmored) -> { success, error, data }
 *
 * GnuPG algo 8（ky768_cv25519 = ML-KEM-768 + X25519）：pgp 0.20 会静默丢弃 v5 子密钥，
 * 该算法由独立模块 gpg_pqc 构造 PKESK(algo 8) + SEIPDv1（RFC 标准格式，gpg 可解）。
 */
static napi_value PgpEncryptGpgPqc(napi_env env, napi_callback_info info) {
    std::string args[2];
    if (!GetArgs(env, info, 2, args)) {
        return MakeResult(env, false, "invalid arguments: expected (plaintext, publicKeyArmored)", "");
    }
    OH_LOG_INFO(LOG_APP, "pgpEncryptGpgPqc: %{public}zu bytes plaintext", args[0].size());

    FfiResult result = hps_pgp_encrypt_gpg_pqc(args[0].c_str(), args[1].c_str());
    napi_value napiResult;
    if (result.success == 0) {
        napiResult = MakeResult(env, true, "", result.data ? result.data : "");
    } else {
        napiResult = MakeResult(env, false, result.error ? result.error : "unknown error", "");
    }
    hps_pgp_result_free(&result);
    return napiResult;
}

/**
 * pgpDecryptGpgPqc(ciphertext, secretKeyArmored, passphrase) -> { success, error, data }
 *
 * GnuPG algo 8（ky768_cv25519 = ML-KEM-768 + X25519）：pgp 0.20 会静默丢弃 v5 子密钥，
 * 该算法由独立模块 gpg_pqc 解析（含带口令保护段）并解密。
 */
static napi_value PgpDecryptGpgPqc(napi_env env, napi_callback_info info) {
    std::string args[3];
    if (!GetArgs(env, info, 3, args)) {
        return MakeResult(env, false, "invalid arguments: expected (ciphertext, secretKeyArmored, passphrase)", "");
    }
    OH_LOG_INFO(LOG_APP, "pgpDecryptGpgPqc: %{public}zu bytes ciphertext", args[0].size());

    FfiResult result = hps_pgp_decrypt_gpg_pqc(args[0].c_str(), args[1].c_str(), args[2].c_str());
    napi_value napiResult;
    if (result.success == 0) {
        napiResult = MakeResult(env, true, "", result.data ? result.data : "");
    } else {
        napiResult = MakeResult(env, false, result.error ? result.error : "unknown error", "");
    }
    hps_pgp_result_free(&result);
    return napiResult;
}

/**
 * pgpGpgPqcVerifyPassphrase(secretKeyArmored, passphrase) -> { success, error, data="1" }
 *
 * rpgp 丢弃 v5 子密钥包，无法校验该子密钥的保护段，
 * 故由 native gpg_pqc 模块尝试解出私钥材料来判定口令。
 */
static napi_value PgpGpgPqcVerifyPassphrase(napi_env env, napi_callback_info info) {
    std::string args[2];
    if (!GetArgs(env, info, 2, args)) {
        return MakeResult(env, false, "invalid arguments: expected (secretKeyArmored, passphrase)", "");
    }

    FfiResult result = hps_pgp_gpg_pqc_verify_passphrase(args[0].c_str(), args[1].c_str());
    napi_value napiResult;
    if (result.success == 0) {
        napiResult = MakeResult(env, true, "", result.data ? result.data : "1");
    } else {
        napiResult = MakeResult(env, false, result.error ? result.error : "unknown error", "");
    }
    hps_pgp_result_free(&result);
    return napiResult;
}

/**
 * pgpGpgPqcSupported(secretKeyArmored) -> { success, error, data="1"|"0" }
 */
static napi_value PgpGpgPqcSupported(napi_env env, napi_callback_info info) {
    std::string args[1];
    if (!GetArgs(env, info, 1, args)) {
        return MakeResult(env, false, "invalid arguments: expected (secretKeyArmored)", "0");
    }

    FfiResult result = hps_pgp_gpg_pqc_supported(args[0].c_str());
    napi_value napiResult;
    if (result.success == 0) {
        napiResult = MakeResult(env, true, "", result.data ? result.data : "0");
    } else {
        napiResult = MakeResult(env, false, result.error ? result.error : "unknown error", "0");
    }
    hps_pgp_result_free(&result);
    return napiResult;
}

/**
 * pgpRecipientKeyIds(ciphertext) -> { success, error, data="KEYID1,KEYID2" }
 *
 * 提取密文 PKESK 的收件人 Key ID（算法无关）。用于解密前判断条目实际由哪把
 * 密钥加密（从而索取正确口令），以及重加密时判断收件人是否已是目标密钥。
 */
static napi_value PgpRecipientKeyIds(napi_env env, napi_callback_info info) {
    std::string args[1];
    if (!GetArgs(env, info, 1, args)) {
        return MakeResult(env, false, "invalid arguments: expected (ciphertext)", "");
    }

    FfiResult result = hps_pgp_recipient_keyids(args[0].c_str());
    napi_value napiResult;
    if (result.success == 0) {
        napiResult = MakeResult(env, true, "", result.data ? result.data : "");
    } else {
        napiResult = MakeResult(env, false, result.error ? result.error : "unknown error", "");
    }
    hps_pgp_result_free(&result);
    return napiResult;
}

/**
 * pgpLock() -> { success, error, data="" }
 *
 * 清空 native 侧的「已解锁私钥缓存」（缓存里是明文私钥材料，见 rpgp_wrapper 的说明）。
 * 必须在应用上锁 / 切到后台时调用——与 ArkTS 侧 PgpCrypto.lock() 清口令缓存同一
 * 生命周期，漏掉它等于给「切后台清敏感缓存」留了个缺口。
 */
static napi_value PgpLock(napi_env env, napi_callback_info info) {
    hps_pgp_lock();
    return MakeResult(env, true, "", "");
}

/**
 * pgpEncryptMixed(plaintext, gpgpqcPubkeysArmored, normalPubkeysArmored)
 *   -> { success, error, data=armored 密文 }
 *
 * 同一目录同时指定 gpgPqc（GnuPG algo 8）与普通密钥时的加密：两类接收方
 * **共用同一个会话密钥**（这正是 OpenPGP 多接收方语义）。普通密钥的 PKESK 交给
 * rpgp 构造（RSA/ECDH 细节它负责），algo 8 的 PKESK 由 gpg_pqc 自建
 * （rpgp 会丢弃其 v5 子密钥），最后统一用一个 SEIPDv1 承载明文。
 *
 * 两侧参数均可含多个拼接的 armored 块（多把同类密钥）。
 */
static napi_value PgpEncryptMixed(napi_env env, napi_callback_info info) {
    std::string args[3];
    if (!GetArgs(env, info, 3, args)) {
        return MakeResult(env, false,
                          "invalid arguments: expected (plaintext, gpgpqcPubkeys, normalPubkeys)", "");
    }
    OH_LOG_INFO(LOG_APP, "pgpEncryptMixed: pqc %{public}zu bytes, normal %{public}zu bytes",
                args[1].size(), args[2].size());

    FfiResult result = hps_pgp_encrypt_mixed(args[0].c_str(), args[1].c_str(), args[2].c_str());
    napi_value napiResult;
    if (result.success == 0) {
        napiResult = MakeResult(env, true, "", result.data ? result.data : "");
    } else {
        napiResult = MakeResult(env, false, result.error ? result.error : "unknown error", "");
    }
    hps_pgp_result_free(&result);
    return napiResult;
}

/**
 * pgpListKeys(armoredKeyring) -> { success, error, data=JSON 数组 }
 */
static napi_value PgpListKeys(napi_env env, napi_callback_info info) {
    std::string args[1];
    if (!GetArgs(env, info, 1, args)) {
        return MakeResult(env, false, "invalid arguments: expected (armoredKeyring)", "");
    }
    OH_LOG_INFO(LOG_APP, "pgpListKeys: %{public}zu bytes keyring", args[0].size());

    FfiResult result = hps_pgp_list_keys(args[0].c_str());
    napi_value napiResult;
    if (result.success == 0) {
        napiResult = MakeResult(env, true, "", result.data ? result.data : "[]");
    } else {
        napiResult = MakeResult(env, false, result.error ? result.error : "unknown error", "[]");
    }
    hps_pgp_result_free(&result);
    return napiResult;
}

/**
 * pgpExtractPublicKey(secretKeyArmored) -> { success, error, data=armored 公钥 }
 */
static napi_value PgpExtractPublicKey(napi_env env, napi_callback_info info) {
    std::string args[1];
    if (!GetArgs(env, info, 1, args)) {
        return MakeResult(env, false, "invalid arguments: expected (secretKeyArmored)", "");
    }
    OH_LOG_INFO(LOG_APP, "pgpExtractPublicKey: %{public}zu bytes seckey", args[0].size());

    FfiResult result = hps_pgp_extract_public_key(args[0].c_str());
    napi_value napiResult;
    if (result.success == 0) {
        napiResult = MakeResult(env, true, "", result.data ? result.data : "");
    } else {
        napiResult = MakeResult(env, false, result.error ? result.error : "unknown error", "");
    }
    hps_pgp_result_free(&result);
    return napiResult;
}

/**
 * pgpGenerateKey(userId, keyType, passphrase) -> { success, error, data=armored 私钥 }
 * keyType: "eddsa" | "rsa4096" | "rsa2048"
 */
static napi_value PgpGenerateKey(napi_env env, napi_callback_info info) {
    std::string args[3];
    if (!GetArgs(env, info, 3, args)) {
        return MakeResult(env, false, "invalid arguments: expected (userId, keyType, passphrase)", "");
    }
    OH_LOG_INFO(LOG_APP, "pgpGenerateKey: type=%{public}s userId=%{public}zu bytes", args[1].c_str(), args[0].size());

    FfiResult result = hps_pgp_generate_key(args[0].c_str(), args[1].c_str(), args[2].c_str());
    napi_value napiResult;
    if (result.success == 0) {
        napiResult = MakeResult(env, true, "", result.data ? result.data : "");
    } else {
        napiResult = MakeResult(env, false, result.error ? result.error : "unknown error", "");
    }
    hps_pgp_result_free(&result);
    return napiResult;
}

/**
 * pgpChangePassphrase(secretKeyArmored, oldPassphrase, newPassphrase) -> { success, error, data=armored 私钥 }
 */
static napi_value PgpChangePassphrase(napi_env env, napi_callback_info info) {
    std::string args[3];
    if (!GetArgs(env, info, 3, args)) {
        return MakeResult(env, false, "invalid arguments: expected (secretKeyArmored, oldPassphrase, newPassphrase)", "");
    }
    OH_LOG_INFO(LOG_APP, "pgpChangePassphrase: %{public}zu bytes seckey", args[0].size());

    FfiResult result = hps_pgp_change_passphrase(args[0].c_str(), args[1].c_str(), args[2].c_str());
    napi_value napiResult;
    if (result.success == 0) {
        napiResult = MakeResult(env, true, "", result.data ? result.data : "");
    } else {
        napiResult = MakeResult(env, false, result.error ? result.error : "unknown error", "");
    }
    hps_pgp_result_free(&result);
    return napiResult;
}

/**
 * pgpBackupKey(keyArmored, backupPassword) -> { success, error, data=对称加密的 armored 备份 }
 */
static napi_value PgpBackupKey(napi_env env, napi_callback_info info) {
    std::string args[2];
    if (!GetArgs(env, info, 2, args)) {
        return MakeResult(env, false, "invalid arguments: expected (keyArmored, backupPassword)", "");
    }
    OH_LOG_INFO(LOG_APP, "pgpBackupKey: %{public}zu bytes key", args[0].size());

    FfiResult result = hps_pgp_backup_key(args[0].c_str(), args[1].c_str());
    napi_value napiResult;
    if (result.success == 0) {
        napiResult = MakeResult(env, true, "", result.data ? result.data : "");
    } else {
        napiResult = MakeResult(env, false, result.error ? result.error : "unknown error", "");
    }
    hps_pgp_result_free(&result);
    return napiResult;
}

/**
 * pgpRestoreBackup(backupArmored, backupPassword) -> { success, error, data=armored 密钥文本 }
 */
static napi_value PgpRestoreBackup(napi_env env, napi_callback_info info) {
    std::string args[2];
    if (!GetArgs(env, info, 2, args)) {
        return MakeResult(env, false, "invalid arguments: expected (backupArmored, backupPassword)", "");
    }
    OH_LOG_INFO(LOG_APP, "pgpRestoreBackup: %{public}zu bytes backup", args[0].size());

    FfiResult result = hps_pgp_restore_backup(args[0].c_str(), args[1].c_str());
    napi_value napiResult;
    if (result.success == 0) {
        napiResult = MakeResult(env, true, "", result.data ? result.data : "");
    } else {
        napiResult = MakeResult(env, false, result.error ? result.error : "unknown error", "");
    }
    hps_pgp_result_free(&result);
    return napiResult;
}

/**
 * pgpSplitKeyring(armoredKeyring) -> { success, error, data=JSON 字符串数组（单个密钥 armored） }
 */
static napi_value PgpSplitKeyring(napi_env env, napi_callback_info info) {
    std::string args[1];
    if (!GetArgs(env, info, 1, args)) {
        return MakeResult(env, false, "invalid arguments: expected (armoredKeyring)", "");
    }
    OH_LOG_INFO(LOG_APP, "pgpSplitKeyring: %{public}zu bytes keyring", args[0].size());

    FfiResult result = hps_pgp_split_keyring(args[0].c_str());
    napi_value napiResult;
    if (result.success == 0) {
        napiResult = MakeResult(env, true, "", result.data ? result.data : "[]");
    } else {
        napiResult = MakeResult(env, false, result.error ? result.error : "unknown error", "[]");
    }
    hps_pgp_result_free(&result);
    return napiResult;
}

/**
 * pgpKeyAsSsh(secretKeyArmored, passphrase) -> { success, error, data=OpenSSH PEM 私钥 }
 *
 * 将 Ed25519 PGP 私钥转换为 SSH 私钥（PGP 密钥即 SSH 密钥）。
 */
static napi_value PgpKeyAsSsh(napi_env env, napi_callback_info info) {
    std::string args[2];
    if (!GetArgs(env, info, 2, args)) {
        return MakeResult(env, false, "invalid arguments: expected (secretKeyArmored, passphrase)", "");
    }
    OH_LOG_INFO(LOG_APP, "pgpKeyAsSsh: %{public}zu bytes seckey", args[0].size());

    FfiResult result = hps_pgp_key_as_ssh(args[0].c_str(), args[1].c_str());
    napi_value napiResult;
    if (result.success == 0) {
        napiResult = MakeResult(env, true, "", result.data ? result.data : "");
    } else {
        napiResult = MakeResult(env, false, result.error ? result.error : "unknown error", "");
    }
    hps_pgp_result_free(&result);
    return napiResult;
}

/**
 * sshKeyStatus(privateKeyPem) -> { success, error, data=JSON }
 *
 * 探测私钥状态：{"valid":bool,"encrypted":bool,"error":string}
 * 用于把「已加密但未输口令」与「文件损坏/格式无效」区分开。
 */
static napi_value SshKeyStatus(napi_env env, napi_callback_info info) {
    std::string args[1];
    if (!GetArgs(env, info, 1, args)) {
        return MakeResult(env, false, "invalid arguments: expected (privateKeyPem)", "");
    }
    OH_LOG_INFO(LOG_APP, "sshKeyStatus: %{public}zu bytes pem", args[0].size());

    FfiResult result = hps_ssh_key_status(args[0].c_str());
    napi_value napiResult;
    if (result.success == 0) {
        napiResult = MakeResult(env, true, "", result.data ? result.data : "");
    } else {
        napiResult = MakeResult(env, false, result.error ? result.error : "unknown error", "");
    }
    hps_pgp_result_free(&result);
    return napiResult;
}

/**
 * sshPublicFromPrivate(privateKeyPem, passphrase) -> { success, error, data="ssh-ed25519 AAAA... comment" }
 *
 * 从 OpenSSH 私钥 PEM 提取公钥（authorized_keys 单行格式）。
 * passphrase 用于带口令保护的私钥；解析失败即私钥无效或口令错误，
 * 因此该调用同时充当「私钥格式校验」。
 */
static napi_value SshPublicFromPrivate(napi_env env, napi_callback_info info) {
    std::string args[2];
    if (!GetArgs(env, info, 2, args)) {
        return MakeResult(env, false, "invalid arguments: expected (privateKeyPem, passphrase)", "");
    }
    OH_LOG_INFO(LOG_APP, "sshPublicFromPrivate: %{public}zu bytes pem", args[0].size());

    FfiResult result = hps_ssh_public_from_private(args[0].c_str(), args[1].c_str());
    napi_value napiResult;
    if (result.success == 0) {
        napiResult = MakeResult(env, true, "", result.data ? result.data : "");
    } else {
        napiResult = MakeResult(env, false, result.error ? result.error : "unknown error", "");
    }
    hps_pgp_result_free(&result);
    return napiResult;
}

// ========== Git 桥接（libgit2） ==========

/** HTTPS 认证凭据（回调 payload） */
struct GitCreds {
    std::string username;
    std::string password;
};

/** fetch/push 通用配置：凭据 + 代理 */
struct GitNetOpts {
    GitCreds creds;
    std::string proxyUrl;

    bool hasCreds() const { return creds.username.length() > 0 || creds.password.length() > 0; }
    bool hasProxy() const { return proxyUrl.length() > 0; }
    const char *proxy() const { return hasProxy() ? proxyUrl.c_str() : nullptr; }
};

/**
 * libgit2 凭据回调：HTTPS 时提供 用户名/Token（userpass plaintext）
 */
static int GitCredCallback(git_credential **out, const char *url, const char *username_from_url,
                           unsigned int allowed_types, void *payload) {
    (void)url;
    (void)username_from_url;
    GitCreds *creds = (GitCreds *)payload;

    // 未配置任何凭据时必须 PASSTHROUGH：否则会用空凭据反复应答服务端挑战，
    // 表现为 "too many redirects or authentication replays"，
    // 用户看不到「请先配置凭据」这个真实原因。
    if (creds->username.empty() && creds->password.empty()) {
        return GIT_PASSTHROUGH;
    }
    if ((allowed_types & GIT_CREDENTIAL_USERPASS_PLAINTEXT) == 0) {
        return GIT_PASSTHROUGH;
    }
    // 令牌式认证常见写法：用户名留空、令牌填在密码栏
    const char *user = creds->username.empty() ? creds->password.c_str() : creds->username.c_str();
    return git_credential_userpass_plaintext_new(out, user, creds->password.c_str());
}

/**
 * 主机密钥被拒时，把**实际收到的指纹**带回上层做 TOFU 确认
 *
 * 上层据此弹确认框（显示指纹与密钥类型），用户确认后落盘并重试。
 * 之所以必须由本次连接回报、而不能另开一次连接去探测：服务器通常同时提供
 * rsa/ecdsa/ed25519 多把主机密钥，不同实现偏好不同（russh 偏好 ed25519、
 * libssh2 偏好 rsa），探测到的指纹与克隆实际用到的根本不是同一把。
 *
 * @param ssh 连接上下文（回调会填写 presentedFingerprint/presentedKeyType）
 * @param fallback 原本的错误信息（未发生主机密钥拒绝时原样返回）
 */
static std::string HostKeyErrorOr(const GitSshCreds &ssh, const std::string &fallback) {
    if (ssh.presentedFingerprint.empty() || ssh.presentedTrustState == "trusted") {
        return fallback;
    }
    // 结论由 GitCertCheckCallback 三态判定填写（同类型指纹变=mismatch，
    // 没见过的类型=untrusted），这里不做二次猜测
    const char *kind = ssh.presentedTrustState == "mismatch" ? "mismatch" : "untrusted";
    return std::string("host key ") + kind + ": " + ssh.presentedFingerprint + "|" + ssh.presentedKeyType;
}

/**
 * 把认证回调挂到 fetch/push 的回调表上
 *
 * 两种认证方式的回调完全不同：HTTPS 用用户名/令牌（GitCredCallback），
 * SSH 用私钥（GitSshCredCallback）**并且**必须同时挂主机密钥校验
 * （GitCertCheckCallback，否则 libgit2 会以「主机密钥未信任」拒绝连接）。
 * 只挂凭据回调的话，SSH 远端会以认证失败告终——克隆能成功、拉取/推送却失败。
 *
 * @param ssh 非空且带私钥时走 SSH，否则走 HTTPS
 */
static void ApplyAuthCallbacks(git_remote_callbacks *cbs, GitNetOpts *net, GitSshCreds *ssh) {
    if (ssh != nullptr && !ssh->privateKey.empty()) {
        cbs->credentials = GitSshCredCallback;
        cbs->certificate_check = GitCertCheckCallback;
        cbs->payload = ssh;
        return;
    }
    cbs->credentials = GitCredCallback;
    cbs->payload = &net->creds;
}

/**
 * 解析类瞬时失败判定（DNS 临时不可用，如 EAI_AGAIN / "Try again"）
 */
static bool GitIsTransientResolveError(const std::string &msg) {
    return msg.find("failed to resolve address") != std::string::npos
        || msg.find("Could not resolve host") != std::string::npos
        || msg.find("Try again") != std::string::npos;
}

/**
 * 网络操作重试包装：仅对 DNS 解析类瞬时错误重试。
 *
 * 设备首个 DNS 服务器不可达时会返回 EAI_AGAIN（"Try again"），
 * 属于瞬时失败，直接放弃会让同步偶发失败；这里重试若干次。
 */
template <typename Fn>
static int GitRetryOnResolve(Fn fn) {
    const int maxAttempts = 3;
    int err = 0;
    for (int attempt = 0; attempt < maxAttempts; attempt++) {
        err = fn();
        if (err == 0) {
            return 0;
        }
        if (!GitIsTransientResolveError(GitLastErr())) {
            return err;
        }
        OH_LOG_WARN(LOG_APP, "git: transient DNS failure, retry %{public}d/%{public}d",
                    attempt + 1, maxAttempts);
        usleep(400 * 1000);
    }
    return err;
}

/**
 * 当前克隆进度（0-100）。
 *
 * .so 在进程内只加载一份，这个原子变量由 TaskPool 工作线程上的
 * transfer_progress 回调写入、由 UI 主线程的 gitCloneProgress() 读取——
 * 纯内存读，不涉及网络/IO，不违反「网络类 native 调用不得跑主线程」的约束。
 * 同一时刻只允许一个克隆（上层 isCloning 已互斥），无需按克隆区分。
 */
static std::atomic<int> g_clone_percent(0);

/**
 * git_clone 的收包进度回调（libgit2 fetch_opts.callbacks.transfer_progress）。
 *
 * 只更新原子变量，**不得**在这里触碰任何 JS/NAPI 对象——回调跑在
 * TaskPool 工作线程上，跨线程调 NAPI 需要额外的线程安全机制。
 * 返回 0 表示继续收包。
 */
static int CloneTransferProgressCb(const git_indexer_progress *stats, void * /*payload*/) {
    if (stats != nullptr && stats->total_objects > 0) {
        int pct = (int)((double)stats->received_objects * 100.0 / (double)stats->total_objects);
        if (pct < 0) pct = 0;
        if (pct > 100) pct = 100;
        g_clone_percent.store(pct);
    }
    return 0;
}

/**
 * gitCloneProgress() -> number（当前克隆进度 0-100）
 *
 * 供 UI 在克隆期间轮询：进度回调跑在 TaskPool 工作线程，无法直接推给 UI，
 * 轮询一个进程级原子变量是最简单可靠的跨线程通道。
 */
static napi_value GitCloneProgress(napi_env env, napi_callback_info info) {
    napi_value result = nullptr;
    napi_create_int32(env, g_clone_percent.load(), &result);
    return result;
}

/**
 * gitClone(remoteUrl, localPath, username, password, proxyUrl) -> { success, error }
 * username/password 为 HTTPS 认证（可空），proxyUrl 为 HTTP(S) 代理（可空）
 */
static napi_value GitClone(napi_env env, napi_callback_info info) {
    std::string args[5];
    if (!GetArgs(env, info, 5, args)) {
        return MakeResult(env, false, "invalid arguments: expected (remoteUrl, localPath, username, password, proxyUrl)", "");
    }

    OH_LOG_INFO(LOG_APP, "gitClone: url=%{public}s path=%{public}s", SanitizeRemoteUrl(args[0]).c_str(), args[1].c_str());

    GitNetOpts net;
    net.creds.username = args[2];
    net.creds.password = args[3];
    net.proxyUrl = args[4];

    git_repository *repo = nullptr;
    git_clone_options opts = GIT_CLONE_OPTIONS_INIT;
    opts.checkout_branch = nullptr; // default branch
    if (net.hasCreds()) {
        opts.fetch_opts.callbacks.credentials = GitCredCallback;
        opts.fetch_opts.callbacks.payload = &net.creds;
    }
    if (net.hasProxy()) {
        opts.fetch_opts.proxy_opts.type = GIT_PROXY_SPECIFIED;
        opts.fetch_opts.proxy_opts.url = net.proxy();
    }
    // 进度：开始前清零（残留上次克隆的值会让 UI 先显示一个错误的百分比），
    // 收包过程中由 CloneTransferProgressCb 更新
    g_clone_percent.store(0);
    opts.fetch_opts.callbacks.transfer_progress = CloneTransferProgressCb;

    int err = git_clone(&repo, args[0].c_str(), args[1].c_str(), &opts);
    if (err != 0) {
        std::string msg = "git_clone failed: " + GitLastErr();
        return MakeResult(env, false, msg.c_str(), "");
    }
    git_repository_free(repo);
    return MakeResult(env, true, "", "");
}

/**
 * gitCloneSsh(remoteUrl, localPath, privateKeyPem, passphrase, knownHostFingerprint)
 *   -> { success, error }
 *
 * SSH 克隆走 libgit2 的 libssh2 传输（HTTPS 克隆仍走 gitClone）。
 * 私钥由 ArkTS 侧从 HUKS 解封后传入内存，不写临时文件。
 */
static napi_value GitCloneSsh(napi_env env, napi_callback_info info) {
    std::string args[5];
    if (!GetArgs(env, info, 5, args)) {
        return MakeResult(env, false,
            "invalid arguments: expected (remoteUrl, localPath, privateKeyPem, passphrase, knownHostFingerprint)",
            "");
    }
    if (args[2].empty()) {
        return MakeResult(env, false, "SSH private key is empty", "");
    }

    OH_LOG_INFO(LOG_APP, "gitCloneSsh: url=%{public}s path=%{public}s fp=%{public}s",
                SanitizeRemoteUrl(args[0]).c_str(), args[1].c_str(),
                args[4].empty() ? "(none)" : args[4].c_str());

    GitSshCreds ssh;
    ssh.username = "";
    ssh.privateKey = args[2];
    ssh.passphrase = args[3];
    ssh.knownFingerprint = args[4];

    git_repository *repo = nullptr;
    git_clone_options opts = GIT_CLONE_OPTIONS_INIT;
    opts.fetch_opts.callbacks.credentials = GitSshCredCallback;
    opts.fetch_opts.callbacks.certificate_check = GitCertCheckCallback;
    opts.fetch_opts.callbacks.payload = &ssh;
    g_clone_percent.store(0);
    opts.fetch_opts.callbacks.transfer_progress = CloneTransferProgressCb;

    int err = git_clone(&repo, args[0].c_str(), args[1].c_str(), &opts);
    if (err != 0) {
        std::string msg = HostKeyErrorOr(ssh, "git_clone(ssh) failed: " + GitLastErr());
        return MakeResult(env, false, msg.c_str(), "");
    }
    git_repository_free(repo);
    return MakeResult(env, true, "", "");
}

/**
 * gitPull(localPath, username, password, proxyUrl) -> { success, error }
 */
static napi_value GitPull(napi_env env, napi_callback_info info) {
    std::string args[8];
    if (!GetArgs(env, info, 8, args)) {
        return MakeResult(env, false,
            "invalid arguments: expected (localPath, username, password, proxyUrl, rebase, "
            "privateKeyPem, passphrase, knownHostFingerprint)", "");
    }
    const bool rebase = (args[4] == "true");
    OH_LOG_INFO(LOG_APP, "gitPull: path=%{public}s rebase=%{public}d ssh=%{public}d",
                args[0].c_str(), rebase ? 1 : 0, args[5].empty() ? 0 : 1);

    GitNetOpts net;
    net.creds.username = args[1];
    net.creds.password = args[2];
    net.proxyUrl = args[3];

    // SSH 远端：私钥/口令/已信任指纹由 ArkTS 侧解封后传入（不落盘）
    GitSshCreds ssh;
    ssh.privateKey = args[5];
    ssh.passphrase = args[6];
    ssh.knownFingerprint = args[7];

    git_repository *repo = nullptr;
    if (git_repository_open(&repo, args[0].c_str()) != 0) {
        std::string msg = "open repo failed: " + GitLastErr();
        return MakeResult(env, false, msg.c_str(), "");
    }

    // 获取 origin remote
    git_remote *remote = nullptr;
    if (git_remote_lookup(&remote, repo, "origin") != 0) {
        git_repository_free(repo);
        std::string msg = "remote lookup failed: " + GitLastErr();
        return MakeResult(env, false, msg.c_str(), "");
    }

    // fetch（HTTPS 或 SSH 认证 + 代理）
    git_fetch_options fetch_opts = GIT_FETCH_OPTIONS_INIT;
    // 始终挂凭据回调，服务端要求时才有机会提供凭据
    ApplyAuthCallbacks(&fetch_opts.callbacks, &net, &ssh);
    if (net.hasProxy()) {
        fetch_opts.proxy_opts.type = GIT_PROXY_SPECIFIED;
        fetch_opts.proxy_opts.url = net.proxy();
    }
    if (GitRetryOnResolve([&]() {
            return git_remote_fetch(remote, nullptr, &fetch_opts, nullptr);
        }) != 0) {
        git_remote_free(remote);
        git_repository_free(repo);
        std::string msg = HostKeyErrorOr(ssh, "fetch failed: " + GitLastErr());
        return MakeResult(env, false, msg.c_str(), "");
    }

    // ===== 合并远程更新到当前分支 =====
    // 之前只 fetch 不合并，用户以为拉取成功但本地没有任何变化。
    git_reference *head_ref = nullptr;
    if (git_repository_head(&head_ref, repo) != 0) {
        // 本地还没有分支（空仓库）：fetch 完成即可
        git_remote_free(remote);
        git_repository_free(repo);
        return MakeResult(env, true, "", "");
    }
    const char *branch = git_reference_shorthand(head_ref);
    std::string remote_ref = std::string("refs/remotes/origin/") + (branch ? branch : "");

    git_reference *tracking_ref = nullptr;
    if (git_reference_lookup(&tracking_ref, repo, remote_ref.c_str()) != 0) {
        // 远程尚无同名分支：无更新可合并
        git_reference_free(head_ref);
        git_remote_free(remote);
        git_repository_free(repo);
        return MakeResult(env, true, "", "");
    }

    git_annotated_commit *annotated = nullptr;
    if (git_annotated_commit_from_ref(&annotated, repo, tracking_ref) != 0) {
        git_reference_free(tracking_ref);
        git_reference_free(head_ref);
        git_remote_free(remote);
        git_repository_free(repo);
        std::string msg = "annotated commit failed: " + GitLastErr();
        return MakeResult(env, false, msg.c_str(), "");
    }

    git_merge_analysis_t analysis = GIT_MERGE_ANALYSIS_NONE;
    git_merge_preference_t preference = GIT_MERGE_PREFERENCE_NONE;
    const git_annotated_commit *heads[] = { annotated };
    git_merge_analysis(&analysis, &preference, repo, heads, 1);

    if ((analysis & GIT_MERGE_ANALYSIS_UP_TO_DATE) != 0) {
        git_annotated_commit_free(annotated);
        git_reference_free(tracking_ref);
        git_reference_free(head_ref);
        git_remote_free(remote);
        git_repository_free(repo);
        return MakeResult(env, true, "", "");
    }

    int merge_err = 0;
    if ((analysis & GIT_MERGE_ANALYSIS_FASTFORWARD) != 0 && !rebase) {
        // 快进：直接把当前分支指向远程提交
        git_oid target_oid;
        if (git_reference_name_to_id(&target_oid, repo, remote_ref.c_str()) == 0) {
            git_reference *new_ref = nullptr;
            if (git_reference_set_target(&new_ref, head_ref, &target_oid, "pull: Fast-forward") != 0) {
                merge_err = -1;
            } else {
                git_reference_free(new_ref);
                git_checkout_options co = GIT_CHECKOUT_OPTIONS_INIT;
                co.checkout_strategy = GIT_CHECKOUT_FORCE;
                git_checkout_head(repo, &co);
            }
        } else {
            merge_err = -1;
        }
    } else if (rebase) {
        // 变基：把本地提交重放到远程提交之上
        git_rebase_options rb_opts = GIT_REBASE_OPTIONS_INIT;
        git_rebase *rb = nullptr;
        if (git_rebase_init(&rb, repo, nullptr, annotated, nullptr, &rb_opts) != 0) {
            merge_err = -1;
        } else {
            git_rebase_operation *op = nullptr;
            int op_err = 0;
            while ((op_err = git_rebase_next(&op, rb)) == 0) {
                git_index *rb_index = nullptr;
                if (git_rebase_commit(nullptr, rb, nullptr, nullptr, nullptr, nullptr) != 0) {
                    if (git_rebase_inmemory_index(&rb_index, rb) == 0 && git_index_has_conflicts(rb_index)) {
                        git_index_free(rb_index);
                        op_err = -2;  // 冲突
                        break;
                    }
                }
                if (rb_index != nullptr) git_index_free(rb_index);
            }
            if (op_err == -2) {
                git_rebase_free(rb);
                merge_err = -2;
            } else if (op_err != GIT_ITEROVER) {
                git_rebase_free(rb);
                merge_err = -1;
            } else if (git_rebase_finish(rb, nullptr) != 0) {
                git_rebase_free(rb);
                merge_err = -1;
            } else {
                git_rebase_free(rb);
            }
        }
    } else {
        // 分叉且未开启变基：执行普通合并
        git_merge_options merge_opts = GIT_MERGE_OPTIONS_INIT;
        git_checkout_options co = GIT_CHECKOUT_OPTIONS_INIT;
        co.checkout_strategy = GIT_CHECKOUT_SAFE;
        if (git_merge(repo, heads, 1, &merge_opts, &co) != 0) {
            merge_err = -1;
        } else {
            git_index *merge_index = nullptr;
            if (git_repository_index(&merge_index, repo) == 0) {
                if (git_index_has_conflicts(merge_index)) {
                    merge_err = -2;
                } else {
                    // 无冲突：生成合并提交。父提交必须取真实 git_commit，
                    // 不能把 git_annotated_commit 强转为 git_commit。
                    git_oid tree_oid;
                    git_tree *merge_tree = nullptr;
                    git_commit *local_commit = nullptr;
                    git_commit *remote_commit = nullptr;
                    git_oid local_oid;
                    git_oid remote_oid;
                    if (git_index_write_tree(&tree_oid, merge_index) == 0
                        && git_tree_lookup(&merge_tree, repo, &tree_oid) == 0
                        && git_reference_name_to_id(&local_oid, repo, "HEAD") == 0
                        && git_commit_lookup(&local_commit, repo, &local_oid) == 0
                        && git_reference_name_to_id(&remote_oid, repo, remote_ref.c_str()) == 0
                        && git_commit_lookup(&remote_commit, repo, &remote_oid) == 0) {
                        git_signature *sig = nullptr;
                        git_signature_now(&sig, "HarmonyPasswordStore", "HarmonyPasswordStore@localhost");
                        if (sig != nullptr) {
                            const git_commit *parents[] = { local_commit, remote_commit };
                            git_oid commit_oid;
                            if (git_commit_create(&commit_oid, repo, "HEAD", sig, sig, "UTF-8",
                                    "pull: Merge remote-tracking branch", merge_tree, 2, parents) != 0) {
                                merge_err = -1;
                            }
                            git_signature_free(sig);
                        } else {
                            merge_err = -1;
                        }
                    } else {
                        merge_err = -1;
                    }
                    if (merge_tree != nullptr) git_tree_free(merge_tree);
                    if (local_commit != nullptr) git_commit_free(local_commit);
                    if (remote_commit != nullptr) git_commit_free(remote_commit);
                }
                git_index_free(merge_index);
            }
        }
    }

    git_annotated_commit_free(annotated);
    git_reference_free(tracking_ref);
    git_reference_free(head_ref);
    git_remote_free(remote);
    git_repository_free(repo);

    if (merge_err == -2) {
        return MakeResult(env, false, "拉取后存在合并冲突，请在 Git 配置中开启「拉取时进行变基」或手动解决", "");
    }
    if (merge_err != 0) {
        std::string msg = "merge failed: " + GitLastErr();
        return MakeResult(env, false, msg.c_str(), "");
    }
    return MakeResult(env, true, "", "");
}

/**
 * gitPush(localPath, username, password, proxyUrl, privateKeyPem, passphrase,
 *         knownHostFingerprint, force) -> { success, error }
 *
 * force='1' 时 refspec 加 '+' 前缀（libgit2 的强制推送语义），
 * 远程分支将被本地覆盖——「仓库管理 → 强制推送远程」专用。
 */
static napi_value GitPush(napi_env env, napi_callback_info info) {
    std::string args[8];
    if (!GetArgs(env, info, 8, args)) {
        return MakeResult(env, false,
            "invalid arguments: expected (localPath, username, password, proxyUrl, "
            "privateKeyPem, passphrase, knownHostFingerprint, force)", "");
    }
    const bool force = (args[7] == "1");
    OH_LOG_INFO(LOG_APP, "gitPush: path=%{public}s ssh=%{public}d force=%{public}d", args[0].c_str(),
                args[4].empty() ? 0 : 1, force ? 1 : 0);

    GitNetOpts net;
    net.creds.username = args[1];
    net.creds.password = args[2];
    net.proxyUrl = args[3];

    GitSshCreds ssh;
    ssh.privateKey = args[4];
    ssh.passphrase = args[5];
    ssh.knownFingerprint = args[6];

    git_repository *repo = nullptr;
    if (git_repository_open(&repo, args[0].c_str()) != 0) {
        std::string msg = "open repo failed: " + GitLastErr();
        return MakeResult(env, false, msg.c_str(), "");
    }

    git_remote *remote = nullptr;
    if (git_remote_lookup(&remote, repo, "origin") != 0) {
        git_repository_free(repo);
        std::string msg = "remote lookup failed: " + GitLastErr();
        return MakeResult(env, false, msg.c_str(), "");
    }

    // push 当前分支 → 同名远程分支。
    // 空 refspec（count=0）不会推送任何内容，必须显式给出 refspec；
    // 未指定时 libgit2 仅推送已配置的 push refspec，克隆仓库默认没有该配置。
    // 前缀 '+' = 强制推送（覆盖远程历史，非快进也接受）。
    std::string refspec_str;
    git_reference *head_ref = nullptr;
    if (git_repository_head(&head_ref, repo) == 0) {
        const char *branch = git_reference_shorthand(head_ref);
        if (branch != nullptr && branch[0] != '\0') {
            refspec_str = std::string("refs/heads/") + branch + ":refs/heads/" + branch;
        }
        git_reference_free(head_ref);
    }
    if (force && !refspec_str.empty()) {
        refspec_str = "+" + refspec_str;
    }
    const char *refspec_items[] = { refspec_str.c_str() };
    const git_strarray refspecs = { const_cast<char **>(refspec_items), refspec_str.empty() ? 0u : 1u };

    git_push_options push_opts = GIT_PUSH_OPTIONS_INIT;
    // 始终挂上凭据回调：libgit2 在服务端要求认证时才回调，
    // 未挂回调会直接报 "remote authentication required but no callback set"，
    // 无法区分「没配凭据」与「凭据错误」。
    ApplyAuthCallbacks(&push_opts.callbacks, &net, &ssh);
    if (net.hasProxy()) {
        push_opts.proxy_opts.type = GIT_PROXY_SPECIFIED;
        push_opts.proxy_opts.url = net.proxy();
    }
    int err = GitRetryOnResolve([&]() {
        return git_remote_push(remote, &refspecs, &push_opts);
    });

    git_remote_free(remote);
    git_repository_free(repo);

    if (err != 0) {
        std::string msg = HostKeyErrorOr(ssh, "push failed: " + GitLastErr());
        OH_LOG_ERROR(LOG_APP, "gitPush failed: %{public}s", msg.c_str());
        return MakeResult(env, false, msg.c_str(), "");
    }
    OH_LOG_INFO(LOG_APP, "gitPush: ok, refspec=%{public}s", refspec_str.c_str());
    return MakeResult(env, true, "", "");
}

/**
 * gitCommitAll(localPath, message, authorName, authorEmail) -> { success, error, data=commitHash }
 */
static napi_value GitCommitAll(napi_env env, napi_callback_info info) {
    std::string args[4];
    if (!GetArgs(env, info, 4, args)) {
        return MakeResult(env, false, "invalid arguments: expected (localPath, message, authorName, authorEmail)", "");
    }

    OH_LOG_INFO(LOG_APP, "gitCommitAll: %{public}zu bytes message by %{public}s",
                args[1].size(), args[2].c_str());

    git_repository *repo = nullptr;
    if (git_repository_open(&repo, args[0].c_str()) != 0) {
        std::string msg = "open repo failed: " + GitLastErr();
        return MakeResult(env, false, msg.c_str(), "");
    }

    // add all
    git_index *index = nullptr;
    if (git_repository_index(&index, repo) != 0) {
        git_repository_free(repo);
        std::string msg = "index open failed: " + GitLastErr();
        return MakeResult(env, false, msg.c_str(), "");
    }

    // add all：libgit2 的 pathspec "." 不匹配任何文件，必须传空 pathspec
    // （NULL 表示全部文件），否则 index 为空、提交内容丢失
    if (git_index_add_all(index, nullptr, GIT_INDEX_ADD_DEFAULT, nullptr, nullptr) != 0) {
        git_index_free(index);
        git_repository_free(repo);
        std::string msg = "index add_all failed: " + GitLastErr();
        return MakeResult(env, false, msg.c_str(), "");
    }

    // write tree
    git_oid tree_oid;
    if (git_index_write_tree(&tree_oid, index) != 0) {
        git_index_free(index);
        git_repository_free(repo);
        std::string msg = "write_tree failed: " + GitLastErr();
        return MakeResult(env, false, msg.c_str(), "");
    }
    git_index_free(index);

    git_tree *tree = nullptr;
    if (git_tree_lookup(&tree, repo, &tree_oid) != 0) {
        git_repository_free(repo);
        std::string msg = "tree lookup failed: " + GitLastErr();
        return MakeResult(env, false, msg.c_str(), "");
    }

    // get HEAD as parent
    git_oid parent_oid;
    git_commit *parent = nullptr;
    bool has_parent = (git_reference_name_to_id(&parent_oid, repo, "HEAD") == 0);
    if (has_parent) {
        git_commit_lookup(&parent, repo, &parent_oid);
    }

    // 无变化就不提交：先前不看树直接 commit_create，于是每次「一键同步」都会留下一个
    // 空提交（实测远端历史里出现 `[harmonypasswordstore] <时间>` 且无任何文件变更），
    // 既污染历史又让「有没有同步成功」无从判断。
    if (has_parent && parent != nullptr && git_oid_equal(git_commit_tree_id(parent), &tree_oid)) {
        git_tree_free(tree);
        git_commit_free(parent);
        git_repository_free(repo);
        return MakeResult(env, false, "没有需要提交的更改", "");
    }

    // signature：姓名/邮箱为空会产生无效签名导致提交失败，给出兜底值
    const char *author_name = args[2].empty() ? "HarmonyPasswordStore" : args[2].c_str();
    const char *author_email = args[3].empty() ? "HarmonyPasswordStore@localhost" : args[3].c_str();
    git_signature *sig = nullptr;
    if (git_signature_now(&sig, author_name, author_email) != 0) {
        git_tree_free(tree);
        if (parent) git_commit_free(parent);
        git_repository_free(repo);
        std::string msg = "signature failed: " + GitLastErr();
        return MakeResult(env, false, msg.c_str(), "");
    }

    // commit
    git_oid commit_oid;
    int err = git_commit_create(
        &commit_oid, repo, "HEAD", sig, sig, "UTF-8",
        args[1].c_str(), tree,
        has_parent ? 1 : 0,
        has_parent ? (const git_commit **)&parent : nullptr);

    git_signature_free(sig);
    git_tree_free(tree);
    if (parent) git_commit_free(parent);
    git_repository_free(repo);

    if (err != 0) {
        std::string msg = "commit_create failed: " + GitLastErr();
        return MakeResult(env, false, msg.c_str(), "");
    }

    // 返回 commit hash（40 字符十六进制）
    char hash_buf[GIT_OID_SHA1_HEXSIZE + 1];
    git_oid_tostr(hash_buf, sizeof(hash_buf), &commit_oid);
    return MakeResult(env, true, "", hash_buf);
}

/**
 * gitLog(localPath, limit) -> { success, error, data=JSON 数组 }
 *
 * limit 为数字参数，单独解析。
 */
static napi_value GitLog(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2] = { nullptr };
    if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok || argc < 2) {
        return MakeResult(env, false, "invalid arguments: expected (localPath, limit)", "");
    }
    std::string localPath;
    double limit = 0;
    if (!GetStdString(env, argv[0], localPath)) {
        return MakeResult(env, false, "invalid arguments: localPath must be string", "");
    }
    napi_valuetype limitType = napi_undefined;
    napi_typeof(env, argv[1], &limitType);
    if (limitType != napi_number || napi_get_value_double(env, argv[1], &limit) != napi_ok) {
        return MakeResult(env, false, "invalid arguments: limit must be number", "");
    }

    git_repository *repo = nullptr;
    if (git_repository_open(&repo, localPath.c_str()) != 0) {
        std::string msg = "open repo failed: " + GitLastErr();
        return MakeResult(env, false, msg.c_str(), "[]");
    }

    git_revwalk *walker = nullptr;
    if (git_revwalk_new(&walker, repo) != 0) {
        git_repository_free(repo);
        std::string msg = "revwalk_new failed: " + GitLastErr();
        return MakeResult(env, false, msg.c_str(), "[]");
    }

    git_revwalk_push_head(walker);

    // JSON 数组
    std::string json = "[";
    bool first = true;
    git_oid oid;
    int count = 0;
    int maxCount = (int)limit;
    if (maxCount <= 0) maxCount = 50;

    while (git_revwalk_next(&oid, walker) == 0 && count < maxCount) {
        git_commit *commit = nullptr;
        if (git_commit_lookup(&commit, repo, &oid) != 0) {
            continue;
        }

        char hash_buf[GIT_OID_SHA1_HEXSIZE + 1];
        git_oid_tostr(hash_buf, sizeof(hash_buf), &oid);

        const char *summary = git_commit_summary(commit);
        const git_signature *author = git_commit_author(commit);
        git_time_t ctime = git_commit_time(commit);

        if (!first) json += ",";
        first = false;
        json += "{\"hash\":\"";
        json += hash_buf;
        json += "\",\"summary\":\"";
        json += summary ? summary : "";
        json += "\",\"authorName\":\"";
        json += author ? author->name : "";
        json += "\",\"authorEmail\":\"";
        json += author ? author->email : "";
        json += "\",\"timestamp\":";
        json += std::to_string((long long)ctime);
        json += "}";

        git_commit_free(commit);
        count++;
    }

    json += "]";

    git_revwalk_free(walker);
    git_repository_free(repo);
    return MakeResult(env, true, "", json.c_str());
}

/**
 * gitStatus(localPath) -> { success, error, data=状态 JSON }
 */
/**
 * gitRemoteUrl(localPath) -> { success, error, data: "<origin 的 URL，无则空串>" }
 *
 * 拉取/推送的认证方式必须按 **origin 实际的 URL** 判断，不能按配置里的 remoteUrl：
 * 两者可以不一致（克隆时用的是克隆页填的地址，配置页的地址是另一个字段，应用从不
 * 自动同步它们）。按配置判断的话，用户改了配置地址后再同步，就会拿 SSH 凭据去连
 * HTTPS 地址（或反之），报出与真实原因无关的认证失败。
 */
static napi_value GitRemoteUrl(napi_env env, napi_callback_info info) {
    std::string args[1];
    if (!GetArgs(env, info, 1, args)) {
        return MakeResult(env, false, "invalid arguments: expected (localPath)", "");
    }
    git_repository *repo = nullptr;
    if (git_repository_open(&repo, args[0].c_str()) != 0) {
        return MakeResult(env, true, "", "");
    }
    git_remote *remote = nullptr;
    std::string url;
    if (git_remote_lookup(&remote, repo, "origin") == 0) {
        const char *u = git_remote_url(remote);
        if (u != nullptr) {
            url = u;
        }
        git_remote_free(remote);
    }
    git_repository_free(repo);
    OH_LOG_INFO(LOG_APP, "gitRemoteUrl: %{public}s", SanitizeRemoteUrl(url).c_str());
    return MakeResult(env, true, "", url.c_str());
}

static napi_value GitStatus(napi_env env, napi_callback_info info) {
    std::string args[1];
    if (!GetArgs(env, info, 1, args)) {
        return MakeResult(env, false, "invalid arguments: expected (localPath)", "");
    }

    git_repository *repo = nullptr;
    if (git_repository_open(&repo, args[0].c_str()) != 0) {
        // 不是 git 仓库
        std::string json = "{\"isRepo\":false,\"branch\":\"\",\"changedCount\":0,\"aheadCount\":0,\"behindCount\":0,\"hasConflicts\":false}";
        return MakeResult(env, true, "", json.c_str());
    }

    // branch
    git_reference *head = nullptr;
    const char *branch = "";
    if (git_repository_head(&head, repo) == 0) {
        branch = git_reference_shorthand(head);
    }

    // status
    git_status_options opts = GIT_STATUS_OPTIONS_INIT;
    opts.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR;
    opts.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED;

    size_t changed = 0;
    git_status_list *status_list = nullptr;
    if (git_status_list_new(&status_list, repo, &opts) == 0) {
        changed = git_status_list_entrycount(status_list);
        git_status_list_free(status_list);
    }

    // 冲突检测：pull/rebase 冲突时 libgit2 会把条目标记为 conflicted。
    // 曾硬编码 false，UI 的冲突提示因此永不触发——用户看到"同步成功"，工作区其实已冲突。
    bool has_conflicts = false;
    git_index *index = nullptr;
    if (git_repository_index(&index, repo) == 0) {
        has_conflicts = git_index_has_conflicts(index) != 0;
        git_index_free(index);
    }
    if (!has_conflicts) {
        // rebase/merge/cherry-pick 进行中同样是未解决的冲突态
        has_conflicts = git_repository_state(repo) != GIT_REPOSITORY_STATE_NONE;
    }

    std::string json = "{\"isRepo\":true,\"branch\":\"";
    json += branch ? branch : "";
    json += "\",\"changedCount\":";
    json += std::to_string(changed);
    json += ",\"aheadCount\":0,\"behindCount\":0,\"hasConflicts\":";
    json += has_conflicts ? "true" : "false";
    json += "}";

    if (head) git_reference_free(head);
    git_repository_free(repo);
    return MakeResult(env, true, "", json.c_str());
}

// ========== Passphrase 验证 ==========

/**
 * gitTestRemote(remoteUrl, username, password, proxyUrl, privateKeyPem, passphrase, knownHostFingerprint)
 *   -> { success, error }
 *
 * 仅做远程连通性 + 认证 + **仓库存在性**校验，不落地任何文件：
 * git_remote_create_anonymous 建临时 remote → git_remote_connect（含认证回调）
 * → git_remote_ls 拉取引用列表。用于「保存前测试连接」。
 *
 * 私钥三参非空时走 SSH（凭据/主机密钥回调与克隆同源，见 ApplyAuthCallbacks）——
 * SSH 认证成功不代表仓库存在（sshd 不看路径），必须 ls 出引用才能发现仓库名写错。
 */
static napi_value GitTestRemote(napi_env env, napi_callback_info info) {
    std::string args[7];
    if (!GetArgs(env, info, 7, args)) {
        return MakeResult(env, false,
            "invalid arguments: expected (remoteUrl, username, password, proxyUrl, privateKeyPem, passphrase, knownHostFingerprint)", "");
    }

    if (args[0].empty()) {
        return MakeResult(env, false, "remote url is empty", "");
    }

    OH_LOG_INFO(LOG_APP, "gitTestRemote: url=%{public}s ssh=%{public}d",
                SanitizeRemoteUrl(args[0]).c_str(), args[4].empty() ? 0 : 1);

    GitNetOpts net;
    net.creds.username = args[1];
    net.creds.password = args[2];
    net.proxyUrl = args[3];

    GitSshCreds ssh;
    ssh.privateKey = args[4];
    ssh.passphrase = args[5];
    ssh.knownFingerprint = args[6];

    git_remote *remote = nullptr;
    if (git_remote_create_anonymous(&remote, nullptr, args[0].c_str()) != 0) {
        std::string msg = "create remote failed: " + GitLastErr();
        return MakeResult(env, false, msg.c_str(), "");
    }

    git_remote_callbacks callbacks = GIT_REMOTE_CALLBACKS_INIT;
    ApplyAuthCallbacks(&callbacks, &net, &ssh);

    // 该版本 libgit2 的 git_remote_connect 为 5 参数签名：
    // (remote, direction, callbacks, proxy_opts, custom_headers)
    git_proxy_options proxy_opts = GIT_PROXY_OPTIONS_INIT;
    if (net.hasProxy()) {
        proxy_opts.type = GIT_PROXY_SPECIFIED;
        proxy_opts.url = net.proxy();
    }

    if (GitRetryOnResolve([&]() {
            return git_remote_connect(remote, GIT_DIRECTION_FETCH, &callbacks, &proxy_opts, nullptr);
        }) != 0) {
        std::string msg = HostKeyErrorOr(ssh, "connect failed: " + GitLastErr());
        git_remote_free(remote);
        return MakeResult(env, false, msg.c_str(), "");
    }

    // 拉取引用列表：能列出即认证通过且仓库存在
    const git_remote_head **refs = nullptr;
    size_t ref_count = 0;
    if (git_remote_ls(&refs, &ref_count, remote) != 0) {
        std::string msg = HostKeyErrorOr(ssh, "ls-remote failed: " + GitLastErr());
        git_remote_disconnect(remote);
        git_remote_free(remote);
        return MakeResult(env, false, msg.c_str(), "");
    }

    git_remote_disconnect(remote);
    git_remote_free(remote);
    OH_LOG_INFO(LOG_APP, "gitTestRemote: ok, %{public}zu refs", ref_count);
    return MakeResult(env, true, "", "");
}

/**
 * pgpVerifyPassphrase(secretKeyArmored, passphrase) -> { success, error, data }
 */
static napi_value PgpVerifyPassphrase(napi_env env, napi_callback_info info) {
    std::string args[2];
    if (!GetArgs(env, info, 2, args)) {
        return MakeResult(env, false, "invalid arguments: expected (secretKeyArmored, passphrase)", "");
    }
    OH_LOG_INFO(LOG_APP, "pgpVerifyPassphrase: verifying passphrase");

    FfiResult result = hps_pgp_verify_passphrase(args[0].c_str(), args[1].c_str());
    napi_value napiResult;
    if (result.success == 0) {
        napiResult = MakeResult(env, true, "", "");
    } else {
        napiResult = MakeResult(env, false, result.error ? result.error : "passphrase verification failed", "");
    }
    hps_pgp_result_free(&result);
    return napiResult;
}

// ========== SSH 认证测试（russh） ==========

/**
 * sshGenerateKey(comment) -> { success, error, data = JSON { privateKeyPem, publicKey } }
 *
 * 生成 Ed25519 密钥并导出 OpenSSH PEM（native 侧生成，原因见 rpgp_wrapper.h）。
 */
static napi_value SshGenerateKey(napi_env env, napi_callback_info info) {
    std::string args[1];
    if (!GetArgs(env, info, 1, args)) {
        return MakeResult(env, false, "invalid arguments: expected (comment)", "");
    }
    OH_LOG_INFO(LOG_APP, "sshGenerateKey: comment=%{public}s", args[0].c_str());

    FfiResult result = hps_ssh_generate_key(args[0].c_str());
    napi_value napiResult;
    if (result.success == 0) {
        napiResult = MakeResult(env, true, "", result.data ? result.data : "");
    } else {
        napiResult = MakeResult(env, false, result.error ? result.error : "unknown error", "");
    }
    hps_pgp_result_free(&result);
    return napiResult;
}

/**
 * sshTestAuth(host, port, username, privateKeyPem, passphrase) -> { success, error, data }
 *
 * 建立 SSH 连接并测试公钥认证（不执行任何命令）。
 * 私钥以 PKCS8/OpenSSH PEM 文本内存传递，不落盘。
 */
static napi_value SshTestAuth(napi_env env, napi_callback_info info) {
    std::string args[6];
    // 参数 1（port）接受 number，其余为 string
    if (!GetArgsMixed(env, info, 6, args, 0b111101)) {
        return MakeResult(env, false, "invalid arguments: expected (host, port, username, privateKeyPath, passphrase, expectedFingerprint)", "");
    }

    uint16_t port = 22;
    try {
        port = static_cast<uint16_t>(std::stoi(args[1].empty() ? "22" : args[1]));
    } catch (...) {
        port = 22;
    }

    OH_LOG_INFO(LOG_APP, "sshTestAuth: %{public}s:%{public}u user=%{public}s",
                args[0].c_str(), port, args[2].c_str());

    FfiResult result = hps_ssh_test_auth(args[0].c_str(), port, args[2].c_str(),
                                         args[3].c_str(), args[4].c_str(), args[5].c_str());
    napi_value napiResult;
    if (result.success == 0) {
        napiResult = MakeResult(env, true, "", result.data ? result.data : "");
    } else {
        napiResult = MakeResult(env, false, result.error ? result.error : "ssh auth failed", "");
    }
    hps_pgp_result_free(&result);
    return napiResult;
}

/**
 * sshTestPassword(host, port, username, password, expectedFingerprint) -> { success, error, data }
 *
 * 建立 SSH 连接并测试密码认证（不执行任何命令）。
 * expectedFingerprint 非空时校验服务器主机密钥（TOFU），不匹配拒绝连接。
 */
static napi_value SshTestPassword(napi_env env, napi_callback_info info) {
    std::string args[5];
    // 参数 1（port）接受 number，其余为 string
    if (!GetArgsMixed(env, info, 5, args, 0b11101)) {
        return MakeResult(env, false, "invalid arguments: expected (host, port, username, password, expectedFingerprint)", "");
    }

    uint16_t port = 22;
    try {
        port = static_cast<uint16_t>(std::stoi(args[1].empty() ? "22" : args[1]));
    } catch (...) {
        port = 22;
    }

    OH_LOG_INFO(LOG_APP, "sshTestPassword: %{public}s:%{public}u user=%{public}s",
                args[0].c_str(), port, args[2].c_str());

    FfiResult result = hps_ssh_test_password(args[0].c_str(), port, args[2].c_str(), args[3].c_str(), args[4].c_str());
    napi_value napiResult;
    if (result.success == 0) {
        napiResult = MakeResult(env, true, "", result.data ? result.data : "");
    } else {
        napiResult = MakeResult(env, false, result.error ? result.error : "ssh auth failed", "");
    }
    hps_pgp_result_free(&result);
    return napiResult;
}

/**
 * sshFingerprint(host, port) -> { success, error, data="SHA256:Base64" 主机密钥指纹 }
 *
 * 仅探测服务器主机密钥指纹（TOFU 首次连接），不认证。
 */
static napi_value SshFingerprint(napi_env env, napi_callback_info info) {
    std::string args[2];
    // 掩码位为 1 表示该位置必须是 string：index0=host 为 string，index1=port 为 number
    if (!GetArgsMixed(env, info, 2, args, 0b01)) {
        return MakeResult(env, false, "invalid arguments: expected (host, port)", "");
    }

    uint16_t port = 22;
    try {
        port = static_cast<uint16_t>(std::stoi(args[1].empty() ? "22" : args[1]));
    } catch (...) {
        port = 22;
    }

    OH_LOG_INFO(LOG_APP, "sshFingerprint: %{public}s:%{public}u", args[0].c_str(), port);

    FfiResult result = hps_ssh_fingerprint(args[0].c_str(), port);
    napi_value napiResult;
    if (result.success == 0) {
        napiResult = MakeResult(env, true, "", result.data ? result.data : "");
    } else {
        napiResult = MakeResult(env, false, result.error ? result.error : "ssh fingerprint failed", "");
    }
    hps_pgp_result_free(&result);
    return napiResult;
}

// ========== 模块注册 ==========

/**
 * 进程级一次性初始化
 *
 * **必须只跑一次**：NAPI 模块在 TaskPool 的每个工作线程上都会各自加载一遍
 * （`Init` 因此被多线程并发调用），而这里设置的是**进程级全局状态**——
 * 两个线程同时执行 `GIT_OPT_SET_SSL_CERT_LOCATIONS` 会让 mbedTLS 并发解析
 * 同一份 CA 包到同一个全局 SSL 上下文上。实测：同时发起两个 git 调用
 * （例如页面 aboutToAppear 与 onShown 各触发一次状态查询）时 SIGSEGV，
 * faultlog 栈顶为 `mbedtls_x509_crt_parse_der_internal`。
 */
static void InitLibgit2Once() {
    git_libgit2_init();

    // 指定系统 CA 证书包：libgit2 的 mbedTLS 后端默认硬编码了构建期路径
    // （/tmp/mb-install-*/etc/certs.pem），在设备上不存在会导致
    // HTTPS 全部报 "the SSL certificate is invalid"。这里指向设备可读的
    // 系统 CA 包（不存在时保持默认，不阻断初始化）。
    const char *caBundle = "/etc/ssl/certs/cacert.pem";
    if (access(caBundle, R_OK) == 0) {
        int rc = git_libgit2_opts(GIT_OPT_SET_SSL_CERT_LOCATIONS, caBundle, nullptr);
        OH_LOG_INFO(LOG_APP, "libgit2 CA bundle set to %{public}s (rc=%{public}d)", caBundle, rc);
    } else {
        OH_LOG_WARN(LOG_APP, "system CA bundle %{public}s not readable, using default", caBundle);
    }
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    static std::once_flag libgit2InitFlag;
    std::call_once(libgit2InitFlag, InitLibgit2Once);

    napi_property_descriptor desc[] = {
        { "pgpEncrypt", nullptr, PgpEncrypt, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "pgpDecrypt", nullptr, PgpDecrypt, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "pgpEncryptGpgPqc", nullptr, PgpEncryptGpgPqc, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "pgpDecryptGpgPqc", nullptr, PgpDecryptGpgPqc, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "pgpGpgPqcSupported", nullptr, PgpGpgPqcSupported, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "pgpGpgPqcVerifyPassphrase", nullptr, PgpGpgPqcVerifyPassphrase, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "pgpEncryptMixed", nullptr, PgpEncryptMixed, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "pgpRecipientKeyIds", nullptr, PgpRecipientKeyIds, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "pgpLock", nullptr, PgpLock, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "pgpListKeys", nullptr, PgpListKeys, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "pgpExtractPublicKey", nullptr, PgpExtractPublicKey, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "pgpVerifyPassphrase", nullptr, PgpVerifyPassphrase, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "pgpGenerateKey", nullptr, PgpGenerateKey, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "pgpChangePassphrase", nullptr, PgpChangePassphrase, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "pgpBackupKey", nullptr, PgpBackupKey, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "pgpRestoreBackup", nullptr, PgpRestoreBackup, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "pgpSplitKeyring", nullptr, PgpSplitKeyring, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "pgpKeyAsSsh", nullptr, PgpKeyAsSsh, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sshGenerateKey", nullptr, SshGenerateKey, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sshTestAuth", nullptr, SshTestAuth, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sshTestPassword", nullptr, SshTestPassword, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sshFingerprint", nullptr, SshFingerprint, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sshPublicFromPrivate", nullptr, SshPublicFromPrivate, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sshKeyStatus", nullptr, SshKeyStatus, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "gitClone", nullptr, GitClone, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "gitCloneSsh", nullptr, GitCloneSsh, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "gitTestRemote", nullptr, GitTestRemote, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "gitPull", nullptr, GitPull, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "gitPush", nullptr, GitPush, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "gitCommitAll", nullptr, GitCommitAll, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "gitLog", nullptr, GitLog, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "gitStatus", nullptr, GitStatus, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "gitRemoteUrl", nullptr, GitRemoteUrl, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "gitCloneProgress", nullptr, GitCloneProgress, nullptr, nullptr, nullptr, napi_default, nullptr },
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module hpsModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "harmonypasswordstore",
    .nm_priv = nullptr,
    .reserved = { 0 },
};

extern "C" __attribute__((constructor)) void RegisterHpsModule(void) {
    napi_module_register(&hpsModule);
}
