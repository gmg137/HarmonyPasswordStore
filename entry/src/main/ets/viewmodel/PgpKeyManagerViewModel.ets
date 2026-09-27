import { PgpKeyManager, KeyImportResult } from '../crypto/PgpKeyManager';
import { PgpPacketParser } from '../crypto/PgpPacketParser';
import { PgpCrypto } from '../crypto/PgpCrypto';
import { PasswordRepository } from '../model/PasswordRepository';
import { GpgKeyId } from '../model/GpgKeyId';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { picker } from '@kit.CoreFileKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { Strings } from '../common/Strings';

/** hilog 域 */
const DOMAIN: number = 0x0001;
/** hilog 标签 */
const TAG: string = 'PgpKeyMgrVM';

/**
 * 密钥导出结果
 *
 * 必须区分「成功 / 用户取消 / 失败」三态：取消是用户主动放弃，不该弹错误提示；
 * 而失败必须给出原因。用一个字符串（空串表示成功）会把两者混在一起。
 */
export interface KeyExportResult {
  ok: boolean;
  /** 用户在保存对话框中取消（非错误） */
  cancelled: boolean;
  /** 失败原因（ok 为 false 且非取消时有效） */
  error: string;
}

/**
 * PGP 密钥管理视图模型
 *
 * 管理密钥列表、导入表单、默认密钥选择。
 */
@ObservedV2
export class PgpKeyManagerViewModel {
  /** 密钥列表 */
  @Trace keys: GpgKeyId[] = [];
  /** 是否正在加载 */
  @Trace isLoading: boolean = false;
  /** 默认密钥指纹 */
  @Trace defaultFingerprint: string = '';
  /** 是否显示导入面板 */
  @Trace isImportVisible: boolean = false;
  /** 导入的 armored 密钥文本 */
  @Trace armoredKey: string = '';
  /** 密钥密码 */
  @Trace passphrase: string = '';
  /** 是否正在导入 */
  @Trace isImporting: boolean = false;
  /** 是否显示生成面板 */
  @Trace isGenerateVisible: boolean = false;
  /** 生成密钥的 User ID（如 Name <email@example.com>） */
  @Trace genUserId: string = '';
  /** 生成密钥算法："eddsa"（推荐）| "rsa4096" | "rsa2048" */
  @Trace genKeyType: string = 'eddsa';
  /** 生成密钥的密码（可选） */
  @Trace genPassphrase: string = '';
  /** 是否正在生成 */
  @Trace isGenerating: boolean = false;
  /** 错误提示 */
  @Trace errorMessage: string = '';
  /** 结果提示 */
  @Trace toast: string = '';
  /**
   * 导入成功但需告知用户的限制（非致命）
   *
   * 页面读取后应弹原生弹窗提示，并清空本字段（避免重复弹出）。
   */
  @Trace pendingWarning: string = '';
  /**
   * 待弹窗提示的导入失败原因（**不是**需要用户修改输入的错误）
   *
   * 目前两类：① 同指纹密钥已存在；② 导入的是公钥、不含私钥材料。
   * 与 `errorMessage` 分开：后者渲染成表单底部的小红字、容易被忽略，
   * 而这两类都不是「改一下输入就能通过」的错误——弹窗直接告知更清楚。
   * 由页面消费（`consumeImportDialog`），弹完清空。
   */
  @Trace pendingDuplicate: string = '';

  private keyManager: PgpKeyManager = PgpKeyManager.getInstance();

  /**
   * 加载密钥列表与默认密钥
   */
  async load(): Promise<void> {
    this.isLoading = true;
    this.errorMessage = '';
    try {
      this.keys = await this.keyManager.listKeys(true);
      this.defaultFingerprint = this.keyManager.getDefaultKeyFingerprint();
    } catch (e) {
      this.errorMessage = Strings.get('pgp_load_failed');
      hilog.error(DOMAIN, TAG, 'load failed: %{public}s', JSON.stringify(e));
    }
    this.isLoading = false;
  }

  /**
   * 切换导入面板
   */
  toggleImportPanel(): void {
    this.isImportVisible = !this.isImportVisible;
    this.errorMessage = '';
  }

  /**
   * 切换生成面板
   */
  toggleGeneratePanel(): void {
    this.isGenerateVisible = !this.isGenerateVisible;
    this.errorMessage = '';
  }

  /**
   * 设置生成算法
   */
  setGenKeyType(keyType: string): void {
    this.genKeyType = keyType;
  }

