import { hilog } from '@kit.PerformanceAnalysisKit';
// NAPI 模块静态导入（ArkTS 不支持 require/动态 import；
// .so 随 HAP 打包必然存在，加载失败场景由调用 try/catch 兜底）
import hpsNative from 'libnativebridge.so';

/** hilog 域 */
const DOMAIN: number = 0x0001;
/** hilog 标签 */
const TAG: string = 'NativeBridge';

/**
 * Native 桥接统一结果
 */
export interface NativeResult {
  success: boolean;
  error: string;
  data: string;
}

/**
 * Native 桥接访问器
 *
 * 封装 libnativebridge.so 的 NAPI 接口；
 * native 函数抛出异常（如低版本系统无法加载）时返回失败结果，
 * 调用方优雅降级到 ArkTS stub 行为，不会崩溃。
 */
export class NativeBridge {
  private static instance: NativeBridge | null = null;

  private constructor() {
  }

  static getInstance(): NativeBridge {
    if (!NativeBridge.instance) {
      NativeBridge.instance = new NativeBridge();
    }
    return NativeBridge.instance;
  }

  /**
   * native 桥接是否可用
   * （.so 随包分发，静态导入成功即视为可用）
   */
  isAvailable(): boolean {
    return hpsNative !== null && hpsNative !== undefined;
  }

  /**
   * 调用 native 函数的统一入口：
   * 调用异常时返回失败结果（不抛出），调用方无需 try/catch。
   */
  private callSafely(fnName: string, invoke: () => NativeResult): NativeResult {
    try {
      return invoke();
    } catch (e) {
      // 必须取 e.message/e.name：ArkTS 里 Error 的属性不可枚举，JSON.stringify(e) 恒为 {}
      // （曾因此只看到「native call failed: {}」，无法定位是哪个 native 调用抛的什么错）
      const detail: string = e instanceof Error ? `${e.name}: ${e.message}` : String(e);
      hilog.error(DOMAIN, TAG, '%{public}s native call failed: %{public}s', fnName, detail);
      const failed: NativeResult = { success: false, error: `native call failed (${detail})`, data: '' };
      return failed;
    }
  }

  // ========== PGP ==========

  pgpEncrypt(plaintext: string, publicKeyArmored: string): NativeResult {
    return this.callSafely('pgpEncrypt', (): NativeResult => hpsNative.pgpEncrypt(plaintext, publicKeyArmored));
  }

  pgpDecrypt(ciphertextArmored: string, secretKeyArmored: string, passphrase: string): NativeResult {
    return this.callSafely('pgpDecrypt',
      (): NativeResult => hpsNative.pgpDecrypt(ciphertextArmored, secretKeyArmored, passphrase));
  }

  /**
   * GnuPG algo 8（ky768_cv25519 = ML-KEM-768 + X25519）解密。
   *
   * pgp 0.20 会静默丢弃 v5 子密钥包，该算法的密钥走不了 rpgp，
   * 由 native 独立模块解析（含带口令保护段）并解密。
   */
  pgpDecryptGpgPqc(ciphertext: string, secretKeyArmored: string, passphrase: string): NativeResult {
    return this.callSafely('pgpDecryptGpgPqc',
      (): NativeResult => hpsNative.pgpDecryptGpgPqc(ciphertext, secretKeyArmored, passphrase));
  }

  /**
   * GnuPG algo 8（ky768_cv25519 = ML-KEM-768 + X25519）加密。
   *
   * rpgp 会静默丢弃 v5 子密钥包，无法用它加密，故由 native 独立模块
   * 构造 PKESK(algo 8) + SEIPDv1（RFC 标准格式，gpg 可直接解密）。
   */
  pgpEncryptGpgPqc(plaintext: string, publicKeyArmored: string): NativeResult {
    return this.callSafely('pgpEncryptGpgPqc',
      (): NativeResult => hpsNative.pgpEncryptGpgPqc(plaintext, publicKeyArmored));
  }

  /** 给定 armored 私钥是否含可解密的 GnuPG algo 8（PQC）密钥（data 为 "1"/"0"） */
  pgpGpgPqcSupported(secretKeyArmored: string): NativeResult {
    return this.callSafely('pgpGpgPqcSupported',
      (): NativeResult => hpsNative.pgpGpgPqcSupported(secretKeyArmored));
  }

  /**
   * 校验 GnuPG algo 8（PQC）私钥的口令。
   *
   * rpgp 会丢弃 v5 子密钥包，无法校验其保护段，故由 native 独立模块
   * 尝试解出私钥材料来判定口令是否正确。
   */
  pgpGpgPqcVerifyPassphrase(secretKeyArmored: string, passphrase: string): NativeResult {
    return this.callSafely('pgpGpgPqcVerifyPassphrase',
      (): NativeResult => hpsNative.pgpGpgPqcVerifyPassphrase(secretKeyArmored, passphrase));
  }

