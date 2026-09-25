import { GitConfig, createDefaultGitConfig } from '../model/GitConfig';
import { SettingsRepository } from '../model/SettingsRepository';
import { GitAuthMode, SshKeyType } from '../common/Constants';
import { GitClient, GitResult, SshUrlTarget } from '../utils/GitClient';
import { RepoChangeNotifier } from '../common/RepoChangeNotifier';
import { NativeBridge, NativeResult } from '../common/NativeBridge';
import { SshClient, SshConnectParams } from '../utils/SshClient';
import { SshKeyManager, SshKeyInfo } from '../crypto/SshKeyManager';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** hilog 域 */
const DOMAIN: number = 0x0001;
/** hilog 标签 */
const TAG: string = 'GitConfigVM';

/**
 * Git 配置视图模型
 *
 * 管理远程仓库地址、认证方式、committer 身份的编辑与保存。
 */
@ObservedV2
export class GitConfigViewModel {
  /** 远程仓库 URL */
  @Trace remoteUrl: string = '';
  /** 认证方式 */
  @Trace authMode: GitAuthMode = GitAuthMode.HTTPS_PASSWORD;
  /** HTTPS 用户名 */
  @Trace username: string = '';
  /** HTTPS 密码或 Token */
  @Trace password: string = '';
  /** SSH 密钥类型 */
  @Trace sshKeyType: SshKeyType = SshKeyType.ED25519;
  /** SSH 密钥别名 */
  @Trace sshKeyAlias: string = '';
  /** SSH 私钥口令（仅私钥本身带口令时需要；经 HUKS 封装后落盘） */
  @Trace sshKeyPassphrase: string = '';
  /** SSH 端口 */
  @Trace sshPort: number = 22;
  /** committer 用户名 */
  @Trace committerName: string = '';
  /** committer 邮箱 */
  @Trace committerEmail: string = '';
  /** HTTP(S) 代理 URL（空为不使用） */
  @Trace proxyUrl: string = '';
  /** 启动时自动同步 */
  @Trace autoSyncOnLaunch: boolean = false;
  /** 是否正在保存 */
  @Trace isSaving: boolean = false;
  /** 保存是否成功 */
  @Trace isSaved: boolean = false;
  /** 正在测试连接 */
  @Trace isTesting: boolean = false;
  /** 连接测试结果提示 */
  @Trace testResult: string = '';
  /** 错误信息 */
  @Trace errorMessage: string = '';
  /** SSH 密钥管理页面已创建的密钥列表 */
  @Trace sshKeyList: SshKeyInfo[] = [];
  /** TOFU：待确认的主机密钥指纹（空表示无待确认项；页面据此弹确认弹窗） */
  @Trace pendingHostKeyFp: string = '';
  /** TOFU 待确认连接的主机:端口 */
  @Trace pendingHost: string = '';
  /** TOFU 待确认连接的端口 */
  @Trace pendingPort: number = 22;
  /** 是否正在克隆（保存后的「立即克隆」流程） */
  @Trace isCloning: boolean = false;
  /** 克隆进度/结果提示 */
  @Trace cloneMessage: string = '';
  /** 克隆是否失败（用于提示配色） */
  @Trace cloneFailed: boolean = false;
  /** TOFU 确认后是否继续克隆（true）还是重试连接测试（false） */
  private confirmThenClone: boolean = false;
  /** 主机密钥类型（提示文案用） */
  @Trace pendingHostKeyType: string = '';
  /** 主机密钥与已有记录不一致（可能中间人） */
  @Trace pendingHostKeyMismatch: boolean = false;

  private settings: SettingsRepository = SettingsRepository.getInstance();

