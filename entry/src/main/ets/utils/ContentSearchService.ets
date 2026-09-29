import { PasswordEntry } from '../model/PasswordEntry';
import { PasswordRepository, RepoResult } from '../model/PasswordRepository';
import { PasswordFileParser } from '../format/PasswordFileParser';
import { PgpCrypto, CryptoResult } from '../crypto/PgpCrypto';
import { PgpKeyManager } from '../crypto/PgpKeyManager';
import { GpgKeyId } from '../model/GpgKeyId';
import { Strings } from '../common/Strings';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0001;
const TAG = 'ContentSearch';

/** 每凑够这么多命中就回调一批（列表每合并一批要全量重排一次，逐条回调是 O(n²)） */
const HIT_BATCH: number = 8;
/** 进度回调节流：每处理这么多条回调一次（阶段切换/结束强制回调） */
const PROGRESS_EVERY: number = 4;
/**
 * 并发处理的条目数
 *
 * 单条的成本几乎全在「TaskPool 往返 + native 解密」上（读文件是主线程的），
 * 一次跑 4 条能让这些往返互相重叠——实测口径见 AGENTS.md 的性能条目。
 * 再大收益递减（TaskPool 工作线程有限），且并发调用 native 解密的内存峰值会抬高。
 */
const ENTRY_CONCURRENCY: number = 4;
/**
 * 解锁请求的等待上限（ms）
 *
 * 页面在所有取消路径（取消按钮 / 遮罩关闭 / 返回键）都会兑现请求，这里是兜底：
 * 万一某条关闭路径没被捕获，run 不能永远挂在 `await unlockHandler(...)` 上
 * （表现会是进度行停在某个数字再也不动）。超时按「用户取消」处理。
 */
const UNLOCK_TIMEOUT_MS: number = 120_000;

/**
 * 内容匹配进度（逐条累加）
 *
 * `scanned` 最终等于 `total`：缓存命中、缺密钥、解密失败、未解锁跳过都会计入。
 */
export interface ContentSearchProgress {
  /** 参与匹配的条目总数（仓库内全部密码文件） */
  total: number;
  /** 已处理条数（含未参与匹配而跳过的） */
  scanned: number;
  /** 命中条数 */
  matched: number;
  /** 有私钥但未解锁，内容未参与匹配 */
  locked: number;
  /** 没有任何已导入私钥可解（缺密钥） */
  missingKey: number;
  /** 读取或解密失败（密文损坏、算法不支持等） */
  failed: number;
}

/** 内容匹配回调：进度与命中都可能在整条流程里被多次调用 */
export interface ContentSearchCallbacks {
  onProgress: (progress: ContentSearchProgress) => void;
  /** 命中一批条目（同一批内不重复，跨批可能重复，调用方按 relativePath 去重） */
  onHits: (hits: ContentHit[]) => void;
}

/** 内容命中：条目 + 命中片段（片段取自可搜索文本，永不含主密码） */
export interface ContentHit {
  entry: PasswordEntry;
  /** 命中的字段值片段（已截断，供列表副标题说明「为什么命中」） */
  snippet: string;
}

/** 待解锁的目录组（组内条目由同一批候选密钥加密） */
export interface ContentUnlockRequest {
  /** 就近 `.gpg-id` 所在目录（空串 = 仓库根） */
  dirPath: string;
  /** 该组的候选解密密钥指纹（密文收件人优先，与未解锁判定同口径） */
  candidateFingerprints: string[];
  /** 密钥展示名（邮箱/uid，多把用列表分隔符连接），供弹窗的 PGP ID 行 */
  keyLabel: string;
  /** 该组待解锁的条目数 */
  entryCount: number;
}

/**
 * 解锁回调：由页面注入并弹出口令框
 *
 * @returns true = 已解锁（service 立即解密该组并出结果）；false = 用户取消（计入 locked）
 */
export type ContentUnlockHandler = (req: ContentUnlockRequest) => Promise<boolean>;

/** 单条解密的结果（记账由调用方做：快速路径失败时要能回退重试，不能先记账） */
enum DecryptOutcome {
  OK = 0,
  /** 密钥已解锁却解不开（密文损坏 / 算法不支持） */
  FAILED = 1,
  /** 候选密钥都未解锁 */
  LOCKED = 2,
}