  /**
   * 应用内生成 PGP 密钥
   *
   * native rpgp 生成 V4 密钥（EdDSA/RSA 主键 + 加密子键），
   * 成功后刷新列表并确保 .gpg-id 存在。
   */
  async generateKey(): Promise<void> {
    if (this.genUserId.trim().length === 0) {
      this.errorMessage = Strings.get('pgp_err_userid_required');
      return;
    }
    if (this.genPassphrase.length > 0 && this.genPassphrase.length < 6) {
      this.errorMessage = Strings.get('pgp_err_passphrase_short');
      return;
    }

    this.isGenerating = true;
    this.errorMessage = '';

    const result: KeyImportResult = await this.keyManager.generateKey(this.genUserId, this.genKeyType, this.genPassphrase);
    this.isGenerating = false;

    if (result.success) {
      this.toast = Strings.get('pgp_generated');
      this.genUserId = '';
      this.genPassphrase = '';
      this.isGenerateVisible = false;
      await this.ensureGpgId();
      await this.load();
      this.scheduleToastClear();
    } else {
      this.errorMessage = result.error;
    }
  }

  /**
   * 导入密钥
   */
  async importKey(): Promise<void> {
    if (this.armoredKey.trim().length === 0) {
      this.errorMessage = Strings.get('pgp_err_paste_required');
      return;
    }
    this.isImporting = true;
    this.errorMessage = '';

    const result: KeyImportResult = await this.keyManager.importSecretKey(this.armoredKey, this.passphrase);
    this.isImporting = false;

    if (result.success) {
      // 导入成功但存在限制（如加密子密钥算法不受支持）时，用弹窗明确告知
      const warning: string = result.warning !== undefined ? result.warning : '';
      this.toast = warning.length > 0 ? Strings.get('pgp_imported_with_limit') : Strings.get('pgp_imported_ok');
      this.armoredKey = '';
      this.passphrase = '';
      this.isImportVisible = false;

      // 仓库尚无 .gpg-id 时自动写入，否则新建密码会报 'No PGP key selected'
      await this.ensureGpgId();

      await this.load();
      this.scheduleToastClear();

      if (warning.length > 0) {
        this.pendingWarning = warning;
      }
    } else if (result.alreadyExists === true || result.needsDialog === true) {
      // 不写 errorMessage（那是表单底部的小红字，容易被忽略）：
      // 这两类都不是改输入就能通过的错误，交由页面弹窗提示
      this.pendingDuplicate = result.alreadyExists === true
        ? Strings.get('pgp_duplicate_key')
        : result.error;
      this.errorMessage = '';
    } else {
      this.errorMessage = result.error;
    }
  }