  /**
   * 从持久化配置加载
   */
  async load(): Promise<void> {
    const config: GitConfig = await this.settings.loadGitConfig();
    this.remoteUrl = config.remoteUrl;
    this.authMode = config.authMode;
    this.username = config.username;
    this.password = config.password;
    this.sshKeyType = config.sshKeyType;
    this.sshKeyAlias = config.sshKeyAlias;
    this.sshKeyPassphrase = config.sshKeyPassphrase;
    this.sshPort = config.sshPort;
    this.committerName = config.committerName;
    this.committerEmail = config.committerEmail;
    this.proxyUrl = config.proxyUrl;
    this.autoSyncOnLaunch = config.autoSyncOnLaunch;
    this.isSaved = false;
    this.errorMessage = '';
    this.refreshSshKeyList();
    // 已保存的 alias 可能指向一把已被删除的密钥：留着它只会在真正克隆时才爆出
    // 「无法导出 SSH 私钥」，用户看着配置页面还以为是配好的。这里当场清掉并说明原因。
    if (this.sshKeyAlias.length > 0
      && this.sshKeyList.find((k: SshKeyInfo): boolean => k.alias === this.sshKeyAlias) === undefined) {
      hilog.warn(DOMAIN, TAG, 'load: saved sshKeyAlias %{public}s no longer exists, cleared',
        this.sshKeyAlias);
      this.sshKeyAlias = '';
      this.errorMessage = '原先选择的 SSH 密钥已被删除，请重新选择';
    }
  }

  /**
   * 刷新 SSH 密钥列表（从 SshKeyManager 读取已创建的密钥）
   */
  refreshSshKeyList(): void {
    this.sshKeyList = SshKeyManager.getInstance().listKeys();
  }

  /**
   * 选择 SSH 密钥（从下拉菜单）
   */
  selectSshKey(alias: string): void {
    const key: SshKeyInfo | undefined = this.sshKeyList.find((k: SshKeyInfo) => k.alias === alias);
    if (key !== undefined) {
      this.sshKeyAlias = key.alias;
      this.sshKeyType = key.keyType;
    }
  }

  /**
   * 切换认证方式，并联动把远程地址换成对应写法
   *
   * HTTPS 与 SSH 用的是两种地址形式（`https://host/user/repo.git` / `git@host:user/repo.git`），
   * 只切开关不改地址的话，用户会拿着 https 地址去走 SSH（或反之），认证必然失败，
   * 而报错与真实原因无关。转换不可靠时（地址为空、已是目标形式、缺路径）保持原样，
   * 不猜也不破坏用户填的内容。
   */
  setAuthMode(mode: GitAuthMode): void {
    if (mode === this.authMode) {
      return;
    }
    this.authMode = mode;
    const converted: string = mode === GitAuthMode.SSH_KEY
      ? toSshRemoteUrl(this.remoteUrl)
      : toHttpsRemoteUrl(this.remoteUrl);
    if (converted.length > 0) {
      this.remoteUrl = converted;
    }
  }

  /**
   * 切换 SSH 密钥类型
   */
  setSshKeyType(type: SshKeyType): void {
    this.sshKeyType = type;
  }

  /**
   * 是否为 HTTPS 认证
   */
  isHttpsAuth(): boolean {
    return this.authMode !== GitAuthMode.SSH_KEY;
  }

  /**
   * 克隆进度（0-100；-1 = 不确定态）
   *
   * 由 native 的 `gitCloneProgress`（原子变量）轮询得来。
   * **注意进度只覆盖「接收对象」阶段**：收完包后 libgit2 还要解 delta 与检出文件，
   * 这段没有回调，所以 UI 需要在进度到 100% 后仍显示「正在检出…」直到克隆返回。
   */
  @Trace clonePercent: number = -1;