/** 缓存条目：可搜索文本（大小写原样 + 小写副本），mtime 未变即可直接复用 */
interface ContentCacheEntry {
  mtime: number;
  text: string;
  lowerText: string;
}

/** 待解锁条目：预扫阶段读到的密文与实际候选密钥 */
interface ContentLockedItem {
  entry: PasswordEntry;
  ciphertext: string;
  candidates: string[];
}

/**
 * 未解锁分组：同一个 .gpg-id 目录下的条目
 *
 * 解锁与口令弹窗都以组为单位（同一目录的条目通常由同一把密钥加密，弹一次即可），
 * `candidates` 是组内候选密钥的并集。
 */
interface ContentLockedGroup {
  dir: string;
  items: ContentLockedItem[];
  candidates: string[];
}

/** 免费解锁 / 解密的各项记忆与分组（一次 run 一份，run 结束即弃） */
interface ScanContext {
  /** 条目所在目录 → 就近 .gpg-id 目录 */
  gpgDirMemo: Map<string, string>;
  /** .gpg-id 目录 → 该目录 .gpg-id 的密钥条目 */
  gpgIdsMemo: Map<string, string[]>;
  /** 「目录 + 候选集合」→ 免密解锁探测结果 */
  readyMemo: Map<string, boolean>;
  /** 免密解锁探测的进行中 promise（并发批内同键复用，避免重复 native 验证） */
  readyInFlight: Map<string, Promise<boolean>>;
  lockedGroups: ContentLockedGroup[];
  lockedIndex: Map<string, number>;
  timings: ContentSearchTimings;
}

/** 分段耗时（ms，日志用：优化前后对比与定位瓶颈都靠它） */
interface ContentSearchTimings {
  /** 枚举全库（searchEntries('')，命中缓存时为 0） */
  enumerate: number;
  /** 读密文 + 二进制转 armor */
  read: number;
  /** 解析密文收件人（TaskPool 的 PKESK 解析） */
  pkesk: number;
  /** 解密（TaskPool，含 native 的解锁与解报文） */
  decrypt: number;
  /** 等用户输入口令（弹窗挂起的时间） */
  prompt: number;
  /** 命中 mtime 缓存（零 IO 零解密）的条数 */
  cacheHits: number;
}

/**
 * 内容匹配引擎（「内容匹配」搜索模式的后半段）
 *
 * 名称/路径匹配仍由 `PasswordRepository.searchEntries` 同步完成、结果先上屏；
 * 本服务逐条**解密**并匹配「除主密码以外的字段内容」（规则见
 * `PasswordFileParser.searchableText`），命中项增量回调给调用方。
 *
 * ## 流程（单趟，进度单调推进）
 *
 * ① 枚举全库密码文件（`searchEntries('')`，同一仓库版本内复用缓存）；
 * ② **名称/路径也含关键词的条目排在最前面**——用户找的通常就是它们，先出结果；
 * ③ 逐条（并发 `ENTRY_CONCURRENCY` 条）：mtime 缓存命中则零 IO 直接匹配；否则
 * 读密文，若该目录 `.gpg-id` 的密钥已解锁就直接解密（省掉一次收件人解析），
 * 否则解析收件人后按需免密解锁 / 收进「按 .gpg-id 目录分组」的未解锁表；
 * ④ 全部条目走完后逐组向页面要口令（`unlockHandler`）：解锁成功就地把该组解密
 * 出结果，取消则记入 `rejectedGroups` 并计 `locked`——同一关键词下不再重复追问，
 * 用户可用状态行的「重新匹配」清掉记忆重试。
 *
 * ## 三条硬性约束（都来自既有教训）
 *
 * 1. **原生调用一律经 TaskPool**：收件人解析走 `entryDecryptionCandidatesAsync`、
 *    解密走 `crypto.decrypt`（内部即 `callPgp`）；且**必须**把预扫出的收件人作为
 *    `preferredFingerprints` 传给 `decrypt`——不传时 `decrypt` 会用**同步** native
 *    再解析一遍 PKESK，逐条循环等于把主线程重新绑住（重加密管线最初就漏了这一处）。
 *    流程中每个昂贵步骤都是 await，天然让出事件循环，无需额外的 sleep 让出。
 * 2. **缓存里是明文**：只存可搜索文本（不含主密码、不含 `rawText`），但仍是条目内容。
 *    故 `AppLockManager.clearSensitiveCaches()`（上锁/切后台）必须调 `clearCache()`；
 *    仓库变更（`RepoChangeNotifier`）同样要清——`lastModified` 只有秒级精度，
 *    同一秒内的编辑靠它发现不了。枚举缓存也在这里失效。
 * 3. **未解锁不静默失败**：锁定条目交给页面弹口令框（`unlockHandler`），
 *    等待有超时兜底；结果与拒绝都计数上报，由调用方决定提示与重试。
 *
 * ## 性能（冷缓存首搜的耗时构成与对策）
 *
 * 解密本身很便宜，贵的是**每条密文都重新解析私钥 + 跑一遍迭代 S2K 解锁**
 * （GnuPG 默认 count 可达 65M 哈希量）。对策分两层：native 侧把解锁后的私钥缓存
 * 起来（每把密钥每会话只解锁一次，见 rpgp_wrapper 的 `hps_pgp_lock`/缓存说明），
 * ArkTS 侧则是本文件的并发、跳过冗余收件人解析、枚举缓存与两波排序。
 */
