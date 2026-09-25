import { SettingsRepository, AppSettings } from '../model/SettingsRepository';
import { PasswordRepository } from '../model/PasswordRepository';
import { GitClient, GitRepoStatus } from '../utils/GitClient';
import { GitConfig } from '../model/GitConfig';
import { FileUtils } from '../utils/FileUtils';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** hilog 域 */
const DOMAIN: number = 0x0001;
/** hilog 标签 */
const TAG: string = 'RepoManageVM';

/**
 * 仓库管理视图模型
 *
 * 管理本地密码仓库的 Git 行为设置（拉取变基）与仓库生命周期
 * （克隆远程仓库 / 删除本地仓库）。
 */
@ObservedV2
export class RepoManageViewModel {
  /** 拉取时进行变基（git pull --rebase） */
  @Trace pullRebase: boolean = false;
  /** 本地是否已是 Git 仓库 */
  @Trace isGitRepo: boolean = false;
  /** 是否已配置远程地址 */
  @Trace hasRemote: boolean = false;
  /** 远程地址（展示用） */
  @Trace remoteUrl: string = '';
  /** 仓库状态摘要 */
  @Trace statusSummary: string = '';
  /** 是否正在执行操作 */
  @Trace isBusy: boolean = false;
  /** 结果提示 */
  @Trace resultMessage: string = '';
  /** 结果是否为成功 */
  @Trace lastSuccess: boolean = true;
  /** 删除确认对话框是否可见 */
  @Trace isDeleteDialogVisible: boolean = false;

  private settings: SettingsRepository = SettingsRepository.getInstance();
  private repo: PasswordRepository = PasswordRepository.getInstance();
  private git: GitClient = GitClient.getInstance();

  /**
   * 加载当前状态
   */
  async load(): Promise<void> {
    const appSettings: AppSettings = this.settings.getSettings();
    this.pullRebase = appSettings.gitPullRebase;
    this.isGitRepo = this.git.isGitRepo();

    const config: GitConfig = await this.settings.loadGitConfig();
    this.remoteUrl = config.remoteUrl;
    this.hasRemote = config.remoteUrl.trim().length > 0;

    await this.refreshStatus();
  }

  /**
   * 刷新仓库状态摘要
   */
  async refreshStatus(): Promise<void> {
    if (!this.isGitRepo) {
      this.statusSummary = '未克隆远程仓库';
      return;
    }
    const status: GitRepoStatus = await this.git.status();
    if (!status.isRepo) {
      this.statusSummary = '未克隆远程仓库';
      return;
    }
    const parts: string[] = [];
    if (status.branch.length > 0) parts.push(status.branch);
    if (status.changedCount > 0) parts.push(`${status.changedCount} 个变更`);
    if (status.aheadCount > 0) parts.push(`↑${status.aheadCount}`);
    if (status.behindCount > 0) parts.push(`↓${status.behindCount}`);
    this.statusSummary = parts.length > 0 ? parts.join(' · ') : '已同步';
  }

  /**
   * 设置拉取时是否变基
   */
  async setPullRebase(value: boolean): Promise<void> {
    this.pullRebase = value;
    await this.settings.updateSetting('gitPullRebase', value);
  }

  /**
   * 打开/关闭删除确认对话框
   */
  setDeleteDialogVisible(visible: boolean): void {
    this.isDeleteDialogVisible = visible;
  }

  /**
   * 删除本地仓库
   *
   * 删除本地仓库目录（含 .git 与全部密码文件），并重置仓库初始化状态，
   * 使应用回到「未初始化」状态，需要重新初始化或克隆。
   */
  async deleteRepo(): Promise<void> {
    this.isDeleteDialogVisible = false;
    this.isBusy = true;
    this.resultMessage = '';

    const storePath: string = this.settings.getStorePath();
    if (storePath.length === 0) {
      this.finish(false, '仓库路径未配置');
      return;
    }

    try {
      const deleted: boolean = FileUtils.deleteDir(storePath);
      if (!deleted) {
        this.finish(false, '删除仓库失败：目录无法删除');
        return;
      }
      // 重置初始化标记与远程地址，回到未初始化状态
      await this.settings.updateSetting('storeInitialized', false);
      const config: GitConfig = await this.settings.loadGitConfig();
      config.remoteUrl = '';
      await this.settings.saveGitConfig(config);

      this.isGitRepo = false;
      this.hasRemote = false;
      this.remoteUrl = '';
      this.statusSummary = '未克隆远程仓库';
      hilog.info(DOMAIN, TAG, 'local repo deleted: %{public}s', storePath);
      this.finish(true, '本地仓库已删除');
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      hilog.error(DOMAIN, TAG, 'deleteRepo failed: %{public}s', msg);
      this.finish(false, `删除仓库失败：${msg}`);
    }
  }

  /**
   * 结束操作并写入结果
   */
  private finish(success: boolean, message: string): void {
    this.isBusy = false;
    this.lastSuccess = success;
    this.resultMessage = message;
  }
}
