import { PasswordRepository } from '../model/PasswordRepository';
import { PasswordFileParser } from '../format/PasswordFileParser';
import { PasswordGenerator, PasswordGenParams, createDefaultPasswordGenParams } from '../passgen/PasswordGenerator';
import { RepoChangeNotifier } from '../common/RepoChangeNotifier';
import { PgpKeyManager } from '../crypto/PgpKeyManager';
import { GpgIdValidation, GpgKeyId } from '../model/GpgKeyId';
import { FileUtils } from '../utils/FileUtils';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** hilog 域 */
const DOMAIN: number = 0x0001;
/** hilog 标签 */
const TAG: string = 'PasswordCreateVM';

/**
 * 新建/编辑密码视图模型
 *
 * 管理密码条目的创建和编辑表单状态，加密后保存到仓库。
 */
@ObservedV2
export class PasswordCreateViewModel {
  /** 条目名称（最后一段） */
  @Trace name: string = '';
  /** 所在目录（相对路径，不含名称） */
  @Trace parentDir: string = '';
  /** 主密码 */
  @Trace password: string = '';
  /** 用户名 */
  @Trace username: string = '';
  /** 邮箱 */
  @Trace email: string = '';
  /** 手机号 */
  @Trace phone: string = '';
  /** URL */
  /** 备注 */
  @Trace notes: string = '';
  /** 额外内容（原始文本） */
  @Trace extraContent: string = '';
  /** 密码是否可见 */
  @Trace isPasswordVisible: boolean = false;
  /** 是否正在保存 */
  @Trace isSaving: boolean = false;
  /** 保存是否成功 */
  @Trace isSaved: boolean = false;
  /** 错误信息 */
  @Trace errorMessage: string = '';
  /** 密码生成器参数 */
  @Trace genParams: PasswordGenParams = createDefaultPasswordGenParams();
  /** 密码生成器是否可见 */
  @Trace isGeneratorVisible: boolean = false;
  /** 生成的密码强度（熵值 bits） */
  @Trace passwordStrength: number = 0;

  /** 是否为编辑模式 */
  private isEditMode: boolean = false;
  /** 编辑模式下的原始路径 */
  private originalPath: string = '';
  private repo: PasswordRepository = PasswordRepository.getInstance();

  /**
   * 初始化：编辑模式（按路径读取并解密）
   *
   * @param relativePath 原始相对路径
   */
  async initForEditByPath(relativePath: string): Promise<void> {
    const result = await this.repo.readPassword(relativePath);
    if (!result.success || !result.data) {
      this.errorMessage = result.error.length > 0 ? result.error : '读取密码失败';
      return;
    }
    this.initForEdit(relativePath, result.data);
  }

  /**
   * 是否为编辑模式
   */
  isEditing(): boolean {
    return this.isEditMode;
  }

  /**
   * 初始化：新建模式
   * @param parentDir 父目录路径
   */
  initForCreate(parentDir: string): void {
    this.isEditMode = false;
    this.parentDir = parentDir;
    this.name = '';
    this.password = '';
    this.username = '';
    this.email = '';
    this.phone = '';
    this.notes = '';
    this.extraContent = '';
    this.isSaved = false;
    this.errorMessage = '';
  }

  /**
   * 初始化：编辑模式
   * @param relativePath 原始相对路径
   * @param content 解密后的密码内容
   */
  initForEdit(relativePath: string, content: import('../model/PasswordEntry').PasswordContent): void {
    this.isEditMode = true;
    this.originalPath = relativePath;
    const lastSlash: number = relativePath.lastIndexOf('/');
    this.parentDir = lastSlash >= 0 ? relativePath.substring(0, lastSlash) : '';
    this.name = lastSlash >= 0 ? relativePath.substring(lastSlash + 1) : relativePath;
    this.password = content.password;
    this.username = content.username;
    this.email = content.email;
    this.phone = content.phone;
    this.notes = content.notes;
    this.extraContent = content.extraContent;
    this.isSaved = false;
    this.errorMessage = '';
  }

  /**
   * 获取完整相对路径
   */
  getRelativePath(): string {
    return this.parentDir.length > 0 ? `${this.parentDir}/${this.name}` : this.name;
  }

  /**
   * 切换密码可见性
   */
  togglePasswordVisibility(): void {
    this.isPasswordVisible = !this.isPasswordVisible;
  }

  /**
   * 使用密码生成器生成密码
   */
  generatePassword(): void {
    const generated: string = PasswordGenerator.generate(this.genParams);
    this.password = generated;
    this.passwordStrength = PasswordGenerator.estimateStrength(generated);
  }

  /**
   * 切换密码生成器面板
   */
  toggleGenerator(): void {
    this.isGeneratorVisible = !this.isGeneratorVisible;
  }

