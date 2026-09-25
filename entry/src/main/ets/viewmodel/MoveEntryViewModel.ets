import { PasswordRepository } from '../model/PasswordRepository';
import { PgpKeyManager } from '../crypto/PgpKeyManager';
import { PgpCrypto, UnlockResult } from '../crypto/PgpCrypto';
import { GpgKeyId } from '../model/GpgKeyId';
import { ReencryptService } from '../utils/ReencryptService';
import { RepoChangeNotifier } from '../common/RepoChangeNotifier';
import { RouteManager } from '../common/RouteManager';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** hilog 域 */
const DOMAIN: number = 0x0001;
/** hilog 标签 */
const TAG: string = 'MoveEntryVM';

/** 一次移动的执行结果（内部用） */
interface MoveOutcome {
  success: boolean;
  error: string;
  /** 成功时的提示文案 */
  toast: string;
}

/**
 * 待执行的移动上下文
 */
interface MoveContext {
  /** 目标相对路径（新位置 + 新名称） */
  newPath: string;
  /** 目标目录的接收方指纹（由该目录就近 .gpg-id 解析而来） */
  targetFingerprints: string[];
  /** 目标接收方的加密子密钥 Key ID 集合 */
  targetKeyIds: string[];
  /** 密文当前的收件人 Key ID（PKESK） */
  currentKeyIds: string[];
  /** 是否需要重加密（当前收件人 != 目标收件人） */
  needsReencrypt: boolean;
  /** 能解开该条目的已导入私钥指纹（解锁与解密都用它） */
  decryptKeys: string[];
}

/**
 * 移动/重命名密码条目视图模型
 *
 * 目录选择由 FolderTreeView 组件承担（selectedPath 为目标目录），
 * 本 VM 管理新名称输入与保存执行。
 *
 * ## 移动与「目标目录密钥」的关系
 *
 * 密文的收件人在加密时就写死了，单纯移动文件不会改变它；因此把条目移到使用
 * **另一把密钥**的目录后，它会成为目标目录里的异类（只有旧密钥能解）。本 VM 的处理：
 * - 目标目录密钥与条目当前收件人**一致** → 直接移动，不打扰用户；
 * - **不一致** → 用旧密钥解密、按目标目录密钥重新加密，再落盘到新位置；
 *   旧密钥已解锁（口令在缓存里，或无口令保护）则全程无提示，
 *   未解锁（如应用上锁清空了口令缓存）则弹口令框，解锁后继续；
 * - 缺少旧密钥（条目由未导入的密钥加密）时无法重加密，此时仍完成移动
 *   但明确提示「未重新加密」，不静默留下打不开的条目。
 *
 * 注：这与 `pass mv`（只 `mv` + git，不重加密）不同，是本应用的有意增强。
 */
@ObservedV2
export class MoveEntryViewModel {
  /** 原相对路径（不含 .gpg 扩展名） */
  @Trace oldPath: string = '';
  /** 原文件名（不含扩展名） */
  @Trace oldName: string = '';
  /** 新名称输入 */
  @Trace newName: string = '';
  /** 目标目录相对路径（'' 为根） */
  @Trace targetDir: string = '';
  /** 是否正在保存 */
  @Trace isSaving: boolean = false;
  /** 错误信息 */
  @Trace errorMessage: string = '';
  /** 成功提示 */
  @Trace toast: string = '';

  // ===== 密钥口令弹窗（需要重加密但旧密钥未解锁）=====
  /** 弹窗是否可见 */
  @Trace passphraseVisible: boolean = false;
  /** 用户输入的口令 */
  @Trace dialogPassphrase: string = '';
  /** 弹窗内错误提示 */
  @Trace dialogError: string = '';
  /** 是否正在解锁 */
  @Trace isUnlocking: boolean = false;
  /** 候选密钥标签（PGP ID，供用户确认是哪把密钥要口令） */
  @Trace candidateLabels: string = '';

  private repo: PasswordRepository = PasswordRepository.getInstance();
  /** 等口令期间挂起的移动上下文（取消/失败时清空，未做任何改动） */
  private pending: MoveContext | null = null;

  /**
   * 初始化（从路由参数读取原路径）
   */
  init(oldPath: string): void {
    this.oldPath = oldPath;
    const lastSlash: number = oldPath.lastIndexOf('/');
    this.oldName = lastSlash >= 0 ? oldPath.substring(lastSlash + 1) : oldPath;
    this.newName = this.oldName;
    this.targetDir = lastSlash >= 0 ? oldPath.substring(0, lastSlash) : '';
  }

  /**
   * 目录树选中回调
   */
  onDirSelected(path: string): void {
    this.targetDir = path;
  }

