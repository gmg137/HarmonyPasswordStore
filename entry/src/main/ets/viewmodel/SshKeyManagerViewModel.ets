import { SshKeyManager, SshKeyInfo, SshKeyResult, SshKeyStatus } from '../crypto/SshKeyManager';
import { SshKeyType } from '../common/Constants';
import { pasteboard } from '@kit.BasicServicesKit';
import { picker } from '@kit.CoreFileKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { NativeBridge, NativeResult } from '../common/NativeBridge';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** hilog 域 */
const DOMAIN: number = 0x0001;
/** hilog 标签 */
const TAG: string = 'SshKeyManagerVM';

/**
 * SSH 密钥管理视图模型
 *
 * SSH 密钥只保留一把：新建/导入都会替换旧密钥。
 * 交互对齐 PGP 密钥管理页（底部动作菜单 + 表单 + 编辑菜单）。
 */
@ObservedV2
export class SshKeyManagerViewModel {
  /** 密钥列表（最多一把） */
  @Trace keys: SshKeyInfo[] = [];
  /** 是否正在加载 */
  @Trace isLoading: boolean = false;
  /** 轻提示（操作结果） */
  @Trace toast: string = '';
  /** 错误提示 */
  @Trace errorMessage: string = '';

  // ===== 底部菜单 / 表单 =====
  /** 新建/导入底部菜单可见 */
  @Trace isAddSheetVisible: boolean = false;
  /** 生成表单可见 */
  @Trace isGenerateFormVisible: boolean = false;
  /** 导入表单可见 */
  @Trace isImportFormVisible: boolean = false;

  /** 选中的密钥类型 */
  @Trace selectedKeyType: SshKeyType = SshKeyType.ED25519;
  /** 公钥注释（通常为邮箱） */
  @Trace comment: string = '';
  /** 是否正在生成 */
  @Trace isGenerating: boolean = false;

  /** 已选中的私钥文件名（从文件导入时展示） */
  @Trace selectedFileName: string = '';
  /** 私钥文本（从文件读取，仅内存持有） */
  @Trace privateKeyText: string = '';
  /** 私钥口令（导入加密私钥时使用） */
  @Trace passphrase: string = '';
  /** 选中的私钥是否加密（选文件后探测，用于弹窗提示输口令） */
  @Trace isSelectedKeyEncrypted: boolean = false;
  /** 是否正在导入 */
  @Trace isImporting: boolean = false;

  // ===== 编辑菜单 =====
  /** 编辑菜单当前作用的密钥别名 */
  @Trace editAlias: string = '';

  private manager: SshKeyManager = SshKeyManager.getInstance();

  /**
   * 加载密钥列表
   */
  async load(): Promise<void> {
    this.isLoading = true;
    try {
      this.keys = this.manager.listKeys();
    } catch (e) {
      this.errorMessage = '加载密钥失败';
      hilog.error(DOMAIN, TAG, 'load failed: %{public}s', e instanceof Error ? e.message : String(e));
    }
    this.isLoading = false;
  }

  /** 是否已存在密钥（决定新建/导入是否需要替换提示） */
  hasKey(): boolean {
    return this.keys.length > 0;
  }

  // ===== 底部菜单 =====

  /** 打开新建菜单（复位表单态，保证每次都是菜单态） */
  openAddSheet(): void {
    this.isGenerateFormVisible = false;
    this.isImportFormVisible = false;
    this.errorMessage = '';
    this.isAddSheetVisible = true;
  }

  /** add sheet 关闭时复位 */
  resetAddSheet(): void {
    this.isAddSheetVisible = false;
    this.isGenerateFormVisible = false;
    this.isImportFormVisible = false;
    this.selectedFileName = '';
    this.privateKeyText = '';
    this.passphrase = '';
    this.isSelectedKeyEncrypted = false;
    this.comment = '';
    this.errorMessage = '';
  }

  /**
   * 打开生成表单（由页面在「无需替换」或用户确认替换后调用）
   */
  openGenerateForm(): void {
    this.isImportFormVisible = false;
    this.isGenerateFormVisible = true;
    this.isAddSheetVisible = true;
  }

  /**
   * 打开导入表单（由页面在「无需替换」或用户确认替换后调用）
   */
  openImportForm(): void {
    this.isGenerateFormVisible = false;
    this.isImportFormVisible = true;
    this.isAddSheetVisible = true;
  }