  /**
   * 仓库根目录无 .gpg-id 时，写入「默认加密密钥」（未设默认时退回首把已导入私钥）
   *
   * 曾固定取 keys[0]（缓存顺序即导入顺序），与用户设置的默认加密密钥无关：
   * 于是导入任意一把密钥都可能把根目录 .gpg-id 写成另一把无关密钥
   * （实测：导入后根目录 .gpg-id 变成早期导入的 "PQC Test"），
   * 用户在根目录新建的条目全部用它加密，设了默认密钥也不生效。
   */
  private async ensureGpgId(): Promise<void> {
    try {
      const repo = PasswordRepository.getInstance();
      if (repo.getGpgIdForPath('').length > 0) {
        return;
      }
      const keys = await this.keyManager.listKeys(true);
      if (keys.length === 0) {
        return;
      }
      const preferred: string = this.keyManager.getDefaultKeyFingerprint();
      const hasPreferred: boolean =
        preferred.length > 0 && keys.some((k: GpgKeyId): boolean => k.fingerprint === preferred);
      const chosen: string = hasPreferred ? preferred : keys[0].fingerprint;
      const gpgIdResult = repo.setGpgIdForDir('', [chosen]);
      if (gpgIdResult.success) {
        hilog.info(DOMAIN, TAG, '.gpg-id written: %{public}s (default=%{public}s)',
          chosen, preferred);
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'ensureGpgId exception: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 根目录 .gpg-id 当前指向的密钥指纹（无 .gpg-id 或内容为空时返回 ''）
   *
   * 供「设为默认」后判断是否需要询问用户一并切换根目录加密密钥。
   */
  rootGpgIdFingerprint(): string {
    const entries: string[] = PasswordRepository.getInstance().getGpgIdForPath('');
    return entries.length > 0 ? entries[0] : '';
  }

  /** 把仓库根目录的加密密钥切换为指定指纹（须先经用户确认） */
  async switchRootGpgId(fingerprint: string): Promise<boolean> {
    const result = PasswordRepository.getInstance().setGpgIdForDir('', [fingerprint]);
    if (!result.success) {
      this.errorMessage = Strings.fmt('pgp_root_switch_failed', result.error);
    }
    return result.success;
  }

  /** 密钥显示名（无匹配时用指纹前 8 位），用于确认弹窗文案 */
  keyLabel(fingerprint: string): string {
    const key: GpgKeyId | undefined =
      this.keys.find((k: GpgKeyId): boolean => k.fingerprint === fingerprint);
    if (key === undefined) {
      return fingerprint.substring(0, 8);
    }
    return key.name.length > 0 ? key.name : key.email;
  }

  /**
   * 通过文件选择器读取 .asc/.gpg 密钥文件
   *
   * 只负责「选文件 → 读内容 → 填进 armoredKey」，实际导入由页面打开导入表单后
   * 调用 importKey() 完成。这样用户能看到文件内容、补填口令再确认，
   * 与「导入文本密钥」走同一条链路（含 ensureGpgId），行为一致。
   *
   * @returns true 表示已成功读入密钥内容，页面应打开导入表单；
   *          false 表示用户取消或读取失败（失败原因见 errorMessage）
   */
  async importKeyFromFile(): Promise<boolean> {
    try {
      const docPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker();
      const opts: picker.DocumentSelectOptions = {
        maxSelectNumber: 1,
        // .pgp 与 .asc 同为常见的 PGP 密钥文件后缀，须一并列出，否则选择器中看不到
        fileSuffixFilters: ['.asc', '.pgp', '.gpg', '.key'],
      };
      const uris: string[] = await docPicker.select(opts);
      if (uris.length === 0) {
        // 用户取消选择：不算错误，静默返回
        return false;
      }

      this.errorMessage = '';

      const fileUri: string = uris[0];
      const file: fs.File = fs.openSync(fileUri, fs.OpenMode.READ_ONLY);
      let bytes: Uint8Array = new Uint8Array(0);
      try {
        const stat: fs.Stat = fs.statSync(file.fd);
        if (stat.size <= 0) {
          this.errorMessage = Strings.get('pgp_file_empty');
          return false;
        }
        const buf: ArrayBuffer = new ArrayBuffer(stat.size);
        const readLen: number = fs.readSync(file.fd, buf);
        bytes = new Uint8Array(buf, 0, readLen);
      } finally {
        // 无论读取是否成功都要关闭 fd，避免句柄泄漏
        fs.closeSync(file);
      }

      // gpg --export-secret-keys 默认输出二进制格式（.pgp/.gpg 常见此格式），
      // 而解析与 native 链路都要求 armored 文本，故二进制需先转换
      if (PgpPacketParser.isBinaryKey(bytes)) {
        this.armoredKey = PgpPacketParser.armorBinaryKey(bytes, true);
        return true;
      }

      this.armoredKey = new util.TextDecoder('utf-8').decodeToString(bytes).trim();

      // armored 文本必须含 PGP 头，否则后续解析只会得到含糊的「解析失败」
      if (!this.armoredKey.includes('BEGIN PGP')) {
        this.errorMessage = Strings.get('pgp_file_not_pgp');
        return false;
      }

      return true;
    } catch (e) {
      this.errorMessage = Strings.fmt('common_file_read_failed', e instanceof Error ? e.message : JSON.stringify(e));
      hilog.error(DOMAIN, TAG, 'importKeyFromFile failed: %{public}s', JSON.stringify(e));
      return false;
    }
  }

  /**
   * 设置默认加密密钥
   */
  async setDefaultKey(fingerprint: string): Promise<void> {
    await this.keyManager.setDefaultKey(fingerprint);
    this.defaultFingerprint = fingerprint;
    this.toast = Strings.get('pgp_set_default_ok');
    this.scheduleToastClear();
  }

  /**
   * 删除密钥
   */
  async deleteKey(fingerprint: string): Promise<void> {
    const success: boolean = await this.keyManager.deleteKey(fingerprint);
    if (success) {
      this.toast = Strings.get('pgp_deleted');
      await this.load();
    } else {
      this.toast = Strings.get('home_delete_failed');
    }
    this.scheduleToastClear();
  }

  /**
   * 修改密钥密码（native 解锁后用新密码重新上锁）
   */
  async changePassphrase(fingerprint: string, oldPassphrase: string, newPassphrase: string): Promise<boolean> {
    const result: KeyImportResult = await this.keyManager.changePassphrase(fingerprint, oldPassphrase, newPassphrase);
    if (result.success) {
      // 旧口令缓存必须作废：留着它，改完口令的解密会反复拿失效的钥匙去试
      PgpCrypto.getInstance().forgetPassphrase(fingerprint);
      this.toast = Strings.get('pgp_pw_changed');
      this.scheduleToastClear();
      await this.load();
      return true;
    }
    this.errorMessage = result.error;
    return false;
  }

  /**
   * 导出密钥到本地 .asc 文件
   *
   * 私钥与公钥共用这一条实现（`isPrivate` 决定取哪份 armored 文本）。用**系统保存
   * 对话框**让用户选位置，文件名取**密钥邮箱**（`<邮箱>.asc`），没有邮箱时退化为
   * **指纹前 8 位**（`<前8位>.asc`）——指纹是唯一稳定标识，而邮箱可能为空。
   * 公钥加 `-public` 后缀：两种导出要能落到同一目录，同名会互相覆盖。
   *
   * **不再复制到剪贴板**：私钥是敏感凭据，剪贴板是明文且其它应用可读（复制路径
   * 只靠自动清除兜底）；而 .asc 文件才是 pass/gpg 生态里传递密钥的标准形态，
   * 落盘后可直接用「从文件导入密钥」或桌面端 gpg 还原。
   */
  async exportKeyToFile(fingerprint: string, isPrivate: boolean): Promise<KeyExportResult> {
    const armored: string = isPrivate
      ? this.keyManager.getKeyArmored(fingerprint)
      : await this.keyManager.exportPublicKey(fingerprint);
    if (armored.length === 0) {
      return { ok: false, cancelled: false, error: isPrivate ? Strings.get('pgp_export_read_private_failed') : Strings.get('pgp_export_pub_failed') };
    }
    try {
      const docPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker();
      const opts: picker.DocumentSaveOptions = {
        newFileNames: [this.keyExportFileName(fingerprint, isPrivate)],
        fileSuffixChoices: ['.asc'],
      };
      const uris: string[] = await docPicker.save(opts);
      if (uris.length === 0) {
        // 用户取消保存：不是失败，不弹错误提示
        return { ok: false, cancelled: true, error: '' };
      }
      // 保存对话框已建好文件，这里覆盖写（TRUNC 保证不留旧内容）
      const file: fs.File = fs.openSync(uris[0], fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, armored);
      } finally {
        // 无论写入是否成功都要关闭 fd，避免句柄泄漏
        fs.closeSync(file);
      }
      hilog.info(DOMAIN, TAG, 'key exported: private=%{public}s bytes=%{public}d',
        `${isPrivate}`, armored.length);
      return { ok: true, cancelled: false, error: '' };
    } catch (e) {
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : String(e);
      hilog.error(DOMAIN, TAG, 'exportKeyToFile failed: %{public}s', msg);
      return { ok: false, cancelled: false, error: Strings.fmt('pgp_export_save_failed', msg) };
    }
  }

  /** 导出文件名：优先密钥邮箱，无邮箱用指纹前 8 位 */
  private keyExportFileName(fingerprint: string, isPrivate: boolean): string {
    let email: string = '';
    for (let i: number = 0; i < this.keys.length; i++) {
      if (this.keys[i].fingerprint === fingerprint) {
        email = this.keys[i].email.trim();
        break;
      }
    }
    const base: string = email.length > 0 ? email : fingerprint.substring(0, 8);
    return isPrivate ? `${base}.asc` : `${base}-public.asc`;
  }

  /**
   * 是否为默认密钥
   */
  isDefaultKey(fingerprint: string): boolean {
    return this.defaultFingerprint.length > 0 && this.defaultFingerprint === fingerprint;
  }

  /**
   * 密钥是否已过期（expiry 为毫秒时间戳，0 表示永不过期）
   */
  isExpired(key: GpgKeyId): boolean {
    return key.expiry > 0 && key.expiry < Date.now();
  }

  /**
   * 2 秒后清除提示
   */
  private scheduleToastClear(): void {
    setTimeout(() => { this.toast = ''; }, 2000);
  }

  /**
   * 截断指纹显示（前后各 8 位）
   */
  formatFingerprint(fingerprint: string): string {
    if (fingerprint.length <= 16) return fingerprint;
    return `${fingerprint.substring(0, 8)}...${fingerprint.substring(fingerprint.length - 8)}`;
  }
}