  /** 起停进度轮询（句柄非 @Trace，不参与 UI 刷新） */
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
   * 保存后立即克隆远程仓库
   *
   * @returns 是否成功（失败时 cloneMessage 里是可操作的原因）
   */
  async cloneNow(): Promise<boolean> {
    if (this.isCloning) {
      return false;
    }
    this.isCloning = true;
    this.cloneFailed = false;
    this.cloneMessage = '正在克隆远程仓库...';
    // 进度轮询：进度回调跑在 TaskPool 工作线程（native 侧写原子变量），
    // UI 只能定时去读。读的是纯内存，不涉及网络/IO。
    this.clonePercent = 0;
    this.startCloneProgressPoll();
    const result: GitResult = await GitClient.getInstance().clone(this.remoteUrl.trim());
    this.stopCloneProgressPoll();
    this.isCloning = false;
    if (result.success) {
      this.cloneMessage = '克隆完成';
      // 克隆下来的条目要立刻出现在列表里（根页面在导航栈里一直活着）
      RepoChangeNotifier.connect().bump();
      return true;
    }
    // 主机密钥未被信任/不一致：弹出确认卡，确认后保存指纹并继续克隆。
    // 指纹取自本次克隆连接（见 GitResult.pendingHostKeyFp 的注释）。
    const fp: string = result.pendingHostKeyFp ?? '';
    if (fp.length > 0) {
      const target: SshUrlTarget | null = SshUrlTarget.parse(this.remoteUrl.trim());
      this.pendingHost = target !== null ? target.host : '';
      this.pendingPort = target !== null ? target.port : 22;
      this.pendingHostKeyFp = fp;
      this.pendingHostKeyType = result.pendingHostKeyType ?? '';
      this.pendingHostKeyMismatch = result.hostKeyMismatch === true;
      this.confirmThenClone = true;
      this.cloneMessage = '';
      this.cloneFailed = false;
      return false;
    }
    this.cloneFailed = true;
    this.cloneMessage = result.error;
    return false;
  }

  /**
   * 先删除本地仓库再克隆
   *
   * 用于「本地已有仓库」的情形：git clone 要求目标目录为空或不存在，
   * 用户确认后删掉本地数据再克隆（配置里的远程地址保留，正是接下来要克隆的地址）。
   */
  async deleteLocalRepoThenClone(): Promise<boolean> {
    const removed: GitResult = await GitClient.getInstance().removeLocalRepo();
    if (!removed.success) {
      this.cloneFailed = true;
      this.cloneMessage = removed.error;
      return false;
    }
    return await this.cloneNow();
  }

  /**
   * 克隆前是否必须先清空本地目录
   *
   * 判据是「目录已有内容」而不是「已是 Git 仓库」：残留文件（.gpg-id、旧条目、
   * 上次失败克隆留下的文件）同样会让 git 拒绝克隆，而那时 isGitRepo() 为 false，
   * 原来的判断会直接去克隆、然后失败——用户只看到「正在克隆远程仓库」，
   * 首页也永远不会出现仓库。
   */
  needsCleanBeforeClone(): boolean {
    return GitClient.getInstance().hasLocalContent();
  }

  /**
   * 构建当前配置对象
   */
  private buildConfig(): GitConfig {
    const config: GitConfig = createDefaultGitConfig();
    config.remoteUrl = this.remoteUrl.trim();
    config.authMode = this.authMode;
    config.username = this.username.trim();
    config.password = this.password;
    config.sshKeyType = this.sshKeyType;
    config.sshKeyAlias = this.sshKeyAlias;
    config.sshKeyPassphrase = this.sshKeyPassphrase;
    config.sshPort = this.sshPort;
    config.committerName = this.committerName.trim();
    config.committerEmail = this.committerEmail.trim();
    config.proxyUrl = this.proxyUrl.trim();
    config.autoSyncOnLaunch = this.autoSyncOnLaunch;
    return config;
  }

  /**
   * 验证输入
   */
  private validate(): string {
    if (this.remoteUrl.trim().length === 0) {
      return '请输入远程仓库地址';
    }
    const url: string = this.remoteUrl.trim();
    const isSsh: boolean = url.startsWith('ssh://') || /^\S+@\S+:/.test(url);
    if (!url.startsWith('https://') && !url.startsWith('http://') && !isSsh) {
      return '地址必须以 https:// 或 ssh:// 开头（或 git@host:path 格式）';
    }
    return '';
  }

