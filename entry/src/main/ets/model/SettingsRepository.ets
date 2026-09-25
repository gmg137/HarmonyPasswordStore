import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { FileUtils } from '../utils/FileUtils';
import { SecretStore } from '../utils/SecretStore';
import {
  PasswordFileFormat,
  PasswordFileOrganization,
  SearchMode,
  SortMode,
  ThemeMode,
  GIT_CONNECT_TIMEOUT,
  UNLOCK_SESSION_TIMEOUT,
  CLIPBOARD_CLEAR_TIMEOUT,
} from '../common/Constants';
import { GitConfig, createDefaultGitConfig, normalizeGitConfig } from '../model/GitConfig';

/**
 * 应用设置数据结构
 */
export interface AppSettings {
  /** 文件组织方式 */
  fileOrganization: PasswordFileOrganization;
  /** 搜索匹配模式 */
  searchMode: SearchMode;
  /** 排序方式 */
  sortMode: SortMode;
  /** 主题模式 */
  themeMode: ThemeMode;
  /** 仓库是否已初始化 */
  storeInitialized: boolean;
  /** 仓库根目录路径 */
  storePath: string;
  /** 剪贴板清除超时（毫秒） */
  clipboardTimeout: number;
  /** 快速解锁会话超时（毫秒） */
  unlockSessionTimeout: number;
  /** 是否启用生物识别快速解锁 */
  biometricUnlockEnabled: boolean;
  /** 新写入密码文件的密文格式（bin / armor） */
  passwordFileFormat: PasswordFileFormat;
  /** 是否在应用启动时自动同步 Git */
  autoSyncOnLaunch: boolean;
  /** 拉取远程更新时是否使用变基（git pull --rebase） */
  gitPullRebase: boolean;
  /** 通用 PGP 密钥指纹（默认加密密钥） */
  defaultKeyFingerprint: string;
  /** 是否完成引导 */
  onboardingCompleted: boolean;
}

/**
 * 默认设置
 */
export function createDefaultSettings(): AppSettings {
  return {
    fileOrganization: PasswordFileOrganization.FILE,
    searchMode: SearchMode.FUZZY,
    sortMode: SortMode.ALPHABETICAL,
    themeMode: ThemeMode.SYSTEM,
    storeInitialized: false,
    storePath: '',
    clipboardTimeout: CLIPBOARD_CLEAR_TIMEOUT,
    unlockSessionTimeout: UNLOCK_SESSION_TIMEOUT,
    biometricUnlockEnabled: false,
    autoSyncOnLaunch: false,
    gitPullRebase: false,
    defaultKeyFingerprint: '',
    onboardingCompleted: false,
    // 默认二进制：与桌面 pass 的输出一致，体积也小约 1/4
    passwordFileFormat: PasswordFileFormat.BIN,
  };
}

/**
 * Preferences 存储键名
 */
class PrefKeys {
  static readonly FILE_ORG = 'file_organization';
  static readonly SEARCH_MODE = 'search_mode';
  static readonly SORT_MODE = 'sort_mode';
  static readonly THEME_MODE = 'theme_mode';
  static readonly PASSWORD_FILE_FORMAT = 'password_file_format';
  static readonly STORE_INITIALIZED = 'store_initialized';
  static readonly STORE_PATH = 'store_path';
  static readonly CLIPBOARD_TIMEOUT = 'clipboard_timeout';
  static readonly UNLOCK_TIMEOUT = 'unlock_session_timeout';
  static readonly BIOMETRIC_ENABLED = 'biometric_unlock_enabled';
  static readonly AUTO_SYNC = 'auto_sync_on_launch';
  static readonly GIT_PULL_REBASE = 'git_pull_rebase';
  static readonly DEFAULT_KEY_FP = 'default_key_fingerprint';
  static readonly ONBOARDING_DONE = 'onboarding_completed';
  static readonly GIT_CONFIG = 'git_config_json';
  static readonly USAGE_MAP = 'entry_usage_map';
}

/** Preferences 实例名 */
const PREF_STORE_NAME: string = 'harmony_password_store_settings';

/**
 * 设置仓库
 *
 * 基于 Preferences 实现应用设置的持久化读写。
 * 在 EntryAbility 中调用 init() 初始化，之后通过 getInstance() 获取单例。
 */
