import { SshKeyType } from '../common/Constants';
import { FileUtils } from '../utils/FileUtils';
import { SecretStore } from '../utils/SecretStore';
import { NativeBridge, NativeResult } from '../common/NativeBridge';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';

/** hilog 域 */
const DOMAIN: number = 0x0001;
/** hilog 标签 */
const TAG: string = 'SshKeyManager';

/** SSH 密钥存储目录名 */
const SSH_KEYS_DIR: string = 'ssh_keys';

/**
 * SSH 密钥信息
 */
export interface SshKeyInfo {
  /** 密钥别名（也是私钥/公钥文件名前缀） */
  alias: string;
  /** 密钥类型 */
  keyType: SshKeyType;
  /** 公钥 OpenSSH 格式文本（如 ssh-ed25519 AAAA... comment） */
  publicKey: string;
  /** 创建时间（Unix 毫秒） */
  createdAt: number;
  /**
   * 邮箱 / 标识（列表主标题）
   *
   * 生成时来自注释；导入时来自「邮箱/标识」输入，
   * 为空则回退公钥末尾的 comment 或私钥文件名。
   */
  email: string;
  /**
   * 是否持有私钥
   *
   * 只有公钥时无法通过 SSH 认证访问 Git 服务器，
   * 因此导入必须同时包含私钥（公钥由私钥推导）。
   */
  hasPrivateKey: boolean;
}

/**
 * 私钥状态探测结果（native sshKeyStatus 返回的 JSON 结构）
 */
export interface SshKeyStatus {
  /** 是否为有效私钥 */
  valid: boolean;
  /** 是否已加密（需口令） */
  encrypted: boolean;
  /** 无效时的原因 */
  error: string;
}

/**
 * SSH 密钥操作结果
 */
export interface SshKeyResult {
  success: boolean;
  error: string;
}

/**
 * SSH 密钥管理器
 *
 * 负责 SSH 密钥的生成、导入、导出公钥、列出与删除。
 * 私钥落盘前经 SecretStore 用 HUKS 不可导出密钥加密（系统会备份应用数据，
 * 明文私钥会随之外发）；公钥以 OpenSSH 格式明文存于应用沙箱。
 */
/** native 生成密钥的返回结构（hps_ssh_generate_key 的 JSON） */
export interface SshGeneratedKey {
  /** OpenSSH 私钥 PEM（未加密） */
  privateKeyPem: string;
  /** OpenSSH 公钥单行（含注释） */
  publicKey: string;
}

export class SshKeyManager {
  private static instance: SshKeyManager | null = null;

  /** 私钥内存缓存（alias → PriKey），进程退出即失效 */
  private privateKeyCache: Map<string, cryptoFramework.PriKey> = new Map();

  private constructor() {
  }

  static getInstance(): SshKeyManager {
    if (!SshKeyManager.instance) {
      SshKeyManager.instance = new SshKeyManager();
    }
    return SshKeyManager.instance;
  }

  /**
   * 获取 SSH 公钥存储目录
   */
  private getKeysDir(): string {
    return `${FileUtils.getFilesDir()}/${SSH_KEYS_DIR}`;
  }

  /**
   * 根据密钥类型生成 HUKS 密钥别名
   */
  static buildKeyAlias(keyType: SshKeyType): string {
    const typePrefix: string = keyType === SshKeyType.RSA ? 'rsa'
      : keyType === SshKeyType.ECDSA ? 'ecdsa' : 'ed25519';
    return `ssh_${typePrefix}_${Date.now()}`;
  }

  /**
   * 当前是否已存在 SSH 密钥
   *
   * SSH 密钥只保留一把：新建/导入前用它判断是否需要提示替换。
   */
  hasKey(): boolean {
    return this.listKeys().length > 0;
  }

  /**
   * 移除全部已有密钥（私钥缓存 + 落盘公钥）
   *
   * 供「新建/导入替换旧密钥」使用：SSH 密钥只保留一把，
   * 写入新密钥前先清掉旧的，避免同时存在两把导致认证用错密钥。
   */
  private async removeAllKeys(): Promise<void> {
    const keys: SshKeyInfo[] = this.listKeys();
    for (let i: number = 0; i < keys.length; i++) {
      await this.deleteKey(keys[i].alias);
    }
    // 兜底：清掉可能残留的私钥缓存（含未落盘公钥的条目）
    this.privateKeyCache.clear();
  }

