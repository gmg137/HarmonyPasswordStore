import { GpgKeyId, GpgIdValidation } from '../model/GpgKeyId';
import { FileUtils } from '../utils/FileUtils';
import { SettingsRepository } from '../model/SettingsRepository';
import { PGP_KEYS_DIR } from '../common/Constants';
import { NativeBridge } from '../common/NativeBridge';
import { PgpPacketParser } from './PgpPacketParser';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * 密钥导入结果
 */
export interface KeyImportResult {
  success: boolean;
  error: string;
  /**
   * 非致命告警：导入已成功，但存在需要用户知晓的限制
   *
   * 目前用于「加密子密钥是 native 用不了的算法」（如 GnuPG 的 ML-KEM 子密钥）——
   * 密钥可正常导入与展示，但无法用于加密新条目。
   */
  warning?: string;
  /** 批量导入时成功导入的密钥数量（单密钥导入为 1） */
  importedCount?: number;
  /**
   * 失败原因是「同指纹密钥已存在」
   *
   * 单独标记而不是让调用方去匹配 `error` 文案：这一种失败需要**弹窗**告知
   * （表单里的小红字容易被忽略，而「已存在」本身也不是需要用户去改输入的错误），
   * 而文案随时可能被改写，靠字符串匹配会静默失效。
   */
  alreadyExists?: boolean;
  /**
   * 失败原因需要**弹窗**告知（而不是表单里的小红字）
   *
   * 用于「这是公钥，不含私钥材料」这类：它不是输入格式错误（用户改不了什么），
   * 而表单底部的小红字位置偏、容易被忽略。与 `alreadyExists` 共用页面的弹窗通道。
   */
  needsDialog?: boolean;
}

/** hilog 域 */
const DOMAIN: number = 0x0001;
/** hilog 标签 */
const TAG: string = 'PgpKeyManager';

/**
 * PGP 密钥管理器
 *
 * 负责 PGP 密钥的导入、存储、列出、选择和删除。
 * 密钥文件加密存储于应用沙箱目录，passphrase 通过 HUKS 派生密钥保护。
 *
 * native PGP 库（rpgp）就绪后，实际加解密操作委托给 PgpCrypto。
 */
export class PgpKeyManager {
  private static instance: PgpKeyManager | null = null;

  /** 已导入密钥的缓存列表 */
  private keyCache: GpgKeyId[] = [];

  /** 指纹 → 密钥文件路径映射（refreshKeyCache/import 时维护，
   *  避免依赖"指纹=文件名"假设：解析出的指纹可能与存储文件名不一致） */
  private keyFiles: Map<string, string> = new Map();

  /** 别名指纹 → 标准指纹（ArkTS 解析指纹可能与文件名不一致，
   *  .gpg-id 中可能写入任一形态，解析时先经别名归一化） */
  private keyAliases: Map<string, string> = new Map();

  private constructor() {
  }

  static getInstance(): PgpKeyManager {
    if (!PgpKeyManager.instance) {
      PgpKeyManager.instance = new PgpKeyManager();
    }
    return PgpKeyManager.instance;
  }

  /**
   * 获取 PGP 密钥存储目录
   */
  private getKeysDir(): string {
    const filesDir: string = FileUtils.getFilesDir();
    return `${filesDir}/${PGP_KEYS_DIR}`;
  }

  /**
   * 初始化密钥管理器（确保目录存在并加载缓存）
   */
  init(): void {
    FileUtils.ensureDir(this.getKeysDir());
    this.refreshKeyCache();
  }

