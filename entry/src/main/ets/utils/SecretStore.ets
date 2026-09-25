import { huks } from '@kit.UniversalKeystoreKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

/** hilog 域 */
const DOMAIN: number = 0x0001;
/** hilog 标签 */
const TAG: string = 'SecretStore';

/** 密钥别名：SSH 私钥与 Git 凭据各用一个，互不复用 */
const ALIAS_SSH_KEY: string = 'harmonypasswordstore_secret_ssh_key';
const ALIAS_GIT_CRED: string = 'harmonypasswordstore_secret_git_cred';

/** AES-GCM NONCE 长度（字节，规范要求 12 字节） */
const GCM_NONCE_LEN: number = 12;

/**
 * 落盘密文封装：base64(nonce || ciphertext||tag)
 */
interface Sealed {
  nonce: string;
  cipher: string;
}

/**
 * 应用内落盘凭据的加密存储
 *
 * SSH 私钥与 Git token 过去以明文写入沙箱文件/Preferences，而系统会按
 * `backup_config.json` 把应用数据纳进备份并外发——明文凭据因此可能离开设备。
 * 本类用 HUKS 生成的不可导出 AES-256-GCM 密钥把这类值封起来后再落盘：
 * 备份出的仍是密文，且密钥留在 HUKS 内，随备份迁移到别的设备也解不开。
 */
/** HUKS：密钥不存在（isKeyItemExist 在部分版本上以异常形式返回该码） */
const HUKS_ERR_NOT_EXIST: number = 12000011;
/** AES-GCM 认证标签长度（HUKS 固定 16 字节） */
const GCM_TAG_LEN: number = 16;

export class SecretStore {
  private static instance: SecretStore | null = null;

  private constructor() {
  }

  static getInstance(): SecretStore {
    if (!SecretStore.instance) {
      SecretStore.instance = new SecretStore();
    }
    return SecretStore.instance;
  }

