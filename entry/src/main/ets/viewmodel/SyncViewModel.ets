import { GitClient, GitRepoStatus, GitResult } from '../utils/GitClient';
import { KnownHostsStore, KnownHostKey } from '../utils/KnownHostsStore';
import { SshUrlTarget } from '../utils/GitClient';
import { RepoChangeNotifier } from '../common/RepoChangeNotifier';
import { Strings } from '../common/Strings';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** hilog 域 */
const DOMAIN: number = 0x0001;
/** hilog 标签 */
const TAG: string = 'SyncVM';

/**
 * 同步视图模型
 *
 * 管理拉取/推送/提交操作与仓库状态展示，
 * 同步操作在本地 Git 仓库上执行（native libgit2 就绪后生效）。
 */
@ObservedV2
export class SyncViewModel {
  /** 是否正在执行同步操作 */
  @Trace isSyncing: boolean = false;
  /** 当前操作提示 */
  @Trace operationText: string = '';
  /** 仓库状态 */
  @Trace repoStatus: GitRepoStatus | null = null;
  /** 冲突提示 */
  @Trace conflictMessage: string = '';
  /** 操作结果提示 */
  @Trace resultToast: string = '';
  /** 最后一次操作是否成功 */
  @Trace lastOperationSuccess: boolean = false;
  /** TOFU：待确认的主机密钥指纹（空 = 无待确认项） */
  @Trace pendingHostKeyFp: string = '';
  /** TOFU：待确认连接的主机 */
  @Trace pendingHost: string = '';
  /** TOFU：待确认连接的端口 */
  @Trace pendingPort: number = 22;
  /** TOFU：实际收到的主机密钥类型（RSA/ECDSA/Ed25519） */
  @Trace pendingHostKeyType: string = '';
  /** TOFU：同类型指纹变化（可能中间人，UI 据此切换告警文案） */
  @Trace pendingHostKeyMismatch: boolean = false;

  private git: GitClient = GitClient.getInstance();
  private knownHosts: KnownHostsStore = KnownHostsStore.getInstance();

  /**
   * 刷新仓库状态
   */
  async refreshStatus(): Promise<void> {
    this.repoStatus = await this.git.status();
    if (this.repoStatus.hasConflicts) {
      this.conflictMessage = Strings.get('sync_conflict_message');
    } else {
      this.conflictMessage = '';
    }
  }

  /**
   * 拉取远程更新
   */
  async pull(): Promise<void> {
    await this.runOperation(Strings.get('sync_pulling_remote'), () => this.git.pull());
  }

  /**
   * 推送本地提交
   */
  async push(): Promise<void> {
    await this.runOperation(Strings.get('sync_pushing_remote'), () => this.git.push());
  }

  /**
   * 提交全部变更
   * @param message 提交信息
   */
  async commit(message: string): Promise<void> {
    await this.runOperation(Strings.get('sync_committing_changes'), () => this.git.commitAll(message));
  }

  /**
   * 同步（拉取 + 提交 + 推送）
   */
  async syncAll(): Promise<void> {
    if (this.isSyncing) return;
    this.isSyncing = true;
    this.resultToast = '';

    this.operationText = Strings.get('sync_pulling');
    const pullResult = await this.git.pull();
    if (!pullResult.success) {
      this.finishWith(pullResult.error, false);
      return;
    }

    this.operationText = Strings.get('sync_committing');
    const commitResult = await this.git.commitAll('');
    if (!commitResult.success) {
      // 无变更时提交可能失败，不视为错误
      hilog.info(DOMAIN, TAG, 'commit skipped: %{public}s', commitResult.error);
    }

    this.operationText = Strings.get('sync_pushing');
    const pushResult = await this.git.push();
    if (!pushResult.success) {
      this.finishWith(pushResult.error, false);
      return;
    }

    this.finishWith(Strings.get('sync_done'), true);
  }

