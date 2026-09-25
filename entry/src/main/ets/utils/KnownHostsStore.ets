import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** hilog 域 */
const DOMAIN: number = 0x0001;
/** hilog 标签 */
const TAG: string = 'KnownHostsStore';

/** preferences 存储名 */
const STORE_NAME: string = 'ssh_known_hosts';

/**
 * 已知主机条目
 */
export interface KnownHostEntry {
  /** "host" 或 "host:port"（非 22 端口时带端口） */
  hostKey: string;
  /** SHA256:Base64 主机密钥指纹 */
  fingerprint: string;
}

/**
 * 保存到信任库的单条主机密钥记录
 *
 * 存储格式为每行一条 "类型|指纹"（如 `RSA|SHA256:xxx`，见 KnownHostsStore.encodeEntry）。
 * 旧版本存的是裸指纹，读取时按类型为空兼容处理。
 */
export interface KnownHostKey {
  /** 主机密钥类型（RSA/ECDSA/Ed25519；旧格式记录为 ''） */
  keyType: string;
  /** SHA256:Base64 指纹 */
  fingerprint: string;
}

/**
 * known_hosts 持久化存储（TOFU）
 *
 * 以 preferences 持久化 "host[:port]" → SHA256 指纹 映射：
 * - 首次连接：记录指纹供用户确认后保存（TOFU）
 * - 再次连接：指纹匹配则直接连接
 * - 指纹变化：拒绝连接并提示（防中间人）
 */
export class KnownHostsStore {
  private static instance: KnownHostsStore | null = null;
  private store: preferences.Preferences | null = null;
  private context: common.Context | null = null;

  private constructor() {
  }

  /**
   * 注入应用上下文（在 EntryAbility 启动时调用；
   * 替代已废弃的 getContext(this)）
   */
  init(context: common.Context): void {
    this.context = context;
  }

  static getInstance(): KnownHostsStore {
    if (!KnownHostsStore.instance) {
      KnownHostsStore.instance = new KnownHostsStore();
    }
    return KnownHostsStore.instance;
  }