  /**
   * 提取密文 PKESK 的收件人 Key ID（算法无关）
   *
   * 用于：① 解密前判断条目实际由哪把密钥加密，从而索取正确口令；
   * ② 重加密时判断条目是否已用目标密钥（相等则跳过）。
   * 无 PKESK（对称加密）或全为隐藏收件人时 data 为空串。
   */
  /**
   * 混合加密：同一目录同时指定 gpgPqc 与普通密钥时使用。
   * 两类接收方共用同一会话密钥，各自出一个 PKESK，明文只加密一次。
   */
  pgpEncryptMixed(plaintext: string, gpgpqcPubkeysArmored: string,
                  normalPubkeysArmored: string): NativeResult {
    return this.callSafely('pgpEncryptMixed',
      (): NativeResult => hpsNative.pgpEncryptMixed(plaintext, gpgpqcPubkeysArmored, normalPubkeysArmored));
  }

  pgpRecipientKeyIds(ciphertext: string): NativeResult {
    return this.callSafely('pgpRecipientKeyIds',
      (): NativeResult => hpsNative.pgpRecipientKeyIds(ciphertext));
  }

  pgpListKeys(armoredKeyring: string): NativeResult {
    return this.callSafely('pgpListKeys', (): NativeResult => hpsNative.pgpListKeys(armoredKeyring));
  }

  pgpExtractPublicKey(secretKeyArmored: string): NativeResult {
    return this.callSafely('pgpExtractPublicKey',
      (): NativeResult => hpsNative.pgpExtractPublicKey(secretKeyArmored));
  }

  pgpVerifyPassphrase(secretKeyArmored: string, passphrase: string): NativeResult {
    return this.callSafely('pgpVerifyPassphrase',
      (): NativeResult => hpsNative.pgpVerifyPassphrase(secretKeyArmored, passphrase));
  }

  pgpGenerateKey(userId: string, keyType: string, passphrase: string): NativeResult {
    return this.callSafely('pgpGenerateKey',
      (): NativeResult => hpsNative.pgpGenerateKey(userId, keyType, passphrase));
  }

  pgpChangePassphrase(secretKeyArmored: string, oldPassphrase: string, newPassphrase: string): NativeResult {
    return this.callSafely('pgpChangePassphrase',
      (): NativeResult => hpsNative.pgpChangePassphrase(secretKeyArmored, oldPassphrase, newPassphrase));
  }

  pgpBackupKey(keyArmored: string, backupPassword: string): NativeResult {
    return this.callSafely('pgpBackupKey',
      (): NativeResult => hpsNative.pgpBackupKey(keyArmored, backupPassword));
  }

  pgpRestoreBackup(backupArmored: string, backupPassword: string): NativeResult {
    return this.callSafely('pgpRestoreBackup',
      (): NativeResult => hpsNative.pgpRestoreBackup(backupArmored, backupPassword));
  }

  pgpSplitKeyring(armoredKeyring: string): NativeResult {
    return this.callSafely('pgpSplitKeyring',
      (): NativeResult => hpsNative.pgpSplitKeyring(armoredKeyring));
  }

  pgpKeyAsSsh(secretKeyArmored: string, passphrase: string): NativeResult {
    return this.callSafely('pgpKeyAsSsh',
      (): NativeResult => hpsNative.pgpKeyAsSsh(secretKeyArmored, passphrase));
  }

  // ========== SSH ==========

  /**
   * 生成 Ed25519 SSH 密钥（native 侧生成，返回 OpenSSH PEM）
   *
   * 不要在 ArkTS 侧用 cryptoFramework 生成：其 Ed25519 私钥导不出来
   * （getEncoded/getEncodedDer('PKCS8') 均不支持），重启后私钥即丢失。
   */
  sshGenerateKey(comment: string): NativeResult {
    return this.callSafely('sshGenerateKey', (): NativeResult => hpsNative.sshGenerateKey(comment));
  }

  sshTestAuth(host: string, port: number, username: string, privateKeyPath: string,
              passphrase: string, expectedFingerprint: string): NativeResult {
    return this.callSafely('sshTestAuth',
      (): NativeResult => hpsNative.sshTestAuth(host, port, username, privateKeyPath, passphrase, expectedFingerprint));
  }

  sshTestPassword(host: string, port: number, username: string, password: string,
                  expectedFingerprint: string): NativeResult {
    return this.callSafely('sshTestPassword',
      (): NativeResult => hpsNative.sshTestPassword(host, port, username, password, expectedFingerprint));
  }

  sshFingerprint(host: string, port: number): NativeResult {
    return this.callSafely('sshFingerprint',
      (): NativeResult => hpsNative.sshFingerprint(host, port));
  }

  /**
   * 探测私钥状态：区分「已加密需口令」与「格式无效/已损坏」
   * @returns data 为 JSON：{"valid":bool,"encrypted":bool,"error":string}
   */
  sshKeyStatus(privateKeyPem: string): NativeResult {
    return this.callSafely('sshKeyStatus',
      (): NativeResult => hpsNative.sshKeyStatus(privateKeyPem));
  }