  /**
   * 确保指定别名的 HUKS 密钥存在
   */
  private async ensureKey(alias: string): Promise<boolean> {
    const properties: huks.HuksParam[] = [
      { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
      { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
      {
        tag: huks.HuksTag.HUKS_TAG_PURPOSE,
        value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT | huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT,
      },
      { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_GCM },
      { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE },
      { tag: huks.HuksTag.HUKS_TAG_DIGEST, value: huks.HuksKeyDigest.HUKS_DIGEST_NONE },
    ];
    const options: huks.HuksOptions = { properties: properties };
    try {
      const exists: boolean = await huks.isKeyItemExist(alias, { properties: [] } as huks.HuksOptions);
      if (!exists) {
        await huks.generateKeyItem(alias, options);
      }
      return true;
    } catch (e) {
      // 实测（模拟器）：密钥**不存在**时 isKeyItemExist 会直接抛 BusinessError
      // 12000011（HUKS_ERROR_NOT_EXIST），而不是返回 false。原实现把它一并当失败返回，
      // 于是「首次封装任何凭据」都必然失败——git 令牌、SSH 私钥全部存不进去
      // （现象：配置保存后 password 为空、私钥只剩 .pub）。
      const code: number = (e as BusinessError).code;
      if (code === HUKS_ERR_NOT_EXIST) {
        try {
          await huks.generateKeyItem(alias, options);
          return true;
        } catch (e2) {
          hilog.error(DOMAIN, TAG, 'ensureKey generate failed for %{public}s: %{public}s',
            alias, JSON.stringify(e2));
          return false;
        }
      }
      hilog.error(DOMAIN, TAG, 'ensureKey failed for %{public}s: %{public}s', alias, JSON.stringify(e));
      return false;
    }
  }

  /**
   * 单次 AES-256-GCM 运算（一次性会话）
   *
   * 参数组合是设备实测出来的（曾用「HUKS 官方示例式」的写法，结果封印成功、
   * 解封恒失败），关键三点：
   * - **不要传 `HUKS_TAG_ASSOCIATED_DATA`**：哪怕是**空**的 Uint8Array 也会让
   *   参数集构建失败（`401 HksBuildParamSet fail`），加密解密都直接起不来。
   *   不需要 AAD 就整个不传。
   * - **解密的 `HUKS_TAG_AE_TAG` 必须与 `initSession` 一起给出**：HUKS 在 init
   *   阶段就固化本次会话的参数集，tag 只放在 finishSession 里会被判缺失
   *   （`401`）。这正是「封印成功、解封永远失败」的根因。
   * - `HUKS_TAG_KEY_SIZE` 与生成时一致地给出（实测无害），`DIGEST_NONE` 同理。
   *
   * @param encrypt true 加密（tag 由 outData 尾部返回）/ false 解密（须传 tag）
   * @returns 加密时为 `密文||tag`，解密时为明文；失败返回 null
   */
  private async gcmOnce(alias: string, encrypt: boolean, nonce: Uint8Array,
                        inData: Uint8Array, tag?: Uint8Array): Promise<Uint8Array | null> {
    const properties: huks.HuksParam[] = [
      { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
      { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
      {
        tag: huks.HuksTag.HUKS_TAG_PURPOSE,
        value: encrypt ? huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT : huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT,
      },
      { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_GCM },
      { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE },
      { tag: huks.HuksTag.HUKS_TAG_DIGEST, value: huks.HuksKeyDigest.HUKS_DIGEST_NONE },
      { tag: huks.HuksTag.HUKS_TAG_NONCE, value: nonce },
    ];
    if (tag !== undefined) {
      properties.push({ tag: huks.HuksTag.HUKS_TAG_AE_TAG, value: tag });
    }
    let handle: number = -1;
    try {
      const session = await huks.initSession(alias, { properties: properties, inData: inData });
      handle = session.handle;
      const finish = await huks.finishSession(handle, { properties: [], inData: inData });
      const out: Uint8Array | undefined = finish.outData as Uint8Array | undefined;
      if (out === undefined || out.length === 0) {
        hilog.error(DOMAIN, TAG, 'gcmOnce: empty result (encrypt=%{public}s)', `${encrypt}`);
        return null;
      }
      return out;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'gcmOnce failed (encrypt=%{public}s, step=%{public}s): code=%{public}d %{public}s',
        `${encrypt}`, handle < 0 ? 'init' : 'finish', err.code, err.message);
      return null;
    }
  }

  /**
   * 加密一段明文（内部生成随机 nonce）
   * @returns base64(nonce || ciphertext||tag)；失败返回空串
   */
  private async seal(alias: string, plaintext: string): Promise<string> {
    if (!(await this.ensureKey(alias))) {
      hilog.error(DOMAIN, TAG, 'seal: no key for %{public}s', alias);
      return '';
    }
    const nonce: Uint8Array = this.randomBytes(GCM_NONCE_LEN);
    if (nonce.length !== GCM_NONCE_LEN) {
      return '';
    }
    const out: Uint8Array | null =
      await this.gcmOnce(alias, true, nonce, new util.TextEncoder().encodeInto(plaintext));
    if (out === null) {
      return '';
    }
    // nonce 与密文拼接后整体 base64，落盘格式自解释，读取端无需额外元数据
    const packed: Uint8Array = new Uint8Array(nonce.length + out.length);
    packed.set(nonce, 0);
    packed.set(out, nonce.length);
    return this.toBase64(packed);
  }

  /**
   * 解密封装值
   * @returns 明文；失败返回空串（调用方须据此报错，不要当成"凭据为空"）
   */
  private async unseal(alias: string, sealed: string): Promise<string> {
    if (sealed.length === 0) {
      return '';
    }
    if (!(await this.ensureKey(alias))) {
      hilog.error(DOMAIN, TAG, 'unseal: no key for %{public}s', alias);
      return '';
    }
    let packed: Uint8Array;
    try {
      packed = this.fromBase64(sealed);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'unseal: base64 decode failed');
      return '';
    }
    if (packed.length <= GCM_NONCE_LEN + GCM_TAG_LEN) {
      return '';
    }
    const nonce: Uint8Array = packed.subarray(0, GCM_NONCE_LEN);
    const tag: Uint8Array = packed.subarray(packed.length - GCM_TAG_LEN);
    const cipher: Uint8Array = packed.subarray(GCM_NONCE_LEN, packed.length - GCM_TAG_LEN);
    const out: Uint8Array | null = await this.gcmOnce(alias, false, nonce, cipher, tag);
    if (out === null) {
      hilog.error(DOMAIN, TAG, 'unseal: 密文无法解开（HUKS 密钥已更换或密文损坏）');
      return '';
    }
    return util.TextDecoder.create('utf-8').decodeToString(out);
  }

  /** 加密 SSH 私钥 */
  async sealSshPrivateKey(pem: string): Promise<string> {
    return this.seal(ALIAS_SSH_KEY, pem);
  }

  /** 解密 SSH 私钥 */
  async unsealSshPrivateKey(sealed: string): Promise<string> {
    return this.unseal(ALIAS_SSH_KEY, sealed);
  }

  /** 加密 Git 凭据（HTTPS 密码或 token） */
  async sealGitCredential(secret: string): Promise<string> {
    return this.seal(ALIAS_GIT_CRED, secret);
  }

  /** 解密 Git 凭据 */
  async unsealGitCredential(sealed: string): Promise<string> {
    return this.unseal(ALIAS_GIT_CRED, sealed);
  }

  /**
   * 判断字符串是否为本类产出的封装格式
   *
   * 用于兼容升级前落盘的明文：老数据不是合法 base64(nonce||ct) 结构，
   * 直接 unseal 会失败，需走明文回退路径。
   */
  static looksSealed(value: string): boolean {
    return value.length > 0 && /^[A-Za-z0-9+/]+={0,2}$/.test(value) && value.length >= 24;
  }

  private randomBytes(len: number): Uint8Array {
    try {
      const rand: cryptoFramework.Random = cryptoFramework.createRandom();
      return rand.generateRandomSync(len).data;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'randomBytes failed: %{public}s', JSON.stringify(e));
      return new Uint8Array(0);
    }
  }

  private toBase64(bytes: Uint8Array): string {
    return new util.Base64Helper().encodeToStringSync(bytes);
  }

  private fromBase64(text: string): Uint8Array {
    return new util.Base64Helper().decodeSync(text);
  }
}
