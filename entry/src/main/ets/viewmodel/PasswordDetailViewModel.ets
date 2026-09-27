import { PasswordRepository } from '../model/PasswordRepository';
import { PasswordContent } from '../model/PasswordEntry';
import { GpgKeyId } from '../model/GpgKeyId';
import { SettingsRepository } from '../model/SettingsRepository';
import { RepoChangeNotifier } from '../common/RepoChangeNotifier';
import { PgpCrypto, UnlockResult } from '../crypto/PgpCrypto';
import { PgpKeyManager } from '../crypto/PgpKeyManager';
import { ClipboardHelper } from '../utils/ClipboardHelper';
import { Strings } from '../common/Strings';
import { promptAction } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** hilog 域 */
const DOMAIN: number = 0x0001;
/** hilog 标签 */
const TAG: string = 'PasswordDetailVM';

/**
 * 密码详情视图模型
 *
 * 负责解密密码文件、管理显示状态、处理复制操作。
 */
@ObservedV2
export class PasswordDetailViewModel {
  /** 条目相对路径 */
  /**
   * 页面注入的 toast 回调（见 showToast：ViewModel 无法拿到 UIContext）
   */
  onToast: ((message: string) => void) | null = null;

  @Trace relativePath: string = '';
  /** 显示名称 */
  @Trace displayName: string = '';
  /** 解密后的密码内容 */
  @Trace content: PasswordContent | null = null;
  /** 是否正在解密 */
  @Trace isDecrypting: boolean = false;
  /** 解密是否成功 */
  @Trace isDecrypted: boolean = false;
  /** 错误信息 */
  @Trace errorMessage: string = '';
  /** 密码是否可见（默认隐藏：密码本身是凭据；备注/额外内容是正文，直接显示） */
  @Trace isPasswordVisible: boolean = false;
  /** 复制提示文本 */
  @Trace copyToast: string = '';
  /** 是否正在删除 */
  @Trace isDeleting: boolean = false;
  /** 删除是否成功（页面据此返回列表） */
  @Trace isDeleted: boolean = false;
  /** 密钥密码弹窗是否可见 */
  @Trace passphraseDialogVisible: boolean = false;
  /** 弹窗中输入的密码 */
  @Trace dialogPassphrase: string = '';

  private repo: PasswordRepository = PasswordRepository.getInstance();

  /**
   * 初始化：设置路径并开始解密
   */
  init(relativePath: string): void {
    this.relativePath = relativePath;
    // 取最后一段作为显示名
    const lastSlash: number = relativePath.lastIndexOf('/');
    this.displayName = lastSlash >= 0 ? relativePath.substring(lastSlash + 1) : relativePath;
    this.decrypt();
  }

  /**
   * 本条密码的解锁候选密钥（供「请输入密钥密码」弹窗使用）
   *
   * **必须以密文实际收件人（PKESK Key ID）为准，`.gpg-id` 只是兜底**：
   * 曾只用 `.gpg-id` 解析，于是当 `.gpg-id` 与密文收件人不一致时（换过密钥、
   * 条目被移到了另一把密钥的目录、或条目本就由别的密钥加密），用户输入的密码会被
   * 拿去做**错误的密钥**的校验——若那把密钥恰好无口令，校验还会"通过"并缓存，
   * 真正能解的密钥永远拿不到密码，条目怎么都打不开（表现为反复弹框、输入正确密码
   * 也报解密失败）。列表页早就是密文优先（`entryDecryptionCandidates`），此处对齐。
   */
  private candidateFingerprints(): string[] {
    const repo: PasswordRepository = PasswordRepository.getInstance();
    const gpgIdFps: string[] = PgpKeyManager.getInstance()
      .resolvedKeyFingerprints(repo.getGpgIdForPath(this.relativePath));
    const ciphertext: string = repo.readCiphertext(this.relativePath);
    return PgpCrypto.getInstance().entryDecryptionCandidates(ciphertext, gpgIdFps);
  }

  /** 兜底：全部已导入私钥指纹（.gpg-id 无可用条目时，让用户密码对任意私钥试一次） */
  private async allSecretFingerprints(): Promise<string[]> {
    const keys: GpgKeyId[] = await PgpKeyManager.getInstance().listKeys(true);
    const result: string[] = [];
    for (let i: number = 0; i < keys.length; i++) {
      result.push(keys[i].fingerprint);
    }
    return result;
  }

