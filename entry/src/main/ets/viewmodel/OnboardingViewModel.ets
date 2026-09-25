import { PasswordRepository } from '../model/PasswordRepository';
import { SettingsRepository } from '../model/SettingsRepository';
import { GitClient, GitResult } from '../utils/GitClient';
import { PgpKeyManager } from '../crypto/PgpKeyManager';
import { KnownHostsStore } from '../utils/KnownHostsStore';
import { SshKeyManager } from '../crypto/SshKeyManager';
import { GitAuthMode, SshKeyType } from '../common/Constants';
import { SshUrlTarget } from '../utils/GitClient';
import { RouteManager } from '../common/RouteManager';
import { NativeBridge } from '../common/NativeBridge';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** hilog 域 */
const DOMAIN: number = 0x0001;
/** hilog 标签 */
const TAG: string = 'OnboardingVM';

/** 引导步骤索引 */
export const STEP_WELCOME: number = 0;
export const STEP_REPO_SETUP: number = 1;
export const STEP_KEY_IMPORT: number = 2;
export const STEP_FINISH: number = 3;

/**
 * `setupRepository()` 的结果
 *
 * 引导页没有「保存」按钮，页面必须自己决定要不要弹「删除并克隆」确认框，
 * 因此这里把「目录非空」作为**正常结果**返回，而不是写成 errorMessage——
 * 曾把它当错误文案直接显示（「请在保存后的提示中选择删除并克隆」），
 * 而引导流程里根本没有那个提示，用户点了「初始化仓库」只会看到一句
 * 无法执行的话，然后彻底卡在第二步。
 */
export enum RepoSetupOutcome {
  /** 已处理完：成功则已推进到下一步，失败则原因在 errorMessage 里 */
  DONE = 0,
  /** 本地目录已有内容：需用户确认「删除并克隆」后才能继续 */
  NEEDS_CLEAN = 1,
}

/**
 * 引导页视图模型
 *
 * 引导用户完成：
 * 1. 欢迎/说明
 * 2. 仓库初始化（新建 或 克隆远程）
 * 3. PGP 密钥导入
 * 4. 完成
 */
@ObservedV2
export class OnboardingViewModel {
  /** 当前步骤 */
  @Trace currentStep: number = STEP_WELCOME;
  /** 仓库初始化方式：'new' | 'clone' */
  @Trace repoMode: string = 'new';
  /** 克隆远程地址 */
  @Trace remoteUrl: string = '';
  /** PGP 私钥 ASCII-armored 文本（由所选 .asc 文件读入） */
  /** 已选择的密钥文件名 */
  /**
   * 已导入的 PGP 密钥名称（空表示尚未导入）
   *
   * 「浏览」现在跳到 PGP 密钥管理页，用户在那里新建/导入后返回本页——
   * 本页一直活着、不会重跑 aboutToAppear，必须由 onShown 主动重读密钥列表。
   */
  @Trace importedKeyLabel: string = '';
  /**
   * 已配置的 SSH 密钥名（空 = 未配置）
   *
   * 克隆步骤卡片据此显示「未配置SSH密钥」或密钥名。从 SSH 密钥管理页返回时
   * 由页面 onShown 调 refreshSshKey() 重读——本页一直活着，不会重跑 aboutToAppear。
   */
  @Trace sshKeyLabel: string = '';
  /** 密钥导入结果提示（成功为绿色、失败走 errorMessage） */
  /** 密钥密码弹窗是否可见（密钥有密码保护时弹出） */
  /** 用户在弹窗中输入的密钥密码 */
  /** 密钥是否已选择（控制导入按钮显隐） */
  /** 是否正在执行操作 */
  @Trace isWorking: boolean = false;
  /**
   * 是否正在克隆远程仓库
   *
   * 与 `isWorking` 分开：克隆要走网络（慢、可能几十秒），期间必须显示全模态进度
   * 并禁止返回；而「新建本地仓库」是本机操作、瞬时完成，不需要挡住整页。
   */
  @Trace isCloning: boolean = false;
  /**
   * 克隆进度（0-100；-1 = 不确定态）
   *
   * 轮询 native 的 `gitCloneProgress`（原子变量）。进度只覆盖「接收对象」阶段，
   * 收完包后还有解 delta + 检出文件（无回调），故 UI 需另给兜底文案。
   */
  @Trace clonePercent: number = -1;
  /** 操作进度提示 */
  @Trace progressText: string = '';
  /** 错误信息 */
  @Trace errorMessage: string = '';
  /** 仓库初始化是否成功 */
  @Trace isRepoReady: boolean = false;
  /** 密钥导入是否成功 */
  @Trace isKeyReady: boolean = false;
  /** TOFU：待用户确认的主机密钥指纹（空表示无待确认项） */
  @Trace pendingHostKeyFp: string = '';
  /** TOFU：待确认连接的主机 */
  @Trace pendingHost: string = '';
  /** TOFU：待确认连接的端口 */
  @Trace pendingPort: number = 22;
  /** TOFU：实际收到的主机密钥类型（RSA/ECDSA/Ed25519） */
  @Trace pendingHostKeyType: string = '';
  /** TOFU：该主机已有记录但指纹不一致（可能中间人，文案要更严厉） */
  @Trace pendingHostKeyMismatch: boolean = false;

