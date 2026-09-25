import { RouteManager } from '../common/RouteManager';
import { RouteNames, SearchMode, SortMode } from '../common/Constants';
import { PasswordRepository } from '../model/PasswordRepository';
import { SettingsRepository } from '../model/SettingsRepository';
import { PasswordEntry } from '../model/PasswordEntry';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** hilog 域 */
const DOMAIN: number = 0x0001;
/** hilog 标签 */
const TAG: string = 'PasswordListVM';

/**
 * 密码条目的视图层数据结构
 * （ViewModel 向 View 传递的数据，禁止直接暴露 Model 类型）
 */
export interface PasswordEntryVM {
  /** 显示名称 */
  name: string;
  /** 相对路径 */
  relativePath: string;
  /** 是否为目录 */
  isDirectory: boolean;
  /** 子条目数量（仅目录） */
  childCount: number;
  /** 最后修改时间 */
  lastModified: number;
}

/**
 * 密码详情页导航参数
 */
export interface PasswordDetailNavParam {
  relativePath: string;
}

/**
 * 新建/编辑密码页导航参数
 * editPath 非空时进入编辑模式；否则以 parentDir 为父目录新建（空串表示根目录）
 */
export interface PasswordCreateNavParam {
  parentDir: string;
  editPath: string;
}

/**
 * 密码列表视图模型
 *
 * 持有密码列表 UI 状态，管理目录浏览、搜索、导航。
 * 通过 PasswordRepository 完成文件系统操作。
 */
@ObservedV2
export class PasswordListViewModel {
  /** 当前目录相对路径（空字符串表示根目录） */
  @Trace currentDir: string = '';
  /** 搜索关键词 */
  @Trace searchKeyword: string = '';
  /** 过滤后的密码条目列表 */
  @Trace filteredEntries: PasswordEntryVM[] = [];
  /** 是否正在加载 */
  @Trace isLoading: boolean = false;
  /** 仓库是否已初始化 */
  @Trace isStoreInitialized: boolean = false;
  /** PGP 加密是否可用 */
  @Trace isCryptoAvailable: boolean = false;
  /** 是否处于搜索模式 */
  @Trace isSearching: boolean = false;
  /** 搜索结果数量 */
  @Trace searchResultCount: number = 0;

  private repo: PasswordRepository = PasswordRepository.getInstance();
  private settings: SettingsRepository = SettingsRepository.getInstance();
  /** 搜索防抖计时器 */
  private searchTimer: number = -1;
  /** 防抖延迟（ms） */
  private static readonly SEARCH_DEBOUNCE: number = 300;

  /**
   * 加载密码条目
   * 如果有搜索关键词则全局搜索，否则列出当前目录内容。
   */
  loadEntries(): void {
    this.isLoading = true;
    this.isStoreInitialized = this.repo.isStoreInitialized();
    this.isCryptoAvailable = this.repo.isCryptoAvailable();

    if (!this.isStoreInitialized) {
      this.filteredEntries = [];
      this.isLoading = false;
      return;
    }

    if (this.searchKeyword.trim().length > 0) {
      this.loadSearchResults();
    } else {
      this.loadDirectoryContents();
    }
    this.isLoading = false;
  }

  /**
   * 加载当前目录内容
   */
  private loadDirectoryContents(): void {
    const result = this.repo.listEntries(this.currentDir);
    if (!result.success || !result.data) {
      hilog.warn(DOMAIN, TAG, 'loadDirectoryContents failed: %{public}s', result.error);
      this.filteredEntries = [];
      return;
    }

    const sortMode: SortMode = this.settings.getSettings().sortMode;
    this.filteredEntries = result.data.map((entry: PasswordEntry) => this.toVM(entry));

    if (sortMode === SortMode.RECENTLY_USED) {
      this.filteredEntries.sort((a: PasswordEntryVM, b: PasswordEntryVM) => b.lastModified - a.lastModified);
    }
    // ALPHABETICAL 模式已在 Repository 中排序
  }