export class ContentSearchService {
  private static instance: ContentSearchService | null = null;

  static getInstance(): ContentSearchService {
    if (!ContentSearchService.instance) {
      ContentSearchService.instance = new ContentSearchService();
    }
    return ContentSearchService.instance;
  }

  /**
   * 会话内的可搜索文本缓存（**含明文**，见类注释第 2 条）
   *
   * key = 条目相对路径；value = mtime + 可搜索文本。`lastModified` 相同即复用，
   * 因此第二次搜索只需解密新增/变更过的条目。
   */
  private cache: Map<string, ContentCacheEntry> = new Map<string, ContentCacheEntry>();

  /**
   * 枚举结果缓存（同一仓库版本内复用）
   *
   * `searchEntries('')` 是同步递归 IO（每目录一次 listDir + 每条一次 statSync），
   * 大仓库约 0.1–0.3s；连打关键词时每轮都重跑毫无意义。仓库变更 / 上锁时由
   * `clearCache()` 一并失效（与可搜索文本缓存同一生命周期）。
   */
  private fileListCache: PasswordEntry[] | null = null;

  /**
   * 解锁回调：由页面注入（弹口令框）
   *
   * null 时锁定条目只计数、不追问（页面销毁后可能处于该状态）。
   */
  private unlockHandler: ContentUnlockHandler | null = null;

  /**
   * 本关键词下已被用户拒绝解锁的组（键 = `groupKey(dir, candidates)`）
   *
   * 关键词变化、清空搜索、仓库变更时清空——否则用户每敲一个字符都会被同一批目录
   * 再追问一遍；`retryUnlock()` 供状态行的「重新匹配」显式清空。
   */
  private rejectedGroups: Set<string> = new Set<string>();

  /** 上一次 run 的关键词（变化时清空拒绝记忆） */
  private lastKeyword: string = '';

  /** 代次：每次 run/cancel 自增，旧流程在条目间自检后静默退出 */
  private generation: number = 0;

  private running: boolean = false;

  // ===== 单次流程的运行态（同一时刻只有一个流程，由 generation 保证） =====
  private progress: ContentSearchProgress = ContentSearchService.emptyProgress();
  private hits: ContentHit[] = [];
  private callbacks: ContentSearchCallbacks | null = null;
  private gen: number = 0;

  private static emptyProgress(): ContentSearchProgress {
    return { total: 0, scanned: 0, matched: 0, locked: 0, missingKey: 0, failed: 0 };
  }

  private static emptyTimings(): ContentSearchTimings {
    return { enumerate: 0, read: 0, pkesk: 0, decrypt: 0, prompt: 0, cacheHits: 0 };
  }

  /** 取消进行中的流程（关键词变化、清空搜索、离开搜索态时调用） */
  cancel(): void {
    this.generation++;
    this.running = false;
  }

  isRunning(): boolean {
    return this.running;
  }

  /**
   * 清空可搜索文本缓存与枚举缓存
   *
   * 必须在上锁/切后台（`AppLockManager.clearSensitiveCaches`）与仓库变更
   * （`RepoChangeNotifier`）时调用：缓存里是条目明文的派生文本。
   */
  clearCache(): void {
    if (this.cache.size > 0) {
      hilog.info(DOMAIN, TAG, 'clearCache: %{public}d entries dropped', this.cache.size);
    }
    this.cache.clear();
    this.fileListCache = null;
  }