  /**
   * 构建新相对路径
   */
  private buildNewPath(): string {
    const name: string = this.newName.trim();
    return this.targetDir.length > 0 ? `${this.targetDir}/${name}` : name;
  }

  /**
   * 构建移动上下文：判断目标位置是否要求换密钥
   *
   * 比较的是**密文实际的收件人 Key ID**（PKESK）与目标目录 `.gpg-id` 解析出的
   * 加密子密钥 Key ID 集合——与「修改此目录加密密钥」同一判据。
   */
  private buildMoveContext(newPath: string): MoveContext {
    const crypto: PgpCrypto = PgpCrypto.getInstance();
    const mgr: PgpKeyManager = PgpKeyManager.getInstance();
    const targetFingerprints: string[] =
      mgr.resolvedKeyFingerprints(this.repo.getGpgIdForPath(newPath));
    const targetKeyIds: string[] =
      ReencryptService.getInstance().targetKeyIds(targetFingerprints);
    const ciphertext: string = this.repo.readCiphertext(this.oldPath);
    const currentKeyIds: string[] = ciphertext.length > 0
      ? crypto.recipientKeyIds(ciphertext) : [];
    // 目标目录无可用密钥、或密文没标收件人（隐藏收件人）时不判为「需要换密钥」：
    // 没有可换的目标，硬换只会把条目变成谁也解不开
    const needsReencrypt: boolean = targetKeyIds.length > 0 && currentKeyIds.length > 0
      && !ReencryptService.sameIdSet(currentKeyIds, targetKeyIds);
    const currentDirFps: string[] = needsReencrypt
      ? mgr.resolvedKeyFingerprints(this.repo.getGpgIdForPath(this.oldPath)) : [];
    const decryptKeys: string[] = needsReencrypt
      ? crypto.entryDecryptionCandidates(ciphertext, currentDirFps) : [];
    return {
      newPath: newPath,
      targetFingerprints: targetFingerprints,
      targetKeyIds: targetKeyIds,
      currentKeyIds: currentKeyIds,
      needsReencrypt: needsReencrypt,
      decryptKeys: decryptKeys,
    };
  }

  /**
   * 执行移动/重命名
   */
  async save(): Promise<void> {
    const name: string = this.newName.trim();
    if (name.length === 0) {
      this.errorMessage = '名称不能为空';
      return;
    }
    if (name.includes('/')) {
      this.errorMessage = '名称不能包含 /';
      return;
    }

    const newPath: string = this.buildNewPath();
    if (newPath === this.oldPath) {
      this.errorMessage = '位置和名称未变化';
      return;
    }

    this.isSaving = true;
    this.errorMessage = '';

    const ctx: MoveContext = this.buildMoveContext(newPath);
    if (!ctx.needsReencrypt) {
      // 收件人一致：直接移动，不提示
      await this.finish(this.plainMove(ctx.newPath, ''), ctx.newPath);
      return;
    }

    hilog.info(DOMAIN, TAG, 'move needs re-encrypt: %{public}s (current=[%{public}s] target=[%{public}s])',
      this.oldPath, ctx.currentKeyIds.join(','), ctx.targetKeyIds.join(','));

    if (ctx.decryptKeys.length === 0) {
      // 没有能解开该条目的私钥：无法重加密，移动照做（对齐 pass mv）但明确告知
      await this.finish(this.plainMove(ctx.newPath,
        '已移动；但缺少解密密钥，未按目标目录密钥重新加密'), ctx.newPath);
      return;
    }

    const crypto: PgpCrypto = PgpCrypto.getInstance();
    if (crypto.isUnlockedFor(ctx.decryptKeys)) {
      // 旧密钥已解锁（缓存有口令，或无口令保护）：静默重加密
      await this.finish(await this.reencryptMove(ctx), ctx.newPath);
      return;
    }

    // 未解锁（例如上锁清空了口令缓存）：弹口令框，解锁后继续
    this.pending = ctx;
    this.candidateLabels = await this.buildCandidateLabels(ctx.decryptKeys);
    this.dialogPassphrase = '';
    this.dialogError = '';
    this.passphraseVisible = true;
    this.isSaving = false;
  }

  /**
   * 纯文件移动（不重加密）
   */
  private plainMove(newPath: string, toast: string): MoveOutcome {
    const result = this.repo.renamePassword(this.oldPath, newPath);
    if (!result.success) {
      return { success: false, error: result.error, toast: '' };
    }
    hilog.info(DOMAIN, TAG, 'moved (no re-encrypt) %{public}s -> %{public}s', this.oldPath, newPath);
    return { success: true, error: '', toast: toast.length > 0 ? toast : '已保存' };
  }

