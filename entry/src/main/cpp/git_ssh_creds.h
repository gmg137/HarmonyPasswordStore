/**
 * SSH 克隆的凭据与主机密钥校验（libgit2 + libssh2）
 *
 * 抽成头文件的原因：设备端探针程序（tools/git_ssh_probe.cpp）要与 App 走**同一份**
 * 实现，否则「探针通过」不代表应用内可用。用法见 hps_napi.cpp 的 GitCloneSsh。
 *
 * 前置条件：libgit2 必须带 -DUSE_SSH=libssh2 编译（见 CMakeLists 与
 * third_party/libssh2），否则其 ssh 传输是桩函数，git@host:path 会报「不支持的协议」。
 */
#ifndef HPS_GIT_SSH_CREDS_H
#define HPS_GIT_SSH_CREDS_H

#include <string>
#include <git2.h>
#include <git2/sys/errors.h>
#include "hilog/log.h"

// libgit2 编译时必须带 -DUSE_SSH=libssh2（见 CMakeLists 与 third_party/libssh2），
// 否则其 ssh 传输是桩函数，git@host:path / ssh:// 会报「不支持的协议」。
// 私钥以 PEM 文本在内存中传递（由 ArkTS 侧从 HUKS 解封后传入，不落盘）。

/**
 * 主机密钥信任库条目（类型 + 指纹，多把）
 *
 * 之所以带类型：同类型指纹不同才是真正的「密钥变了」（可能中间人）；
 * 服务器本就同时提供多把不同类型的主机密钥，不同 SSH 实现（russh/libssh2）
 * 偏好不同、各选一把——对方选到一把**没见过类型**的密钥不是攻击，是正常的。
 * 只比较指纹（不带类型）会把「服务器有 3 把密钥」误判成「3 次中间人攻击」。
 */
struct HostKeyTrust {
    std::string keyType;    // rsa/ecdsa/ed25519/未知
    std::string fingerprint; // SHA256:Base64（不带 '=' 填充）
};

/** 解析一行信任条目 "类型|指纹"（旧格式裸指纹按空类型处理，仍可按指纹匹配） */
static HostKeyTrust ParseHostKeyTrust(const std::string &line) {
    HostKeyTrust t;
    const size_t sep = line.find('|');
    if (sep == std::string::npos) {
        t.fingerprint = line;
    } else {
        t.keyType = line.substr(0, sep);
        t.fingerprint = line.substr(sep + 1);
    }
    return t;
}

/** SSH 凭据与主机指纹校验共用的上下文 */
struct GitSshCreds {
    std::string username;          // 通常为 "git"，URL 里的用户名优先
    std::string privateKey;        // OpenSSH/PEM 私钥文本
    std::string passphrase;        // 私钥口令，可为空
    /**
     * 已信任的主机密钥，每行一条 "类型|指纹"（空=未信任；兼容旧格式裸指纹）
     *
     * 之所以是**多把**：同一台服务器通常同时提供 rsa/ecdsa/ed25519 多把主机密钥，
     * 而不同 SSH 实现偏好不同（russh 偏好 ed25519、libssh2 偏好 rsa），
     * 各流程各钉一把；这里只要**指纹匹配任意一把**就放行。
     */
    std::string knownFingerprint;
    /**
     * 本次连接**实际收到**的主机密钥指纹（由回调填写，出参）
     *
     * 用途：主机密钥未被信任时，把这个指纹带回上层做 TOFU 确认。
     * **必须取实际连接的这一份**，不能用别的实现（russh）另开一次连接去探测：
     * 服务器通常同时提供 rsa/ecdsa/ed25519 多把主机密钥，russh 偏好 ed25519 而
     * libssh2 偏好 rsa，两者算出的指纹天然不同（真机实测 gitee：
     * 探测得到 ed25519 的 +ULzij2u…，而克隆实际收到 rsa 的 FQGC9Kn/…），
     * 于是确认过的指纹永远匹配不上实际连接。
     */
    std::string presentedFingerprint;
    /** 实际收到的主机密钥类型（rsa/ecdsa/ed25519，仅用于提示文案） */
    std::string presentedKeyType;
    /**
     * 主机密钥校验结论（由回调填写，出参）：trusted / untrusted / mismatch
     *
     * 回调是唯一知道「三态」结论的地方（untrusted=本次类型没钉过，mismatch=
     * 同类型指纹变了），HostKeyErrorOr 直接取用，不要用「信任列表是否为空」
     * 二次猜测——列表非空但全是不相关类型时，结论是 untrusted 而非 mismatch。
     */
    std::string presentedTrustState;
};