  /** 已缓存的条目数（诊断/日志用） */
  cachedCount(): number {
    return this.cache.size;
  }

  /** 页面注入解锁回调（aboutToAppear 注入、aboutToDisappear 传 null 解除） */
  setUnlockHandler(handler: ContentUnlockHandler | null): void {
    this.unlockHandler = handler;
  }

  /**
   * 清空拒绝记忆
   *
   * 清空关键词、离开搜索态、仓库变更时调用；同时复位 `lastKeyword`，
   * 使下一次同关键词的 run 也被视为新一轮。
   */
  clearRejections(): void {
    this.rejectedGroups.clear();
    this.lastKeyword = '';
  }

  /**
   * 重新匹配（状态行的「点按重新匹配」）
   *
   * 只清拒绝记忆、不动 `lastKeyword`：调用方紧接着用**同一关键词**重跑 run 时，
   * run 不应再把这批目录当作「已拒绝」。
   */
  retryUnlock(): void {
    this.rejectedGroups.clear();
  }

  /**
   * 执行一次内容匹配
   *
   * @param keyword 关键词（调用方保证非空；匹配按小写子串）
   * @param callbacks 进度与命中回调（可能被多次调用；取消后不再回调）
   */
  async run(keyword: string, callbacks: ContentSearchCallbacks): Promise<void> {
    const gen: number = ++this.generation;
    this.gen = gen;
    this.running = true;
    this.callbacks = callbacks;
    this.progress = ContentSearchService.emptyProgress();
    this.hits = [];
    // 关键词变了就是一轮新搜索：上一轮被拒绝的目录要重新询问（同一关键词内不重复追问）
    if (keyword !== this.lastKeyword) {
      this.rejectedGroups.clear();
      this.lastKeyword = keyword;
    }
    const lowerKeyword: string = keyword.toLowerCase();
    const repo: PasswordRepository = PasswordRepository.getInstance();
    const ctx: ScanContext = {
      gpgDirMemo: new Map<string, string>(),
      gpgIdsMemo: new Map<string, string[]>(),
      readyMemo: new Map<string, boolean>(),
      readyInFlight: new Map<string, Promise<boolean>>(),
      lockedGroups: [],
      lockedIndex: new Map<string, number>(),
      timings: ContentSearchService.emptyTimings(),
    };

    try {
      const files: PasswordEntry[] | null = this.enumerateFiles(repo, ctx.timings);
      if (files === null) {
        return;
      }
      this.progress.total = files.length;
      this.emit(true);

      // 名称/路径也命中的条目先处理（用户找的通常就是这些），其余随后
      const ordered: PasswordEntry[] = ContentSearchService.prioritize(files, lowerKeyword);

      for (let start: number = 0; start < ordered.length; start += ENTRY_CONCURRENCY) {
        if (this.cancelled()) {
          return;
        }
        const batch: PasswordEntry[] = ordered.slice(start, start + ENTRY_CONCURRENCY);
        // 批次内并发：每条的成本主要在 TaskPool 往返与 native 上，重叠后总时长明显缩短；
        // 进度/命中/分组都是单线程累加，取消检查在每个 await 之后
        await Promise.all(batch.map((entry: PasswordEntry): Promise<void> =>
          this.processEntry(entry, lowerKeyword, ctx)));
      }
      this.flushHits(true);

      // 未解锁的分组：逐组向页面要口令（已拒绝过的组不再追问），
      // 解锁成功就地把该组解密出结果
      await this.processLockedGroups(ctx, lowerKeyword);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'run failed: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : String(e));
    } finally {
      // 只有仍是当前代次才收尾（被取消/被新流程取代时不碰新流程的运行态）
      if (this.gen === this.generation) {
        this.running = false;
        this.flushHits(true);
        this.emit(true);
        const p: ContentSearchProgress = this.progress;
        const t: ContentSearchTimings = ctx.timings;
        hilog.info(DOMAIN, TAG,
          'run done: total=%{public}d matched=%{public}d locked=%{public}d missing=%{public}d failed=%{public}d cached=%{public}d | ms: enumerate=%{public}d read=%{public}d pkesk=%{public}d decrypt=%{public}d prompt=%{public}d cacheHits=%{public}d',
          p.total, p.matched, p.locked, p.missingKey, p.failed, this.cache.size,
          t.enumerate, t.read, t.pkesk, t.decrypt, t.prompt, t.cacheHits);
      }
    }
  }

