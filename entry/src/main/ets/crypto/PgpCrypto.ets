/**
 * PGP 加解密接口
 *
 * 负责密码文件的加密与解密操作，管理 PGP 密钥。
 * 底层实现：通过 NAPI 桥接 native rpgp 库（纯 Rust OpenPGP，已集成）。
 */

import { GpgKeyId } from '../model/GpgKeyId';
import { NativeBridge, NativeResult } from '../common/NativeBridge';
import { PgpKeyManager } from './PgpKeyManager';
import { Strings } from '../common/Strings';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { taskpool } from '@kit.ArkTS';
import { invokeNativePgp } from '../utils/NativePgpTask';
import { dispatchPgpLocal, NativePgpRequest } from '../utils/NativePgpDispatch';

const DOMAIN = 0x0001;
const TAG = 'PgpCrypto';

/**
 * 加解密结果
 */
export interface CryptoResult {
  success: boolean;
  data: string;
  error: string;
}

/**
 * 解锁结果
 *
 * 必须带上失败原因：只返回 boolean 时，UI 只能笼统显示「密钥密码错误」，
 * 而真实原因可能是「导入的是公钥」「密钥文件缺失」等——用户会误以为
 * 口令不对而反复重试，无从定位。
 */
export interface UnlockResult {
  success: boolean;
  /** 失败原因（success 为 true 时为空串） */
  error: string;
}

/**
 * PGP 加解密操作接口
 */
export interface PgpCryptoInterface {
  /** 加密文本为 PGP 格式，使用指定密钥指纹列表 */
  encrypt(plaintext: string, keyFingerprints: string[]): Promise<CryptoResult>;

  /**
   * 解密 PGP 加密文本，返回明文
   *
   * 按候选密钥逐一尝试，首把成功即返回——每条密码由各自目录 .gpg-id
   * 指定的密钥加密，不能用全局单一会话的密钥张冠李戴。
   * @param ciphertext armored 密文
   * @param candidateFingerprints 候选解密密钥指纹（通常来自条目所属 .gpg-id），
   *        空/未传时回退到已解锁密钥 + 默认密钥 + 全部私钥
   */
  decrypt(ciphertext: string, candidateFingerprints?: string[]): Promise<CryptoResult>;

  /** 导入 ASCII-armored 私钥备份 */
  importSecretKey(armoredKey: string, passphrase: string): Promise<CryptoResult>;

  /** 列出本地已导入的密钥 */
  listKeys(isSecret: boolean): Promise<GpgKeyId[]>;

  /** 删除指定指纹的密钥 */
  deleteKey(fingerprint: string): Promise<boolean>;

  /** 导出公钥（ASCII-armored 格式） */
  exportPublicKey(fingerprint: string): Promise<string>;

  /** 使用 passphrase 解锁私钥，缓存会话密钥用于快速解锁 */
  unlockPassphrase(fingerprint: string, passphrase: string): Promise<UnlockResult>;

  /**
   * 确保候选密钥可用于解密：已解锁直接成功；未解锁时用空密码试探
   * （无密码保护的密钥免输入，不应弹「请输入密钥密码」）
   * @param candidateFingerprints 候选密钥（通常来自条目所属 .gpg-id），空则用默认 + 全部私钥
   */
  ensureUnlocked(candidateFingerprints?: string[]): Promise<boolean>;

  /** 检查候选密钥中是否已有解锁的；未传/空则检查是否存在任一已解锁密钥 */
  isUnlockedFor(candidateFingerprints: string[]): boolean;

  /** 检查是否存在任一已解锁密钥 */
  isUnlocked(): boolean;

  /** 清除所有已缓存的会话密码，锁定 */
  lock(): void;
}

/**
 * PGP 加解密实现
 *
 * 通过 NativeBridge 调用 native rpgp 桥接（encrypt/decrypt/verifyPassphrase）；
 * 密钥管理委托 PgpKeyManager（import/listKeys/deleteKey/exportPublicKey）。
 * native 调用异常时 callSafely 返回失败结果，调用方优雅降级。
 */
export class PgpCrypto implements PgpCryptoInterface {
  private static instance: PgpCrypto | null = null;