  /**
   * 解密密码文件
   */
  async decrypt(): Promise<void> {
    this.isDecrypting = true;
    this.errorMessage = '';

    // 按本条目的实际密钥判断是否已就绪：无密码保护的密钥不应弹输入框，
    // 也不能因别的密钥已解锁就跳过（否则会张冠李戴、把会话串到别的密钥上）
    const candidates: string[] = this.candidateFingerprints();
    const crypto: PgpCrypto = PgpCrypto.getInstance();
    const ready: boolean = candidates.length > 0
      ? crypto.isUnlockedFor(candidates)
      : crypto.isUnlocked();
    if (!ready) {
      await crypto.ensureUnlocked(candidates);
    }

    const result = await this.repo.readPassword(this.relativePath);
    this.isDecrypting = false;

    if (!result.success || !result.data) {
      // 文件不存在（如已被移动/删除）：不弹密码框，仅记录错误
      if (result.error.indexOf('not found') >= 0) {
        this.isDecrypted = false;
        this.errorMessage = Strings.get('detail_err_file_missing');
        hilog.info(DOMAIN, TAG, 'decrypt failed: file not found');
        return;
      }
      // 解密失败：可能是密钥有密码保护但未解锁，弹窗让用户输入
      this.isDecrypted = false;
      this.passphraseDialogVisible = true;
      this.dialogPassphrase = '';
      this.errorMessage = '';
      hilog.info(DOMAIN, TAG, 'decrypt failed, showing passphrase dialog');
      return;
    }

    this.content = result.data;
    this.isDecrypted = true;
  }

  /**
   * 弹窗中确认密码后重试解密
   */
  async confirmPassphraseAndDecrypt(): Promise<void> {
    // 先进入加载态再关弹窗：避免渲染帧落在「非解密中且未成功」分支闪现"解密失败"
    this.isDecrypting = true;
    this.passphraseDialogVisible = false;
    if (this.dialogPassphrase.length === 0) {
      this.isDecrypting = false;
      this.errorMessage = Strings.get('detail_err_passphrase_required');
      return;
    }

    // 用输入的密码解锁「本条密码所属目录的密钥」——
    // 若用默认密钥解锁，解锁的会话与密文密钥不匹配，仍会解密失败
    const pgpCrypto: PgpCrypto = PgpCrypto.getInstance();
    const candidates: string[] = this.candidateFingerprints();
    const targets: string[] = candidates.length > 0
      ? candidates
      : await this.allSecretFingerprints();
    let unlocked: boolean = false;
    // 记录失败原因：只显示「密码错误」会掩盖「导入的是公钥」等可修复问题
    let failReason: string = Strings.get('detail_err_unlock_failed');
    for (let i: number = 0; i < targets.length; i++) {
      const res: UnlockResult = await pgpCrypto.unlockPassphrase(targets[i], this.dialogPassphrase);
      if (res.success) {
        unlocked = true;
        break;
      }
      if (res.error.length > 0) {
        failReason = res.error;
      }
    }
    this.dialogPassphrase = '';

    if (!unlocked) {
      // 必须复位 isDecrypting：页面在 isDecrypting 为真时只渲染 LoadingProgress，
      // 不复位会让用户永久卡在「正在解密…」，连 errorMessage 都看不到，也无重试入口。
      // 同时重新打开弹窗，否则（弹窗已关 + isDecrypted 仍为 false）没有任何可操作控件。
      this.isDecrypting = false;
      this.errorMessage = failReason;
      this.passphraseDialogVisible = true;
      hilog.error(DOMAIN, TAG, 'unlockPassphrase failed: %{public}s', failReason);
      return;
    }

    // 解锁成功，重试解密
    this.isDecrypting = true;
    this.errorMessage = '';
    const result = await this.repo.readPassword(this.relativePath);
    this.isDecrypting = false;

    if (!result.success || !result.data) {
      this.isDecrypted = false;
      this.errorMessage = result.error;
      hilog.error(DOMAIN, TAG, 'retry decrypt failed: %{public}s', result.error);
      return;
    }

    this.content = result.data;
    this.isDecrypted = true;
  }