  /**
   * 生成新密钥对（会替换旧密钥）
   */
  async generateKeyPair(): Promise<void> {
    this.isGenerating = true;
    this.errorMessage = '';
    this.toast = '';
    try {
      const hadKey: boolean = this.hasKey();
      const info: SshKeyInfo | null = await this.manager.generateKeyPair(this.selectedKeyType, this.comment);
      if (info === null) {
        this.errorMessage = '密钥生成失败';
      } else {
        this.toast = hadKey ? 'SSH 密钥已替换' : 'SSH 密钥已生成';
        this.isAddSheetVisible = false;
        this.isGenerateFormVisible = false;
        this.comment = '';
        await this.load();
        this.scheduleToastClear();
      }
    } catch (e) {
      this.errorMessage = e instanceof Error ? e.message : '密钥生成失败';
    }
    this.isGenerating = false;
  }

  /**
   * 从文件选择私钥（OpenSSH 私钥文件）
   *
   * 只支持私钥：仅公钥无法通过 SSH 认证访问 Git 服务器，
   * 公钥由私钥在导入时自动推导。
   * @returns 是否成功选中并读取文件
   */
  async pickPrivateKeyFile(): Promise<boolean> {
    this.errorMessage = '';
    try {
      const docPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker();
      const opts: picker.DocumentSelectOptions = {
        maxSelectNumber: 1,
        // 私钥文件通常无后缀（id_ed25519）或为 .pem/.key，故不加后缀过滤
        // 以免文件被过滤掉导致选不到
      };
      const uris: string[] = await docPicker.select(opts);
      if (uris.length === 0) {
        return false;
      }

      const fileUri: string = uris[0];
      const file: fs.File = fs.openSync(fileUri, fs.OpenMode.READ_ONLY);
      const stat: fs.Stat = fs.statSync(file.fd);
      const buf: ArrayBuffer = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buf);
      fs.closeSync(file);

      const text: string = new util.TextDecoder('utf-8').decodeToString(new Uint8Array(buf));
      if (text.trim().length === 0) {
        this.errorMessage = '所选文件为空';
        return false;
      }

      this.privateKeyText = text;
      this.selectedFileName = SshKeyManagerViewModel.fileNameFromUri(fileUri);
      hilog.info(DOMAIN, TAG, 'pickPrivateKeyFile: %{public}s (%{public}d bytes)',
        this.selectedFileName, text.length);

      // 选中后立刻探测是否加密：已加密则提前引导用户输入口令，
      // 避免用户点导入后才被告知、误以为是文件损坏
      this.detectEncrypted();
      return true;
    } catch (e) {
      this.errorMessage = `文件读取失败: ${e instanceof Error ? e.message : String(e)}`;
      hilog.error(DOMAIN, TAG, 'pickPrivateKeyFile failed: %{public}s',
        e instanceof Error ? e.message : String(e));
      return false;
    }
  }

  /** 从 URI 取文件名（用于界面展示） */
  private static fileNameFromUri(uri: string): string {
    const idx: number = uri.lastIndexOf('/');
    return idx >= 0 ? uri.substring(idx + 1) : uri;
  }

  /**
   * 探测已选私钥是否加密
   *
   * native 推导公钥不带 comment，所以邮箱必须单独输入；
   * 这里只用于提前提示口令。
   */
  private detectEncrypted(): void {
    this.isSelectedKeyEncrypted = false;
    if (this.privateKeyText.trim().length === 0) {
      return;
    }
    // 无口令解析失败、且探测为有效 → 说明已加密
    const status: NativeResult = NativeBridge.getInstance().sshKeyStatus(this.privateKeyText);
    if (status.success && status.data.length > 0) {
      try {
        const parsed: SshKeyStatus = JSON.parse(status.data) as SshKeyStatus;
        this.isSelectedKeyEncrypted = parsed.valid && parsed.encrypted;
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'detectEncrypted: parse failed');
      }
    }
    hilog.info(DOMAIN, TAG, 'detectEncrypted: encrypted=%{public}d', this.isSelectedKeyEncrypted ? 1 : 0);
  }

  /**
   * 导入已选中的私钥文件（会替换旧密钥）
   *
   * 私钥经 native 解析校验（兼容带口令的私钥）并推导公钥，
   * 私钥与公钥一并保存。
   */
  async importPrivateKey(): Promise<void> {
    if (this.privateKeyText.trim().length === 0) {
      this.errorMessage = '请先选择私钥文件';
      return;
    }
    this.isImporting = true;
    this.errorMessage = '';
    this.toast = '';
    try {
      const hadKey: boolean = this.hasKey();
      const errOut: string[] = [];
      const info: SshKeyInfo | null = await this.manager
        .importPrivateKey(this.privateKeyText, this.passphrase, errOut);
      if (info === null) {
        this.errorMessage = errOut.length > 0 ? errOut[0] : '私钥导入失败';
      } else {
        this.toast = hadKey ? 'SSH 密钥已替换' : 'SSH 密钥已导入';
        this.isAddSheetVisible = false;
        this.isImportFormVisible = false;
        this.privateKeyText = '';
        this.selectedFileName = '';
        this.passphrase = '';
        this.isSelectedKeyEncrypted = false;
        await this.load();
        this.scheduleToastClear();
      }
    } catch (e) {
      this.errorMessage = e instanceof Error ? e.message : '导入失败';
    }
    this.isImporting = false;
  }

  // ===== 编辑菜单 =====

  /** 记录编辑菜单作用的密钥 */
  setEditAlias(alias: string): void {
    this.editAlias = alias;
  }

  /**
   * 复制公钥到剪贴板
   * @returns 结果提示文案（供页面用系统 Toast 展示）
   */
  async copyPublicKey(alias: string): Promise<string> {
    const pub: string = this.manager.getPublicKey(alias);
    if (pub.length === 0) {
      return '公钥不存在';
    }
    try {
      const pasteData: pasteboard.PasteData =
        pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, pub.trim());
      await pasteboard.getSystemPasteboard().setData(pasteData);
      return '公钥已复制到剪贴板';
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'copyPublicKey failed: %{public}s', e instanceof Error ? e.message : String(e));
      return '复制失败';
    }
  }

  /**
   * 删除密钥
   * @returns 结果提示文案
   */
  async deleteKey(alias: string): Promise<string> {
    const result: SshKeyResult = await this.manager.deleteKey(alias);
    if (result.success) {
      await this.load();
      return 'SSH 密钥已删除';
    }
    this.errorMessage = result.error.length > 0 ? result.error : '删除失败';
    return '删除失败';
  }

  /**
   * 密钥类型显示名
   */
  keyTypeLabel(keyType: SshKeyType): string {
    switch (keyType) {
      case SshKeyType.RSA:
        return 'RSA 3072';
      case SshKeyType.ECDSA:
        return 'ECDSA P-256';
      case SshKeyType.ED25519:
      default:
        return 'Ed25519';
    }
  }

  /**
   * 格式化创建时间
   */
  formatCreatedAt(ts: number): string {
    if (ts <= 0) return '';
    const d: Date = new Date(ts);
    const pad = (n: number): string => n < 10 ? `0${n}` : `${n}`;
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
  }

  /**
   * 列表主标题：邮箱 / 标识；未设置时回退别名（私钥文件名）
   */
  displayName(key: SshKeyInfo): string {
    if (key.email.length > 0) return key.email;
    // 公钥末尾可能带 comment（导入公钥场景），再回退一次
    const parts: string[] = key.publicKey.trim().split(/\s+/);
    if (parts.length >= 3 && parts[2].length > 0) return parts[2];
    return key.alias;
  }

  /**
   * 列表副标题：加密方式 · 导入日期
   */
  subtitle(key: SshKeyInfo): string {
    const date: string = this.formatCreatedAt(key.createdAt);
    return date.length > 0
      ? `${this.keyTypeLabel(key.keyType)} · ${date}`
      : this.keyTypeLabel(key.keyType);
  }

  /**
   * 截断公钥显示（前 40 位 + 省略号）
   */
  formatPublicKey(pub: string): string {
    if (pub.length <= 40) return pub;
    return `${pub.substring(0, 40)}…`;
  }

  /**
   * 2 秒后清除提示
   */
  private scheduleToastClear(): void {
    setTimeout(() => { this.toast = ''; }, 2000);
  }
}