/**
 * 标准 base64（用于把主机密钥 SHA-256 摘要编码成与 russh 一致的指纹格式）
 *
 * **不带 `=` 填充**：OpenSSH 的 `SHA256:…` 指纹（`ssh-keygen -lf`）用的是去填充的
 * base64——32 字节摘要编码成 43 个字符。早期实现带填充（44 字符，尾部 `=`），
 * 于是与 russh/known_hosts 里保存的指纹**永远不相等**，每一次 SSH 连接都被
 * 自己的主机密钥校验拒掉（libgit2 只会报 "invalid or unknown remote ssh hostkey"，
 * 看不出是比较字符串的问题）。
 */
static std::string Base64Encode(const unsigned char *data, size_t len) {
    static const char *tbl = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string out;
    out.reserve(((len + 2) / 3) * 4);
    for (size_t i = 0; i < len; i += 3) {
        unsigned int v = data[i] << 16;
        if (i + 1 < len) v |= data[i + 1] << 8;
        if (i + 2 < len) v |= data[i + 2];
        out.push_back(tbl[(v >> 18) & 0x3F]);
        out.push_back(tbl[(v >> 12) & 0x3F]);
        if (i + 1 < len) out.push_back(tbl[(v >> 6) & 0x3F]);
        if (i + 2 < len) out.push_back(tbl[v & 0x3F]);
    }
    return out;
}

/** SSH 公钥认证：用内存中的私钥应答服务端挑战 */
static int GitSshCredCallback(git_credential **out, const char *url, const char *username_from_url,
                              unsigned int allowed_types, void *payload) {
    (void)url;
    GitSshCreds *c = (GitSshCreds *)payload;
    if ((allowed_types & GIT_CREDENTIAL_SSH_KEY) == 0) {
        return GIT_PASSTHROUGH;
    }
    const char *user = (username_from_url != nullptr && *username_from_url != '\0')
        ? username_from_url
        : (c->username.empty() ? "git" : c->username.c_str());
    // publickey 传 nullptr：libssh2 会从私钥推导（OpenSSH 格式支持）
    return git_credential_ssh_key_memory_new(out, user, nullptr, c->privateKey.c_str(),
        c->passphrase.empty() ? nullptr : c->passphrase.c_str());
}

/**
 * 主机密钥校验：与已保存指纹比对，不一致直接中断连接
 *
 * 指纹格式与 russh 侧（`hps_ssh_fingerprint`）保持一致：`SHA256:` + base64(sha256(hostkey))
 * （base64 **不带 `=` 填充**，见 Base64Encode 的说明）。
 * 未配置已知指纹时不放行也不静默信任——交由上层先走「测试连接」的 TOFU 流程。
 *
 * 注意：本头文件里的 OH_LOG_* 用哪套 domain/tag，取决于**包含方**在包含本文件前
 * 是否已定义 LOG_DOMAIN/LOG_TAG（见 hps_napi.cpp 顶部）。
 */