  /** 枚举全库密码文件（同一仓库版本内复用；失败返回 null） */
  private enumerateFiles(repo: PasswordRepository, timings: ContentSearchTimings): PasswordEntry[] | null {
    if (this.fileListCache !== null) {
      return this.fileListCache;
    }
    const started: number = Date.now();
    const listResult: RepoResult<PasswordEntry[]> = repo.searchEntries('');
    timings.enumerate += Date.now() - started;
    if (!listResult.success || !listResult.data) {
      hilog.warn(DOMAIN, TAG, 'run: enumerate store failed');
      return null;
    }
    this.fileListCache = listResult.data; // 空关键词只返回文件
    return this.fileListCache;
  }

  /**
   * 处理一条条目：缓存命中 → 直接匹配；否则读密文、解密或收进未解锁分组
   *
   * 每条只在这里记账一次（`scanned`/`failed`/`locked`/`matched`）；收进未解锁分组的
   * 条目不在这里计 `scanned`，等分组处理时统一计（否则进度条会在弹窗期间先满）。
   */
  private async processEntry(entry: PasswordEntry, lowerKeyword: string, ctx: ScanContext): Promise<void> {
    if (this.cancelled()) {
      return;
    }
    const crypto: PgpCrypto = PgpCrypto.getInstance();
    const repo: PasswordRepository = PasswordRepository.getInstance();

    // ① mtime 未变的条目：零 IO、零解密，直接用缓存的可搜索文本匹配
    const cached: ContentCacheEntry | undefined = this.cache.get(entry.relativePath);
    if (cached !== undefined && cached.mtime === entry.lastModified) {
      ctx.timings.cacheHits++;
      this.progress.scanned++;
      if (cached.lowerText.includes(lowerKeyword)) {
        this.progress.matched++;
        this.hits.push({
          entry: entry,
          snippet: PasswordFileParser.matchSnippet(cached.text, lowerKeyword),
        });
        this.flushHits(false);
      }
      this.emit(false);
      return;
    }

    // ② 读密文（主线程：文件 IO + 二进制转 armor）
    const readStart: number = Date.now();
    const ciphertext: string = repo.readCiphertext(entry.relativePath);
    ctx.timings.read += Date.now() - readStart;
    if (ciphertext.length === 0) {
      this.progress.scanned++;
      this.progress.failed++;
      this.emit(false);
      return;
    }

    const dir: string = this.gpgDirOf(entry, repo, ctx.gpgDirMemo);
    const gpgIds: string[] = this.gpgIdsOf(dir, repo, ctx.gpgIdsMemo);

    // ③ 快路：该目录 .gpg-id 指定的密钥已解锁时直接用它解密——省掉一次
    //    「解析密文收件人」的 TaskPool 往返（同目录共用密钥是常态）。
    //    解不开说明条目实际由别的密钥加密（移动/换过密钥的残留），
    //    回落完整链路按密文收件人重试（该路径负责弹窗解锁）。
    const gpgIdFps: string[] = PgpKeyManager.getInstance().resolvedKeyFingerprints(gpgIds);
    if (gpgIdFps.length > 0 && this.hasCachedPassphrase(crypto, gpgIdFps)) {
      const fastStart: number = Date.now();
      const fast: DecryptOutcome = await this.decryptAndMatch(entry, ciphertext, gpgIdFps, lowerKeyword);
      ctx.timings.decrypt += Date.now() - fastStart;
      if (this.cancelled()) {
        return;
      }
      if (fast === DecryptOutcome.OK) {
        this.progress.scanned++;
        this.emit(false);
        return;
      }
      // 解不开：继续走完整链路（按密文收件人重试，必要时弹窗）
    }

    // ④ 完整链路：解析收件人（TaskPool）→ 免密解锁探测 → 解密 / 收进未解锁分组
    const pkeskStart: number = Date.now();
    const candidates: string[] = await crypto.entryDecryptionCandidatesAsync(ciphertext, gpgIds);
    ctx.timings.pkesk += Date.now() - pkeskStart;
    if (this.cancelled()) {
      return;
    }
    if (candidates.length === 0) {
      this.progress.scanned++;
      this.progress.missingKey++;
      this.emit(false);
      return;
    }

    const ready: boolean = await this.ensureReady(dir, candidates, crypto, ctx);
    if (this.cancelled()) {
      return;
    }
    if (!ready) {
      ContentSearchService.addToLockedGroup(ctx.lockedGroups, ctx.lockedIndex, dir, entry, ciphertext, candidates);
      this.emit(false);
      return;
    }

    const decryptStart: number = Date.now();
    const outcome: DecryptOutcome = await this.decryptAndMatch(entry, ciphertext, candidates, lowerKeyword);
    ctx.timings.decrypt += Date.now() - decryptStart;
    this.progress.scanned++;
    if (outcome === DecryptOutcome.FAILED) {
      this.progress.failed++;
    } else if (outcome === DecryptOutcome.LOCKED) {
      this.progress.locked++;
    }
    this.emit(false);
  }

