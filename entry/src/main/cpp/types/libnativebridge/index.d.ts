/**
 * libnativebridge.so NAPI 接口声明
 *
 * 与 hps_napi.cpp 注册的导出函数一一对应。
 * 统一返回 NativeResult 结构（success/error/data 字符串字段）。
 */
export interface NativeResult {
  success: boolean;
  error: string;
  data: string;
}

// ========== PGP ==========
export const pgpEncrypt: (plaintext: string, publicKeyArmored: string) => NativeResult;
export const pgpDecrypt: (ciphertextArmored: string, secretKeyArmored: string, passphrase: string) => NativeResult;
// GnuPG algo 8（ky768_cv25519 = ML-KEM-768 + X25519）：pgp 0.20 会丢弃 v5 子密钥，
// 该算法由独立模块解析与解密
export const pgpDecryptGpgPqc: (ciphertext: string, secretKeyArmored: string, passphrase: string) => NativeResult;
export const pgpEncryptGpgPqc: (plaintext: string, publicKeyArmored: string) => NativeResult;
export const pgpGpgPqcSupported: (secretKeyArmored: string) => NativeResult;
export const pgpGpgPqcVerifyPassphrase: (secretKeyArmored: string, passphrase: string) => NativeResult;
/**
 * 混合加密：同一份密文同时发给 gpgPqc（GnuPG algo 8）与普通密钥，两类接收方
 * 共用同一会话密钥。两侧参数均可含多个拼接的 armored 块。
 */
export const pgpEncryptMixed: (plaintext: string, gpgpqcPubkeysArmored: string, normalPubkeysArmored: string) => NativeResult;
/** 提取密文 PKESK 的收件人 Key ID（逗号分隔，大写十六进制；无则空串） */
export const pgpRecipientKeyIds: (ciphertext: string) => NativeResult;
/** 清空 native 侧的已解锁私钥缓存（上锁 / 切后台时调用，data 为空串） */
export const pgpLock: () => NativeResult;
export const pgpListKeys: (armoredKeyring: string) => NativeResult;
export const pgpExtractPublicKey: (secretKeyArmored: string) => NativeResult;
export const pgpVerifyPassphrase: (secretKeyArmored: string, passphrase: string) => NativeResult;
export const pgpGenerateKey: (userId: string, keyType: string, passphrase: string) => NativeResult;
export const pgpChangePassphrase: (secretKeyArmored: string, oldPassphrase: string, newPassphrase: string) => NativeResult;
export const pgpBackupKey: (keyArmored: string, backupPassword: string) => NativeResult;
export const pgpRestoreBackup: (backupArmored: string, backupPassword: string) => NativeResult;
export const pgpSplitKeyring: (armoredKeyring: string) => NativeResult;
export const pgpKeyAsSsh: (secretKeyArmored: string, passphrase: string) => NativeResult;

// ========== SSH ==========
/** 生成 Ed25519 SSH 密钥 -> data = JSON { privateKeyPem, publicKey } */
export const sshGenerateKey: (comment: string) => NativeResult;
export const sshTestAuth: (host: string, port: number, username: string, privateKeyPath: string,
  passphrase: string, expectedFingerprint: string) => NativeResult;
export const sshTestPassword: (host: string, port: number, username: string, password: string,
  expectedFingerprint: string) => NativeResult;
export const sshFingerprint: (host: string, port: number) => NativeResult;
export const sshPublicFromPrivate: (privateKeyPem: string, passphrase: string) => NativeResult;
export const sshKeyStatus: (privateKeyPem: string) => NativeResult;

// ========== Git ==========
export const gitClone: (remoteUrl: string, localPath: string, username: string, password: string, proxyUrl: string) => NativeResult;
/**
 * SSH 克隆（libgit2 + libssh2）。私钥以 PEM 文本在内存中传递（不落盘）；
 * knownHostFingerprint 为已信任的主机指纹（"SHA256:Base64"），不一致会中断连接。
 */
export const gitCloneSsh: (remoteUrl: string, localPath: string, privateKeyPem: string, passphrase: string, knownHostFingerprint: string) => NativeResult;
export const gitTestRemote: (remoteUrl: string, username: string, password: string, proxyUrl: string,
  privateKeyPem: string, passphrase: string, knownHostFingerprint: string) => NativeResult;
/**
 * 拉取/推送。HTTPS 用 username/password；SSH 用 privateKeyPem/passphrase/knownHostFingerprint
 * （私钥 PEM 在内存中传递、不落盘；指纹不一致会中断连接）。SSH 时把 username/password 传空串。
 */
export const gitPull: (localPath: string, username: string, password: string, proxyUrl: string, rebase: string,
  privateKeyPem: string, passphrase: string, knownHostFingerprint: string) => NativeResult;
/** force='1' 时强制推送（refspec 加 '+' 前缀，覆盖远程分支历史） */
export const gitPush: (localPath: string, username: string, password: string, proxyUrl: string,
  privateKeyPem: string, passphrase: string, knownHostFingerprint: string, force: string) => NativeResult;
export const gitCommitAll: (localPath: string, message: string, authorName: string, authorEmail: string) => NativeResult;
export const gitLog: (localPath: string, limit: number) => NativeResult;
export const gitStatus: (localPath: string) => NativeResult;
/** origin 的实际 URL（空串表示未配置 origin 或不是仓库）；拉取/推送据此选择认证方式 */
export const gitRemoteUrl: (localPath: string) => NativeResult;
/** 当前克隆进度（0-100）。进度回调跑在 TaskPool 工作线程，UI 主线程轮询读取 */
export const gitCloneProgress: () => number;