  static getInstance(): PgpCrypto {
    if (!PgpCrypto.instance) {
      PgpCrypto.instance = new PgpCrypto();
    }
    return PgpCrypto.instance;
  }

  /**
   * 已解锁密钥的密码缓存（内存态，进程退出即失效）
   *
   * key = 密钥指纹，value = 该密钥的密码（无密码保护的密钥缓存空串）。
   * 每条密码由各自目录 .gpg-id 指定的密钥加密，必须按密钥分别记忆密码，
   * 否则用 A 密钥解锁后再解密 B 密钥的密文会张冠李戴、并污染全局会话。
   */
  private passphraseCache: Map<string, string> = new Map<string, string>();

  /** 去重追加候选指纹 */
  private static addUnique(list: string[], fingerprint: string): void {
    if (fingerprint.length > 0 && list.indexOf(fingerprint) < 0) {
      list.push(fingerprint);
    }
  }

  /**
   * 该密钥是否含 GnuPG algo 8（PQC）加密子密钥。
   *
   * 这类密钥的 v5 子密钥包会被 rpgp 静默丢弃，解密与口令校验
   * 都必须改走 native 的 gpg_pqc 独立模块。
   */
  private isGpgPqcKey(fingerprint: string): boolean {
    const key: GpgKeyId | null = PgpKeyManager.getInstance().findKey(fingerprint);
    // 曲线未实现的 algo 8 密钥不能走 native 路径：那条路径只实现了
    // X25519 / brainpoolP256r1 / brainpoolP384r1，其余会以难懂的错误失败
    return key !== null && key.gpgPqc && key.gpgPqcUsable;
  }

  /**
   * 用指定密钥解密（按密钥类型选择 native 入口）
   *
   * - 普通密钥：rpgp 的 pgpDecrypt
   * - GnuPG algo 8（PQC）密钥：gpg_pqc 独立模块的 pgpDecryptGpgPqc
   *
   * native 调用经 TaskPool 下发：重加密会逐条解密大量条目，S2K/OCB/ML-KEM
   * 都是 CPU 密集操作，留在主线程会把界面卡死（真机实测被 watchdog 终止）。
   */
  private async decryptWithKey(fingerprint: string, ciphertext: string,
    secretKeyArmored: string, passphrase: string): Promise<NativeResult> {
    if (this.isGpgPqcKey(fingerprint)) {
      return this.callPgp('pgpDecryptGpgPqc', [ciphertext, secretKeyArmored, passphrase]);
    }
    return this.callPgp('pgpDecrypt', [ciphertext, secretKeyArmored, passphrase]);
  }

  /**
   * 校验指定密钥的口令（按密钥类型选择 native 入口）
   *
   * rpgp 丢弃 v5 子密钥包，无法校验 GnuPG algo 8 子密钥的保护段，
   * 故这类密钥改由 gpg_pqc 模块尝试解出材料来判定。同样经 TaskPool 下发。
   */
  private async verifyPassphraseWithKey(fingerprint: string, secretKeyArmored: string,
    passphrase: string): Promise<NativeResult> {
    if (this.isGpgPqcKey(fingerprint)) {
      return this.callPgp('pgpGpgPqcVerifyPassphrase', [secretKeyArmored, passphrase]);
    }
    return this.callPgp('pgpVerifyPassphrase', [secretKeyArmored, passphrase]);
  }