  /**
   * 候选密钥是否已可用于解密
   *
   * 已缓存口令（无口令密钥在 `ensureUnlocked` 时缓存空串）直接可用；
   * 否则试一次免密解锁，并按「目录 + 候选密钥集合」记忆探测结果——同一目录同一批
   * 候选只探一次，避免逐条去 native 验证空口令；键里带上候选集合是因为同一目录
   * 可能存在候选不同的条目（移动/换密钥的残留），只用目录做键会让前一条的失败
   * 结果把它们一起误判为未解锁。并发批内同键复用进行中的 promise。
   */
  private ensureReady(dir: string, candidates: string[], crypto: PgpCrypto,
    ctx: ScanContext): Promise<boolean> {
    if (this.hasCachedPassphrase(crypto, candidates)) {
      return Promise.resolve(true);
    }
    const key: string = `${dir}|${candidates.join(',')}`;
    const probed: boolean | undefined = ctx.readyMemo.get(key);
    if (probed !== undefined) {
      return Promise.resolve(probed && this.hasCachedPassphrase(crypto, candidates));
    }
    const inFlight: Promise<boolean> | undefined = ctx.readyInFlight.get(key);
    if (inFlight !== undefined) {
      return inFlight;
    }
    const probe: Promise<boolean> = crypto.ensureUnlocked(candidates)
      .then((ok: boolean): boolean => {
        ctx.readyInFlight.delete(key);
        ctx.readyMemo.set(key, ok);
        return ok && this.hasCachedPassphrase(crypto, candidates);
      })
      .catch((): boolean => {
        ctx.readyInFlight.delete(key);
        ctx.readyMemo.set(key, false);
        return false;
      });
    ctx.readyInFlight.set(key, probe);
    return probe;
  }

  /**
   * 解密一条并匹配内容：命中入列、可搜索文本入缓存
   *
   * 只返回结果、不做进度记账（快速路径失败时不能先记账，否则回落完整链路会重复计）；
   * 预扫已解析出收件人时**必须**作为 preferred 传入（否则 `decrypt` 内部会用同步
   * native 再解析一遍 PKESK，逐条循环等于把主线程重新绑住）。
   */
  private async decryptAndMatch(entry: PasswordEntry, ciphertext: string, candidates: string[],
    lowerKeyword: string): Promise<DecryptOutcome> {
    const crypto: PgpCrypto = PgpCrypto.getInstance();
    // 用于区分「密钥没解锁」与「密钥已解锁但密文解不开」两类失败
    const unlocked: boolean = this.hasCachedPassphrase(crypto, candidates);
    const result: CryptoResult = await crypto.decrypt(ciphertext, candidates, candidates);
    if (!result.success) {
      if (unlocked) {
        hilog.warn(DOMAIN, TAG, 'decrypt failed for %{public}s', entry.relativePath);
        return DecryptOutcome.FAILED;
      }
      return DecryptOutcome.LOCKED;
    }
    const text: string = PasswordFileParser.searchableText(PasswordFileParser.parse(result.data));
    const lowerText: string = text.toLowerCase();
    this.cache.set(entry.relativePath,
      { mtime: entry.lastModified, text: text, lowerText: lowerText });
    if (lowerText.includes(lowerKeyword)) {
      this.progress.matched++;
      this.hits.push({
        entry: entry,
        snippet: PasswordFileParser.matchSnippet(text, lowerKeyword),
      });
      this.flushHits(false);
    }
    return DecryptOutcome.OK;
  }