  /**
   * 惰性初始化 preferences（context 在 EntryAbility 启动后可用）
   */
  private async getStore(): Promise<preferences.Preferences | null> {
    if (this.store !== null) {
      return this.store;
    }
    try {
      // 替代已废弃的 getContext(this)：使用注入的应用上下文
      if (this.context === null) {
        hilog.error(DOMAIN, TAG, 'getStore failed: context not initialized');
        return null;
      }
      this.store = await preferences.getPreferences(this.context, STORE_NAME);
      return this.store;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'getStore failed: %{public}s', e instanceof Error ? e.message : String(e));
      return null;
    }
  }

  /**
   * 规范化 host key：非 22 端口时带 ":port"
   */
  static normalizeHostKey(host: string, port: number): string {
    const trimmed: string = host.trim();
    return port === 22 ? trimmed : `${trimmed}:${port}`;
  }

  /**
   * 单条记录 ↔ "类型|指纹" 行的编解码
   *
   * 带类型的原因见 KnownHostKey：同类型指纹不同才是「密钥变了」（中间人告警），
   * 新类型只是服务器多把主机密钥里没钉过的一把（TOFU 确认后追加）。
   */
  static encodeEntry(key: KnownHostKey): string {
    return key.keyType.length > 0 ? `${key.keyType}|${key.fingerprint}` : key.fingerprint;
  }

  /** 解析一行；空行返回 null */
  static decodeEntry(line: string): KnownHostKey | null {
    const trimmed: string = line.trim();
    if (trimmed.length === 0) {
      return null;
    }
    const sep: number = trimmed.indexOf('|');
    if (sep < 0) {
      return { keyType: '', fingerprint: trimmed };
    }
    return { keyType: trimmed.substring(0, sep), fingerprint: trimmed.substring(sep + 1) };
  }

  /**
   * 查询已知主机的**全部**信任记录
   *
   * @returns 记录列表（按存储顺序）；无记录返回空数组
   */
  async getHostKeys(host: string, port: number): Promise<KnownHostKey[]> {
    const store = await this.getStore();
    if (store === null) {
      return [];
    }
    try {
      const value = await store.get(KnownHostsStore.normalizeHostKey(host, port), '');
      if (typeof value !== 'string' || value.length === 0) {
        return [];
      }
      const out: KnownHostKey[] = [];
      const lines: string[] = value.split('\n');
      for (let i: number = 0; i < lines.length; i++) {
        const key: KnownHostKey | null = KnownHostsStore.decodeEntry(lines[i]);
        if (key !== null) {
          out.push(key);
        }
      }
      return out;
    } catch (e) {
      return [];
    }
  }

  /**
   * 查询已知主机指纹（多把，按记录顺序）
   *
   * 同一台服务器可能同时提供 rsa/ecdsa/ed25519 多把主机密钥，而不同 SSH 实现
   * （russh / libgit2 用的 libssh2）偏好不同、各自选到不同类型，因此这里保存的是
   * **一组**指纹：libgit2 侧传全部（任意一把匹配即放行），russh 侧按探测到的指纹
   * 判断是否已在其中。
   *
   * @returns 指纹列表；无记录返回空数组
   */
  async getFingerprints(host: string, port: number): Promise<string[]> {
    const keys: KnownHostKey[] = await this.getHostKeys(host, port);
    const out: string[] = [];
    for (let i: number = 0; i < keys.length; i++) {
      out.push(keys[i].fingerprint);
    }
    return out;
  }

  /**
   * 查询已知主机指纹（兼容旧调用：返回第一把）
   * @returns 指纹；无记录返回 ''
   */
  async getFingerprint(host: string, port: number): Promise<string> {
    const all: string[] = await this.getFingerprints(host, port);
    return all.length > 0 ? all[0] : '';
  }

  /**
   * 保存主机指纹（TOFU 确认后调用，带类型）
   *
   * 追加而不是覆盖：两种 SSH 实现可能各钉一把不同类型的主机密钥，覆盖会让
   * 另一条流程每次都要重新确认（来回弹窗）。同类型同指纹已存在时是幂等操作。
   */
  async saveHostKey(host: string, port: number, key: KnownHostKey): Promise<boolean> {
    const store = await this.getStore();
    if (store === null) {
      return false;
    }
    try {
      const existing: KnownHostKey[] = await this.getHostKeys(host, port);
      for (let i: number = 0; i < existing.length; i++) {
        if (existing[i].fingerprint === key.fingerprint) {
          // 指纹已在：同类型（或旧记录无类型）无需变化；旧记录补上类型
          if (existing[i].keyType.length === 0 && key.keyType.length > 0) {
            existing[i].keyType = key.keyType;
            await store.put(KnownHostsStore.normalizeHostKey(host, port),
              this.encodeAll(existing));
            await store.flush();
          }
          return true;
        }
      }
      existing.push(key);
      await store.put(KnownHostsStore.normalizeHostKey(host, port), this.encodeAll(existing));
      const keys: string[] = await this.loadKeyIndex(store);
      const hostKey: string = KnownHostsStore.normalizeHostKey(host, port);
      if (!keys.includes(hostKey)) {
        keys.push(hostKey);
        await this.saveKeyIndex(store, keys);
      }
      await store.flush();
      hilog.info(DOMAIN, TAG, 'saved host key for %{public}s (%{public}s)',
        KnownHostsStore.normalizeHostKey(host, port), key.keyType);
      return true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'saveHostKey failed: %{public}s', e instanceof Error ? e.message : String(e));
      return false;
    }
  }

  /** 把记录列表编码成存储文本（每行一条） */
  private encodeAll(keys: KnownHostKey[]): string {
    const lines: string[] = [];
    for (let i: number = 0; i < keys.length; i++) {
      lines.push(KnownHostsStore.encodeEntry(keys[i]));
    }
    return lines.join('\n');
  }

  /**
   * 保存主机指纹（TOFU 确认后调用；不带类型，保留给旧调用方）
   */
  async saveFingerprint(host: string, port: number, fingerprint: string): Promise<boolean> {
    return this.saveHostKey(host, port, { keyType: '', fingerprint: fingerprint });
  }

  /**
   * 判断「待确认的指纹」相对信任记录的状态
   *
   * 三态（与 native 的 GitCertCheckCallback 判定一致）：
   * - 'trusted'：指纹已在记录中；
   * - 'mismatch'：同类型、指纹不同 → 该类型密钥真的变了，可能中间人；
   * - 'unknown'：类型从未记录过 → 只是没钉过的一把，确认后追加。
   */
  async hostKeyState(host: string, port: number, keyType: string,
    fingerprint: string): Promise<string> {
    const keys: KnownHostKey[] = await this.getHostKeys(host, port);
    let mismatchSameType: boolean = false;
    for (let i: number = 0; i < keys.length; i++) {
      if (keys[i].fingerprint === fingerprint) {
        return 'trusted';
      }
      if (keyType.length > 0 && keys[i].keyType === keyType) {
        mismatchSameType = true;
      }
    }
    return mismatchSameType ? 'mismatch' : 'unknown';
  }

  /**
   * 删除主机记录（用户主动清除 / 重置信任）
   */
  async removeHost(host: string, port: number): Promise<void> {
    const store = await this.getStore();
    if (store === null) {
      return;
    }
    try {
      await store.delete(KnownHostsStore.normalizeHostKey(host, port));
      const keys: string[] = await this.loadKeyIndex(store);
      const filtered: string[] = keys.filter((k: string) => k !== KnownHostsStore.normalizeHostKey(host, port));
      await this.saveKeyIndex(store, filtered);
      await store.flush();
    } catch (e) {
      // 忽略删除失败
    }
  }

  /**
   * 已记录的主机 key 列表（持久化维护，规避 getAll 后的索引访问限制）
   */
  private static readonly KEYS_INDEX: string = '__known_hosts_keys__';

  private async loadKeyIndex(store: preferences.Preferences): Promise<string[]> {
    try {
      const raw = await store.get(KnownHostsStore.KEYS_INDEX, '');
      if (typeof raw === 'string' && raw.length > 0) {
        return raw.split('\n').filter((s: string) => s.length > 0);
      }
    } catch (e) {
      // 忽略
    }
    return [];
  }

  private async saveKeyIndex(store: preferences.Preferences, keys: string[]): Promise<void> {
    try {
      await store.put(KnownHostsStore.KEYS_INDEX, keys.join('\n'));
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'saveKeyIndex failed: %{public}s', e instanceof Error ? e.message : String(e));
    }
  }

  /**
   * 列出全部已知主机
   */
  async listAll(): Promise<KnownHostEntry[]> {
    const store = await this.getStore();
    if (store === null) {
      return [];
    }
    const hostKeys: string[] = await this.loadKeyIndex(store);
    const entries: KnownHostEntry[] = [];
    for (let i: number = 0; i < hostKeys.length; i++) {
      try {
        const value = await store.get(hostKeys[i], '');
        if (typeof value === 'string') {
          entries.push({ hostKey: hostKeys[i], fingerprint: value });
        }
      } catch (e) {
        // 忽略单个读取失败
      }
    }
    return entries;
  }
}