export class SettingsRepository {
  private static instance: SettingsRepository | null = null;
  private prefStore: preferences.Preferences | null = null;
  private cache: AppSettings = createDefaultSettings();
  /**
   * 设置加载完成信号
   *
   * `init()` 是异步的，而 UIAbility 的生命周期**不会等待 async onCreate**——
   * 实测 onWindowStageCreate 的 loadContent 回调比 init() 里的 await 早约 100ms，
   * 那时 getSettings() 返回的还是默认值（「启动时自动同步」因此永远读到 false，
   * 开关形同虚设）。需要读设置的地方（尤其启动流程）必须先 await whenReady()。
   */
  private readyPromise: Promise<void> | null = null;
  private readyResolve: (() => void) | null = null;
  private context: common.Context | null = null;

  private constructor() {
  }

  static getInstance(): SettingsRepository {
    if (!SettingsRepository.instance) {
      SettingsRepository.instance = new SettingsRepository();
    }
    return SettingsRepository.instance;
  }

  /**
   * 初始化 Preferences（在 EntryAbility 中调用）
   */
  async init(context: common.Context): Promise<void> {
    this.context = context;
    if (this.readyPromise === null) {
      this.readyPromise = new Promise<void>((resolve: () => void) => {
        this.readyResolve = resolve;
      });
    }
    try {
      this.prefStore = await preferences.getPreferences(context, PREF_STORE_NAME);
      await this.loadSettings();
    } catch (e) {
      hilog.error(0x0000, 'SettingsRepo', 'Failed to init preferences: %{public}s', JSON.stringify(e));
    }
    if (this.readyResolve !== null) {
      this.readyResolve();
      this.readyResolve = null;
    }
  }

  /**
   * 等待设置加载完成（未 init 时立即返回，避免调用方永久挂起）
   */
  whenReady(): Promise<void> {
    return this.readyPromise === null ? Promise.resolve() : this.readyPromise;
  }