  /**
   * 执行单个操作并处理结果
   */
  private async runOperation(text: string, op: () => Promise<GitResult>): Promise<void> {
    if (this.isSyncing) return;
    this.isSyncing = true;
    this.operationText = text;
    this.resultToast = '';

    try {
      const result = await op();
      this.lastOperationSuccess = result.success;
      if (result.success) {
        this.resultToast = Strings.get('sync_op_success');
      } else if (result.pendingHostKeyFp !== undefined && result.pendingHostKeyFp.length > 0) {
        // 主机密钥未信任（同类型指纹变化 = 可能中间人；新类型 = 没钉过的一把）：
        // 弹指纹确认卡，确认后重跑同一操作
        const target: SshUrlTarget | null =
          SshUrlTarget.parse(await this.git.effectiveRemoteUrlPublic());
        this.pendingHost = target !== null ? target.host : '';
        this.pendingPort = target !== null ? target.port : 22;
        this.pendingHostKeyFp = result.pendingHostKeyFp;
        this.pendingHostKeyType = result.pendingHostKeyType ?? '';
        this.pendingHostKeyMismatch = result.hostKeyMismatch === true;
        this.resultToast = '';
      } else {
        this.resultToast = result.error;
      }
    } catch (e) {
      this.lastOperationSuccess = false;
      this.resultToast = Strings.get('sync_op_exception');
      hilog.error(DOMAIN, TAG, 'operation exception: %{public}s', JSON.stringify(e));
    }
    this.isSyncing = false;
    this.operationText = '';
    await this.refreshStatus();
    this.scheduleToastClear();
  }

  /**
   * TOFU 确认：保存主机密钥（带类型）后重跑拉取
   */
  async confirmHostKey(): Promise<void> {
    const host: string = this.pendingHost;
    const port: number = this.pendingPort;
    const fp: string = this.pendingHostKeyFp;
    const keyType: string = this.pendingHostKeyType;
    this.pendingHostKeyFp = '';
    this.pendingHost = '';
    this.pendingHostKeyType = '';
    this.pendingHostKeyMismatch = false;
    if (fp.length === 0) {
      return;
    }
    const ok: boolean = await this.knownHosts.saveHostKey(host, port,
      { keyType: keyType, fingerprint: fp });
    if (!ok) {
      this.resultToast = Strings.get('sync_save_hostkey_failed');
      this.scheduleToastClear();
      return;
    }
    hilog.info(DOMAIN, TAG, 'host key trusted via sync sheet: %{public}s:%{public}d (%{public}s)',
      host, port, keyType);
    await this.pull();
  }

  /** TOFU 拒绝：放弃本次指纹确认 */
  rejectHostKey(): void {
    this.pendingHostKeyFp = '';
    this.pendingHost = '';
    this.pendingPort = 22;
    this.pendingHostKeyType = '';
    this.pendingHostKeyMismatch = false;
  }

  /**
   * 完成同步流程
   */
  private finishWith(message: string, success: boolean): void {
    this.lastOperationSuccess = success;
    this.resultToast = message;
    this.isSyncing = false;
    this.operationText = '';
    this.refreshStatus();
    this.scheduleToastClear();
  }

  /**
   * 2.5 秒后清除结果提示
   */
  private scheduleToastClear(): void {
    setTimeout(() => { this.resultToast = ''; }, 2500);
  }

  /**
   * 状态摘要文本（供列表页展示）
   */
  getStatusSummary(): string {
    if (!this.repoStatus || !this.repoStatus.isRepo) return Strings.get('sync_status_no_repo');
    const parts: string[] = [];
    if (this.repoStatus.branch.length > 0) parts.push(this.repoStatus.branch);
    if (this.repoStatus.changedCount > 0) parts.push(Strings.fmt('sync_status_changes', this.repoStatus.changedCount));
    if (this.repoStatus.aheadCount > 0) parts.push(`↑${this.repoStatus.aheadCount}`);
    if (this.repoStatus.behindCount > 0) parts.push(`↓${this.repoStatus.behindCount}`);
    return parts.length > 0 ? parts.join(' · ') : Strings.get('sync_status_synced');
  }
}