  private repo: PasswordRepository = PasswordRepository.getInstance();
  private settings: SettingsRepository = SettingsRepository.getInstance();
  private git: GitClient = GitClient.getInstance();
  private keyManager: PgpKeyManager = PgpKeyManager.getInstance();
  private sshKeys: SshKeyManager = SshKeyManager.getInstance();
  private knownHosts: KnownHostsStore = KnownHostsStore.getInstance();

  /**
   * 进入下一步
   */
  nextStep(): void {
    if (this.currentStep < STEP_FINISH) {
      this.currentStep++;
    }
  }

  /**
   * 返回上一步
   */
  prevStep(): void {
    if (this.currentStep > STEP_WELCOME) {
      this.currentStep--;
    }
    this.errorMessage = '';
  }

  /**
   * 设置仓库初始化方式
   */
  setRepoMode(mode: string): void {
    this.repoMode = mode;
  }

  /**
   * 执行仓库初始化（新建或克隆）
   *
   * 克隆前会先看本地目录是否已有内容（见 `RepoSetupOutcome`）：
   * git clone 要求目标目录为空，而引导页没有「保存」按钮、也没有第二个克隆入口，
   * 所以这里必须把「需要先清空」交回页面去弹确认框。
   */
  async setupRepository(): Promise<RepoSetupOutcome> {
    this.isWorking = true;
    this.errorMessage = '';

    if (this.repoMode === 'new') {
      this.progressText = '正在初始化本地仓库...';
      const result = this.repo.initStore();
      if (result.success) {
        const storePath: string = result.data ?? '';
        await this.settings.updateSetting('storePath', storePath);
        await this.settings.updateSetting('storeInitialized', true);
        // 创建 git 仓库骨架（.git 目录）。否则仓库目录已存在但缺 .git，
        // 引导标志丢失后无法凭「已有 git 仓库」判据跳过初始设置界面
        await this.git.initRepo();
        this.isRepoReady = true;
        this.progressText = '';
        this.nextStep();
      } else {
        this.errorMessage = result.error;
      }
      this.isWorking = false;
      return RepoSetupOutcome.DONE;
    }

    // ===== 克隆远程仓库 =====
    const url: string = this.remoteUrl.trim();
    if (url.length === 0) {
      this.errorMessage = '请输入远程仓库地址';
      this.isWorking = false;
      this.progressText = '';
      return RepoSetupOutcome.DONE;
    }
    // 初始设置只支持 SSH 克隆：HTTPS 需要用户名/令牌，而本流程没有采集这两项的入口
    // （配置页才有），用户填了 https 地址只会在克隆时撞上「请配置用户名密码」。
    if (!url.startsWith('git@') && !url.startsWith('ssh://')) {
      this.errorMessage = '初始设置只支持 SSH 克隆，请填 git@host:用户名/仓库.git 或 ssh://git@host[:端口]/路径'
        + '（HTTPS 仓库请先完成初始设置，再到「仓库管理 → Git 配置」中配置用户名与令牌）';
      this.isWorking = false;
      this.progressText = '';
      return RepoSetupOutcome.DONE;
    }
    // 保存远程地址并落成 SSH 认证方式（与上面的限制保持一致）
    const config = await this.settings.loadGitConfig();
    config.remoteUrl = url;
    config.authMode = GitAuthMode.SSH_KEY;
    await this.settings.saveGitConfig(config);

    // 判据是「目录已有内容」而不是「已是 Git 仓库」：残留文件（.gpg-id、旧条目、
    // 上次失败克隆留下的文件）同样会让 git 拒绝克隆，而那时 isGitRepo() 为 false。
    if (this.git.hasLocalContent()) {
      this.isWorking = false;
      this.progressText = '';
      return RepoSetupOutcome.NEEDS_CLEAN;
    }

    await this.cloneIntoStore(url);
    return RepoSetupOutcome.DONE;
  }