  /**
   * 获取密钥类型对应的 cryptoFramework 算法规格
   */
  private getAlgSpec(keyType: SshKeyType): string {
    switch (keyType) {
      case SshKeyType.RSA:
        return 'RSA3072';
      case SshKeyType.ECDSA:
        return 'ECC256';
      case SshKeyType.ED25519:
      default:
        return 'Ed25519';
    }
  }

  /**
   * 获取 OpenSSH 算法名
   */
  private getOpenSshAlgName(keyType: SshKeyType): string {
    switch (keyType) {
      case SshKeyType.RSA:
        return 'ssh-rsa';
      case SshKeyType.ECDSA:
        return 'ecdsa-sha2-nistp256';
      case SshKeyType.ED25519:
      default:
        return 'ssh-ed25519';
    }
  }

  /**
   * 生成新的 SSH 密钥对
   *
   * 私钥暂存内存缓存（native libssh2 就绪后改为 HUKS 托管），
   * 公钥以 OpenSSH 格式落盘。
   * @param keyType 密钥类型
   * @param comment 公钥注释（通常为邮箱）
   * @returns 密钥信息（失败时返回 null）
   */
  async generateKeyPair(keyType: SshKeyType, comment: string): Promise<SshKeyInfo | null> {
    const alias: string = SshKeyManager.buildKeyAlias(keyType);
    try {
      // 私钥必须**在 native 侧生成**：cryptoFramework 生成的 Ed25519 私钥无法导出
      // （getEncoded / getEncodedDer('PKCS8') 均不支持），重启后私钥就没了——
      // 曾因此只留下 .pub，用户注册到远端的公钥再也配不上对。
      // native 侧直接产出标准 OpenSSH PEM，可落盘（HUKS 封装）供克隆/同步长期使用。
      const generated: NativeResult = NativeBridge.getInstance().sshGenerateKey(comment);
      if (!generated.success || generated.data.length === 0) {
        hilog.error(DOMAIN, TAG, 'generateKeyPair: native failed: %{public}s', generated.error);
        return null;
      }
      let pem: string = '';
      let openSshPubKey: string = '';
      try {
        const parsed: SshGeneratedKey = JSON.parse(generated.data) as SshGeneratedKey;
        pem = parsed.privateKeyPem ?? '';
        openSshPubKey = parsed.publicKey ?? '';
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'generateKeyPair: parse result failed');
        return null;
      }
      if (pem.length === 0 || openSshPubKey.length === 0) {
        hilog.error(DOMAIN, TAG, 'generateKeyPair: empty key material');
        return null;
      }

      // SSH 密钥只保留一把：生成成功后先清掉旧密钥，再写入新的
      await this.removeAllKeys();

      const keysDir: string = this.getKeysDir();
      FileUtils.ensureDir(keysDir);

      // 私钥 HUKS 封装后落盘（明文私钥会随系统备份外发）
      const sealedPrivate: string = await SecretStore.getInstance().sealSshPrivateKey(pem);
      if (sealedPrivate.length === 0) {
        hilog.error(DOMAIN, TAG, 'generateKeyPair: seal private key failed');
        return null;
      }
      FileUtils.writeTextFile(`${keysDir}/${alias}.key`, sealedPrivate);
      FileUtils.writeTextFile(`${keysDir}/${alias}.pub`, openSshPubKey);
      // 邮箱/注释单独落盘：公钥的 comment 只作展示，不能作为回读来源
      FileUtils.writeTextFile(`${keysDir}/${alias}.email`, comment);

      hilog.info(DOMAIN, TAG, 'generateKeyPair: alias=%{public}s (native, persisted)', alias);

      return {
        alias: alias,
        keyType: keyType,
        publicKey: openSshPubKey,
        createdAt: Date.now(),
        email: comment,
        hasPrivateKey: true,
      };
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'generateKeyPair failed: %{public}s',
        e instanceof Error ? e.message : String(e));
      return null;
    }
  }

  /**
   * 构造 OpenSSH 格式公钥文本
   *
   * 格式：<algorithm> <base64(wire_format)> <comment>
   *
   * wire format 由若干 SSH mpint/string 拼接，每段前 4 字节大端长度。
   */
  private buildOpenSshPublicKey(keyType: SshKeyType, derBytes: Uint8Array, comment: string): string {
    const algName: string = this.getOpenSshAlgName(keyType);
    let wireBytes: Uint8Array;

    if (keyType === SshKeyType.ED25519) {
      // Ed25519: 从 DER 中提取 32 字节公钥点
      // Ed25519 公钥 DER 格式：SPKI 头(12 字节) + 32 字节公钥
      const pubKeyBytes: Uint8Array = derBytes.length >= 44 ? derBytes.subarray(12) : derBytes;
      wireBytes = this.encodeOpenSshString(algName, this.encodeOpenSshString2(pubKeyBytes));
    } else if (keyType === SshKeyType.RSA) {
      // RSA: 从 DER 中提取 公钥(n, e)
      // 简化处理：直接用 DER 原始数据作为占位（native libssh2 就绪后替换为精确解析）
      wireBytes = this.encodeOpenSshString(algName, derBytes);
    } else {
      // ECDSA: 简化处理
      wireBytes = this.encodeOpenSshString(algName, derBytes);
    }

    const base64Str: string = new util.Base64Helper().encodeToStringSync(wireBytes);
    const commentPart: string = comment.length > 0 ? ` ${comment}` : '';
    return `${algName} ${base64Str}${commentPart}`;
  }

  /**
   * 编码一个 SSH string（4 字节大端长度 + 数据）
   */
  private encodeOpenSshString2(data: Uint8Array): Uint8Array {
    const result: Uint8Array = new Uint8Array(4 + data.length);
    const len: number = data.length;
    result[0] = (len >> 24) & 0xFF;
    result[1] = (len >> 16) & 0xFF;
    result[2] = (len >> 8) & 0xFF;
    result[3] = len & 0xFF;
    for (let i: number = 0; i < data.length; i++) {
      result[4 + i] = data[i];
    }
    return result;
  }

  /**
   * 编码 algorithm string + payload string 为完整 wire format
   */
  private encodeOpenSshString(algName: string, payload: Uint8Array): Uint8Array {
    const algBytes: Uint8Array = new util.TextEncoder().encodeInto(algName);
    const algEncoded: Uint8Array = this.encodeOpenSshString2(algBytes);
    // 拼接 algEncoded + payload
    const result: Uint8Array = new Uint8Array(algEncoded.length + payload.length);
    for (let i: number = 0; i < algEncoded.length; i++) {
      result[i] = algEncoded[i];
    }
    for (let i: number = 0; i < payload.length; i++) {
      result[algEncoded.length + i] = payload[i];
    }
    return result;
  }

  // ========== 导入 / 列出 / 导出 / 删除 ==========

  /**
   * 导入 OpenSSH 私钥（同时得到对应公钥）
   *
   * 只有公钥无法通过 SSH 认证访问 Git 服务器，因此导入必须包含私钥：
   * 私钥经 native 解析校验（同时兼容带口令的私钥），并由私钥推导出公钥，
   * 两者一并落盘（私钥 .key / 公钥 .pub）。SSH 密钥只保留一把，导入即替换旧密钥。
   *
   * @param privateKeyText OpenSSH 私钥文本（-----BEGIN OPENSSH PRIVATE KEY-----）
   * @param passphrase 私钥口令（无口令传空串）
   * @returns 密钥信息（失败时返回 null，errorOut 带回失败原因）
   */
  async importPrivateKey(privateKeyText: string, passphrase: string,
    errorOut?: string[]): Promise<SshKeyInfo | null> {
    const setError: (msg: string) => void = (msg: string): void => {
      if (errorOut !== undefined) errorOut[0] = msg;
    };

    const trimmed: string = privateKeyText.trim();
    if (trimmed.length === 0) {
      setError('私钥内容为空');
      return null;
    }
    if (!trimmed.includes('PRIVATE KEY')) {
      setError('文件不是有效的私钥（未找到 PRIVATE KEY 标记）');
      return null;
    }

    try {
      const bridge: NativeBridge = NativeBridge.getInstance();
      if (!bridge.isAvailable()) {
        setError('native 库不可用，无法解析私钥');
        return null;
      }

      // ===== 先探测状态：把「已加密未输口令」与「文件损坏」分开 =====
      const statusResult: NativeResult = bridge.sshKeyStatus(trimmed);
      let isEncrypted: boolean = false;
      if (statusResult.success && statusResult.data.length > 0) {
        try {
          const parsed: SshKeyStatus = JSON.parse(statusResult.data) as SshKeyStatus;
          if (!parsed.valid) {
            // 确认不是有效私钥：格式无效或已损坏
            hilog.warn(DOMAIN, TAG, 'importPrivateKey: invalid key: %{public}s', parsed.error);
            setError('私钥格式无效或文件已损坏，请确认是完整的 OpenSSH 私钥文件');
            return null;
          }
          isEncrypted = parsed.encrypted;
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'importPrivateKey: status parse failed, fallback');
        }
      }

      // 已加密但没输口令：明确提示，而不是报格式错误
      if (isEncrypted && passphrase.length === 0) {
        setError('该私钥已加密，请输入私钥口令');
        return null;
      }

      // ===== 再用口令解析并推导公钥 =====
      const derived: NativeResult = bridge.sshPublicFromPrivate(trimmed, passphrase);
      if (!derived.success || derived.data.length === 0) {
        hilog.warn(DOMAIN, TAG, 'importPrivateKey: derive failed: %{public}s', derived.error);
        // 走到这里说明文件有效：已加密即口令错，未加密才是真损坏
        setError(isEncrypted ? '私钥口令错误，请重新输入' : '私钥格式无效或文件已损坏');
        return null;
      }
      const publicKey: string = derived.data.trim();

      const algName: string = publicKey.split(/\s+/)[0];
      const keyType: SshKeyType = this.parseOpenSshAlgName(algName);
      const alias: string = SshKeyManager.buildKeyAlias(keyType);

      // SSH 密钥只保留一把：解析成功后才清掉旧密钥
      await this.removeAllKeys();

      const keysDir: string = this.getKeysDir();
      FileUtils.ensureDir(keysDir);

      // 私钥加密后落盘（明文私钥会随系统备份外发），公钥为公开信息照常明文存
      const sealedPrivate: string = await SecretStore.getInstance().sealSshPrivateKey(trimmed);
      if (sealedPrivate.length === 0) {
        setError('私钥加密失败，未能保存（请重试）');
        return null;
      }
      FileUtils.writeTextFile(`${keysDir}/${alias}.key`, sealedPrivate);
      FileUtils.writeTextFile(`${keysDir}/${alias}.pub`, publicKey);

      hilog.info(DOMAIN, TAG, 'importPrivateKey: alias=%{public}s alg=%{public}s', alias, algName);

      return {
        alias: alias,
        keyType: keyType,
        publicKey: publicKey,
        createdAt: Date.now(),
        // 导入的私钥无法提供邮箱：native 推导的公钥不带 comment，
        // 列表主标题由 displayName() 回退到别名（文件名）
        email: '',
        hasPrivateKey: true,
      };
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'importPrivateKey failed: %{public}s', e instanceof Error ? e.message : String(e));
      setError('导入失败');
      return null;
    }
  }

  /**
   * 导入 OpenSSH 格式公钥
   *
   * 仅公钥无法用于 SSH 认证，仅作兼容保留；
   * 正常导入应使用 importPrivateKey（私钥 + 推导公钥）。
   *
   * @param openSshPublicKey OpenSSH 公钥文本（ssh-ed25519 AAAA... comment）
   * @param comment 注释
   * @returns 密钥信息（失败时返回 null）
   */
  async importPublicKey(openSshPublicKey: string, comment: string): Promise<SshKeyInfo | null> {
    if (openSshPublicKey.trim().length === 0) {
      hilog.warn(DOMAIN, TAG, 'importPublicKey: empty key text');
      return null;
    }

    try {
      const parts: string[] = openSshPublicKey.trim().split(/\s+/);
      if (parts.length < 2) {
        hilog.warn(DOMAIN, TAG, 'importPublicKey: invalid format');
        return null;
      }

      const algName: string = parts[0];
      const keyType: SshKeyType = this.parseOpenSshAlgName(algName);
      const alias: string = SshKeyManager.buildKeyAlias(keyType);

      // SSH 密钥只保留一把：格式校验通过后先清掉旧密钥，再写入新的
      await this.removeAllKeys();

      // 确保目录存在
      const keysDir: string = this.getKeysDir();
      FileUtils.ensureDir(keysDir);

      // 公钥写入 .pub 文件
      const pubPath: string = `${keysDir}/${alias}.pub`;
      FileUtils.writeTextFile(pubPath, openSshPublicKey);

      // 邮箱回退：取公钥末尾 comment
      const email: string = parts.length >= 3 ? parts[2] : '';

      hilog.info(DOMAIN, TAG, 'importPublicKey: alias=%{public}s alg=%{public}s', alias, algName);

      return {
        alias: alias,
        keyType: keyType,
        publicKey: openSshPublicKey,
        createdAt: Date.now(),
        email: email,
        hasPrivateKey: false,
      };
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'importPublicKey failed: %{public}s', e instanceof Error ? e.message : String(e));
      return null;
    }
  }

  /**
   * 从 OpenSSH 算法名解析密钥类型
   */
  private parseOpenSshAlgName(algName: string): SshKeyType {
    if (algName === 'ssh-rsa') return SshKeyType.RSA;
    if (algName.startsWith('ecdsa')) return SshKeyType.ECDSA;
    return SshKeyType.ED25519;
  }

  /**
   * 列出本地管理的 SSH 密钥
   *
   * 扫描公钥存储目录，解析每个 .pub 文件。
   */
  listKeys(): SshKeyInfo[] {
    const keysDir: string = this.getKeysDir();
    if (!FileUtils.exists(keysDir)) return [];

    const result: SshKeyInfo[] = [];
    try {
      const entries: string[] = fs.listFileSync(keysDir);
      for (let i: number = 0; i < entries.length; i++) {
        const entry: string = entries[i];
        if (!entry.endsWith('.pub')) continue;

        const pubPath: string = `${keysDir}/${entry}`;
        try {
          const pubText: string = FileUtils.readTextFile(pubPath);
          if (pubText.trim().length === 0) continue;

          const parts: string[] = pubText.trim().split(/\s+/);
          if (parts.length < 2) continue;

          const keyType: SshKeyType = this.parseOpenSshAlgName(parts[0]);
          const alias: string = entry.substring(0, entry.length - 4); // 去掉 .pub 后缀

          // 从文件名提取创建时间（alias 格式 ssh_xxx_timestamp）
          let createdAt: number = 0;
          const lastUnderscore: number = alias.lastIndexOf('_');
          if (lastUnderscore >= 0) {
            const ts: number = parseInt(alias.substring(lastUnderscore + 1));
            if (!isNaN(ts)) createdAt = ts;
          }

          // 私钥文件与公钥同名（.key）：存在即表示持有私钥
          const hasPrivateKey: boolean = FileUtils.exists(`${keysDir}/${alias}.key`)
            || this.privateKeyCache.has(alias);

          // 邮箱：优先读落盘的 .email，回退公钥末尾 comment
          let email: string = '';
          const emailPath: string = `${keysDir}/${alias}.email`;
          if (FileUtils.exists(emailPath)) {
            email = FileUtils.readTextFile(emailPath).trim();
          }
          if (email.length === 0 && parts.length >= 3) {
            email = parts[2];
          }

          result.push({
            alias: alias,
            keyType: keyType,
            publicKey: pubText,
            createdAt: createdAt,
            email: email,
            hasPrivateKey: hasPrivateKey,
          });
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'listKeys: failed to parse %{public}s', entry);
        }
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'listKeys failed: %{public}s', e instanceof Error ? e.message : String(e));
    }

    hilog.info(DOMAIN, TAG, 'listKeys: %{public}d keys', result.length);
    return result;
  }

  /**
   * 导出公钥（OpenSSH 格式文本）
   * @param alias 密钥别名
   */
  getPublicKey(alias: string): string {
    const pubPath: string = `${this.getKeysDir()}/${alias}.pub`;
    if (!FileUtils.exists(pubPath)) {
      return '';
    }
    return FileUtils.readTextFile(pubPath);
  }

  /**
   * 导出私钥 PEM 文本（供 native SSH 认证使用）
   *
   * 落盘的私钥是 HUKS 加密后的密文，需先解封；进程重启后仍可用。
   * 否则回退内存缓存的私钥（generateKeyPair 生成后导出为 PKCS8 PEM）。
   *
   * 解密需异步，故本方法返回 Promise。
   *
   * @param alias 密钥别名
   */
  async exportPrivateKeyPem(alias: string): Promise<string> {
    // 1) 落盘的私钥文件（加密存储；老版本留下的明文也能直读，见下）
    const keyPath: string = `${this.getKeysDir()}/${alias}.key`;
    if (FileUtils.exists(keyPath)) {
      const text: string = FileUtils.readTextFile(keyPath);
      if (text.trim().length > 0) {
        // 升级前写入的是明文 PEM（含 PEM 头），按封装格式判断以区分
        if (SecretStore.looksSealed(text.trim()) && text.includes('BEGIN') === false) {
          const pem: string = await SecretStore.getInstance().unsealSshPrivateKey(text.trim());
          if (pem.length > 0) {
            return pem;
          }
          // 解封失败（HUKS 密钥丢失）不能当成"没有私钥"静默降级，
          // 否则会误导上层走 TCP 降级路径，掩盖真正的故障
          hilog.error(DOMAIN, TAG, 'exportPrivateKeyPem: unseal failed for %{public}s', alias);
          return '';
        }
        return text;
      }
    }

    // 2) 生成的密钥：从内存缓存导出
    const priKey: cryptoFramework.PriKey | undefined = this.privateKeyCache.get(alias);
    if (priKey === undefined) {
      return '';
    }
    try {
      // getEncodedDer('PKCS8') 对 Ed25519 私钥不可用（仅 EC/RSA/ML-DSA 支持），
      // 优先用通用 getEncoded()（返回私钥默认编码），失败再回退 PKCS8 DER
      let der: cryptoFramework.DataBlob;
      try {
        der = priKey.getEncoded();
      } catch (e) {
        der = priKey.getEncodedDer('PKCS8');
      }
      const base64: string = new util.Base64Helper().encodeToStringSync(der.data);
      // 包装为 PEM（64 字符一行）
      const lines: string[] = ['-----BEGIN PRIVATE KEY-----'];
      for (let i = 0; i < base64.length; i += 64) {
        lines.push(base64.substring(i, Math.min(i + 64, base64.length)));
      }
      lines.push('-----END PRIVATE KEY-----');
      return lines.join('\n');
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'exportPrivateKeyPem failed: %{public}s', e instanceof Error ? e.message : String(e));
      return '';
    }
  }

  /**
   * 删除密钥（内存缓存的私钥 + 落盘的私钥/公钥文件）
   * @param alias 密钥别名
   */
  async deleteKey(alias: string): Promise<SshKeyResult> {
    try {
      // 删除内存中的私钥缓存
      this.privateKeyCache.delete(alias);

      // 删除公钥文件
      const pubPath: string = `${this.getKeysDir()}/${alias}.pub`;
      if (FileUtils.exists(pubPath)) {
        fs.unlinkSync(pubPath);
      }

      // 删除落盘的私钥文件
      const keyPath: string = `${this.getKeysDir()}/${alias}.key`;
      if (FileUtils.exists(keyPath)) {
        fs.unlinkSync(keyPath);
      }

      hilog.info(DOMAIN, TAG, 'deleteKey: removed %{public}s', alias);
      return { success: true, error: '' };
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'deleteKey failed: %{public}s', e instanceof Error ? e.message : String(e));
      return { success: false, error: e instanceof Error ? e.message : String(e) };
    }
  }

  /**
   * 清除全部内存私钥缓存（应用进入后台 / 手动锁定时调用）
   */
  clearCache(): void {
    this.privateKeyCache.clear();
    hilog.info(DOMAIN, TAG, 'clearCache: private key cache cleared');
  }
}
