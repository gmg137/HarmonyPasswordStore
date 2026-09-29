import { RouteManager } from '../common/RouteManager';
import { RouteNames, SearchMode, SortMode } from '../common/Constants';
import { PasswordRepository } from '../model/PasswordRepository';
import { SettingsRepository } from '../model/SettingsRepository';
import { PasswordEntry } from '../model/PasswordEntry';
import { ContentSearchService, ContentSearchCallbacks, ContentSearchProgress, ContentHit } from '../utils/ContentSearchService';
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
  /**
   * 内容匹配的命中片段（仅「内容匹配」模式搜出来的条目有值，空串表示名称命中或目录浏览）
   *
   * 片段取自 `PasswordFileParser.searchableText`，因此**不含主密码**。
   */
  contentSnippet: string;
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

  // ===== 内容匹配（`SearchMode.CONTENT`）状态 =====
  /** 内容匹配是否进行中（真正在跑 run） */
  @Trace contentRunning: boolean = false;
  /**
   * 本轮内容匹配是否已安排（含防抖等待窗口）或进行中
   *
   * 与 `contentRunning` 分开：内容阶段有 600ms 防抖窗口，那段时间里**一条结果都还
   * 没有**——页面据此避免先渲染「找到 0 个结果」与空状态（内容模式的关键词常常不在
   * 条目名里，先报 0 再冒出一堆命中会让用户以为搜索失败）。
   */
  @Trace contentPending: boolean = false;
  /** 已处理条数 / 总条数 */
  @Trace contentScanned: number = 0;
  @Trace contentTotal: number = 0;
  /** 因密钥未解锁而未参与匹配的条数 */
  @Trace contentLocked: number = 0;
  /** 因缺少解密密钥而未参与匹配的条数 */
  @Trace contentMissing: number = 0;

  private repo: PasswordRepository = PasswordRepository.getInstance();
  private settings: SettingsRepository = SettingsRepository.getInstance();
  /** 搜索防抖计时器 */
  private searchTimer: number = -1;
  /**
   * 内容匹配流程令牌：cancel/重新发起时自增，用于丢弃在途流程的完成回调
   * （否则旧流程 resolve 时会把新流程的 contentRunning 置回 false，进度行消失）
   */
  private contentRunToken: number = 0;
  /** 内容阶段防抖计时器 */
  private contentTimer: number = -1;
  /**
   * 内容阶段防抖延迟（ms，比名称阶段的 `SEARCH_DEBOUNCE` 长）
   *
   * 一次内容扫描要读并解密**全库**：沿用 300ms 会在连打时反复重启整轮扫描
   * （已解密的条目有缓存，但读密文、解析收件人、枚举都要重做）。名字阶段先上屏，
   * 内容阶段等用户停手再启动。
   */
  private static readonly CONTENT_DEBOUNCE: number = 600;
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
      this.cancelContentSearch(false);
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
    // 离开搜索态（清空关键词/进目录）：停掉在途的内容匹配，缓存保留供下次复用
    this.cancelContentSearch(false);
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
   *
   * 名称/路径匹配同步完成、结果先上屏；`SearchMode.CONTENT` 时再异步启动内容匹配，
   * 命中项由 `mergeContentHits` 增量并入列表（用户不必等解密完才看到结果）。
   */
  private loadSearchResults(): void {
    const searchMode: SearchMode = this.settings.getSettings().searchMode;
    const keyword: string = this.searchKeyword.trim();

    // 精确匹配与模糊匹配必须传不同参数，否则设置页的模式切换完全无效
    // （内容模式的名称阶段与模糊同口径，故只有 EXACT 传 true）
    const result = this.repo.searchEntries(keyword, searchMode === SearchMode.EXACT);
    if (!result.success || !result.data) {
      this.filteredEntries = [];
      this.searchResultCount = 0;
      this.cancelContentSearch(false);
      return;
    }

    // 目录条目保留（不再过滤）：目录行可点、可进入；childCount 由 toVM 按
    // listEntries 填好的 children 直接子项数取值，搜索场景无需另行统计
    this.filteredEntries = result.data.map((entry: PasswordEntry) => this.toVM(entry));

    this.searchResultCount = this.filteredEntries.length;
    this.sortSearchResults();

    if (searchMode === SearchMode.CONTENT) {
      this.scheduleContentSearch(keyword);
    } else {
      this.cancelContentSearch(false);
      // 离开内容匹配模式：拒绝记忆作废（下次切回内容匹配应重新询问未解锁目录）
      ContentSearchService.getInstance().clearRejections();
    }
  }

  /** 安排内容匹配：清掉待触发的计时器后延迟启动（用户停手才真正开跑） */
  private scheduleContentSearch(keyword: string): void {
    if (this.contentTimer !== -1) {
      clearTimeout(this.contentTimer);
    }
    // 从「已安排」起就算 pending：防抖窗口内页面不显示「0 个结果」与空状态
    this.contentPending = true;
    this.contentTimer = setTimeout((): void => {
      this.contentTimer = -1;
      this.startContentSearch(keyword);
    }, PasswordListViewModel.CONTENT_DEBOUNCE);
  }

  /**
   * 启动内容匹配（异步）：进度写进 contentXxx 状态，命中批量并入列表
   */
  private startContentSearch(keyword: string): void {
    const service: ContentSearchService = ContentSearchService.getInstance();
    // 令牌自增使上一轮的在途流程失效（旧流程 .then 回来时不再动运行态）
    const token: number = ++this.contentRunToken;
    this.contentRunning = true;
    this.contentPending = true;
    this.contentScanned = 0;
    this.contentTotal = 0;
    this.contentLocked = 0;
    this.contentMissing = 0;

    const callbacks: ContentSearchCallbacks = {
      onProgress: (progress: ContentSearchProgress): void => {
        if (token !== this.contentRunToken) {
          return;
        }
        this.contentScanned = progress.scanned;
        this.contentTotal = progress.total;
        this.contentLocked = progress.locked;
        this.contentMissing = progress.missingKey;
      },
      onHits: (hits: ContentHit[]): void => {
        if (token !== this.contentRunToken) {
          return;
        }
        this.mergeContentHits(hits);
      },
    };

    service.run(keyword, callbacks).then((): void => {
      if (token === this.contentRunToken) {
        this.contentRunning = false;
        this.contentPending = false;
      }
    }).catch((e: Error): void => {
      if (token === this.contentRunToken) {
        this.contentRunning = false;
        this.contentPending = false;
      }
      hilog.warn(DOMAIN, TAG, 'content search failed: %{public}s', e.message);
    });
  }

  /**
   * 取消内容匹配并复位进度状态
   *
   * @param clearCache 是否连明文缓存一并丢弃（仓库变更/上锁时为 true）
   */
  private cancelContentSearch(clearCache: boolean): void {
    if (this.contentTimer !== -1) {
      clearTimeout(this.contentTimer);
      this.contentTimer = -1;
    }
    this.contentRunToken++;
    const service: ContentSearchService = ContentSearchService.getInstance();
    service.cancel();
    if (clearCache) {
      service.clearCache();
    }
    this.contentRunning = false;
    this.contentPending = false;
    this.contentScanned = 0;
    this.contentTotal = 0;
    this.contentLocked = 0;
    this.contentMissing = 0;
  }

  /**
   * 内容命中批量并入列表
   *
   * 名称已命中的条目不再重复加入（同一 relativePath 只出现一行），
   * 并入后仍按「目录在前、组内名称字母序」重排，与名称阶段同口径；
   * 内容命中的行带上 `contentSnippet`，列表用它显示「为什么命中」。
   */
  private mergeContentHits(hits: ContentHit[]): void {
    if (hits.length === 0) {
      return;
    }
    const existing: Set<string> = new Set<string>();
    for (let i: number = 0; i < this.filteredEntries.length; i++) {
      existing.add(this.filteredEntries[i].relativePath);
    }
    const merged: PasswordEntryVM[] = this.filteredEntries.slice();
    for (let i: number = 0; i < hits.length; i++) {
      const hit: ContentHit = hits[i];
      if (existing.has(hit.entry.relativePath)) {
        continue;
      }
      existing.add(hit.entry.relativePath);
      const vm: PasswordEntryVM = this.toVM(hit.entry);
      vm.contentSnippet = hit.snippet;
      merged.push(vm);
    }
    if (merged.length === this.filteredEntries.length) {
      return;
    }
    merged.sort(PasswordListViewModel.compareEntries);
    this.filteredEntries = merged;
    this.searchResultCount = merged.length;
  }

  /**
   * 重新匹配内容：清掉「已拒绝解锁」记忆并重跑内容匹配
   *
   * 状态行的未解锁提示点按后走这里——用户拒绝过的目录会重新弹口令框
   * （已在此前输入过口令的密钥直接命中缓存，不再询问）。
   */
  retryContentUnlock(): void {
    const keyword: string = this.searchKeyword.trim();
    if (keyword.length === 0) {
      return;
    }
    ContentSearchService.getInstance().retryUnlock();
    this.startContentSearch(keyword);
  }

  /** 搜索结果排序：目录在前，组内按名称字母序（目录浏览与搜索同口径） */
  private sortSearchResults(): void {
    this.filteredEntries.sort(PasswordListViewModel.compareEntries);
  }

  private static compareEntries(a: PasswordEntryVM, b: PasswordEntryVM): number {
    if (a.isDirectory !== b.isDirectory) {
      return a.isDirectory ? -1 : 1;
    }
    return a.name.localeCompare(b.name);
  }

  /**
   * 仓库变更（保存/删除/移动/拉取）后的处理
   *
   * 内容匹配的明文缓存必须丢弃：`lastModified` 只有秒级精度，
   * 同一秒内的编辑靠 mtime 比对发现不了，留着就会用旧文本给出结果。
   * 拒绝记忆一并清掉：内容变了，之前拒绝解锁的目录值得再问一次。
   */
  onRepoChanged(): void {
    this.cancelContentSearch(true);
    ContentSearchService.getInstance().clearRejections();
    this.loadEntries();
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
      contentSnippet: '',
    };
  }

  /**
   * 更新搜索关键词并刷新列表（带防抖）
   */
  updateSearchKeyword(keyword: string): void {
    this.searchKeyword = keyword;
    this.isSearching = keyword.trim().length > 0;

    // 立刻停掉在途的内容匹配：防抖窗口内关键词已变，旧流程的解密结果不再是本轮要的
    // （缓存保留——已解密的条目下次仍可直接复用）
    this.cancelContentSearch(false);

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
    // 离开这一轮搜索：拒绝记忆作废（下次同关键词应重新询问未解锁目录）
    ContentSearchService.getInstance().clearRejections();
    this.loadEntries();
  }

  /**
   * 点击目录进入（含从搜索结果点击）：
   * 必须先清空搜索关键词再加载，否则 loadEntries 会因关键词非空
   * 继续走搜索分支，列表看似纹丝不动（表现为「点了进不去目录」）
   */
  enterDirectory(relativePath: string): void {
    this.currentDir = relativePath;
    if (this.searchKeyword.length > 0) {
      this.searchKeyword = '';
      this.isSearching = false;
    }
    // 从搜索结果进入目录 = 离开这一轮搜索，拒绝记忆作废
    ContentSearchService.getInstance().clearRejections();
    this.loadEntries();
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