  /**
   * 更新生成器参数
   */
  updateGenParam(key: string, value: boolean | number | string): void {
    if (key === 'length' && typeof value === 'number') {
      this.genParams.length = value;
    } else if (key === 'includeUppercase' && typeof value === 'boolean') {
      this.genParams.includeUppercase = value;
    } else if (key === 'includeLowercase' && typeof value === 'boolean') {
      this.genParams.includeLowercase = value;
    } else if (key === 'includeDigits' && typeof value === 'boolean') {
      this.genParams.includeDigits = value;
    } else if (key === 'includeSymbols' && typeof value === 'boolean') {
      this.genParams.includeSymbols = value;
    } else if (key === 'excludeAmbiguous' && typeof value === 'boolean') {
      this.genParams.excludeAmbiguous = value;
    } else if (key === 'customCharset' && typeof value === 'string') {
      this.genParams.customCharset = value;
    }
    // 触发 @Trace 刷新：重新赋值整个对象
    const old: PasswordGenParams = this.genParams;
    this.genParams = {
      length: old.length,
      includeUppercase: old.includeUppercase,
      includeLowercase: old.includeLowercase,
      includeDigits: old.includeDigits,
      includeSymbols: old.includeSymbols,
      customCharset: old.customCharset,
      excludeAmbiguous: old.excludeAmbiguous,
    };
  }

  /**
   * 监听密码输入，更新强度
   */
  onPasswordInput(value: string): void {
    this.password = value;
    this.passwordStrength = PasswordGenerator.estimateStrength(value);
  }

  /**
   * 保存密码（加密写入）
   */
  async save(): Promise<void> {
    // 验证输入
    if (this.name.trim().length === 0) {
      this.errorMessage = '请输入名称';
      return;
    }
    if (this.password.length === 0) {
      this.errorMessage = '请输入密码';
      return;
    }
    // 名称会拼进文件路径：`../`、绝对路径或 `.` 开头都会读写到仓库之外
    if (!FileUtils.isSafeRelativePath(this.name.trim())) {
      this.errorMessage = '名称不能包含 ..、\\ 或以 . 开头';
      return;
    }
    // 编辑模式下名称未变化时跳过；新建/改名后与目录同名会遮蔽密码条目，必须拦截
    const conflictPath: string = this.getRelativePath();
    if (conflictPath !== this.originalPath && this.repo.directoryExists(conflictPath)) {
      this.errorMessage = '已存在同名目录，请更换名称';
      return;
    }

    this.isSaving = true;
    this.errorMessage = '';

    // 序列化为 pass 文件格式
    const serialized: string = PasswordFileParser.serialize(
      this.password,
      this.username,
      this.email,
      this.phone,
      this.notes,
      this.extraContent,
    );

    const relativePath: string = this.getRelativePath();

    // .gpg-id 校验：**只校验，不改写**。
    //
    // 曾把「引用了未导入密钥」的 .gpg-id 自动"修复"为有效子集（全部无效时还会回退到
    // 默认密钥并改写），这在一目录多密钥（pass 的常态，本应用已支持混用）下是**静默剥夺
    // 其他接收方的读取权**：只要本机没导入同事那把公钥，新建一个条目就会把那一行从
    // .gpg-id 里删掉，而 .gpg-id 属仓库内容、会随 git 同步下发给所有人。
    // 现在与 pass 对齐（`pass insert` 从不改 .gpg-id，gpg 遇到缺公钥直接报错）：
    // 明确报错并让用户显式处理（导入密钥，或用「修改此目录加密密钥」）。
    const gpgIdEntries: string[] = this.repo.getGpgIdForPath(relativePath);
    if (gpgIdEntries.length === 0) {
      // 该路径向上都没有 .gpg-id：用「默认加密密钥」兜底并落盘一份 .gpg-id。
      // 这是**新增**而非改写（不存在同名文件），否则 writePassword 直接报
      // 「No PGP key selected for this directory」——用户在根目录新建条目时
      // 看到的是无从下手的错误，而不是设置好的默认密钥生效。
      const defaultFp: string = await this.resolveDefaultRecipient();
      if (defaultFp.length === 0) {
        this.errorMessage = '未导入任何 PGP 密钥，无法加密保存，请先在设置中导入密钥';
        this.isSaving = false;
        return;
      }
      const gpgIdDir: string = this.repo.findGpgIdDir(relativePath);
      const writeResult = this.repo.setGpgIdForDir(gpgIdDir, [defaultFp]);
      if (!writeResult.success) {
        this.errorMessage = '写入 .gpg-id 失败: ' + writeResult.error;
        this.isSaving = false;
        return;
      }
      hilog.info(DOMAIN, TAG, 'no .gpg-id found, wrote default key %{public}s at %{public}s',
        defaultFp, gpgIdDir.length > 0 ? gpgIdDir : '(root)');
    } else {
      // 诊断日志：输出 .gpg-id 条目与已导入密钥的实际比对值
      // （含 encryptionKeyId —— 密文 PKESK 里的收件人是**加密子密钥**的 Key ID，
      //   排查「条目明明由已导入密钥加密却报缺少解密密钥」时靠它定位）
      const diagKeys: GpgKeyId[] = await PgpKeyManager.getInstance().listKeys(true);
      const diagFps: string[] = diagKeys.map((k: GpgKeyId) =>
        `fp=${k.fingerprint}(${k.fingerprint.length}) keyId=${k.keyId} encId=${k.encryptionKeyId}`);
      hilog.info(DOMAIN, TAG, 'gpg-id validate: entries=%{public}s cached=[%{public}s]',
        JSON.stringify(gpgIdEntries), diagFps.join('; '));
      const validation: GpgIdValidation = PgpKeyManager.getInstance().validateFingerprints(gpgIdEntries);
      if (validation.invalid.length > 0) {
        hilog.warn(DOMAIN, TAG, 'gpg-id has %{public}d unimported entries, refusing to save',
          validation.invalid.length);
        this.errorMessage = `该目录的 .gpg-id 引用了未导入的密钥（${validation.invalid.join('、')}），`
          + `无法为全部接收方加密。请先导入这些密钥，或用「修改此目录加密密钥」显式调整。`;
        this.isSaving = false;
        return;
      }
      // 实际用于加密的接收方列表（可能多把：pass 约定 .gpg-id 每行一把）
      const recipients: string[] = validation.valid;
      // 过期密钥校验：多接收方目录下只要还有一把未过期的可用密钥就能加密
      // （pass/gpg 允许收件人密钥过期，只是 gpg 会告警；此处只在全部过期时阻止）
      const keyMgr: PgpKeyManager = PgpKeyManager.getInstance();
      let hasUsableKey: boolean = false;
      for (let i: number = 0; i < recipients.length; i++) {
        const key = keyMgr.findKey(recipients[i]);
        if (key !== null && !(key.expiry > 0 && key.expiry < Date.now())) {
          hasUsableKey = true;
          break;
        }
      }
      if (!hasUsableKey) {
        this.errorMessage = '该目录的加密密钥均已过期，无法创建新密码（请导入新密钥或更新密钥）';
        this.isSaving = false;
        return;
      }
    }

    let result = await this.repo.writePassword(relativePath, serialized);

    // 改名成功后再删旧文件：顺序颠倒时，写入失败会让新密码和旧密码一起丢失
    // （deletePassword 不可回滚，还会级联清理空的父目录）。
    if (result.success && this.isEditMode && this.originalPath !== relativePath) {
      const del = this.repo.deletePassword(this.originalPath);
      if (!del.success) {
        // 新文件已写好，旧文件残留只是冗余，不阻断流程但要让用户知道
        hilog.warn(DOMAIN, TAG, 'cleanup of old file failed: %{public}s', del.error);
      }
    }

    this.isSaving = false;

    if (!result.success) {
      this.errorMessage = result.error;
      hilog.error(DOMAIN, TAG, 'save failed: %{public}s', result.error);
      return;
    }

    this.isSaved = true;
    // 编辑改名（名称/所在目录变化）时，详情页还持有旧路径——必须让它跟随新路径，
    // 否则它按旧路径解密会报「密钥不存在或解密失败」（旧文件已删）。
    // 与 MoveEntryViewModel 的同名机制一致（详情页 onRepoChange 读 movedFrom/movedTo）。
    const notifier = RepoChangeNotifier.connect();
    if (this.isEditMode && this.originalPath !== relativePath) {
      notifier.movedFrom = this.originalPath;
      notifier.movedTo = relativePath;
    }
    notifier.bump();
    hilog.info(DOMAIN, TAG, 'Password saved: %{public}s', relativePath);
  }