  /**
   * 删除本地仓库内容后重新克隆（引导页「本地目录已有内容」确认框的确认分支）
   */
  async deleteLocalRepoThenClone(): Promise<RepoSetupOutcome> {
    this.isWorking = true;
    this.errorMessage = '';
    // 用 removeLocalRepo 而不是 deleteRepo：后者会连配置里的 remoteUrl 一起清掉，
    // 而那个地址正是接下来要克隆的目标
    const removed: GitResult = await this.git.removeLocalRepo();
    if (!removed.success) {
      this.errorMessage = removed.error;
      this.isWorking = false;
      return RepoSetupOutcome.DONE;
    }
    await this.cloneIntoStore(this.remoteUrl.trim());
    return RepoSetupOutcome.DONE;
  }

  /** 进度轮询句柄（非 @Trace，不参与 UI 刷新） */
  private clonePollTimer: number = -1;

  private startCloneProgressPoll(): void {
    this.stopCloneProgressPoll();
    this.clonePollTimer = setInterval((): void => {
      this.clonePercent = NativeBridge.getInstance().gitCloneProgress();
    }, 200);
  }

  private stopCloneProgressPoll(): void {
    if (this.clonePollTimer >= 0) {
      clearInterval(this.clonePollTimer);
      this.clonePollTimer = -1;
    }
    this.clonePercent = -1;
  }

  /**
   * 实际执行克隆（含 TOFU 主机密钥处理）
   *
   * `isCloning` 覆盖整个网络过程：页面据此显示全模态进度并禁止返回/操作。
   */
  private async cloneIntoStore(url: string): Promise<void> {
    this.progressText = '正在克隆远程仓库...';
    this.isCloning = true;
    this.clonePercent = 0;
    this.startCloneProgressPoll();
    try {
      // TOFU：主机密钥必须确认后才能克隆。**指纹取自本次克隆连接本身**——
      // 服务器通常同时提供 rsa/ecdsa/ed25519 多把主机密钥，而 russh（探测）偏好
      // ed25519、libgit2 用的 libssh2 偏好 rsa，另开一次连接探测得到的指纹与克隆
      // 实际用到的不是同一把（真机 gitee 实测正是如此），确认了也匹配不上。
      const cloneResult: GitResult = await this.git.clone(url);
      if (cloneResult.success) {
        this.isRepoReady = true;
        this.nextStep();
        return;
      }
      const fp: string = cloneResult.pendingHostKeyFp ?? '';
      if (fp.length > 0) {
        const target: SshUrlTarget | null = SshUrlTarget.parse(url);
        this.pendingHost = target !== null ? target.host : '';
        this.pendingPort = target !== null ? target.port : 22;
        this.pendingHostKeyFp = fp;
        this.pendingHostKeyType = cloneResult.pendingHostKeyType ?? '';
        this.pendingHostKeyMismatch = cloneResult.hostKeyMismatch === true;
        this.errorMessage = '';
        return;
      }
      this.errorMessage = cloneResult.error;
    } finally {
      // 无论成功/失败/主机密钥待确认都要复位，否则进度层会永久挡住页面
      this.stopCloneProgressPoll();
      this.isCloning = false;
      this.isWorking = false;
      this.progressText = '';
    }
  }