  /**
   * 逐组处理未解锁目录
   *
   * 弹窗以**组**为单位（同一 .gpg-id 目录一次口令即可）：解锁成功后该组条目
   * 复用 `decryptAndMatch` 出结果；用户取消则记入 `rejectedGroups` 并计入 `locked`，
   * 同一关键词下不再追问。页面未注入回调（已销毁）时同样只计数。
   */
  private async processLockedGroups(ctx: ScanContext, lowerKeyword: string): Promise<void> {
    const groups: ContentLockedGroup[] = ctx.lockedGroups;
    for (let g: number = 0; g < groups.length; g++) {
      if (this.cancelled()) {
        return;
      }
      const group: ContentLockedGroup = groups[g];
      const key: string = ContentSearchService.groupKey(group.dir, group.candidates);

      let unlocked: boolean = false;
      if (!this.rejectedGroups.has(key) && this.unlockHandler !== null) {
        const promptStart: number = Date.now();
        unlocked = await ContentSearchService.withTimeout(
          this.unlockHandler(this.buildUnlockRequest(group)), UNLOCK_TIMEOUT_MS);
        ctx.timings.prompt += Date.now() - promptStart;
        if (this.cancelled()) {
          return;
        }
      }

      if (!unlocked) {
        if (this.unlockHandler !== null) {
          // 记住「本关键词下不再追问」；页面销毁无回调时不必记（下次进入是新页面）
          this.rejectedGroups.add(key);
        }
        this.progress.locked += group.items.length;
        this.progress.scanned += group.items.length;
        hilog.info(DOMAIN, TAG, 'group locked: dir=%{public}s entries=%{public}d',
          group.dir, group.items.length);
        this.emit(true);
        continue;
      }

      for (let i: number = 0; i < group.items.length; i++) {
        if (this.cancelled()) {
          return;
        }
        const item: ContentLockedItem = group.items[i];
        const decryptStart: number = Date.now();
        const outcome: DecryptOutcome =
          await this.decryptAndMatch(item.entry, item.ciphertext, item.candidates, lowerKeyword);
        ctx.timings.decrypt += Date.now() - decryptStart;
        this.progress.scanned++;
        if (outcome === DecryptOutcome.FAILED) {
          this.progress.failed++;
        } else if (outcome === DecryptOutcome.LOCKED) {
          this.progress.locked++;
        }
        this.emit(false);
      }
      this.flushHits(true);
    }
  }

  private buildUnlockRequest(group: ContentLockedGroup): ContentUnlockRequest {
    return {
      dirPath: group.dir,
      candidateFingerprints: group.candidates,
      keyLabel: ContentSearchService.keyLabelOf(group.candidates),
      entryCount: group.items.length,
    };
  }

  /** 弹窗的密钥展示名：邮箱优先、uid 兜底，多把用列表分隔符连接（同页面 resolveEntryKeyId） */
  private static keyLabelOf(fingerprints: string[]): string {
    const labels: string[] = [];
    for (let i: number = 0; i < fingerprints.length; i++) {
      const key: GpgKeyId | null = PgpKeyManager.getInstance().findKey(fingerprints[i]);
      if (key !== null) {
        labels.push(key.email.length > 0 ? key.email : key.userId);
      }
    }
    return labels.length > 0 ? labels.join(Strings.get('common_list_sep')) : '****@***';
  }

  /** 组键：目录 + 排序后的候选密钥集合（与免密探测的记忆键同口径） */
  private static groupKey(dir: string, candidates: string[]): string {
    return `${dir}|${candidates.slice().sort().join(',')}`;
  }

  /**
   * 名称/路径含关键词的条目排前面，其余保持原顺序
   *
   * 总耗时不变，但用户要找的那几条通常几百毫秒内就上屏（配合渐进式出结果）。
   */
  private static prioritize(files: PasswordEntry[], lowerKeyword: string): PasswordEntry[] {
    const named: PasswordEntry[] = [];
    const rest: PasswordEntry[] = [];
    for (let i: number = 0; i < files.length; i++) {
      const entry: PasswordEntry = files[i];
      if (entry.relativePath.toLowerCase().includes(lowerKeyword)) {
        named.push(entry);
      } else {
        rest.push(entry);
      }
    }
    if (named.length === 0) {
      return files;
    }
    return named.concat(rest);
  }