  /**
   * 解析兜底接收方：默认加密密钥 → 首把已导入私钥
   *
   * 默认密钥可能指向已删除/未导入的密钥，故必须校验存在性后再用。
   */
  private async resolveDefaultRecipient(): Promise<string> {
    const preferred: string = PgpKeyManager.getInstance().getDefaultKeyFingerprint();
    if (preferred.length > 0 && PgpKeyManager.getInstance().findKey(preferred) !== null) {
      return preferred;
    }
    const imported: GpgKeyId[] = await PgpKeyManager.getInstance().listKeys(false);
    return imported.length > 0 ? imported[0].fingerprint : '';
  }

  /**
   * 是否可以保存
   */
  canSave(): boolean {
    return this.name.trim().length > 0 && this.password.length > 0 && !this.isSaving;
  }

  /**
   * 密码强度等级文本
   */
  getStrengthLabel(): string {
    if (this.passwordStrength < 40) return '弱';
    if (this.passwordStrength < 80) return '中';
    if (this.passwordStrength < 120) return '强';
    return '极强';
  }

  /**
   * 密码强度颜色
   */
  getStrengthColor(): string {
    if (this.passwordStrength < 40) return '#FF4444';
    if (this.passwordStrength < 80) return '#FF8800';
    if (this.passwordStrength < 120) return '#44AA44';
    return '#008800';
  }
}