static int GitCertCheckCallback(git_cert *cert, int valid, const char *host, void *payload) {
    (void)valid;
    GitSshCreds *c = (GitSshCreds *)payload;
    if (cert->cert_type != GIT_CERT_HOSTKEY_LIBSSH2) {
        OH_LOG_WARN(LOG_APP, "gitCertCheck(%{public}s): unexpected cert_type=%{public}d, accepting",
                    host, cert->cert_type);
        return 0;
    }
    git_cert_hostkey *hk = (git_cert_hostkey *)cert;
    // 1.9 的 git_cert_hostkey 没有 hash_sha256_len，用 type 位掩码判断字段是否可用
    if ((hk->type & GIT_CERT_SSH_SHA256) == 0) {
        OH_LOG_WARN(LOG_APP, "gitCertCheck(%{public}s): no SHA256 in type=0x%{public}x, accepting",
                    host, hk->type);
        return 0;
    }
    const std::string fp = "SHA256:" + Base64Encode(hk->hash_sha256, 32);
    // 记录实际指纹（供上层做 TOFU 确认）
    c->presentedFingerprint = fp;
    switch (hk->raw_type) {
        case GIT_CERT_SSH_RAW_TYPE_RSA: c->presentedKeyType = "RSA"; break;
        case GIT_CERT_SSH_RAW_TYPE_KEY_ECDSA_256:
        case GIT_CERT_SSH_RAW_TYPE_KEY_ECDSA_384:
        case GIT_CERT_SSH_RAW_TYPE_KEY_ECDSA_521: c->presentedKeyType = "ECDSA"; break;
        case GIT_CERT_SSH_RAW_TYPE_KEY_ED25519: c->presentedKeyType = "Ed25519"; break;
        default: c->presentedKeyType = "未知类型"; break;
    }

    if (c->knownFingerprint.empty()) {
        OH_LOG_ERROR(LOG_APP, "gitCertCheck(%{public}s): untrusted host key %{public}s (%{public}s)",
                     host, fp.c_str(), c->presentedKeyType.c_str());
        c->presentedTrustState = "untrusted";
        git_error_set_str(GIT_ERROR_NET, "host key not trusted");
        return GIT_EUSER;
    }
    // 多把信任条目逐条比对（三态判定）：
    // ① 指纹匹配任意一条 → 信任，放行；
    // ② 同类型、指纹不同 → 该类型的密钥真的变了，可能中间人，拒绝；
    // ③ 类型从未见过 → 服务器本就有多把主机密钥，这次只是选了把没钉过的，
    //    按「未信任」处理（回报指纹走一次 TOFU 确认后追加），不算攻击。
    bool mismatchSameType = false;
    bool fingerprintSeen = false;
    size_t pos = 0;
    while (pos <= c->knownFingerprint.size()) {
        const size_t nl = c->knownFingerprint.find('\n', pos);
        const std::string line = c->knownFingerprint.substr(
            pos, nl == std::string::npos ? std::string::npos : nl - pos);
        pos = (nl == std::string::npos) ? c->knownFingerprint.size() + 1 : nl + 1;
        if (line.empty()) {
            continue;
        }
        const HostKeyTrust t = ParseHostKeyTrust(line);
        if (t.fingerprint == fp) {
            fingerprintSeen = true;
            break;
        }
        if (!t.keyType.empty() && t.keyType == c->presentedKeyType) {
            mismatchSameType = true;
        }
    }
    if (fingerprintSeen) {
        OH_LOG_INFO(LOG_APP, "gitCertCheck: host key verified (%{public}s)", fp.c_str());
        // **通过时必须显式置 trusted**：HostKeyErrorOr 只在 state=="trusted" 时
        // 才回传原始错误。曾经这里只 return 0 不写状态，于是「主机密钥已信任、
        // 但克隆因别的原因失败」（如仓库名写错）被回报成 host key untrusted——
        // UI 反复弹「首次连接确认指纹」弹窗，真正的失败原因永远显示不出来。
        c->presentedTrustState = "trusted";
        return 0;
    }
    if (mismatchSameType) {
        OH_LOG_ERROR(LOG_APP, "gitCertCheck: host key mismatch for %{public}s (got %{public}s)",
                     c->presentedKeyType.c_str(), fp.c_str());
        c->presentedTrustState = "mismatch";
        git_error_set_str(GIT_ERROR_NET, "host key mismatch");
        return GIT_EUSER;
    }
    OH_LOG_ERROR(LOG_APP, "gitCertCheck(%{public}s): untrusted host key type %{public}s %{public}s",
                 host, c->presentedKeyType.c_str(), fp.c_str());
    c->presentedTrustState = "untrusted";
    git_error_set_str(GIT_ERROR_NET, "host key not trusted");
    return GIT_EUSER;
}


#endif  // HPS_GIT_SSH_CREDS_H