  /**
   * 解密 → 按目标目录密钥重加密 → 写到新位置 → 删除旧文件
   */
  private async reencryptMove(ctx: MoveContext): Promise<MoveOutcome> {
    const crypto: PgpCrypto = PgpCrypto.getInstance();
    const ciphertext: string = this.repo.readCiphertext(this.oldPath);
    if (ciphertext.length === 0) {
      return { success: false, error: '读取密文失败', toast: '' };
    }
    const decrypted = await crypto.decrypt(ciphertext, ctx.decryptKeys);
    if (!decrypted.success) {
      return { success: false, error: `解密失败：${decrypted.error}`, toast: '' };
    }
    const encrypted = await crypto.encrypt(decrypted.data, ctx.targetFingerprints);
    if (!encrypted.success) {
      return { success: false, error: `按目标目录密钥加密失败：${encrypted.error}`, toast: '' };
    }
    // **先写新位置、再删旧文件**：任一步失败都不会两头空
    const written = this.repo.writeCiphertextAt(ctx.newPath, encrypted.data);
    if (!written.success) {
      return { success: false, error: `写入新位置失败：${written.error}`, toast: '' };
    }
    const deleted = this.repo.deletePassword(this.oldPath);
    if (!deleted.success) {
      return { success: false, error: `已写入新位置，但删除原文件失败：${deleted.error}`, toast: '' };
    }
    hilog.info(DOMAIN, TAG, 'moved with re-encrypt %{public}s -> %{public}s',
      this.oldPath, ctx.newPath);
    return { success: true, error: '', toast: '已移动并按目标目录密钥重新加密' };
  }

  /**
   * 收尾：通知列表/详情刷新并关闭页面
   */
  private async finish(outcome: MoveOutcome, newPath: string): Promise<void> {
    this.isSaving = false;
    if (!outcome.success) {
      this.errorMessage = outcome.error;
      return;
    }
    this.pending = null;
    // 携带移动前后路径通知，详情页跟随新路径重新解密
    const notifier: RepoChangeNotifier = RepoChangeNotifier.connect();
    notifier.movedFrom = this.oldPath;
    notifier.movedTo = newPath;
    notifier.bump();
    this.toast = outcome.toast;
    this.scheduleClose();
  }

  /**
   * 口令弹窗确认：逐把候选密钥验证口令，成功后继续挂起的移动
   *
   * 逐把尝试是因为多接收方条目任一把的口令都能解开（与列表页解锁同逻辑）。
   */
  async confirmPassphrase(): Promise<void> {
    if (this.isUnlocking || this.dialogPassphrase.length === 0) {
      return;
    }
    const ctx: MoveContext | null = this.pending;
    if (ctx === null) {
      this.cancelPassphrase();
      return;
    }
    this.isUnlocking = true;
    this.dialogError = '';

    const crypto: PgpCrypto = PgpCrypto.getInstance();
    let unlocked: boolean = false;
    let failReason: string = '密钥密码错误，请重试';
    for (let i: number = 0; i < ctx.decryptKeys.length; i++) {
      const res: UnlockResult = await crypto.unlockPassphrase(ctx.decryptKeys[i], this.dialogPassphrase);
      if (res.success) {
        unlocked = true;
        break;
      }
      if (res.error.length > 0) {
        failReason = res.error;
      }
    }
    this.isUnlocking = false;
    if (!unlocked) {
      this.dialogError = failReason;
      return;
    }

    this.passphraseVisible = false;
    this.isSaving = true;
    await this.finish(await this.reencryptMove(ctx), ctx.newPath);
  }

  /** 口令弹窗取消：放弃本次移动（尚未改动任何文件） */
  cancelPassphrase(): void {
    this.passphraseVisible = false;
    this.dialogPassphrase = '';
    this.dialogError = '';
    this.pending = null;
  }

  /**
   * 候选密钥标签（弹窗里告诉用户是哪把密钥要口令）
   *
   * 与列表页口径一致：多把候选全部列出——任一把的口令都能解锁该条目
   */
  private async buildCandidateLabels(fingerprints: string[]): Promise<string> {
    const keys: GpgKeyId[] = await PgpKeyManager.getInstance().listKeys(true);
    const labels: string[] = [];
    for (let i: number = 0; i < fingerprints.length; i++) {
      const key: GpgKeyId | undefined = keys.find((k: GpgKeyId) => k.fingerprint === fingerprints[i]);
      if (key === undefined) {
        continue;
      }
      const label: string = key.email.length > 0 ? key.email : key.name;
      if (!labels.includes(label)) {
        labels.push(label);
      }
    }
    return labels.join('、');
  }

  /**
   * 短暂停留后关闭页面（让用户看到成功提示）
   */
  private scheduleClose(): void {
    setTimeout(() => {
      RouteManager.getInstance().pop();
    }, 800);
  }
}
