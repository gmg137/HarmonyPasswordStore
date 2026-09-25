import { SettingsRepository, AppSettings } from '../model/SettingsRepository';
import { ThemeColors } from '../common/ThemeColors';
import { PasswordFileFormat, ThemeMode, SearchMode, SortMode } from '../common/Constants';
import { RouteManager } from '../common/RouteManager';
import { RouteNames } from '../common/Constants';
import { BiometricHelper, BiometricDetail } from '../utils/BiometricHelper';
import { GitClient } from '../utils/GitClient';

/**
 * 设置视图模型
 *
 * 管理通用设置的读取与更新，设置项变更立即持久化。
 */
@ObservedV2
export class SettingsViewModel {
  /** 设置快照（用于 UI 展示） */
  @Trace themeMode: ThemeMode = ThemeMode.SYSTEM;
  @Trace clipboardTimeout: number = 30;
  @Trace biometricUnlockEnabled: boolean = false;
  /** 生物识别不可用时的友好原因（空表示可用） */
  @Trace biometricReason: string = '';
  @Trace autoSyncOnLaunch: boolean = false;
  /**
   * 「启动时自动同步」是否可用
   *
   * 未配置远程地址、或本地还不是 Git 仓库（没克隆过）时自动同步必然失败，
   * 开关置灰并说明原因——否则用户打开它却毫无效果，还以为是应用坏了。
   */
  @Trace autoSyncAvailable: boolean = false;
  /** 不可用时的原因（可用时为空串） */
  @Trace autoSyncDisabledReason: string = '';
  @Trace searchMode: SearchMode = SearchMode.FUZZY;
  /** 新写入密码文件的密文格式（bin / armor） */
  @Trace passwordFileFormat: PasswordFileFormat = PasswordFileFormat.BIN;
  @Trace sortMode: SortMode = SortMode.ALPHABETICAL;
  @Trace storeInitialized: boolean = false;
  /** 是否正在保存 */
  @Trace isSaving: boolean = false;
  /** 保存结果提示 */
  @Trace toast: string = '';

  private settings: SettingsRepository = SettingsRepository.getInstance();

  /**
   * 从持久化配置加载
   *
   * async 只为读 Git 配置（远程地址存在 Preferences 的 JSON 里，读取是异步的）；
   * 调用方（SettingsPage.aboutToAppear）不需要 await。
   */
  async load(): Promise<void> {
    const s: AppSettings = this.settings.getSettings();
    this.themeMode = s.themeMode;
    this.clipboardTimeout = Math.round(s.clipboardTimeout / 1000);
    this.biometricUnlockEnabled = s.biometricUnlockEnabled;
    const detail: BiometricDetail = BiometricHelper.getInstance().checkBiometricDetail();
    this.biometricReason = detail.reason;
    this.autoSyncOnLaunch = s.autoSyncOnLaunch;
    this.searchMode = s.searchMode;
    this.passwordFileFormat = s.passwordFileFormat;
    this.sortMode = s.sortMode;
    this.storeInitialized = s.storeInitialized;
    await this.refreshAutoSyncAvailability();
  }

  /**
   * 设置主题模式
   */
  async setThemeMode(mode: ThemeMode): Promise<void> {
    this.themeMode = mode;
    await this.settings.updateSetting('themeMode', mode);
    // 同步到全局调色板：LIGHT/DARK 立即生效；SYSTEM 回读系统深浅色状态
    if (mode === ThemeMode.DARK) {
      ThemeColors.getInstance().setDark(true);
    } else if (mode === ThemeMode.LIGHT) {
      ThemeColors.getInstance().setDark(false);
    } else {
      ThemeColors.getInstance().syncMode(false);
    }
  }

  /**
   * 设置剪贴板超时（秒）
   */
  async setClipboardTimeout(seconds: number): Promise<void> {
    this.clipboardTimeout = seconds;
    await this.settings.updateSetting('clipboardTimeout', seconds * 1000);
  }

  /**
   * 设置生物识别开关
   */
  async setBiometricEnabled(enabled: boolean): Promise<void> {
    // 不可用时不开启：PIN 已移除，应用锁只剩生物识别，开了也不会生效，
    // 用户却会以为密码库已经受保护
    if (enabled && this.biometricReason.length > 0) {
      this.toast = this.biometricReason;
      return;
    }
    this.biometricUnlockEnabled = enabled;
    await this.settings.updateSetting('biometricUnlockEnabled', enabled);
  }

  /**
   * 设置启动时自动同步
   */
  /**
   * 重新判断自动同步是否可用（进入设置页、从 Git 配置/仓库管理返回时调用）
   *
   * 两个前提缺一不可：远程地址已配置（否则没有同步目标）、本地已是 Git 仓库
   * （否则 pull 会以「当前目录不是 Git 仓库」失败）。读取用同步 API，可在 load 里直接调。
   */
  async refreshAutoSyncAvailability(): Promise<void> {
    const remoteUrl: string = (await this.settings.loadGitConfig()).remoteUrl;
    const isRepo: boolean = GitClient.getInstance().isGitRepo();
    this.autoSyncAvailable = remoteUrl.length > 0 && isRepo;
    if (remoteUrl.length === 0) {
      this.autoSyncDisabledReason = '未配置远程仓库地址，请先在「Git 配置」中填写';
    } else if (!isRepo) {
      this.autoSyncDisabledReason = '本地尚未克隆远程仓库，请先在「仓库管理」中克隆';
    } else {
      this.autoSyncDisabledReason = '';
    }
  }

  async setAutoSync(enabled: boolean): Promise<void> {
    // 不可用时不开：否则每次启动都会静默失败（拉取报「不是 Git 仓库」），
    // 用户只看到开关是打开的，无从知道没生效
    if (enabled && !this.autoSyncAvailable) {
      this.toast = this.autoSyncDisabledReason;
      return;
    }
    this.autoSyncOnLaunch = enabled;
    await this.settings.updateSetting('autoSyncOnLaunch', enabled);
  }

  /**
   * 设置搜索模式
   */
  async setSearchMode(mode: SearchMode): Promise<void> {
    this.searchMode = mode;
    await this.settings.updateSetting('searchMode', mode);
  }

  /**
   * 设置密码文件格式（只影响之后新写入的条目：新建/编辑/重加密）
   */
  async setPasswordFileFormat(format: PasswordFileFormat): Promise<void> {
    this.passwordFileFormat = format;
    await this.settings.updateSetting('passwordFileFormat', format);
  }

  /**
   * 导航到 PGP 密钥管理页
   */
  navigateToPgpKeys(): void {
    RouteManager.getInstance().pushPath(RouteNames.PGP_KEY_MANAGER);
  }

  /**
   * 导航到 SSH 密钥管理页
   */
  navigateToSshKeys(): void {
    RouteManager.getInstance().pushPath(RouteNames.SSH_KEY_MANAGER);
  }

  /**
   * 导航到仓库管理页
   */
  navigateToRepoManage(): void {
    RouteManager.getInstance().pushPath(RouteNames.REPO_MANAGE);
  }

  /**
   * 重新显示引导页（重新初始化仓库）
   */
  navigateToOnboarding(): void {
    RouteManager.getInstance().pushPath(RouteNames.ONBOARDING);
  }
}
