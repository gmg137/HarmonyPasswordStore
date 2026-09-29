import { SettingsRepository, AppSettings } from '../model/SettingsRepository';
import { PasswordRepository } from '../model/PasswordRepository';
import { GitClient, GitRepoStatus, GitResult, SshUrlTarget } from '../utils/GitClient';
import { KnownHostsStore } from '../utils/KnownHostsStore';
import { GitConfig } from '../model/GitConfig';
import { FileUtils } from '../utils/FileUtils';
import { RepoChangeNotifier } from '../common/RepoChangeNotifier';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Strings } from '../common/Strings';

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
  /**
   * 结果递增序号（页面据此弹成功气泡）
   *
   * 不能直接 `@Monitor('resultMessage')`：连续两次操作的结果文案相同（都是
   * 「操作成功」），值没变就不会触发第二次监听，用户第二次操作看不到任何反馈。
   * 用自增序号保证每次操作都触发一次（与 RepoChangeNotifier.nonce 同一机制）。
   */
  @Trace resultNonce: number = 0;
  /** 强制推送执行中（LoadingOverlay 全模态遮罩） */
  @Trace isForcePushing: boolean = false;
  /** 强制推送失败原因（空 = 无；页面据此弹失败原因弹窗，展示后清空） */
  @Trace forcePushError: string = '';
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
      this.statusSummary = Strings.get('repo_status_not_cloned');
      return;
    }
    const status: GitRepoStatus = await this.git.status();
    if (!status.isRepo) {
      this.statusSummary = Strings.get('repo_status_not_cloned');
      return;
    }
    const parts: string[] = [];
    if (status.branch.length > 0) parts.push(status.branch);
    if (status.changedCount > 0) parts.push(Strings.fmt('sync_status_changes', status.changedCount));
    if (status.aheadCount > 0) parts.push(`↑${status.aheadCount}`);
    if (status.behindCount > 0) parts.push(`↓${status.behindCount}`);
    this.statusSummary = parts.length > 0 ? parts.join(' · ') : Strings.get('sync_status_synced');
  }

  /**
   * 设置拉取时是否变基
   */
  async setPullRebase(value: boolean): Promise<void> {
    this.pullRebase = value;
    await this.settings.updateSetting('gitPullRebase', value);
  }

  /** 清空强制推送失败原因（页面弹过失败弹窗后调用，避免重复弹出） */
  clearForcePushError(): void {
    this.forcePushError = '';
  }

  /**
   * 强制推送的瞬时前置校验
   *
   * 仓库未初始化 / 远程地址未配置时直接写入 `forcePushError`（页面弹失败原因
   * 弹窗），否则返回 true 让页面弹危险操作确认面板。全程无网络 IO，不进遮罩。
   */
  async precheckForcePush(): Promise<boolean> {
    this.forcePushError = '';
    if (!this.git.isGitRepo()) {
      this.forcePushError = Strings.get('gitlog_not_repo');
      return false;
    }
    const url: string = (await this.git.effectiveRemoteUrlPublic()).trim();
    const config: GitConfig = await this.settings.loadGitConfig();
    if (url.length === 0 && config.remoteUrl.trim().length === 0) {
      this.forcePushError = Strings.get('settings_autosync_no_remote');
      return false;
    }
    return true;
  }

  /**
   * 执行强制推送：连接测试（含 TOFU）→ gitPush(force)
   *
   * 由确认面板的确认按钮触发。三条出口：
   * - 成功：resultMessage 写成功文案（页面以消息气泡提示）并刷新仓库状态；
   * - 主机密钥未信任：写入 TOFU 待确认状态（`pendingHostKeyFp`），页面弹指纹
   *   确认弹窗，用户确认后经 `confirmHostKey()` 回到本方法重试（可重入——
   *   服务器可能出示多把不同类型的主机密钥）；
   * - 其余失败：`forcePushError` 写入原因（GitClient 已本地化），页面弹失败弹窗。
   */
  async runForcePush(): Promise<void> {
    if (this.isForcePushing) {
      return;
    }
    this.isForcePushing = true;
    this.forcePushError = '';
    // 先清空上次结果：成功文案经 @Monitor 触发气泡，连续两次成功若值不变
    // 可能不触发监听（与 deleteRepo 起始清空同一理由）
    this.resultMessage = '';
    try {
      const config: GitConfig = await this.settings.loadGitConfig();
      const url: string = (await this.git.effectiveRemoteUrlPublic()).trim();
      const isHttps: boolean = url.startsWith('https://') || url.startsWith('http://');

      // 连接测试先行：把「远端不存在 / DNS 解析不了 / 认证不过」在推送前暴露出来，
      // 失败原因用测试连接的可操作文案，而不是推送报出的传输层错误
      const testErr: string = isHttps
        ? await this.testHttpsConnection(url, config)
        : await this.testSshConnection(url);
      if (testErr.length > 0) {
        if (this.pendingHostKeyFp.length === 0) {
          this.forcePushError = testErr;
        }
        return;
      }
      // 测试阶段遇到未信任主机指纹：中止本次执行，待页面弹指纹确认
      // （confirmHostKey 保存后会整体重跑本方法）
      if (this.pendingHostKeyFp.length > 0) {
        return;
      }

      const result: GitResult = await this.git.push(true);
      if (result.success) {
        hilog.info(DOMAIN, TAG, 'force push ok');
        await this.refreshStatus();
        // 先 await 再写结果：用户反馈第二次成功后也不弹气泡，而 @Monitor 对
        // 「await 打断的异步序列」里的赋值存在去重风险，把结果放到最后一个
        // await 之后，确保每次成功都产生一次独立的 nonce 变化
        this.finish(true, Strings.get('sync_op_success'));
        return;
      }
      if (result.pendingHostKeyFp !== undefined && result.pendingHostKeyFp.length > 0) {
        // 推送阶段才遇到未信任指纹（连接测试用的是同一链路，罕见但可能）：
        // 与测试阶段同一套 TOFU 状态，确认后整体重试
        await this.setPendingHostKey(result.pendingHostKeyFp, result.pendingHostKeyType ?? '',
          result.hostKeyMismatch === true);
        return;
      }
      this.forcePushError = result.error;
    } catch (e) {
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : String(e);
      hilog.error(DOMAIN, TAG, 'forcePush exception: %{public}s', msg);
      this.forcePushError = Strings.get('common_native_call_failed');
    } finally {
      this.isForcePushing = false;
    }
  }

  /**
   * SSH 连接测试（认证材料解析 + libgit2 ls-remote）
   *
   * @returns '' 表示通过；否则为失败原因。主机密钥未信任时写入 TOFU 状态并返回 ''，
   *          由调用方据 `pendingHostKeyFp` 区分「待确认」与「通过」
   */
  private async testSshConnection(url: string): Promise<string> {
    const result: GitResult = await this.git.testSshRemote(url);
    if (result.success) {
      return '';
    }
    if (result.pendingHostKeyFp !== undefined && result.pendingHostKeyFp.length > 0) {
      await this.setPendingHostKey(result.pendingHostKeyFp, result.pendingHostKeyType ?? '',
        result.hostKeyMismatch === true);
      return '';
    }
    return result.error;
  }

  /**
   * HTTPS 连接测试（libgit2 connect + ls-remote，GitClient 内部走 TaskPool）
   *
   * @returns '' 表示通过；否则为翻译后的失败原因
   */
  private async testHttpsConnection(url: string, config: GitConfig): Promise<string> {
    const result = await this.git.testHttpsRemote(url,
      config.username, config.password, config.proxyUrl);
    if (result.success) {
      return '';
    }
    hilog.warn(DOMAIN, TAG, 'force push https test raw error: %{public}s', result.error);
    return this.friendlyHttpsError(result.error);
  }

  /**
   * 把 HTTPS 测试连接的 native 原始错误翻译成可操作提示（映射与 GitConfigViewModel 一致）
   */
  private friendlyHttpsError(raw: string): string {
    if (raw.includes('401') || raw.includes('authentication') || raw.includes('credential')
      || raw.includes('too many redirects')) {
      return Strings.get('gitcfg_https_err_auth');
    }
    if (raw.includes('failed to resolve address') || raw.includes('Could not resolve host')
      || raw.includes('resolve')) {
      return Strings.get('gitcfg_https_err_dns');
    }
    if (raw.includes('not found') || raw.includes('repository not found')) {
      return Strings.get('gitcfg_https_err_notfound');
    }
    if (raw.includes('unsupported URL protocol') || raw.includes('unsupported protocol')) {
      return Strings.get('gitcfg_https_err_proto');
    }
    return Strings.fmt('gitcfg_https_err_generic', raw);
  }

  /** 记录 TOFU 待确认状态（主机/端口从实际推送地址解析） */
  private async setPendingHostKey(fp: string, keyType: string, mismatch: boolean): Promise<void> {
    const target: SshUrlTarget | null = SshUrlTarget.parse(await this.git.effectiveRemoteUrlPublic());
    this.pendingHost = target !== null ? target.host : '';
    this.pendingPort = target !== null ? target.port : 22;
    this.pendingHostKeyFp = fp;
    this.pendingHostKeyType = keyType;
    this.pendingHostKeyMismatch = mismatch;
  }

  /**
   * TOFU 确认：保存主机密钥（带类型）后整体重试强制推送
   */
  async confirmHostKey(): Promise<void> {
    const host: string = this.pendingHost;
    const port: number = this.pendingPort;
    const fp: string = this.pendingHostKeyFp;
    const keyType: string = this.pendingHostKeyType;
    this.pendingHostKeyFp = '';
    this.pendingHostKeyType = '';
    this.pendingHostKeyMismatch = false;
    if (fp.length === 0) {
      return;
    }
    const ok: boolean = await KnownHostsStore.getInstance().saveHostKey(host, port,
      { keyType: keyType, fingerprint: fp });
    if (!ok) {
      this.forcePushError = Strings.get('sync_save_hostkey_failed');
      return;
    }
    hilog.info(DOMAIN, TAG, 'host key trusted via repo manage: %{public}s:%{public}d (%{public}s)',
      host, port, keyType);
    await this.runForcePush();
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
   * 删除本地仓库
   *
   * 删除本地仓库目录（含 .git 与全部密码文件），并重置仓库初始化状态，
   * 使应用回到「未初始化」状态，需要重新初始化或克隆。
   */
  async deleteRepo(): Promise<void> {
    this.isBusy = true;
    this.resultMessage = '';

    const storePath: string = this.settings.getStorePath();
    if (storePath.length === 0) {
      this.finish(false, Strings.get('repo_err_no_path'));
      return;
    }

    try {
      const deleted: boolean = FileUtils.deleteDir(storePath);
      if (!deleted) {
        this.finish(false, Strings.get('repo_err_delete_failed_dir'));
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
      this.statusSummary = Strings.get('repo_status_not_cloned');
      hilog.info(DOMAIN, TAG, 'local repo deleted: %{public}s', storePath);
      // 结果放在所有 await 之后：见 runForcePush 里同样的处理（保证 nonce 变化
      // 一定被 @Monitor 观察到，不会第二次操作时不弹气泡）
      this.finish(true, Strings.get('repo_deleted'));
      // 广播仓库已删除：首页是 Navigation 根内容（常驻不销毁），只靠 RepoChangeNotifier
      // 感知仓库变更——漏掉 bump 会让我返回首页后列表仍是删除前的旧数据（同
      // GitConfigViewModel.cloneNow 的收尾口径）。首页 onRepoChanged 会顺带清掉
      // 内容匹配的明文缓存并把列表复位到未初始化空状态
      RepoChangeNotifier.connect().bump();
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      hilog.error(DOMAIN, TAG, 'deleteRepo failed: %{public}s', msg);
      this.finish(false, Strings.fmt('repo_err_delete_failed', msg));
    }
  }

  /**
   * 结束操作并写入结果
   *
   * `resultNonce` 每次自增：页面监听它弹出成功气泡（见该字段注释）。
   */
  private finish(success: boolean, message: string): void {
    this.isBusy = false;
    this.lastSuccess = success;
    this.resultMessage = message;
    this.resultNonce++;
  }
}