  /**
   * 从 Preferences 加载设置到缓存
   */
  private async loadSettings(): Promise<void> {
    if (!this.prefStore) return;

    const defaults: AppSettings = createDefaultSettings();

    try {
      this.cache.fileOrganization = await this.prefStore.get(PrefKeys.FILE_ORG, defaults.fileOrganization) as PasswordFileOrganization;
      this.cache.searchMode = await this.prefStore.get(PrefKeys.SEARCH_MODE, defaults.searchMode) as SearchMode;
      this.cache.sortMode = await this.prefStore.get(PrefKeys.SORT_MODE, defaults.sortMode) as SortMode;
      this.cache.themeMode = await this.prefStore.get(PrefKeys.THEME_MODE, defaults.themeMode) as ThemeMode;
      this.cache.passwordFileFormat = await this.prefStore.get(PrefKeys.PASSWORD_FILE_FORMAT,
        defaults.passwordFileFormat) as PasswordFileFormat;
      this.cache.storeInitialized = await this.prefStore.get(PrefKeys.STORE_INITIALIZED, defaults.storeInitialized) as boolean;
      this.cache.storePath = await this.prefStore.get(PrefKeys.STORE_PATH, defaults.storePath) as string;
      this.cache.clipboardTimeout = await this.prefStore.get(PrefKeys.CLIPBOARD_TIMEOUT, defaults.clipboardTimeout) as number;
      this.cache.unlockSessionTimeout = await this.prefStore.get(PrefKeys.UNLOCK_TIMEOUT, defaults.unlockSessionTimeout) as number;
      this.cache.biometricUnlockEnabled = await this.prefStore.get(PrefKeys.BIOMETRIC_ENABLED, defaults.biometricUnlockEnabled) as boolean;
      this.cache.autoSyncOnLaunch = await this.prefStore.get(PrefKeys.AUTO_SYNC, defaults.autoSyncOnLaunch) as boolean;
      this.cache.gitPullRebase = await this.prefStore.get(PrefKeys.GIT_PULL_REBASE, defaults.gitPullRebase) as boolean;
      this.cache.defaultKeyFingerprint = await this.prefStore.get(PrefKeys.DEFAULT_KEY_FP, defaults.defaultKeyFingerprint) as string;
      this.cache.onboardingCompleted = await this.prefStore.get(PrefKeys.ONBOARDING_DONE, defaults.onboardingCompleted) as boolean;
    } catch (e) {
      // 读取失败时保留默认值，不中断应用启动
      hilog.error(0x0000, 'SettingsRepo', 'loadSettings failed: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 获取当前设置（内存缓存，不触发 IO）
   */
  getSettings(): AppSettings {
    return this.cache;
  }

  /**
   * 保存完整设置并持久化
   */
  async saveSettings(settings: AppSettings): Promise<void> {
    this.cache = settings;
    if (!this.prefStore) return;

    try {
      await this.prefStore.put(PrefKeys.FILE_ORG, settings.fileOrganization);
      await this.prefStore.put(PrefKeys.SEARCH_MODE, settings.searchMode);
      await this.prefStore.put(PrefKeys.SORT_MODE, settings.sortMode);
      await this.prefStore.put(PrefKeys.THEME_MODE, settings.themeMode);
      await this.prefStore.put(PrefKeys.PASSWORD_FILE_FORMAT, settings.passwordFileFormat);
      await this.prefStore.put(PrefKeys.STORE_INITIALIZED, settings.storeInitialized);
      await this.prefStore.put(PrefKeys.STORE_PATH, settings.storePath);
      await this.prefStore.put(PrefKeys.CLIPBOARD_TIMEOUT, settings.clipboardTimeout);
      await this.prefStore.put(PrefKeys.UNLOCK_TIMEOUT, settings.unlockSessionTimeout);
      await this.prefStore.put(PrefKeys.BIOMETRIC_ENABLED, settings.biometricUnlockEnabled);
      await this.prefStore.put(PrefKeys.AUTO_SYNC, settings.autoSyncOnLaunch);
      await this.prefStore.put(PrefKeys.GIT_PULL_REBASE, settings.gitPullRebase);
      await this.prefStore.put(PrefKeys.DEFAULT_KEY_FP, settings.defaultKeyFingerprint);
      await this.prefStore.put(PrefKeys.ONBOARDING_DONE, settings.onboardingCompleted);
      await this.prefStore.flush();
    } catch (e) {
      hilog.error(0x0000, 'SettingsRepo', 'saveSettings failed: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 更新单个设置项
   */
  async updateSetting(key: string, value: Object): Promise<void> {
    switch (key) {
      case 'fileOrganization':
        this.cache.fileOrganization = value as PasswordFileOrganization;
        break;
      case 'searchMode':
        this.cache.searchMode = value as SearchMode;
        break;
      case 'sortMode':
        this.cache.sortMode = value as SortMode;
        break;
      case 'passwordFileFormat':
        this.cache.passwordFileFormat = value as PasswordFileFormat;
        break;
      case 'themeMode':
        this.cache.themeMode = value as ThemeMode;
        break;
      case 'storeInitialized':
        this.cache.storeInitialized = value as boolean;
        break;
      case 'storePath':
        this.cache.storePath = value as string;
        break;
      case 'clipboardTimeout':
        this.cache.clipboardTimeout = value as number;
        break;
      case 'unlockSessionTimeout':
        this.cache.unlockSessionTimeout = value as number;
        break;
      case 'biometricUnlockEnabled':
        this.cache.biometricUnlockEnabled = value as boolean;
        break;
      case 'autoSyncOnLaunch':
        this.cache.autoSyncOnLaunch = value as boolean;
        break;
      case 'gitPullRebase':
        this.cache.gitPullRebase = value as boolean;
        break;
      case 'defaultKeyFingerprint':
        this.cache.defaultKeyFingerprint = value as string;
        break;
      case 'onboardingCompleted':
        this.cache.onboardingCompleted = value as boolean;
        break;
      default:
        return;
    }
    if (!this.prefStore) return;

    const prefKey: string = this.getPrefKey(key);
    try {
      await this.prefStore.put(prefKey, value);
      await this.prefStore.flush();
    } catch (e) {
      hilog.error(0x0000, 'SettingsRepo', 'updateSetting %{public}s failed: %{public}s', prefKey, JSON.stringify(e));
    }
  }

  /**
   * 加载 Git 配置
   *
   * `password` 字段（HTTPS 密码/token）以 HUKS 密文落盘，此处透明解开。
   */
  async loadGitConfig(): Promise<GitConfig> {
    if (!this.prefStore) return createDefaultGitConfig();
    let json: string = '';
    try {
      json = await this.prefStore.get(PrefKeys.GIT_CONFIG, '') as string;
    } catch (e) {
      hilog.error(0x0000, 'SettingsRepo', 'loadGitConfig get failed: %{public}s', JSON.stringify(e));
      return createDefaultGitConfig();
    }
    if (json.length === 0) return createDefaultGitConfig();
    let config: GitConfig;
    try {
      // 归一化：落盘 JSON 可能缺字段（字段是后加的）、或来自被属性混淆改过名的旧版本，
      // 缺字段会以 undefined 传进 native 调用被 GetArgs 拒绝
      config = normalizeGitConfig(JSON.parse(json) as GitConfig);
    } catch (e) {
      hilog.error(0x0000, 'SettingsRepo', 'loadGitConfig parse failed: %{public}s',
        e instanceof Error ? e.message : String(e));
      return createDefaultGitConfig();
    }
    return await this.unsealGitPassword(config);
  }

  /**
   * 解开 Git 配置里的凭据字段
   *
   * 兼容升级前落盘的明文：非封装格式的值原样返回，下次保存时自动升为密文。
   */
  private async unsealGitPassword(config: GitConfig): Promise<GitConfig> {
    // SSH 私钥口令与 HTTPS 令牌同样封装落盘，逐个解封
    config.sshKeyPassphrase = await this.unsealCredential(config.sshKeyPassphrase ?? '', 'sshKeyPassphrase');
    const stored: string = config.password ?? '';
    if (stored.length === 0 || !SecretStore.looksSealed(stored)) {
      return config;
    }
    const plain: string = await this.unsealCredential(stored, 'password');
    if (plain.length === 0) {
      // 解不开（HUKS 密钥丢失）不能悄悄返回密文去当密码用，
      // 否则 Git 会拿一串 base64 去认证，报出令人困惑的鉴权失败
      config.password = '';
      return config;
    }
    config.password = plain;
    return config;
  }

  /** 解封单个凭据字段（非封装格式原样返回，兼容升级前的明文） */
  private async unsealCredential(stored: string, field: string): Promise<string> {
    if (stored.length === 0 || !SecretStore.looksSealed(stored)) {
      return stored;
    }
    const plain: string = await SecretStore.getInstance().unsealGitCredential(stored);
    if (plain.length === 0) {
      hilog.error(0x0000, 'SettingsRepo', 'unsealCredential failed for %{public}s, clearing', field);
    }
    return plain;
  }

  /** 封装单个凭据字段（失败时返回空串，绝不退回明文落盘） */
  private async sealCredential(plain: string, field: string): Promise<string> {
    if (plain.length === 0) {
      return plain;
    }
    const sealed: string = await SecretStore.getInstance().sealGitCredential(plain);
    if (sealed.length === 0) {
      hilog.error(0x0000, 'SettingsRepo', 'sealCredential failed for %{public}s', field);
      return '';
    }
    return sealed;
  }

  /** 加密 Git 配置里的凭据字段 */
  private async sealGitPassword(config: GitConfig): Promise<GitConfig> {
    config.sshKeyPassphrase = await this.sealCredential(config.sshKeyPassphrase ?? '', 'sshKeyPassphrase');
    const plain: string = config.password ?? '';
    if (plain.length === 0) {
      return config;
    }
    const sealed: string = await SecretStore.getInstance().sealGitCredential(plain);
    if (sealed.length === 0) {
      // 加密失败时宁可清空，也不要退回明文落盘
      hilog.error(0x0000, 'SettingsRepo', 'sealGitPassword failed');
      config.password = '';
      return config;
    }
    config.password = sealed;
    return config;
  }

  /**
   * 保存 Git 配置
   *
   * `password` 字段加密后再写 Preferences：Preferences 是明文库，
   * 且应用数据会被系统备份外发，明文 token 会因此离开设备。
   */
  async saveGitConfig(config: GitConfig): Promise<void> {
    if (!this.prefStore) return;
    try {
      const toStore: GitConfig = await this.sealGitPassword(config);
      await this.prefStore.put(PrefKeys.GIT_CONFIG, JSON.stringify(toStore));
      await this.prefStore.flush();
    } catch (e) {
      hilog.error(0x0000, 'SettingsRepo', 'saveGitConfig failed: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 记录条目使用时间（供自动填充候选最近使用排序）
   */
  async recordEntryUsage(relativePath: string, timestamp: number): Promise<void> {
    if (!this.prefStore) return;
    try {
      const map: Record<string, number> = await this.loadUsageMap();
      map[relativePath] = timestamp;
      await this.prefStore.put(PrefKeys.USAGE_MAP, JSON.stringify(map));
      await this.prefStore.flush();
    } catch (e) {
      hilog.error(0x0000, 'SettingsRepo', 'recordEntryUsage failed: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 加载条目使用时间表（路径 → 最后使用毫秒时间戳）
   */
  async loadUsageMap(): Promise<Record<string, number>> {
    if (!this.prefStore) return {};
    let json: string = '';
    try {
      json = await this.prefStore.get(PrefKeys.USAGE_MAP, '') as string;
    } catch (e) {
      hilog.error(0x0000, 'SettingsRepo', 'loadUsageMap get failed: %{public}s', JSON.stringify(e));
      return {};
    }
    if (json.length === 0) return {};
    try {
      return JSON.parse(json) as Record<string, number>;
    } catch (e) {
      return {};
    }
  }

  /**
   * 是否需要显示引导页
   *
   * 以「是否已初始化密码仓库」为判据，而不是只依赖 onboardingCompleted 标志
   * （该标志是 Preferences 里的布尔值，一旦丢失就会导致已配置完成的设备
   * 每次启动都重新进入初始设置界面）：
   * 1. 引导已完成 → 不需要
   * 2. 仓库路径已配置且存在 git 仓库（.git 目录）→ 不需要
   * 3. 仓库路径已配置且仓库目录已存在（本地新建仓库在首次提交前尚无 .git）→ 不需要
   * 4. 仓库路径未持久化，但默认仓库目录已存在 → 补记路径，视为已初始化
   */
  needsOnboarding(): boolean {
    if (this.cache.onboardingCompleted) {
      return false;
    }
    const storePath: string = this.getStorePath();
    if (storePath.length > 0) {
      const isRepo: boolean = this.hasGitRepo(storePath);
      const dirExists: boolean = FileUtils.exists(storePath);
      if (!isRepo && !dirExists) {
        return true;
      }
      hilog.info(0x0000, 'SettingsRepo', 'repo already initialized, skip onboarding: %{public}s (git=%{public}s)',
        storePath, isRepo ? 'yes' : 'no');
      return false;
    }
    // storePath 未持久化时回退到默认仓库路径：目录已存在即视为仓库已初始化
    const defaultPath: string = this.getDefaultStorePath();
    if (defaultPath.length > 0 && FileUtils.exists(defaultPath)) {
      this.cache.storePath = defaultPath;
      hilog.info(0x0000, 'SettingsRepo', 'storePath missing but repo exists, treating as initialized: %{public}s', defaultPath);
      return false;
    }
    return true;
  }

  /**
   * 判断指定路径下是否为已初始化的 git 仓库（存在 .git 目录）
   */
  private hasGitRepo(storePath: string): boolean {
    return FileUtils.exists(`${storePath}/.git`);
  }

  /**
   * 默认密码仓库路径（未显式配置 storePath 时使用）
   */
  private getDefaultStorePath(): string {
    if (this.context) {
      return `${this.context.filesDir}/password-store`;
    }
    return '';
  }

  /**
   * 获取当前仓库路径
   */
  getStorePath(): string {
    if (this.cache.storePath.length > 0) return this.cache.storePath;
    if (this.context) {
      return `${this.context.filesDir}/password-store`;
    }
    return '';
  }

  /**
   * 将 AppSettings 键映射到 Preferences 键
   */
  private getPrefKey(key: keyof AppSettings): string {
    const map: Record<string, string> = {
      'fileOrganization': PrefKeys.FILE_ORG,
      'searchMode': PrefKeys.SEARCH_MODE,
      'passwordFileFormat': PrefKeys.PASSWORD_FILE_FORMAT,
      'sortMode': PrefKeys.SORT_MODE,
      'themeMode': PrefKeys.THEME_MODE,
      'storeInitialized': PrefKeys.STORE_INITIALIZED,
      'storePath': PrefKeys.STORE_PATH,
      'clipboardTimeout': PrefKeys.CLIPBOARD_TIMEOUT,
      'unlockSessionTimeout': PrefKeys.UNLOCK_TIMEOUT,
      'biometricUnlockEnabled': PrefKeys.BIOMETRIC_ENABLED,
      'autoSyncOnLaunch': PrefKeys.AUTO_SYNC,
      'gitPullRebase': PrefKeys.GIT_PULL_REBASE,
      'defaultKeyFingerprint': PrefKeys.DEFAULT_KEY_FP,
      'onboardingCompleted': PrefKeys.ONBOARDING_DONE,
    };
    return map[key] ?? key;
  }
}