  /**
   * 把 PGP native 调用分发到 TaskPool 工作线程
   *
   * 只承载「字符串入 → NativeResult 出」的纯调用（参数见 NativePgpDispatch）；
   * taskpool 分发失败时回退主线程同步直调——正确性优先于流畅性，
   * 宁可卡顿也不能让重加密中途失败。
   */
  private async callPgp(fn: string, args: string[]): Promise<NativeResult> {
    const req: NativePgpRequest = { fn: fn, args: args };
    try {
      return await taskpool.execute(invokeNativePgp, req) as NativeResult;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'taskpool dispatch failed for %{public}s, fallback to main thread: %{public}s',
        fn, e instanceof Error ? `${e.name}: ${e.message}` : String(e));
      return dispatchPgpLocal(fn, args);
    }
  }

  /**
   * 构造解密候选密钥顺序：
   * 1) .gpg-id 指定的候选密钥（优先，逐把尝试）
   * 2) 已解锁（含空密码免密）的密钥
   * 3) 默认密钥
   * 4) 兜底：全部已导入私钥
   */
  /**
   * 提取密文的收件人 Key ID（native 解析 PKESK，算法无关）
   *
   * 无 PKESK（对称加密）或全为隐藏收件人时返回空数组。
   */
  recipientKeyIds(ciphertext: string): string[] {
    if (ciphertext.length === 0) {
      return [];
    }
    const res: NativeResult = NativeBridge.getInstance().pgpRecipientKeyIds(ciphertext);
    if (!res.success || res.data.length === 0) {
      return [];
    }
    return res.data.split(',').filter((s: string) => s.length > 0);
  }

  /**
   * 提取密文的收件人 Key ID（native 解析 PKESK，算法无关）——**TaskPool 版本**
   *
   * 重加密预扫会对子树里每条条目各解析一次，条目多时同步版会把主线程
   * 卡住（真机实测 freeze），故预扫一律走本方法；单条目快路径
   * （点击条目弹口令框）仍可用同步版 `recipientKeyIds`。
   * 无 PKESK（对称加密）或全为隐藏收件人时返回空数组。
   */
  async recipientKeyIdsAsync(ciphertext: string): Promise<string[]> {
    if (ciphertext.length === 0) {
      return [];
    }
    const res: NativeResult = await this.callPgp('pgpRecipientKeyIds', [ciphertext]);
    if (!res.success || res.data.length === 0) {
      return [];
    }
    return res.data.split(',').filter((s: string) => s.length > 0);
  }

  /**
   * 按收件人 Key ID 集合匹配已导入密钥（纯缓存查找，无 native 调用）
   *
   * 从 `keysForCiphertext` 抽出：预扫已经拿到 Key ID（经 TaskPool 异步解析），
   * 匹配这步只查主线程密钥缓存，无需再为它付一次同步 native 解析的代价。
   */
  keysForIds(ids: string[]): string[] {
    const out: string[] = [];
    for (let i: number = 0; i < ids.length; i++) {
      const key: GpgKeyId | null = PgpKeyManager.getInstance().findByEncryptionKeyId(ids[i]);
      if (key !== null) {
        PgpCrypto.addUnique(out, key.fingerprint);
      }
    }
    // 静默失败曾是排查盲区：密文收件人解析出来了却一个都没匹配上时，
    // 上层只会报「缺少解密密钥」，看不出是「没导入」还是「匹配字段不对」
    if (ids.length > 0 && out.length === 0) {
      hilog.warn(DOMAIN, TAG,
        'keysForIds: no imported key matches PKESK ids=[%{public}s]',
        ids.join(','));
    }
    return out;
  }

  /**
   * 该密文**实际**由哪些已导入密钥加密（按 PKESK 的收件人 Key ID 匹配）
   *
   * 这是解密选密钥的权威依据（`pass` 的 `gpg --decrypt --list-only` 同理）：
   * `.gpg-id` 只决定加密时的接收方，改过 `.gpg-id`（换密钥）后旧条目仍由旧密钥
   * 加密——只有按密文判定才能索取正确的口令。
   */
  keysForCiphertext(ciphertext: string): string[] {
    const ids: string[] = this.recipientKeyIds(ciphertext);
    return this.keysForIds(ids);
  }

  /**
   * 条目解密的候选密钥（供解锁弹窗判断该向用户索取哪把密钥的口令）
   *
   * 顺序：① 密文实际收件人（权威）→ ② .gpg-id 指定（兜底：隐藏收件人时无 ①）。
   * 返回空表示**没有任何已导入密钥**能解该条目，此时应明确告知用户
   * （而不是反复索取口令）。
   */
  entryDecryptionCandidates(ciphertext: string, gpgIdFingerprints: string[]): string[] {
    const out: string[] = [];
    const byCipher: string[] = this.keysForCiphertext(ciphertext);
    for (let i: number = 0; i < byCipher.length; i++) {
      PgpCrypto.addUnique(out, byCipher[i]);
    }
    for (let i: number = 0; i < gpgIdFingerprints.length; i++) {
      const resolved: GpgKeyId | null =
        PgpKeyManager.getInstance().resolveKeyByIdEntry(gpgIdFingerprints[i]);
      if (resolved !== null) {
        PgpCrypto.addUnique(out, resolved.fingerprint);
      }
    }
    return out;
  }

  private buildCandidateOrder(keys: GpgKeyId[], candidateFingerprints?: string[],
    preferred: string[] = []): string[] {
    const ordered: string[] = [];
    // ① 密文实际收件人优先：换过 .gpg-id 的旧条目由旧密钥加密，必须先用它
    for (let i: number = 0; i < preferred.length; i++) {
      PgpCrypto.addUnique(ordered, preferred[i]);
    }
    if (candidateFingerprints !== undefined) {
      for (let i: number = 0; i < candidateFingerprints.length; i++) {
        // 兼容 .gpg-id 中的 KeyID / 小写指纹，统一解析为标准密钥
        const resolved: GpgKeyId | null = PgpKeyManager.getInstance().resolveKeyByIdEntry(candidateFingerprints[i]);
        if (resolved !== null) {
          PgpCrypto.addUnique(ordered, resolved.fingerprint);
        }
      }
    }

    const unlocked: string[] = [];
    this.passphraseCache.forEach((_pass: string, fp: string): void => {
      unlocked.push(fp);
    });
    for (let i: number = 0; i < unlocked.length; i++) {
      PgpCrypto.addUnique(ordered, unlocked[i]);
    }

    PgpCrypto.addUnique(ordered, PgpKeyManager.getInstance().getDefaultKeyFingerprint());

    for (let i: number = 0; i < keys.length; i++) {
      PgpCrypto.addUnique(ordered, keys[i].fingerprint);
    }
    return ordered;
  }

  async encrypt(plaintext: string, keyFingerprints: string[]): Promise<CryptoResult> {
    // 按密钥类型分流：
    // - 普通密钥：走 rpgp（pgpEncrypt），公钥经 rpgp 导出
    // - GnuPG algo 8（PQC）密钥：rpgp 的 to_public_key 会丢掉 v5 子密钥，
    //   必须直接传原始 armored（其公钥部分足够加密），走独立模块
    const pqcArmored: string[] = [];
    const normalArmored: string[] = [];
    if (keyFingerprints.length > 0) {
      for (let i: number = 0; i < keyFingerprints.length; i++) {
        // 兼容 .gpg-id 中的 KeyID / 小写指纹，统一解析为标准密钥
        const key: GpgKeyId | null = PgpKeyManager.getInstance().resolveKeyByIdEntry(keyFingerprints[i]);
        if (key === null) {
          continue;
        }
        if (key.gpgPqc) {
          // 关键：用原始存储的 armored，**不要**经 exportPublicKey（rpgp 会丢 v5 子密钥）
          const raw: string = PgpKeyManager.getInstance().getKeyArmored(key.fingerprint);
          if (raw.length > 0) {
            pqcArmored.push(raw);
          }
          continue;
        }
        const armored: string = await PgpKeyManager.getInstance().exportPublicKey(key.fingerprint);
        if (armored.length > 0) {
          normalArmored.push(armored);
        }
      }
    }

    // 混合场景（同一目录同时指定 gpgPqc 与普通密钥）：两类接收方共用同一会话密钥，
    // 普通密钥的 PKESK 由 rpgp 构造、algo 8 的由 gpg_pqc 自建，明文只加密一次。
    // pass 本身支持多密钥（set_gpg_recipients 为每行各加一个 -r），故此处必须支持。
    if (pqcArmored.length > 0 && normalArmored.length > 0) {
      const mixed = await this.callPgp('pgpEncryptMixed',
        [plaintext, pqcArmored.join('\n'), normalArmored.join('\n')]);
      return { success: mixed.success, data: mixed.data, error: mixed.error };
    }

    if (pqcArmored.length > 0) {
      // GnuPG algo 8：走 native 独立模块（PKESK(algo 8) + SEIPDv1），支持多接收方
      const pqcResult = await this.callPgp('pgpEncryptGpgPqc', [plaintext, pqcArmored.join('\n')]);
      return { success: pqcResult.success, data: pqcResult.data, error: pqcResult.error };
    }

    const publicKeyArmored: string = normalArmored.join('\n');
    if (publicKeyArmored.length === 0) {
      return { success: false, data: '', error: Strings.get('pgp_no_public_key') };
    }
    const result = await this.callPgp('pgpEncrypt', [plaintext, publicKeyArmored]);
    return { success: result.success, data: result.data, error: result.error };
  }

  /**
   * 解密：按候选密钥顺序逐一尝试，首把成功即返回。
   *
   * 候选顺序见 buildCandidateOrder()——.gpg-id 指定的密钥最优先。
   * 只有缓存在 passphraseCache 中的密钥才会带上其密码尝试；
   * 未缓存的密钥先用空密码尝试（覆盖无密码保护的密钥），失败则跳过，
   * 由上层在全部失败时弹框索取密码（避免用错密钥/错密码反复污染会话）。
   *
   * @param preferredFingerprints 密文收件人对应的已导入密钥指纹。**调用方已经解析过
   *        收件人时必须传**（重加密管线的预扫结果就是逐条经 TaskPool 解析出来的）：
   *        不传则本方法会用同步 native 解析一遍 PKESK，在逐条循环里重新拖住主线程。
   */
  async decrypt(ciphertext: string, candidateFingerprints?: string[],
    preferredFingerprints?: string[]): Promise<CryptoResult> {
    const keys: GpgKeyId[] = await PgpKeyManager.getInstance().listKeys(true);
    if (keys.length === 0) {
      return { success: false, data: '', error: Strings.get('pgp_no_secret_key') };
    }

    // 先按密文的收件人 Key ID 找出真正能解的密钥（换过 .gpg-id 时 .gpg-id 会指向别的密钥）
    const preferred: string[] = preferredFingerprints !== undefined
      ? preferredFingerprints
      : this.keysForCiphertext(ciphertext);
    const order: string[] = this.buildCandidateOrder(keys, candidateFingerprints, preferred);
    let lastError: string = Strings.get('common_decrypt_failed');
    for (let i: number = 0; i < order.length; i++) {
      const fp: string = order[i];
      const secretKeyArmored: string = PgpKeyManager.getInstance().getKeyArmored(fp);
      if (secretKeyArmored.length === 0) {
        continue;
      }
      // 已缓存密码的密钥用其密码；未缓存的先用空密码试探（无密码保护的密钥可直接解）
      const cached: string | undefined = this.passphraseCache.get(fp);
      const candidatePasses: string[] = cached !== undefined ? [cached] : [''];

      for (let j: number = 0; j < candidatePasses.length; j++) {
        const passphrase: string = candidatePasses[j];
        hilog.info(DOMAIN, TAG, 'decrypt: try key=%{public}s cached=%{public}s',
          fp.substring(fp.length - 8), cached !== undefined ? 'yes' : 'no');
        const result = await this.decryptWithKey(fp, ciphertext, secretKeyArmored, passphrase);
        if (result.success) {
          if (cached === undefined) {
            // 空密码试探成功 = 该密钥无密码保护，记住以免每次重试
            this.passphraseCache.set(fp, passphrase);
          }
          return { success: true, data: result.data, error: '' };
        }
        lastError = result.error;
      }
    }

    hilog.warn(DOMAIN, TAG, 'decrypt: all %{public}d candidate keys failed', order.length);
    return { success: false, data: '', error: lastError };
  }

  async importSecretKey(armoredKey: string, passphrase: string): Promise<CryptoResult> {
    const result = await PgpKeyManager.getInstance().importSecretKey(armoredKey, passphrase);
    return { success: result.success, data: '', error: result.error };
  }

  async listKeys(isSecret: boolean): Promise<GpgKeyId[]> {
    return PgpKeyManager.getInstance().listKeys(isSecret);
  }

  async deleteKey(fingerprint: string): Promise<boolean> {
    return PgpKeyManager.getInstance().deleteKey(fingerprint);
  }

  async exportPublicKey(fingerprint: string): Promise<string> {
    return PgpKeyManager.getInstance().exportPublicKey(fingerprint);
  }

  async unlockPassphrase(fingerprint: string, passphrase: string): Promise<UnlockResult> {
    if (passphrase.length === 0) {
      hilog.warn(DOMAIN, TAG, 'unlockPassphrase: empty passphrase');
      return { success: false, error: Strings.get('common_enter_passphrase') };
    }

    // 检查密钥是否已导入
    const keys: GpgKeyId[] = await this.listKeys(true);
    if (keys.length === 0) {
      hilog.warn(DOMAIN, TAG, 'unlockPassphrase: no secret keys imported');
      return { success: false, error: Strings.get('pgp_no_secret_imported') };
    }

    // 兼容旧数据：defaultKeyFingerprint 为空或指向已不存在的密钥时
    // （密钥被重建/重置后设置残留旧值），回退到第一把已导入私钥，
    // 并把默认指纹补写回设置（自愈）
    let fp: string = fingerprint;
    let found: GpgKeyId | undefined = keys.find((k: GpgKeyId) => k.fingerprint === fp);
    if (found === undefined) {
      fp = keys[0].fingerprint;
      await PgpKeyManager.getInstance().setDefaultKey(fp);
      hilog.info(DOMAIN, TAG, 'unlockPassphrase: defaultKeyFingerprint %{public}s missing/stale, fallback to %{public}s',
        fingerprint.length > 0 ? fingerprint : '(empty)', fp);
      found = keys.find((k: GpgKeyId) => k.fingerprint === fp);
    }
    if (found === undefined) {
      hilog.warn(DOMAIN, TAG, 'unlockPassphrase: fingerprint not found after fallback');
      return { success: false, error: Strings.get('pgp_key_not_found_reimport') };
    }

    // 通过 native 验证 passphrase（rpgp 或 gpg_pqc 模块，按密钥类型分发）
    const secretKeyArmored: string = PgpKeyManager.getInstance().getKeyArmored(fp);
    if (secretKeyArmored.length === 0) {
      hilog.warn(DOMAIN, TAG, 'unlockPassphrase: key armored file missing for %{public}s', fp);
      return { success: false, error: Strings.get('pgp_key_file_missing') };
    }
    const result = await this.verifyPassphraseWithKey(fp, secretKeyArmored, passphrase);
    if (!result.success) {
      hilog.warn(DOMAIN, TAG, 'unlockPassphrase: native verify failed: %{public}s', result.error);
      // 透传 native 的真实原因（如「缺少私钥段」= 导入的是公钥），
      // 不再一律归为「密码错误」——否则用户无从定位
      return { success: false, error: PgpCrypto.describeVerifyError(result.error) };
    }

    this.passphraseCache.set(fp, passphrase);
    return { success: true, error: '' };
  }

  /**
   * 把 native 的校验失败原因翻译成用户能理解并据此行动的提示
   *
   * native 的错误多为英文/技术性描述，直接展示无助于用户；
   * 但完全丢弃又会让「导入的是公钥」这类可修复问题伪装成「密码错误」。
   */
  private static describeVerifyError(nativeError: string): string {
    if (nativeError.length === 0) {
      return Strings.get('common_passphrase_wrong');
    }
    // 公钥没有私钥段：这是导入环节的问题，不是密码错
    if (nativeError.includes('缺少私钥段')) {
      return Strings.get('pgp_verify_no_secret_material');
    }
    if (nativeError.includes('未找到 GnuPG algo 8')) {
      return Strings.get('pgp_verify_no_mlkem_material');
    }
    // ML-KEM 私钥材料读取失败：**口令此时已经通过**（同一口令的 ECC 段已解开，
    // native 侧按段标注了失败位置），属密钥编码/格式问题，
    // 绝不能再报「密码错误」——否则用户会反复重试一个正确的口令。
    // gpg 2.5.x 对 ML-KEM 私钥有多个变体（明文 seed / 加密展开私钥 /
    // protected 位于 kyber768 列表内外 / 外层 composite-key），支持不全是
    // 「口令正确却被拒」的根因。
    if (nativeError.includes('ML-KEM') || nativeError.includes('kyber')) {
      return Strings.fmt('pgp_verify_mlkem_unreadable', nativeError);
    }
    // 经典曲线不支持：brainpool 系（ky768_bp256 / ky1024_bp384/512）的点是 65 字节，
    // 而 native 的 algo 8 只实现了 X25519（32 字节），必然报长度异常。
    // 这同样不是口令问题——报「密码错误」会让用户反复重试。
    if (nativeError.includes('ECC 公钥点长度异常') || nativeError.includes('X25519 材料长度必须')) {
      return Strings.fmt('pgp_verify_curve_unsupported', nativeError);
    }
    // 其余情况（ECC 段 OCB 认证失败等）最可能就是口令不对
    return Strings.get('common_passphrase_wrong');
  }

  /**
   * 确保候选密钥可用于解密（无密码密钥免输入）：
   * 逐一检查候选密钥，已缓存密码的直接通过；未缓存的用空密码试探一次，
   * 通过即说明该密钥无密码保护，缓存空密码并返回成功——
   * 避免无密码密钥仍弹出「请输入密钥密码」。
   * 全部候选都无法免密解锁时返回 false，由上层弹框索取密码。
   */
  async ensureUnlocked(candidateFingerprints?: string[]): Promise<boolean> {
    const keys: GpgKeyId[] = await PgpKeyManager.getInstance().listKeys(true);
    if (keys.length === 0) {
      return false;
    }

    // 严格只检查本条目的候选密钥：
    // 若兜底到「默认密钥 + 全部私钥」，只要任意一把无关密钥已解锁/无密码就会放行，
    // 结果跳进详情页才解密失败、把密码框显示在页面中间。
    // 只有 .gpg-id 解析不出候选时才回退到全部私钥（无候选可依）。
    const resolved: string[] = candidateFingerprints !== undefined && candidateFingerprints.length > 0
      ? PgpKeyManager.getInstance().resolvedKeyFingerprints(candidateFingerprints)
      : [];
    const order: string[] = resolved.length > 0
      ? resolved
      : this.buildCandidateOrder(keys);

    for (let i: number = 0; i < order.length; i++) {
      const fp: string = order[i];
      if (this.passphraseCache.has(fp)) {
        return true;
      }
      const secretKeyArmored: string = PgpKeyManager.getInstance().getKeyArmored(fp);
      if (secretKeyArmored.length === 0) {
        continue;
      }
      // 空密码验证成功即表示私钥未加密（无密码保护）
      const result = await this.verifyPassphraseWithKey(fp, secretKeyArmored, '');
      if (result.success) {
        this.passphraseCache.set(fp, '');
        hilog.info(DOMAIN, TAG, 'ensureUnlocked: key %{public}s has no passphrase, auto-unlocked',
          fp.substring(fp.length - 8));
        return true;
      }
    }
    return false;
  }

  /**
   * 获取指定密钥已缓存的密码（未缓存返回 undefined）
   */
  getPassphrase(fingerprint: string): string | undefined {
    return this.passphraseCache.get(fingerprint);
  }

  /** 候选密钥中是否已有可用（已缓存密码）的密钥 */
  isUnlockedFor(candidateFingerprints: string[]): boolean {
    for (let i: number = 0; i < candidateFingerprints.length; i++) {
      const resolved: GpgKeyId | null = PgpKeyManager.getInstance().resolveKeyByIdEntry(candidateFingerprints[i]);
      if (resolved !== null && this.passphraseCache.has(resolved.fingerprint)) {
        return true;
      }
    }
    return false;
  }

  isUnlocked(): boolean {
    return this.passphraseCache.size > 0;
  }

  /**
   * 忘掉指定密钥已缓存的密码
   *
   * 改密钥口令后必须调用：缓存里还是旧口令，留着它只会让后续解密
   * 反复用一把已经失效的钥匙去试（表现成莫名加解密失败）。
   */
  forgetPassphrase(fingerprint: string): void {
    if (this.passphraseCache.delete(fingerprint)) {
      hilog.info(DOMAIN, TAG, 'forgetPassphrase: dropped cache for %{public}s',
        fingerprint.substring(fingerprint.length - 8));
    }
  }

  lock(): void {
    this.passphraseCache.clear();
  }
}
