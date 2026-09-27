import { GitClient, GitCommitInfo } from '../utils/GitClient';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Strings } from '../common/Strings';

/** hilog 域 */
const DOMAIN: number = 0x0001;
/** hilog 标签 */
const TAG: string = 'GitLogVM';

/**
 * 提交历史视图模型
 *
 * 从 GitClient 加载提交记录列表。
 */
@ObservedV2
export class GitLogViewModel {
  /** 提交记录列表 */
  @Trace commits: GitCommitInfo[] = [];
  /** 是否正在加载 */
  @Trace isLoading: boolean = false;
  /** 是否为 Git 仓库 */
  @Trace isRepo: boolean = false;
  /** 错误提示 */
  @Trace errorMessage: string = '';

  private git: GitClient = GitClient.getInstance();

  /**
   * 加载提交历史
   * @param limit 最大条数
   */
  async loadLog(limit: number = 50): Promise<void> {
    this.isLoading = true;
    this.errorMessage = '';
    try {
      this.commits = await this.git.log(limit);
      this.isRepo = this.git.isGitRepo();
      if (!this.isRepo) {
        this.errorMessage = Strings.get('gitlog_not_repo');
      }
    } catch (e) {
      this.errorMessage = Strings.get('gitlog_load_failed');
      hilog.error(DOMAIN, TAG, 'loadLog failed: %{public}s', JSON.stringify(e));
    }
    this.isLoading = false;
  }

  /**
   * 格式化提交时间为可读文本
   */
  formatTime(timestamp: number): string {
    if (timestamp <= 0) return '';
    const date: Date = new Date(timestamp * 1000);
    const pad: (n: number) => string = (n: number) => n.toString().padStart(2, '0');
    return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}`;
  }

  /**
   * 缩短哈希显示（前 7 位）
   */
  shortHash(hash: string): string {
    return hash.length > 7 ? hash.substring(0, 7) : hash;
  }
}