  /**
   * 保存配置
   *
   * 保存前必须真实测试远程连接：连接失败则不写入配置，
   * 避免把错误地址/凭据落盘后同步才报错。
   */
  async save(): Promise<void> {
    const err: string = this.validate();
    if (err.length > 0) {
      this.errorMessage = err;
      return;
    }

    // 地址按当前认证方式规范化：HTTPS 模式存 https 地址、SSH 模式存 SSH 地址。
    // 否则用户切了认证方式却没动地址时，会存下一份「认证方式与地址不匹配」的配置，
    // 之后的克隆/同步必然认证失败且报错与真实原因无关。
    const normalized: string = this.authMode === GitAuthMode.SSH_KEY
      ? toSshRemoteUrl(this.remoteUrl)
      : toHttpsRemoteUrl(this.remoteUrl);
    if (normalized.length > 0) {
      this.remoteUrl = normalized;
    }

    this.isSaving = true;
    this.errorMessage = '';
    this.testResult = '';

    // 先测连接：失败直接返回，不保存
    const ok: boolean = await this.testRemote();
    if (!ok) {
      this.isSaving = false;
      return;
    }

    try {
      await this.settings.saveGitConfig(this.buildConfig());
      this.isSaved = true;
      hilog.info(DOMAIN, TAG, 'Git config saved');
    } catch (e) {
      this.errorMessage = '保存失败';
      hilog.error(DOMAIN, TAG, 'save failed: %{public}s', JSON.stringify(e));
    }
    this.isSaving = false;
  }

  /**
   * 真实测试远程连接（HTTPS 走 native libgit2 connect + ls-remote）
   * @returns 连接是否成功；失败时 testResult 已写入原因
   */
  private async testRemote(): Promise<boolean> {
    const url: string = this.remoteUrl.trim();

    // SSH 地址：走 SSH 连通性测试（含 TOFU 首连确认）
    if (this.authMode === GitAuthMode.SSH_KEY) {
      const params: SshConnectParams | null = SshClient.parseSshUrl(url);
      if (params === null) {
        this.testResult = '无法从地址解析 SSH 主机信息';
        return false;
      }
      // 地址自带端口时以地址为准：表单里的「SSH 端口」只是地址没写端口时的补充，
      // 无条件覆盖会让测试连接去连错误的端口（实测地址带 :2224 时仍探 22，
      // 只报「获取主机密钥失败」，与真实原因无关）
      if (!SshUrlTarget.hasExplicitPort(url)) {
        params.port = this.sshPort;
      }
      params.keyAlias = this.sshKeyAlias;
      // 私钥带口令时必须一起传，否则测试连接会用不了这把钥匙
      params.passphrase = this.sshKeyPassphrase;
      const result = await SshClient.getInstance().testConnection(params);
      if (result.hostKeyState === 'unknown' && result.hostKeyFingerprint !== undefined) {
        // TOFU 首连 / 新类型主机密钥：弹指纹确认，本次不保存（用户确认后重试）
        this.pendingHost = params.host;
        this.pendingPort = params.port;
        this.pendingHostKeyFp = result.hostKeyFingerprint;
        this.pendingHostKeyType = result.hostKeyType ?? '';
        this.pendingHostKeyMismatch = result.hostKeyMismatch === true;
        this.testResult = '首次连接需先确认服务器指纹，请确认后重新保存';
        return false;
      }
      if (result.hostKeyState === 'mismatch') {
        this.testResult = result.error;
        return false;
      }
      if (result.success) {
        // SSH 认证成功 ≠ 仓库存在：sshd 只看密钥、不看路径，仓库名写错时认证照样通过。
        // 这里再用 libgit2 对同一地址做一次 ls-remote，把「仓库不存在」在测试连接时就暴露出来。
        const ls: GitResult = await GitClient.getInstance().testSshRemote(url);
        if (ls.success) {
          this.testResult = '连接成功';
          return true;
        }
        this.testResult = ls.error;
        return false;
      }
      this.testResult = result.error;
      return false;
    }

    // HTTPS：native libgit2 真实 connect + ls-remote。
    // **必须走 TaskPool**：DNS 不可达时该调用会阻塞数秒，直接在主线程调用
    // 正是触发系统 watchdog（APP_INPUT_BLOCK）杀进程的场景（AGENTS「网络类
    // native 调用绝不能跑在 JS 主线程」）。
    const result: NativeResult =
      await GitClient.getInstance().testHttpsRemote(url, this.username.trim(), this.password, this.proxyUrl.trim());
    if (result.success) {
      this.testResult = '连接成功';
      return true;
    }
    hilog.warn(DOMAIN, TAG, 'gitTestRemote raw error: %{public}s', result.error);
    this.testResult = this.friendlyHttpsError(result.error);
    return false;
  }

