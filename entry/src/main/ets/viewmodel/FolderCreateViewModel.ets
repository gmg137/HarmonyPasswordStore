import { PasswordRepository } from '../model/PasswordRepository';
import { FileUtils } from '../utils/FileUtils';
import { PgpKeyManager } from '../crypto/PgpKeyManager';
import { GpgKeyId } from '../model/GpgKeyId';
import { RepoChangeNotifier } from '../common/RepoChangeNotifier';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** hilog 域 */
const DOMAIN: number = 0x0001;
/** hilog 标签 */
const TAG: string = 'FolderCreateVM';

/**
 * 创建文件夹视图模型
 *
 * 管理文件夹名称输入和 PGP 密钥选择状态，
 * 创建文件夹时可同时为子目录设置 .gpg-id（覆盖父目录密钥）。
 */
@ObservedV2
export class FolderCreateViewModel {
  /** 文件夹名称 */
  @Trace folderName: string = '';
  /** 父目录（相对路径） */
  @Trace parentDir: string = '';
  /** 已导入的密钥列表 */
  @Trace keys: GpgKeyId[] = [];
  /** 选中的密钥指纹列表（多选） */
  @Trace selectedFingerprints: Set<string> = new Set<string>();
  /** 是否正在保存 */
  @Trace isSaving: boolean = false;
  /** 错误信息 */
  @Trace errorMessage: string = '';
  /** 成功提示 */
  @Trace toast: string = '';

  private repo: PasswordRepository = PasswordRepository.getInstance();
  private keyManager: PgpKeyManager = PgpKeyManager.getInstance();

  /**
   * 加载已导入的密钥列表
   */
  async loadKeys(): Promise<void> {
    try {
      this.keys = await this.keyManager.listKeys(true);
      // 默认**全不选中**：不选则子目录不写 .gpg-id，加解密继承父目录的密钥（pass 约定）。
      // 曾默认按父目录 .gpg-id 预勾选，结果用户新建一个目录就「全选」，与直觉相悖。
      this.selectedFingerprints = new Set<string>();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'loadKeys failed: %{public}s', e instanceof Error ? e.message : String(e));
    }
  }

  /**
   * 切换密钥选中状态
   */
  toggleKey(fingerprint: string): void {
    const newSet: Set<string> = new Set<string>(this.selectedFingerprints);
    if (newSet.has(fingerprint)) {
      newSet.delete(fingerprint);
    } else {
      newSet.add(fingerprint);
    }
    this.selectedFingerprints = newSet;
  }

  /**
   * 判断密钥是否选中
   */
  isKeySelected(fingerprint: string): boolean {
    return this.selectedFingerprints.has(fingerprint);
  }

  /**
   * 创建文件夹
   */
  async createFolder(): Promise<void> {
    if (this.folderName.trim().length === 0) {
      this.errorMessage = '请输入文件夹名称';
      return;
    }
    // 名称会拼进目录路径：`../`、绝对路径或 `.` 开头都会在仓库之外建/删目录
    if (!FileUtils.isSafeRelativePath(this.folderName.trim())) {
      this.errorMessage = '文件夹名称不能包含 ..、\\ 或以 . 开头';
      return;
    }

    this.isSaving = true;
    this.errorMessage = '';

    try {
      // 构建子目录相对路径
      const relativePath: string = this.parentDir.length > 0
        ? `${this.parentDir}/${this.folderName.trim()}`
        : this.folderName.trim();

      // 创建目录
      const result = this.repo.createDirectory(relativePath);
      if (!result.success) {
        this.errorMessage = result.error;
        this.isSaving = false;
        return;
      }

      // 如果用户选了密钥，为子目录写入 .gpg-id（覆盖父目录密钥）
      if (this.selectedFingerprints.size > 0) {
        const fpArray: string[] = Array.from(this.selectedFingerprints);
        const gpgIdResult = this.repo.setGpgIdForDir(relativePath, fpArray);
        if (!gpgIdResult.success) {
          this.errorMessage = gpgIdResult.error;
          this.isSaving = false;
          return;
        }
      }

      // 通知列表刷新
      RepoChangeNotifier.connect().bump();

      this.toast = '文件夹已创建';
      this.scheduleToastClear();
      this.isSaving = false;
    } catch (e) {
      this.errorMessage = `创建失败: ${e instanceof Error ? e.message : String(e)}`;
      this.isSaving = false;
    }
  }

  /**
   * 2 秒后清除提示
   */
  private scheduleToastClear(): void {
    setTimeout(() => { this.toast = ''; }, 2000);
  }

  /**
   * 截断指纹显示
   */
  formatFingerprint(fingerprint: string): string {
    if (fingerprint.length <= 16) return fingerprint;
    return `${fingerprint.substring(0, 8)}...${fingerprint.substring(fingerprint.length - 8)}`;
  }
}