  /**
   * 是否已配置 PGP 密钥
   *
   * 供底部按钮决定显示「下一步」还是「跳过」——文案与点击行为必须用同一个判断，
   * 否则会出现「显示下一步、点了却按跳过处理（顺带把 isKeyReady 清掉）」的不一致。
   */
  isKeyConfigured(): boolean {
    return this.importedKeyLabel.length > 0;
  }

  /**
   * 用户确认主机指纹（TOFU）后保存并继续克隆
   */
  async confirmHostKeyAndClone(): Promise<RepoSetupOutcome> {
    const host: string = this.pendingHost;
    const port: number = this.pendingPort;
    const fp: string = this.pendingHostKeyFp;
    const keyType: string = this.pendingHostKeyType;
    this.pendingHostKeyFp = '';
    this.pendingHost = '';
    this.pendingPort = 22;
    this.pendingHostKeyType = '';
    this.pendingHostKeyMismatch = false;

    // 带类型保存：同类型指纹变化才是「密钥变了」（mismatch），新类型只是
    // 服务器多把主机密钥里没钉过的一把（追加即可，不算攻击）
    const ok: boolean = await this.knownHosts.saveHostKey(host, port,
      { keyType: keyType, fingerprint: fp });
    if (!ok) {
      this.errorMessage = '保存主机指纹失败，请重试';
      return RepoSetupOutcome.DONE;
    }
    hilog.info(DOMAIN, TAG, 'host key trusted: %{public}s:%{public}d (%{public}s)', host, port, keyType);
    return await this.setupRepository();
  }

  /** 放弃本次主机指纹确认 */
  cancelHostKeyConfirm(): void {
    this.pendingHostKeyFp = '';
    this.pendingHost = '';
    this.pendingPort = 22;
    this.pendingHostKeyType = '';
    this.pendingHostKeyMismatch = false;
  }

  /**
   * 刷新「已导入的 PGP 密钥」展示
   *
   * 用户从 PGP 密钥管理页返回时由页面 onShown 调用：本页在导航栈里一直活着，
   * 不主动重读就会一直显示「尚未设置」，用户以为刚才的导入没生效。
   */
  async refreshImportedKey(): Promise<void> {
    try {
      const keys = await this.keyManager.listKeys(true);
      if (keys.length === 0) {
        this.importedKeyLabel = '';
        return;
      }
      const first = keys[0];
      this.importedKeyLabel = first.name.length > 0 ? first.name : first.email;
      this.isKeyReady = true;
      hilog.info(DOMAIN, TAG, 'imported key detected: %{public}s', this.importedKeyLabel);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'refreshImportedKey failed: %{public}s',
        e instanceof Error ? e.message : String(e));
    }
  }

  /**
   * 刷新「已配置的 SSH 密钥」展示
   *
   * 用户从 SSH 密钥管理页返回时由页面 onShown 调用（同 refreshImportedKey 的道理）。
   * 应用内 SSH 密钥只保留一把（SshKeyManager.removeAllKeys），取第一把即全部。
   */
  async refreshSshKey(): Promise<void> {
    try {
      const keys = this.sshKeys.listKeys();
      if (keys.length === 0) {
        this.sshKeyLabel = '';
        return;
      }
      const first = keys[0];
      this.sshKeyLabel = first.email.length > 0 ? first.email : first.alias;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'refreshSshKey failed: %{public}s',
        e instanceof Error ? e.message : String(e));
    }
  }

  /**
   * 跳过密钥导入
   */
  skipKeyImport(): void {
    this.isKeyReady = false;
    this.nextStep();
  }

  /**
   * 完成引导
   */
  async finish(): Promise<void> {
    await this.settings.updateSetting('onboardingCompleted', true);
    hilog.info(DOMAIN, TAG, 'Onboarding completed');
    // 引导页关闭后回到列表页（pop 到根）
    RouteManager.getInstance().pop();
  }
}