  /**
   * 把 native 原始错误翻译成可操作的中文提示
   */
  private friendlyHttpsError(raw: string): string {
    if (raw.includes('401') || raw.includes('authentication') || raw.includes('credential')
      || raw.includes('too many redirects')) {
      return '认证失败：请检查用户名与密码/Token（Gitee/GitHub 需使用访问令牌而非登录密码）';
    }
    if (raw.includes('failed to resolve address') || raw.includes('Could not resolve host')
      || raw.includes('resolve')) {
      return '无法解析主机地址：请检查网络与远程地址是否正确';
    }
    if (raw.includes('not found') || raw.includes('repository not found')) {
      return '仓库不存在或无权访问：请确认远程地址与访问权限';
    }
    if (raw.includes('unsupported URL protocol') || raw.includes('unsupported protocol')) {
      return '不支持的协议：HTTPS 测试需要 native TLS 支持';
    }
    return `连接失败：${raw}`;
  }

  /**
   * 测试连接（供「测试连接」按钮使用，逻辑与保存前校验一致）
   */
  async testConnection(): Promise<void> {
    const err: string = this.validate();
    if (err.length > 0) {
      this.testResult = err;
      return;
    }

    this.isTesting = true;
    this.testResult = '';
    await this.testRemote();
    this.isTesting = false;
  }

  /**
   * TOFU 确认：用户接受主机密钥指纹后保存并重试连接
   */
  async confirmHostKey(): Promise<void> {
    if (this.pendingHostKeyFp.length === 0) {
      return;
    }
    const fp: string = this.pendingHostKeyFp;
    const keyType: string = this.pendingHostKeyType;
    this.pendingHostKeyFp = '';
    const saved: boolean = await SshClient.getInstance().confirmHostKey(
      this.pendingHost, this.pendingPort, fp, keyType);
    if (!saved) {
      this.testResult = '保存主机密钥失败';
      return;
    }
    // 信任已建立：若本次确认是为克隆而来，继续克隆；否则重试连接测试
    if (this.confirmThenClone) {
      this.confirmThenClone = false;
      this.pendingHostKeyType = '';
      this.pendingHostKeyMismatch = false;
      await this.cloneNow();
      return;
    }
    await this.testConnection();
  }

  /**
   * TOFU 拒绝：用户不接受指纹
   */
  rejectHostKey(): void {
    this.pendingHostKeyFp = '';
    this.pendingHostKeyType = '';
    this.pendingHostKeyMismatch = false;
    if (this.confirmThenClone) {
      this.confirmThenClone = false;
      this.cloneFailed = true;
      this.cloneMessage = '已取消克隆（主机密钥未确认）';
      return;
    }
    this.testResult = '已取消连接（主机密钥未确认）';
  }

  /**
   * SSH 密钥显示名：邮箱 / 标识；未设置时回退别名（私钥文件名）
   *
   * 与 SshKeyManagerViewModel.displayName 逻辑一致：优先 email、回退公钥 comment、
   * 最后回退 alias（文件名）。Git 配置页的密钥选择列表与表单当前值都用它。
   */
  sshKeyDisplayName(key: SshKeyInfo): string {
    if (key.email.length > 0) return key.email;
    const parts: string[] = key.publicKey.trim().split(/\s+/);
    if (parts.length >= 3 && parts[2].length > 0) return parts[2];
    return key.alias;
  }