  /**
   * 弹窗取消
   */
  cancelPassphraseDialog(): void {
    this.passphraseDialogVisible = false;
    this.dialogPassphrase = '';
    this.errorMessage = Strings.get('detail_err_cancelled');
  }

  /**
   * 切换密码可见性
   */
  togglePasswordVisibility(): void {
    this.isPasswordVisible = !this.isPasswordVisible;
  }

  /**
   * 删除密码条目
   */
  async deleteEntry(): Promise<void> {
    if (this.isDeleting) return;
    this.isDeleting = true;
    this.errorMessage = '';

    const result = this.repo.deletePassword(this.relativePath);
    this.isDeleting = false;

    if (!result.success) {
      this.errorMessage = result.error.length > 0 ? result.error : Strings.get('detail_err_delete_failed');
      hilog.error(DOMAIN, TAG, 'delete failed: %{public}s', result.error);
      return;
    }
    this.isDeleted = true;
    RepoChangeNotifier.connect().bump();
    hilog.info(DOMAIN, TAG, 'password deleted: %{public}s', this.relativePath);
  }

  /**
   * 复制密码到剪贴板
   */
  async copyPassword(): Promise<void> {
    if (!this.content) return;
    await this.copyToClipboard(this.content.password, Strings.get('detail_copied_password'));
  }

  /**
   * 复制用户名到剪贴板
   */
  async copyUsername(): Promise<void> {
    if (!this.content || this.content.username.length === 0) return;
    await this.copyToClipboard(this.content.username, Strings.get('detail_copied_username'));
  }

  /**
   * 复制邮箱到剪贴板
   */
  async copyEmail(): Promise<void> {
    if (!this.content || this.content.email.length === 0) return;
    await this.copyToClipboard(this.content.email, Strings.get('detail_copied_email'));
  }

  /**
   * 复制手机号到剪贴板
   */
  async copyPhone(): Promise<void> {
    if (!this.content || this.content.phone.length === 0) return;
    await this.copyToClipboard(this.content.phone, Strings.get('detail_copied_phone'));
  }

  /**
   * 复制备注到剪贴板
   */
  async copyNotes(): Promise<void> {
    if (!this.content || this.content.notes.length === 0) return;
    await this.copyToClipboard(this.content.notes, Strings.get('detail_copied_notes'));
  }

  /**
   * 复制额外内容到剪贴板
   *
   * 额外内容有自己的复制按钮，**不能复用 `copyAll()`**：后者复制的是整份原文
   * （rawText，含密码/用户名等全部字段）——曾因此在「额外内容」行点复制却把
   * 密码一起复制走，与按钮语义不符，也把敏感字段多复制了一份。
   */
  async copyExtraContent(): Promise<void> {
    if (!this.content || this.content.extraContent.length === 0) return;
    await this.copyToClipboard(this.content.extraContent, Strings.get('detail_copied_extra'));
  }

  /**
   * 复制全部内容到剪贴板
   */
  async copyAll(): Promise<void> {
    if (!this.content) return;
    await this.copyToClipboard(this.content.rawText, Strings.get('detail_copied_all'));
  }

  /**
   * 执行复制操作
   */
  private async copyToClipboard(text: string, toastMessage: string): Promise<void> {
    // 走 ClipboardHelper 统一排定自动清除（含页面销毁时的强制清除）
    const ok: boolean = await ClipboardHelper.getInstance().copy(text);
    if (ok) {
      this.showToast(toastMessage);
    } else {
      this.showToast(Strings.get('common_copy_failed'));
    }
  }

  /**
   * 系统悬浮气泡提示（不占页面布局，不会顶起底部按钮）
   */
  private showToast(message: string): void {
    // 全局 promptAction.showToast 自 API 18 废弃（且会引发 UI 上下文不明确的问题），
    // 而 ViewModel 拿不到 UIContext，故由页面在初始化时注入 toast 回调。
    if (this.onToast !== null) {
      this.onToast(message);
    }
  }

  /**
   * 页面销毁时清理
   *
   * 必须真的清掉剪贴板：仅取消定时器会让刚复制的密码永久留在系统剪贴板里。
   */
  onDispose(): void {
    ClipboardHelper.getInstance().onDispose();
  }
}