  /**
   * 从 OpenSSH 私钥 PEM 推导公钥（authorized_keys 单行格式）
   *
   * 解析失败即私钥无效或口令错误，因此同时充当私钥格式校验。
   * @param privateKeyPem 私钥 PEM 文本
   * @param passphrase 私钥口令（无口令传空串）
   */
  sshPublicFromPrivate(privateKeyPem: string, passphrase: string): NativeResult {
    return this.callSafely('sshPublicFromPrivate',
      (): NativeResult => hpsNative.sshPublicFromPrivate(privateKeyPem, passphrase));
  }

  // ========== Git ==========

  gitClone(remoteUrl: string, localPath: string, username: string, password: string, proxyUrl: string): NativeResult {
    return this.callSafely('gitClone', (): NativeResult => hpsNative.gitClone(remoteUrl, localPath, username, password, proxyUrl));
  }

  /**
   * SSH 克隆：私钥由 ArkTS 侧从 HUKS 解封后传入内存（不写临时文件）
   *
   * `knownHostFingerprint` 是已信任的主机指纹（`SHA256:Base64`），native 侧与
   * 服务端实际主机密钥比对，不一致直接中断——未配置指纹时同样拒绝连接，
   * 强制先走「测试连接」的 TOFU 确认流程。
   */
  gitCloneSsh(remoteUrl: string, localPath: string, privateKeyPem: string,
              passphrase: string, knownHostFingerprint: string): NativeResult {
    return this.callSafely('gitCloneSsh',
      (): NativeResult => hpsNative.gitCloneSsh(remoteUrl, localPath, privateKeyPem,
        passphrase, knownHostFingerprint));
  }

  /**
   * 当前克隆进度（0-100）
   *
   * 纯内存读（native 侧的原子变量），**不涉及网络/IO**——所以它可以在主线程调用，
   * 与「网络类 native 调用必须走 TaskPool」那条约束不冲突。
   */
  gitCloneProgress(): number {
    if (!this.isAvailable()) {
      return 0;
    }
    // 不用 callSafely：它只接受返回 NativeResult 的调用，而这里返回 number。
    // 失败时降级为 0（UI 退化为不确定态），不能让它把整个进度环打断。
    try {
      return hpsNative.gitCloneProgress();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'gitCloneProgress failed: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : String(e));
      return 0;
    }
  }

  /**
   * 测试远程仓库连通性与认证（不落地文件，仅 connect + ls-remote）
   */
  gitTestRemote(remoteUrl: string, username: string, password: string, proxyUrl: string,
    privateKeyPem: string, passphrase: string, knownHostFingerprint: string): NativeResult {
    return this.callSafely('gitTestRemote',
      (): NativeResult => hpsNative.gitTestRemote(remoteUrl, username, password, proxyUrl,
        privateKeyPem, passphrase, knownHostFingerprint));
  }

  /**
   * 拉取远程更新并合并到当前分支
   * @param rebase 'true' 时使用变基（保持线性历史），否则快进/普通合并
   */
  gitPull(localPath: string, username: string, password: string, proxyUrl: string, rebase: boolean,
          privateKeyPem: string, passphrase: string, knownHostFingerprint: string): NativeResult {
    return this.callSafely('gitPull',
      (): NativeResult => hpsNative.gitPull(localPath, username, password, proxyUrl, rebase ? 'true' : 'false',
        privateKeyPem, passphrase, knownHostFingerprint));
  }

  /**
   * 推送当前分支到远程
   * @param force '1' 时强制推送（覆盖远程分支历史，仓库管理「强制推送远程」专用）
   */
  gitPush(localPath: string, username: string, password: string, proxyUrl: string,
          privateKeyPem: string, passphrase: string, knownHostFingerprint: string,
          force: string): NativeResult {
    return this.callSafely('gitPush', (): NativeResult => hpsNative.gitPush(localPath, username, password, proxyUrl,
      privateKeyPem, passphrase, knownHostFingerprint, force));
  }

  gitCommitAll(localPath: string, message: string, authorName: string, authorEmail: string): NativeResult {
    return this.callSafely('gitCommitAll',
      (): NativeResult => hpsNative.gitCommitAll(localPath, message, authorName, authorEmail));
  }

  gitLog(localPath: string, limit: number): NativeResult {
    return this.callSafely('gitLog', (): NativeResult => hpsNative.gitLog(localPath, limit));
  }

  gitStatus(localPath: string): NativeResult {
    return this.callSafely('gitStatus', (): NativeResult => hpsNative.gitStatus(localPath));
  }

  /** 读取 origin 的实际 URL（用于判断拉取/推送走 HTTPS 还是 SSH） */
  gitRemoteUrl(localPath: string): NativeResult {
    return this.callSafely('gitRemoteUrl', (): NativeResult => hpsNative.gitRemoteUrl(localPath));
  }
}