  /**
   * 全局搜索
   */
  private loadSearchResults(): void {
    const searchMode: SearchMode = this.settings.getSettings().searchMode;
    const keyword: string = this.searchKeyword.trim();

    // 精确匹配与模糊匹配必须传不同参数，否则设置页的模式切换完全无效
    const result = this.repo.searchEntries(keyword, searchMode === SearchMode.EXACT);
    if (!result.success || !result.data) {
      this.filteredEntries = [];
      this.searchResultCount = 0;
      return;
    }

    // 搜索只返回文件，不包含目录
    this.filteredEntries = result.data
      .filter((entry: PasswordEntry) => !entry.isDirectory)
      .map((entry: PasswordEntry) => this.toVM(entry));

    this.searchResultCount = this.filteredEntries.length;

    // 模糊搜索时按名称字母序排序
    this.filteredEntries.sort((a: PasswordEntryVM, b: PasswordEntryVM) =>
      a.name.localeCompare(b.name)
    );
  }

  /**
   * 将 Model 的 PasswordEntry 转换为 ViewModel 的 PasswordEntryVM
   */
  private toVM(entry: PasswordEntry): PasswordEntryVM {
    return {
      name: entry.name,
      relativePath: entry.relativePath,
      isDirectory: entry.isDirectory,
      childCount: entry.children.length,
      lastModified: entry.lastModified,
    };
  }

  /**
   * 更新搜索关键词并刷新列表（带防抖）
   */
  updateSearchKeyword(keyword: string): void {
    this.searchKeyword = keyword;
    this.isSearching = keyword.trim().length > 0;

    // 防抖：清除旧计时器，延迟执行搜索
    if (this.searchTimer !== -1) {
      clearTimeout(this.searchTimer);
    }
    this.searchTimer = setTimeout(() => {
      this.loadEntries();
      this.searchTimer = -1;
    }, PasswordListViewModel.SEARCH_DEBOUNCE);
  }

  /**
   * 立即搜索（无防抖，用于提交按钮）
   */
  submitSearch(): void {
    if (this.searchTimer !== -1) {
      clearTimeout(this.searchTimer);
      this.searchTimer = -1;
    }
    this.loadEntries();
  }

  /**
   * 清除搜索并返回当前目录
   */
  clearSearch(): void {
    this.searchKeyword = '';
    this.loadEntries();
  }

  /**
   * 点击条目处理
   */
  onEntryClicked(entry: PasswordEntryVM): void {
    if (entry.isDirectory) {
      this.currentDir = entry.relativePath;
      this.loadEntries();
    } else {
      const param: PasswordDetailNavParam = { relativePath: entry.relativePath };
      RouteManager.getInstance().pushPath(RouteNames.PASSWORD_DETAIL, param);
    }
  }

  /**
   * 返回上级目录
   */
  navigateUp(): void {
    if (this.currentDir.length === 0) return;
    const lastSlash: number = this.currentDir.lastIndexOf('/');
    this.currentDir = lastSlash >= 0 ? this.currentDir.substring(0, lastSlash) : '';
    this.loadEntries();
  }

  /**
   * 是否可以返回上级目录
   */
  canNavigateUp(): boolean {
    return this.currentDir.length > 0;
  }

  /**
   * 导航到新建密码页
   */
  navigateToCreate(): void {
    // 携带当前目录，避免在子目录内新建时默认落到根目录
    const param: PasswordCreateNavParam = { parentDir: this.currentDir, editPath: '' };
    RouteManager.getInstance().pushPath(RouteNames.PASSWORD_CREATE, param);
  }

  /**
   * 切换排序方式并刷新列表
   */
  async toggleSortMode(): Promise<void> {
    const current: SortMode = this.settings.getSettings().sortMode;
    const next: SortMode = current === SortMode.ALPHABETICAL ? SortMode.RECENTLY_USED : SortMode.ALPHABETICAL;
    await this.settings.updateSetting('sortMode', next);
    this.loadEntries();
  }

  /**
   * 获取当前排序方式
   */
  getSortMode(): SortMode {
    return this.settings.getSettings().sortMode;
  }

  /**
   * 导航到设置页
   */
  navigateToSettings(): void {
    RouteManager.getInstance().pushPath(RouteNames.SETTINGS);
  }
}