  /**
   * 给解锁请求加等待上限
   *
   * 页面在取消按钮 / 遮罩关闭 / 返回键三条路径都会兑现请求，这里是兜底：
   * 漏掉任一条都不能让 run 永远挂住（进度行会卡死在某个数字）。
   */
  private static withTimeout(pending: Promise<boolean>, ms: number): Promise<boolean> {
    return new Promise<boolean>((resolve: (value: boolean) => void): void => {
      let settled: boolean = false;
      const timer: number = setTimeout((): void => {
        if (settled) {
          return;
        }
        settled = true;
        hilog.warn(DOMAIN, TAG, 'unlock request timed out after %{public}dms, treated as cancel', ms);
        resolve(false);
      }, ms);
      pending.then((ok: boolean): void => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        resolve(ok);
      }).catch((e: Error): void => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        hilog.warn(DOMAIN, TAG, 'unlock handler rejected: %{public}s', e.message);
        resolve(false);
      });
    });
  }

  private hasCachedPassphrase(crypto: PgpCrypto, candidates: string[]): boolean {
    for (let i: number = 0; i < candidates.length; i++) {
      if (crypto.getPassphrase(candidates[i]) !== undefined) {
        return true;
      }
    }
    return false;
  }

  private cancelled(): boolean {
    return this.gen !== this.generation;
  }

  /** 进度回调（按条数节流，阶段切换/结束时 force） */
  private emit(force: boolean): void {
    if (this.callbacks === null) {
      return;
    }
    if (!force && this.progress.scanned % PROGRESS_EVERY !== 0) {
      return;
    }
    this.callbacks.onProgress(this.progress);
  }

  /** 命中回调（攒够 `HIT_BATCH` 或 force 时批量交付） */
  private flushHits(force: boolean): void {
    if (this.callbacks === null || this.hits.length === 0) {
      return;
    }
    if (!force && this.hits.length < HIT_BATCH) {
      return;
    }
    const batch: ContentHit[] = this.hits;
    this.hits = [];
    this.callbacks.onHits(batch);
  }

  /** 条目所属的就近 .gpg-id 目录（按「所在目录」记忆，避免逐条向上遍历文件系统） */
  private gpgDirOf(entry: PasswordEntry, repo: PasswordRepository,
    memo: Map<string, string>): string {
    const parent: string = ContentSearchService.parentDirOf(entry.relativePath);
    const cached: string | undefined = memo.get(parent);
    if (cached !== undefined) {
      return cached;
    }
    const dir: string = repo.findGpgIdDir(parent);
    memo.set(parent, dir);
    return dir;
  }

  /** 该 .gpg-id 目录的密钥条目（按目录记忆，避免逐条读 .gpg-id 文件） */
  private gpgIdsOf(dir: string, repo: PasswordRepository, memo: Map<string, string[]>): string[] {
    const cached: string[] | undefined = memo.get(dir);
    if (cached !== undefined) {
      return cached;
    }
    const ids: string[] = repo.getGpgIdForPath(dir);
    memo.set(dir, ids);
    return ids;
  }

  private static parentDirOf(relativePath: string): string {
    const lastSlash: number = relativePath.lastIndexOf('/');
    return lastSlash > 0 ? relativePath.substring(0, lastSlash) : '';
  }

  private static addToLockedGroup(groups: ContentLockedGroup[], index: Map<string, number>,
    dir: string, entry: PasswordEntry, ciphertext: string, candidates: string[]): void {
    const item: ContentLockedItem = { entry: entry, ciphertext: ciphertext, candidates: candidates };
    const at: number | undefined = index.get(dir);
    if (at === undefined) {
      index.set(dir, groups.length);
      const group: ContentLockedGroup = { dir: dir, items: [item], candidates: candidates.slice() };
      groups.push(group);
      return;
    }
    const group: ContentLockedGroup = groups[at];
    group.items.push(item);
    for (let i: number = 0; i < candidates.length; i++) {
      if (group.candidates.indexOf(candidates[i]) < 0) {
        group.candidates.push(candidates[i]);
      }
    }
  }
}