  /**
   * 当前选中 SSH 密钥的显示名（空表示未选择）
   */
  selectedSshKeyDisplayName(): string {
    if (this.sshKeyAlias.length === 0) return '';
    const key: SshKeyInfo | undefined = this.sshKeyList.find((k: SshKeyInfo) => k.alias === this.sshKeyAlias);
    if (key === undefined) return this.sshKeyAlias;
    return this.sshKeyDisplayName(key);
  }

  /**
   * 是否可以保存
   */
  canSave(): boolean {
    return this.remoteUrl.trim().length > 0 && !this.isSaving;
  }
}

/**
 * HTTPS 地址 → SSH 写法
 *
 * `https://host[:port]/user/repo.git` → 默认端口写 `git@host:user/repo.git`，
 * 非默认端口写 `ssh://git@host:port/user/repo.git`（scp 风格表达不了端口）。
 * SSH 用户名取约定值 `git`（gitee/GitHub 等托管平台一律用它），用户可自行改。
 * 不满足转换条件时返回空串，调用方保持原地址不变。
 */
function toSshRemoteUrl(url: string): string {
  const trimmed: string = url.trim();
  const lower: string = trimmed.toLowerCase();
  if (!lower.startsWith('https://') && !lower.startsWith('http://')) {
    return '';
  }
  const afterScheme: string = trimmed.substring(trimmed.indexOf('://') + 3);
  const slash: number = afterScheme.indexOf('/');
  if (slash <= 0) {
    return ''; // 没有路径，构造不出可用的仓库地址
  }
  let authority: string = afterScheme.substring(0, slash);
  const path: string = afterScheme.substring(slash + 1);
  if (path.length === 0) {
    return '';
  }
  const at: number = authority.lastIndexOf('@');
  if (at >= 0) {
    authority = authority.substring(at + 1); // 丢掉 HTTPS 的用户名信息
  }
  const colon: number = authority.lastIndexOf(':');
  if (colon > 0) {
    const host: string = authority.substring(0, colon);
    const port: string = authority.substring(colon + 1);
    if (port.length > 0 && port !== '22') {
      return `ssh://git@${host}:${port}/${path}`;
    }
    return `git@${host}:${path}`;
  }
  return `git@${authority}:${path}`;
}

/**
 * SSH 地址 → HTTPS 写法
 *
 * 支持 `ssh://[user@]host[:port]/path` 与 scp 风格 `[user@]host:path`；
 * 非默认端口保留在 https 地址里。无法识别时返回空串。
 */
function toHttpsRemoteUrl(url: string): string {
  const trimmed: string = url.trim();
  if (trimmed.length === 0) {
    return '';
  }
  const lower: string = trimmed.toLowerCase();
  if (lower.startsWith('https://') || lower.startsWith('http://')) {
    return ''; // 已是 HTTPS 形式
  }
  if (lower.startsWith('ssh://')) {
    const rest: string = trimmed.substring(6);
    const slash: number = rest.indexOf('/');
    if (slash <= 0) {
      return '';
    }
    const authority: string = rest.substring(0, slash);
    const path: string = rest.substring(slash + 1);
    if (path.length === 0) {
      return '';
    }
    const at: number = authority.lastIndexOf('@');
    const hostPort: string = at >= 0 ? authority.substring(at + 1) : authority;
    return `https://${hostPort}/${path}`;
  }
  // scp 风格：user@host:path
  const at: number = trimmed.lastIndexOf('@');
  const colon: number = trimmed.indexOf(':');
  if (at <= 0 || colon <= at) {
    return '';
  }
  const host: string = trimmed.substring(at + 1, colon);
  const path: string = trimmed.substring(colon + 1);
  if (host.length === 0 || path.length === 0) {
    return '';
  }
  return `https://${host}/${path}`;
}