  /**
   * 刷新密钥缓存：扫描密钥目录，解析每个 .asc 文件
   */
  async refreshKeyCache(): Promise<void> {
    this.keyCache = [];
    this.keyFiles.clear();
    this.keyAliases.clear();
    const keysDir: string = this.getKeysDir();
    if (!FileUtils.exists(keysDir)) return;

    try {
      const entries: string[] = fs.listFileSync(keysDir);
      for (let i: number = 0; i < entries.length; i++) {
        const entry: string = entries[i];
        if (!entry.endsWith('.asc')) continue;

        const filePath: string = `${keysDir}/${entry}`;
        try {
          const armored: string = FileUtils.readTextFile(filePath);
          const keyInfo: GpgKeyId | null = await PgpPacketParser.parseArmoredKey(armored, true);
          if (keyInfo !== null) {
            // 文件名是导入时 native rpgp 按真实指纹命名的，作为权威指纹；
            // ArkTS 解析出的指纹若有偏差，作为别名登记（.gpg-id 兼容两种形态）
            const canonicalFp: string = entry.substring(0, entry.length - '.asc'.length).toUpperCase();
            if (keyInfo.fingerprint.length > 0 && keyInfo.fingerprint.toUpperCase() !== canonicalFp) {
              this.keyAliases.set(keyInfo.fingerprint.toUpperCase(), canonicalFp);
            }
            keyInfo.fingerprint = canonicalFp;
            this.keyCache.push(keyInfo);
            this.keyFiles.set(canonicalFp, filePath);
          }
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'Failed to parse key file %{public}s', entry);
        }
      }
      hilog.info(DOMAIN, TAG, 'refreshKeyCache: loaded %{public}d keys', this.keyCache.length);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'refreshKeyCache failed: %{public}s', e instanceof Error ? e.message : String(e));
    }
  }

  /**
   * 列出本地已导入的密钥
   * @param isSecret 是否只返回私钥
   * @returns 密钥列表
   */
  async listKeys(isSecret: boolean): Promise<GpgKeyId[]> {
    if (isSecret) {
      return this.keyCache.filter((k: GpgKeyId) => k.isSecret);
    }
    return this.keyCache;
  }

  /**
   * 导入 ASCII-armored 私钥备份
   * @param armoredKey ASCII-armored 密钥文本
   * @param passphrase 密钥密码
   * @returns 成功与否及错误信息
   */
  async importSecretKey(armoredKey: string, passphrase: string): Promise<KeyImportResult> {
    if (armoredKey.trim().length === 0) {
      return { success: false, error: '密钥内容为空' };
    }

    try {
      // 先判定是否含私钥材料：用户常误用 `gpg --export` 导出公钥当私钥导入。
      // 必须在此给出精确原因——若让公钥入库，解密时才报「缺少私钥段」，
      // 而 UI 只显示「密钥密码错误」，用户会误以为口令不对、反复重试。
      if (!PgpPacketParser.containsSecretMaterial(armoredKey)) {
        hilog.warn(DOMAIN, TAG, 'importSecretKey: no secret material (likely a public key)');
        return {
          success: false,
          error: '这不是合法的私钥材料，无法用于解密。'
            + '请改用 `gpg --export-secret-keys --armor <密钥ID>` 导出私钥后再导入。',
          needsDialog: true,
        };
      }

      // 解析 armored 密钥提取元数据
      const keyInfo: GpgKeyId | null = await PgpPacketParser.parseArmoredKey(armoredKey, true);
      if (keyInfo === null) {
        return { success: false, error: '密钥解析失败（格式不正确或不支持）' };
      }

      // native 无法处理的算法必须在写盘前拒绝：
      // 否则会「导入成功但解密失败」，用户无从定位（如 PQC 密钥、未知算法号）
      const reason: string = PgpPacketParser.unsupportedAlgorithmReason(keyInfo.algorithm);
      if (reason.length > 0) {
        hilog.warn(DOMAIN, TAG, 'importSecretKey: unsupported algorithm %{public}s', keyInfo.algorithm);
        return { success: false, error: reason };
      }

      // 有加密密钥、但 rpgp 用不了的变体（如 GnuPG 的 ML-KEM 子密钥，
      // 编码为算法号 8 + v5 子密钥，rpgp 会丢弃该子密钥）：
      // 仍允许导入（用户需要看到密钥及其真实算法），但必须明确告警——
      // 否则用户到加密时才发现失败，且无从理解原因。
      // 注意：纯签名密钥（如仅 ed25519 主密钥）没有加密密钥，属正常情况，不告警。
      let warning: string = '';
      if (keyInfo.gpgPqc && keyInfo.gpgPqcUsable) {
        hilog.info(DOMAIN, TAG, 'importSecretKey: gpg pqc key (algo 8) %{public}s',
          keyInfo.encryptionAlgorithm);
        warning = `该密钥的加密子密钥为 ${keyInfo.encryptionAlgorithm}（GnuPG 私有算法号），`
          + `本应用可正常用它加解密新条目，但 GnuPG 之外的实现可能无法识别。`;
      } else if (keyInfo.gpgPqc) {
        // algo 8 但经典曲线未实现：必须明确说不可用。
        // 曾一律提示「可正常加解密」，用户在创建/解密时才失败，
        // 而错误看着像口令问题（本 bug 消耗过多轮排查）。
        hilog.warn(DOMAIN, TAG, 'importSecretKey: gpg pqc curve unsupported: %{public}s',
          keyInfo.encryptionAlgorithm);
        warning = `该密钥的加密子密钥为 ${keyInfo.encryptionAlgorithm}，`
          + `其经典曲线本应用尚未支持（当前支持 ky768_cv25519 / ky768_bp256 / ky1024_bp384）。`
          + `密钥已导入，可查看与管理，但无法用它加解密新条目。`;
      } else if (keyInfo.hasEncryptionKey && !keyInfo.encryptionSupported) {
        hilog.warn(DOMAIN, TAG, 'importSecretKey: encryption key unsupported: %{public}s',
          keyInfo.encryptionAlgorithm);
        warning = `该密钥的加密子密钥为 ${keyInfo.encryptionAlgorithm}，当前版本不支持用它加密新条目。`
          + `密钥已导入，可查看与管理，但请另选一把 RSA 或 ECC 密钥作为加密密钥。`;
      }

      // 检查是否已存在同指纹密钥
      const existing: GpgKeyId | null = this.findKey(keyInfo.fingerprint);
      if (existing !== null) {
        return { success: false, error: '该密钥已存在', alreadyExists: true };
      }

      // 写入文件（以指纹命名）并记录路径映射
      // 落盘前规范化 armor：粘贴进来的可能是**单行（不折行）**文本——ArkTS 解析器
      // 不在乎折行、导入会「成功」，但 native rpgp 严格要求标准 armor，之后所有
      // native 调用（口令校验、加解密）都会失败，密钥等于废掉（见 normalizeArmor 注释）
      const normalized: string = PgpPacketParser.normalizeArmor(armoredKey);
      if (normalized !== armoredKey) {
        hilog.info(DOMAIN, TAG, 'importSecretKey: normalized armor before storing (body re-wrapped)');
      }
      const fileName: string = `${keyInfo.fingerprint}.asc`;
      const filePath: string = `${this.getKeysDir()}/${fileName}`;
      FileUtils.writeTextFile(filePath, normalized);
      this.keyFiles.set(keyInfo.fingerprint, filePath);

      // 更新缓存
      this.keyCache.push(keyInfo);

      hilog.info(DOMAIN, TAG, 'importSecretKey: imported %{public}s (%{public}s)',
        keyInfo.fingerprint, keyInfo.userId);
      return { success: true, error: '', warning: warning };
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      hilog.error(DOMAIN, TAG, 'importSecretKey failed: %{public}s', msg);
      return { success: false, error: `导入失败: ${msg}` };
    }
  }

  /**
   * 从包含多个密钥的 armored 文本批量导入
   *
   * 兼容：gpg --export-secret-keys 导出的 keyring、本应用多密钥备份
   * （先经 pgpRestoreBackup 解密还原出 armored 文本，再调用本方法导入）。
   * native 端 from_armor_many 拆分为单密钥后逐一导入，部分失败不影响其余密钥。
   * @param armoredKey 包含一个或多个密钥的 armored 文本
   * @param passphrase 密钥密码（预留，导入不校验）
   * @returns 成功与否、首个错误信息及成功导入数量
   */
  async importSecretKeysFromArmored(armoredKey: string, passphrase: string): Promise<KeyImportResult> {
    if (armoredKey.trim().length === 0) {
      return { success: false, error: '密钥内容为空' };
    }

    // native 拆分 keyring 为单密钥 armored 数组；拆分失败时按单密钥回退导入
    const splitResult = NativeBridge.getInstance().pgpSplitKeyring(armoredKey);
    if (!splitResult.success || splitResult.data.length === 0) {
      const single: KeyImportResult = await this.importSecretKey(armoredKey, passphrase);
      single.importedCount = single.success ? 1 : 0;
      return single;
    }

    let entries: Array<string> = [];
    try {
      entries = JSON.parse(splitResult.data) as Array<string>;
    } catch (e) {
      return { success: false, error: '密钥拆分结果解析失败' };
    }

    let imported: number = 0;
    let firstError: string = '';
    for (let i: number = 0; i < entries.length; i++) {
      const result: KeyImportResult = await this.importSecretKey(entries[i], passphrase);
      if (result.success) {
        imported++;
      } else if (firstError.length === 0) {
        firstError = result.error;
      }
    }

    if (imported === 0) {
      return { success: false, error: firstError.length > 0 ? firstError : '无密钥被导入' };
    }
    hilog.info(DOMAIN, TAG, 'importSecretKeysFromArmored: %{public}d imported, %{public}d failed',
      imported, entries.length - imported);
    return { success: true, error: '', importedCount: imported };
  }

  /**
   * 应用内生成 PGP 密钥对并导入
   *
   * native rpgp 生成 V4 格式密钥（EdDSA/RSA 主键 + 加密子键），
   * passphrase 非空时同时锁定主键与子键；生成后走标准导入流程存储。
   * @param userId 用户 ID，如 "Name <email@example.com>"
   * @param keyType "eddsa"（推荐）| "rsa4096" | "rsa2048"
   * @param passphrase 密钥密码（可为空）
   */
  async generateKey(userId: string, keyType: string, passphrase: string): Promise<KeyImportResult> {
    if (userId.trim().length === 0) {
      return { success: false, error: '请输入 User ID（如 Name <email@example.com>）' };
    }
    if (keyType !== 'eddsa' && keyType !== 'rsa4096' && keyType !== 'rsa2048') {
      return { success: false, error: '不支持的密钥算法' };
    }

    const result = NativeBridge.getInstance().pgpGenerateKey(userId.trim(), keyType, passphrase);
    if (!result.success || result.data.length === 0) {
      hilog.error(DOMAIN, TAG, 'generateKey failed: %{public}s', result.error);
      return { success: false, error: result.error.length > 0 ? result.error : '密钥生成失败' };
    }

    const importResult: KeyImportResult = await this.importSecretKey(result.data, passphrase);
    if (importResult.success) {
      hilog.info(DOMAIN, TAG, 'generateKey: generated and imported %{public}s key', keyType);
    }
    return importResult;
  }

  /**
   * 修改密钥 passphrase
   *
   * native 先用旧密码解锁主键与全部子键，再用新密码上锁（新密码为空则去除锁定），
   * 成功后将新的 armored 私钥覆盖存储（指纹不变，文件名不变）。
   */
  async changePassphrase(fingerprint: string, oldPassphrase: string, newPassphrase: string): Promise<KeyImportResult> {
    const armored: string = this.getKeyArmored(fingerprint);
    if (armored.length === 0) {
      return { success: false, error: '密钥不存在' };
    }

    const result = NativeBridge.getInstance().pgpChangePassphrase(armored, oldPassphrase, newPassphrase);
    if (!result.success || result.data.length === 0) {
      hilog.warn(DOMAIN, TAG, 'changePassphrase failed: %{public}s', result.error);
      return { success: false, error: result.error.length > 0 ? result.error : '修改失败（旧密码不正确？）' };
    }

    const filePath: string = `${this.getKeysDir()}/${fingerprint}.asc`;
    try {
      FileUtils.writeTextFile(filePath, result.data);
      // 缓存必须重读：文件已按新口令重写，而列表里的 gpgPqc/算法等元数据
      // 是按旧文件解析的（不刷新的话改完口令密钥标签会维持旧值）
      await this.refreshKeyCache();
      hilog.info(DOMAIN, TAG, 'changePassphrase: updated %{public}s', fingerprint);
      return { success: true, error: '' };
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      return { success: false, error: `存储新密钥失败: ${msg}` };
    }
  }

  /**
   * 导出单把密钥的对称加密备份
   *
   * **注意：当前 UI 不再调用它**——密钥导出统一走
   * `PgpKeyManagerViewModel.exportKeyToFile()`（私钥/公钥存为 .asc 文件），
   * 「导出/备份」那个带备份密码的入口已随之删除。保留该能力是因为它与
   * `pgpRestoreBackup` 成对（对称加密备份 → 还原）；若要彻底清理，须连 native 的
   * `hps_pgp_backup_key`/`hps_pgp_restore_backup` 一起删（4 处同步 + 重编静态库）。
   *
   * @param fingerprint 密钥指纹
   * @param backupPassword 备份密码
   * @returns armored 备份文本；失败返回空字符串（错误见 hilog）
   */
  async backupKey(fingerprint: string, backupPassword: string): Promise<string> {
    const armored: string = this.getKeyArmored(fingerprint);
    if (armored.length === 0) {
      hilog.error(DOMAIN, TAG, 'backupKey: key missing %{public}s', fingerprint);
      return '';
    }
    return this.backupArmoredText(armored, backupPassword);
  }

  /**
   * 导出全部已导入密钥的对称加密备份（多密钥单文件）
   *
   * 备份内容为全部 armored 密钥拼接后对称加密；还原时
   * pgpRestoreBackup 解密后经 importSecretKeysFromArmored 批量导入。
   * @returns armored 备份文本；失败返回空字符串
   */
  async backupAllKeys(backupPassword: string): Promise<string> {
    if (this.keyCache.length === 0) {
      hilog.warn(DOMAIN, TAG, 'backupAllKeys: no keys');
      return '';
    }
    const parts: string[] = [];
    for (let i: number = 0; i < this.keyCache.length; i++) {
      const armored: string = this.getKeyArmored(this.keyCache[i].fingerprint);
      if (armored.length > 0) {
        parts.push(armored);
      }
    }
    if (parts.length === 0) {
      return '';
    }
    return this.backupArmoredText(parts.join('\n'), backupPassword);
  }

  /**
   * 对 armored 密钥文本做对称加密备份（内部共用）
   */
  private backupArmoredText(armored: string, backupPassword: string): Promise<string> {
    if (backupPassword.length === 0) {
      hilog.error(DOMAIN, TAG, 'backupArmoredText: empty password');
      return Promise.resolve('');
    }
    const result = NativeBridge.getInstance().pgpBackupKey(armored, backupPassword);
    if (!result.success || result.data.length === 0) {
      hilog.error(DOMAIN, TAG, 'backupArmoredText failed: %{public}s', result.error);
      return Promise.resolve('');
    }
    return Promise.resolve(result.data);
  }

  /**
   * 删除指定指纹的密钥
   * @param fingerprint 密钥指纹
   * @returns 是否删除成功
   */
  async deleteKey(fingerprint: string): Promise<boolean> {
    const keyInfo: GpgKeyId | null = this.findKey(fingerprint);
    if (keyInfo === null) {
      hilog.warn(DOMAIN, TAG, 'deleteKey: key not found %{public}s', fingerprint);
      return false;
    }

    const filePath: string = `${this.getKeysDir()}/${fingerprint}.asc`;
    try {
      if (FileUtils.exists(filePath)) {
        fs.unlinkSync(filePath);
      }
      // 从缓存与路径映射中移除
      this.keyCache = this.keyCache.filter((k: GpgKeyId) => k.fingerprint !== fingerprint);
      this.keyFiles.delete(fingerprint);

      // 如为默认密钥，清除默认设置
      if (this.getDefaultKeyFingerprint() === fingerprint) {
        await this.setDefaultKey('');
      }

      hilog.info(DOMAIN, TAG, 'deleteKey: removed %{public}s', fingerprint);
      return true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'deleteKey failed: %{public}s', e instanceof Error ? e.message : String(e));
      return false;
    }
  }

  /**
   * 导出公钥（ASCII-armored 格式）
   * @param fingerprint 密钥指纹
   * @returns ASCII-armored 公钥文本
   */
  async exportPublicKey(fingerprint: string): Promise<string> {
    // 私钥文件中的公钥部分无法在纯 ArkTS 中分离提取，
    // 需 native rpgp 的 splitting 功能。当前返回空字符串并记录日志。
    const keyInfo: GpgKeyId | null = this.findKey(fingerprint);
    if (keyInfo === null) {
      hilog.warn(DOMAIN, TAG, 'exportPublicKey: key not found %{public}s', fingerprint);
      return '';
    }

    // 如已存储的是公钥文件，直接返回
    const filePath: string = `${this.getKeysDir()}/${fingerprint}.asc`;
    if (!FileUtils.exists(filePath)) {
      hilog.warn(DOMAIN, TAG, 'exportPublicKey: file missing %{public}s', fingerprint);
      return '';
    }

    try {
      const armored: string = FileUtils.readTextFile(filePath);
      // 检查是否为公钥 armor（BEGIN PGP PUBLIC KEY BLOCK）
      if (armored.includes('PGP PUBLIC KEY BLOCK')) {
        return armored;
      }
      // 私钥文件：通过 native rpgp 提取公钥部分
      const result = NativeBridge.getInstance().pgpExtractPublicKey(armored);
      if (!result.success || result.data.length === 0) {
        hilog.warn(DOMAIN, TAG, 'exportPublicKey: native extract failed: %{public}s', result.error);
        return '';
      }
      return result.data;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'exportPublicKey failed: %{public}s', e instanceof Error ? e.message : String(e));
      return '';
    }
  }

  /**
   * 获取密钥的 armored 文本（直接读取存储的 .asc 文件）
   *
   * 供 PgpCrypto.decrypt 传入 NativeBridge 使用。
   * @param fingerprint 密钥指纹
   * @returns armored 文本，不存在时返回空字符串
   */
  getKeyArmored(fingerprint: string): string {
    // 优先用映射表定位文件（指纹与文件名可能不一致），
    // 映射缺失时回退"指纹.asc"约定路径
    const mappedPath: string | undefined = this.keyFiles.get(fingerprint);
    const filePath: string = mappedPath !== undefined
      ? mappedPath
      : `${this.getKeysDir()}/${fingerprint}.asc`;
    if (!FileUtils.exists(filePath)) {
      hilog.warn(DOMAIN, TAG, 'getKeyArmored: file missing %{public}s (path=%{public}s)',
        fingerprint, filePath);
      return '';
    }
    try {
      return FileUtils.readTextFile(filePath);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'getKeyArmored failed: %{public}s', e instanceof Error ? e.message : String(e));
      return '';
    }
  }

  /**
   * 密钥显示名（uid 优先，其次 email，都没有则用指纹前 8 位）
   *
   * 供重加密确认框等文案使用（页面/服务层都要用，故放在 manager 而非某个 viewmodel）。
   */
  keyLabelFor(fingerprint: string): string {
    const key: GpgKeyId | null = this.findKey(fingerprint);
    if (key === null) {
      return fingerprint.length > 8 ? fingerprint.substring(0, 8) : fingerprint;
    }
    if (key.name.length > 0) {
      return key.name;
    }
    return key.email.length > 0 ? key.email : fingerprint.substring(0, 8);
  }

  /**
   * 按**加密子密钥**的 Key ID 查找已导入密钥
   *
   * 密文 PKESK 里的收件人 keyid 是子密钥的，与主密钥 `keyId` 不同，
   * 故不能用 `resolveKeyByIdEntry` 匹配。大小写不敏感。
   *
   * @param keyId 16 位十六进制 Key ID（大写）
   */
  findByEncryptionKeyId(keyId: string): GpgKeyId | null {
    if (keyId.length === 0) {
      return null;
    }
    const want: string = keyId.toUpperCase();
    for (let i: number = 0; i < this.keyCache.length; i++) {
      const k: GpgKeyId = this.keyCache[i];
      if (k.encryptionKeyId.length > 0 && k.encryptionKeyId.toUpperCase() === want) {
        return k;
      }
    }
    return null;
  }

  /**
   * 获取默认加密密钥指纹
   */
  getDefaultKeyFingerprint(): string {
    return SettingsRepository.getInstance().getSettings().defaultKeyFingerprint;
  }

  /**
   * 设置默认加密密钥
   * @param fingerprint 密钥指纹
   */
  async setDefaultKey(fingerprint: string): Promise<void> {
    await SettingsRepository.getInstance().updateSetting('defaultKeyFingerprint', fingerprint);
    hilog.info(DOMAIN, TAG, 'Default key set to %{public}s', fingerprint);
  }

  /**
   * 检查是否有可用密钥
   */
  hasKeys(): boolean {
    return this.keyCache.length > 0;
  }

  /**
   * 根据指纹查找密钥
   * @param fingerprint 密钥指纹
   * @returns 密钥信息或 null
   */
  findKey(fingerprint: string): GpgKeyId | null {
    const found: GpgKeyId | undefined = this.keyCache.find((k: GpgKeyId) => k.fingerprint === fingerprint);
    return found ?? null;
  }

  /**
   * 按 `.gpg-id` 条目解析已导入的密钥（大小写不敏感）
   *
   * `pass` 把 `.gpg-id` 每行**原样**交给 gpg 当接收方参数，因此真实仓库里这一行
   * 可以是 gpg 认识的任意写法，远不止指纹：
   * - 完整指纹（主密钥）
   * - Key ID（长格式 16 位十六进制）——**主密钥或加密子密钥都要认**：
   *   用户常从 `gpg --list-keys` 的 `sub` 行复制子密钥 ID，桌面 gpg 能解析，
   *   本应用此前只比对主密钥 Key ID，于是保存时报「.gpg-id 引用了未导入的密钥」，
   *   而该密钥其实就在密钥列表里
   * - `0x` 前缀写法（`0xDEADBEEF…`）
   * - 邮箱 / 完整 uid（`Name <mail>`）
   * - 短 Key ID（8 位十六进制，即长 Key ID 的后 8 位）
   *
   * 歧义（同一邮箱/短 ID 命中多把密钥）时**返回 null 而不是猜**：猜错等于把密码
   * 加密给错误的接收方，本人反而打不开。短 ID 只有在唯一命中时才接受。
   *
   * @param entry `.gpg-id` 中的一行（已剥离注释与 `!` 标记）
   * @returns 密钥信息或 null
   */
  resolveKeyByIdEntry(entry: string): GpgKeyId | null {
    const raw: string = entry.trim();
    if (raw.length === 0) {
      return null;
    }
    // gpg 允许 0x 前缀，pass 原样透传，故先统一去掉
    const bare: string = raw.replace(/^0x/i, '');
    const upper: string = bare.toUpperCase();
    // ① 十六进制标识：指纹（含别名归一化）/ 主密钥 Key ID / 加密子密钥 Key ID
    const canonical: string = this.keyAliases.get(upper) ?? upper;
    const byId: GpgKeyId | undefined = this.keyCache.find((k: GpgKeyId) =>
      k.fingerprint.toUpperCase() === canonical
      || k.keyId.toUpperCase() === upper
      || (k.encryptionKeyId.length > 0 && k.encryptionKeyId.toUpperCase() === upper)
    );
    if (byId !== undefined) {
      return byId;
    }
    // ② 邮箱 / 完整 uid（gpg 接受这类接收方写法）
    const lower: string = bare.toLowerCase();
    const byText: GpgKeyId[] = this.keyCache.filter((k: GpgKeyId) =>
      (k.email.length > 0 && k.email.toLowerCase() === lower)
      || (k.userId.trim().length > 0 && k.userId.trim().toLowerCase() === lower)
    );
    if (byText.length === 1) {
      return byText[0];
    }
    // ③ 短 Key ID（8 位十六进制 = 长 Key ID 的后 8 位），唯一命中才认
    if (/^[0-9A-F]{8}$/.test(upper)) {
      const byShort: GpgKeyId[] = this.keyCache.filter((k: GpgKeyId) =>
        k.keyId.length >= 8 && k.keyId.toUpperCase().endsWith(upper)
      );
      if (byShort.length === 1) {
        return byShort[0];
      }
      hilog.warn(DOMAIN, TAG, 'short key id %{public}s matched %{public}d keys (ambiguous)',
        bare, byShort.length);
    }
    return null;
  }

  /**
   * 校验 .gpg-id 条目：区分已导入（有效）与未导入（无效）密钥
   * 有效条目统一返回标准指纹，供写回修复使用
   * @param entries .gpg-id 解析出的条目列表
   */
  validateFingerprints(entries: string[]): GpgIdValidation {
    const valid: string[] = [];
    const invalid: string[] = [];
    for (let i: number = 0; i < entries.length; i++) {
      const resolved: GpgKeyId | null = this.resolveKeyByIdEntry(entries[i]);
      if (resolved !== null) {
        valid.push(resolved.fingerprint);
      } else {
        // 记明确原因便于排查：短 Key ID 只有在唯一命中时才接受，走到这里说明
        // 它未导入或命中多把（有歧义）；其余形式则基本是「确实没导入这把密钥」
        const bare: string = entries[i].replace(/^0x/i, '');
        if (/^[0-9a-fA-F]{8}$/.test(bare)) {
          hilog.warn(DOMAIN, TAG, 'gpg-id short key id unresolved (not imported or ambiguous): %{public}s', entries[i]);
        } else {
          hilog.warn(DOMAIN, TAG, 'gpg-id entry unresolved (key not imported?): %{public}s', entries[i]);
        }
        invalid.push(entries[i]);
      }
    }
    const result: GpgIdValidation = { valid: valid, invalid: invalid };
    return result;
  }

  /**
   * 将 .gpg-id 条目解析为已导入密钥的标准指纹列表（未导入的条目丢弃）
   * 供解密时确定「这条密码由哪把密钥加密」
   * @param entries .gpg-id 解析出的条目列表
   */
  resolvedKeyFingerprints(entries: string[]): string[] {
    const result: string[] = [];
    for (let i: number = 0; i < entries.length; i++) {
      const resolved: GpgKeyId | null = this.resolveKeyByIdEntry(entries[i]);
      if (resolved !== null && result.indexOf(resolved.fingerprint) < 0) {
        result.push(resolved.fingerprint);
      }
    }
    return result;
  }

  /**
   * 按用户名模糊查找密钥
   * @param name 用户名关键词
   * @returns 匹配的密钥列表
   */
  searchKeysByName(name: string): GpgKeyId[] {
    const lowerName: string = name.toLowerCase();
    return this.keyCache.filter((k: GpgKeyId) =>
      k.name.toLowerCase().includes(lowerName) || k.email.toLowerCase().includes(lowerName)
    );
  }
}
