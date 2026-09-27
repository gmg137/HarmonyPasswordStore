import { GitConfig } from '../model/GitConfig';
import { SettingsRepository } from '../model/SettingsRepository';
import { FileUtils } from './FileUtils';
import { NativeBridge, NativeResult } from '../common/NativeBridge';
import { SshKeyManager, SshKeyInfo, SshKeyStatus } from '../crypto/SshKeyManager';
import { KnownHostsStore } from './KnownHostsStore';
import { invokeNativeGit, NativeGitRequest, NativeGitReply } from './NativeGitTask';
import { RepoChangeNotifier } from '../common/RepoChangeNotifier';
import { Strings } from '../common/Strings';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { taskpool } from '@kit.ArkTS';

/** hilog 域 */
const DOMAIN: number = 0x0001;
/** hilog 标签 */
const TAG: string = 'GitClient';

/**
 * Git 操作结果
 */
export interface GitResult {
  success: boolean;
  error: string;
  /**
   * 主机密钥未被信任时，本次连接**实际收到**的主机密钥指纹（"SHA256:Base64"）
   *
   * 由 native 端回调回传：服务器通常同时提供 rsa/ecdsa/ed25519 多把主机密钥，
   * 而不同 SSH 实现偏好不同（russh 偏好 ed25519、libgit2 用的 libssh2 偏好 rsa），
   * 所以「另开一次连接去探测指纹」得到的与克隆实际用到的不是同一把，
   * 确认过的指纹永远匹配不上。必须用本次连接回报的这一份。
   */
  pendingHostKeyFp?: string;
  /** 实际收到的主机密钥类型（RSA/ECDSA/Ed25519，仅用于提示文案） */
  pendingHostKeyType?: string;
  /** true 表示该主机已有记录但指纹不一致（可能中间人）；false 表示首次连接 */
  hostKeyMismatch?: boolean;
}

/**
 * SSH 认证材料解析结果（拉取/推送/克隆共用）
 *
 * 用 ok/error 而不是抛异常：三处前置条件（未选密钥、私钥解不开、主机指纹未信任）
 * 都要变成用户能照着做的提示，异常会被上层统一压成「操作失败」看不出原因。
 */
export interface SshAuthResolution {
  ok: boolean;
  error: string;
  /** 私钥 PEM（内存传递，不落盘） */
  pem: string;
  /** 私钥口令（私钥未加密时为空） */
  passphrase: string;
  /** 已信任的主机指纹（"SHA256:Base64"，不带 = 填充） */
  fingerprint: string;
}

/**
 * Git 提交记录
 */
export interface GitCommitInfo {
  /** 提交哈希 */
  hash: string;
  /** 提交摘要 */
  summary: string;
  /** 作者名 */
  authorName: string;
  /** 作者邮箱 */
  authorEmail: string;
  /** 提交时间（Unix 秒） */
  timestamp: number;
}

/**
 * Git 仓库状态
 */
export interface GitRepoStatus {
  /** 是否为 Git 仓库 */
  isRepo: boolean;
  /** 当前分支名 */
  branch: string;
  /** 未提交变更文件数 */
  changedCount: number;
  /** 待推送提交数 */
  aheadCount: number;
  /** 待拉取提交数 */
  behindCount: number;
  /** 是否有合并冲突 */
  hasConflicts: boolean;
}

/**
 * Git 客户端
 *
 * 封装 Git 仓库操作（clone / pull / push / commit / log）。
 * 底层通过 NAPI 桥接 libgit2 native 库实现；
 * native 桥接就绪前，所有操作返回明确的不可用错误。
 *
 * TODO Phase 3 native 部分：
 *   - C++ 侧封装 libgit2（git_clone / git_pull / git_push / git_commit）
 *   - SSH 认证经由 libssh2 回调注入密钥
 */
export class GitClient {
  private static instance: GitClient | null = null;

  private constructor() {
  }

  static getInstance(): GitClient {
    if (!GitClient.instance) {
      GitClient.instance = new GitClient();
    }
    return GitClient.instance;
  }

  /**
   * 把 native/libgit2 的认证错误翻译成可操作的中文提示
   *
   * 注意 libgit2 在「未配置凭据」与「凭据被拒」时都可能报
   * "remote authentication required but no callback set"，需一并覆盖。
   * @returns 命中认证类错误时返回提示文案；否则返回空串
   */
  static translateAuthError(raw: string): string {
    if (raw.includes('no callback set') || raw.includes('authentication required')
      || raw.includes('too many redirects') || raw.includes('401')
      || raw.includes('authentication') || raw.includes('credential')) {
      return Strings.get('git_auth_required_hint');
    }
    return '';
  }

  /**
   * 获取仓库本地路径
   */
  getRepoPath(): string {
    const storePath: string = SettingsRepository.getInstance().getSettings().storePath;
    return storePath.length > 0 ? storePath : FileUtils.getFilesDir();
  }

  /**
   * 检查目录是否已是 Git 仓库
   */
  isGitRepo(): boolean {
    return FileUtils.exists(`${this.getRepoPath()}/.git`);
  }

  /**
   * 仓库目录是否已有内容
   *
   * 与 `isGitRepo()` 不同：**没有 `.git` 但目录非空**（残留的 .gpg-id、旧条目、
   * 上次失败克隆留下的文件）同样无法克隆——git 要求目标目录为空或不存在。
   * 克隆前必须按这个判据决定是否要先清空，否则用户会看到「正在克隆」然后失败，
   * 却不知道原因（首页也不会出现仓库）。
   */
  hasLocalContent(): boolean {
    const storePath: string = this.getRepoPath();
    if (!FileUtils.exists(storePath)) {
      return false;
    }
    return FileUtils.listDir(storePath).length > 0;
  }

  /**
   * 删除本地仓库内容（保留并重建空目录）
   *
   * 供「保存配置后立即克隆」使用：git clone 要求目标目录为空或不存在，
   * 而这里**不清空配置里的远程地址**——那个地址正是接下来要克隆的目标
   * （`RepoManageViewModel.deleteRepo` 是另一回事：那是「删除仓库」，
   * 删完回到未初始化状态，故会一并清掉远程地址）。
   */
  async removeLocalRepo(): Promise<GitResult> {
    const storePath: string = this.getRepoPath();
    if (!FileUtils.exists(storePath)) {
      FileUtils.ensureDir(storePath);
      return { success: true, error: '' };
    }
    if (!FileUtils.deleteDir(storePath)) {
      return { success: false, error: Strings.get('git_remove_repo_dir_failed') };
    }
    // 重建空目录：克隆目标目录需要存在且为空（或不存在）
    FileUtils.ensureDir(storePath);
    return { success: true, error: '' };
  }

  /**
   * 初始化本地仓库（不设远程）
   */
  async initRepo(): Promise<GitResult> {
    if (this.isGitRepo()) {
      return { success: true, error: '' };
    }

    try {
      const repoPath: string = SettingsRepository.getInstance().getSettings().storePath;
      if (repoPath.length === 0) {
        return { success: false, error: Strings.get('repo_err_no_path') };
      }

      const gitDir: string = `${repoPath}/.git`;
      FileUtils.ensureDir(`${gitDir}/objects`);
      FileUtils.ensureDir(`${gitDir}/objects/info`);
      FileUtils.ensureDir(`${gitDir}/objects/pack`);
      FileUtils.ensureDir(`${gitDir}/refs`);
      FileUtils.ensureDir(`${gitDir}/refs/heads`);
      FileUtils.ensureDir(`${gitDir}/refs/tags`);

      // HEAD → refs/heads/main
      FileUtils.writeTextFile(`${gitDir}/HEAD`, 'ref: refs/heads/main\n');

      // config
      const configContent: string =
        '[core]\n\trepositoryformatversion = 0\n\tfilemode = false\n\tbare = false\n\tlogallrefupdates = true\n';
      FileUtils.writeTextFile(`${gitDir}/config`, configContent);

      // description
      FileUtils.writeTextFile(`${gitDir}/description`, 'Unnamed repository; edit this file to name the repository.\n');

      hilog.info(DOMAIN, TAG, 'initRepo: created .git skeleton at %{public}s', gitDir);
      return { success: true, error: '' };
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      hilog.error(DOMAIN, TAG, 'initRepo failed: %{public}s', msg);
      return { success: false, error: msg };
    }
  }

  /**
   * 通过 TaskPool 调用**阻塞的** native git 接口
   *
   * 这些调用内部是同步网络 IO（DNS/TCP/TLS/传输），直接在 JS 主线程上跑会让界面卡死，
   * 系统 watchdog 会以 APP_INPUT_BLOCK 杀进程（实测：DNS 不可达时约 6 秒应用消失）。
   */
  private async callNativeGit(fn: string, args: string[]): Promise<NativeResult> {
    const req: NativeGitRequest = { fn: fn, args: args };
    try {
      const reply: NativeGitReply = await taskpool.execute(invokeNativeGit, req) as NativeGitReply;
      const result: NativeResult = { success: reply.success, error: reply.error, data: reply.data };
      return result;
    } catch (e) {
      // taskpool.execute 本身也可能失败（任务数超限、线程无法创建等）；
      // 直接抛出会让「克隆/同步」这类调用点崩溃，故统一转成失败结果交给上层提示
      hilog.error(DOMAIN, TAG, 'callNativeGit(%{public}s) failed: %{public}s', fn,
        e instanceof Error ? `${e.name}: ${e.message}` : String(e));
      return { success: false, error: Strings.get('common_native_call_failed'), data: '' };
    }
  }

  /**
   * 解析 SSH 认证材料：私钥 PEM + 口令 + 已信任主机指纹
   *
   * 拉取/推送/克隆共用一份实现——三者的前置条件完全相同，各写一套必然走样
   * （克隆曾能认证、而拉取/推送只挂了 HTTPS 凭据回调，SSH 远端一律认证失败）。
   */
  private async resolveSshAuth(config: GitConfig, host: string, port: number): Promise<SshAuthResolution> {
    const out: SshAuthResolution = { ok: false, error: '', pem: '', passphrase: '', fingerprint: '' };
    if (config.sshKeyAlias.length === 0) {
      // 应用内 SSH 密钥只保留一把（新建/导入会替换旧的，见 SshKeyManager.removeAllKeys），
      // 所以「没选」时直接用那把是确定无歧义的。初始设置流程里用户配好密钥后不会再回
      // Git 配置页选一次，原先这里直接报错，导致引导页的克隆必然失败。
      const keys: SshKeyInfo[] = SshKeyManager.getInstance().listKeys();
      if (keys.length === 0) {
        out.error = Strings.get('git_ssh_no_key_hint');
        return out;
      }
      if (keys.length > 1) {
        out.error = Strings.fmt('git_ssh_multi_key_hint', keys.length);
        return out;
      }
      config.sshKeyAlias = keys[0].alias;
      config.sshKeyType = keys[0].keyType;
      await SettingsRepository.getInstance().saveGitConfig(config);
      hilog.info(DOMAIN, TAG, 'resolveSshAuth: auto-selected the only SSH key %{public}s', keys[0].alias);
    }
    const pem: string = await SshKeyManager.getInstance().exportPrivateKeyPem(config.sshKeyAlias);
    if (pem.length === 0) {
      out.error = Strings.fmt('common_ssh_pem_read_failed', config.sshKeyAlias);
      return out;
    }
    // 私钥本身带口令时必须有口令，否则 libssh2 用不了这把钥匙
    const status: NativeResult = NativeBridge.getInstance().sshKeyStatus(pem);
    if (status.success && status.data.length > 0) {
      let encrypted: boolean = false;
      try {
        const parsed: SshKeyStatus = JSON.parse(status.data) as SshKeyStatus;
        encrypted = parsed.encrypted === true;
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'resolveSshAuth: key status parse failed');
      }
      if (encrypted && config.sshKeyPassphrase.length === 0) {
        out.error = Strings.get('git_ssh_key_encrypted');
        return out;
      }
    }
    // 传**全部**已信任指纹（换行分隔），native 侧任意一把匹配即放行：
    // 服务器可能提供多把主机密钥，而各流程选到的类型可能不同。
    // 指纹为空时交给本次连接自己回报实际指纹（见 GitResult.pendingHostKeyFp），由上层弹确认框——
    // **不能**在这里用别的实现预探测，那会探到另一把主机密钥（见字段注释）。
    const knownFps: string[] = await KnownHostsStore.getInstance().getFingerprints(host, port);
    out.ok = true;
    out.pem = pem;
    out.passphrase = config.sshKeyPassphrase;
    out.fingerprint = knownFps.join('\n');
    return out;
  }

  /**
   * SSH 远端测试：认证材料解析 + libgit2 ls-remote（走 TaskPool，网络 IO 不进主线程）
   *
   * SSH 认证成功 ≠ 仓库存在：sshd 只看密钥不看路径，仓库名写错时认证照样通过，
   * 用户会带着「连接成功」的假象去克隆，然后在克隆处才失败（曾报出的还是
   * 与真实原因无关的传输错误）。这里必须真的 ls 一次引用。
   *
   * @returns success = 认证且仓库存在；失败时 error 是可操作的中文原因
   */
  async testSshRemote(url: string): Promise<GitResult> {
    const config: GitConfig = await SettingsRepository.getInstance().loadGitConfig();
    const auth: SshAuthResolution = await this.resolveSshAuthForRemote(config, url);
    if (!auth.ok) {
      return { success: false, error: auth.error };
    }
    const result: NativeResult = await this.callNativeGit('gitTestRemote',
      [url, '', '', '', auth.pem, auth.passphrase, auth.fingerprint]);
    if (result.success) {
      return { success: true, error: '' };
    }
    const hostKey: GitResult | null = GitClient.parseHostKeyError(result.error);
    if (hostKey !== null) {
      return hostKey;
    }
    return { success: false, error: GitClient.friendlySshRemoteError(result.error) };
  }

  /**
   * HTTPS 远端测试：libgit2 connect + ls-remote（走 TaskPool）
   *
   * 曾直接在主线程同步调 native：DNS 不可达时阻塞数秒，正是会触发系统
   * watchdog（APP_INPUT_BLOCK）杀进程的场景，必须走 TaskPool。
   */
  async testHttpsRemote(url: string, username: string, password: string, proxyUrl: string): Promise<NativeResult> {
    return await this.callNativeGit('gitTestRemote', [url, username, password, proxyUrl, '', '', '']);
  }

  /**
   * 把 SSH ls-remote 的原始错误翻译成可操作提示
   *
   * 仓库名写错时 libgit2/libssh2 报的是传输层错误（如 upload-pack 退出后
   * "could not read from remote repository"），与真实原因无关，必须映射。
   */
  private static friendlySshRemoteError(raw: string): string {
    if (raw.includes('does not appear to be a git repository')
      || raw.includes('Repository not found') || raw.includes('repository not found')
      || raw.includes('could not read from remote')
      || raw.includes('Failed to receive response') || raw.includes('failed to receive response')) {
      return Strings.get('git_ssh_remote_notfound');
    }
    if (raw.includes('host key untrusted') || raw.includes('host key mismatch')) {
      return Strings.get('git_hostkey_not_trusted');
    }
    if (raw.includes('authentication') || raw.includes('auth fail') || raw.includes('publickey')) {
      return Strings.get('git_ssh_auth_failed');
    }
    if (raw.includes('failed to resolve address') || raw.includes('Could not resolve host')) {
      return Strings.get('gitcfg_https_err_dns');
    }
    return Strings.fmt('gitcfg_https_err_generic', raw);
  }

  /**
   * 取拉取/推送**实际**使用的远程地址
   *
   * 那是 origin 的 URL，不是配置页的 remoteUrl——克隆用的是克隆页填的地址，
   * 配置页那个字段是另一处输入，应用从不自动同步两者。按配置判断认证方式的话，
   * 用户改过配置地址后同步会拿 SSH 凭据去连 HTTPS（或反之），报出与真实原因
   * 无关的认证失败。origin 读不到时才退回配置值。
   */
  private async effectiveRemoteUrl(config: GitConfig): Promise<string> {
    const origin: NativeResult = NativeBridge.getInstance().gitRemoteUrl(this.getRepoPath());
    if (origin.success && origin.data.length > 0) {
      return origin.data;
    }
    return config.remoteUrl;
  }

  /**
   * 取拉取/推送**实际**使用的远程地址（公开版，供同步面板解析 TOFU 主机）
   */
  async effectiveRemoteUrlPublic(): Promise<string> {
    const config: GitConfig = await SettingsRepository.getInstance().loadGitConfig();
    return this.effectiveRemoteUrl(config);
  }

  /**
   * 按远程地址解析 SSH 认证材料
   *
   * 主机/端口从该地址解析，不能用 Git 配置页的 SSH 端口字段——
   * 两者可能不一致（例如地址里写了 :2222）。
   */
  private async resolveSshAuthForRemote(config: GitConfig, remoteUrl: string): Promise<SshAuthResolution> {
    const target: SshUrlTarget | null = SshUrlTarget.parse(remoteUrl);
    if (target === null) {
      return {
        ok: false,
        error: Strings.get('git_ssh_url_unparsed_remote'),
        pem: '', passphrase: '', fingerprint: '',
      };
    }
    return await this.resolveSshAuth(config, target.host, target.port);
  }

  /**
   * 解析 native 回传的主机密钥拒绝信息
   *
   * native 在主机密钥未被信任/不匹配时返回 `host key untrusted: SHA256:xxx|RSA`
   * 或 `host key mismatch: SHA256:xxx|RSA`（见 hps_napi.cpp 的 HostKeyErrorOr）。
   */
  private static parseHostKeyError(raw: string): GitResult | null {
    const idx: number = raw.indexOf('host key untrusted: ') >= 0
      ? raw.indexOf('host key untrusted: ') : raw.indexOf('host key mismatch: ');
    if (idx < 0) {
      return null;
    }
    const mismatch: boolean = raw.startsWith('host key mismatch: ') || raw.includes('host key mismatch: ');
    const payload: string = raw.substring(idx + (mismatch ? 'host key mismatch: '.length : 'host key untrusted: '.length));
    const sep: number = payload.indexOf('|');
    const fp: string = sep >= 0 ? payload.substring(0, sep) : payload;
    const keyType: string = sep >= 0 ? payload.substring(sep + 1) : '';
    return {
      success: false,
      error: mismatch
        ? Strings.get('git_hostkey_mismatch_short')
        : Strings.get('git_hostkey_first_connect'),
      pendingHostKeyFp: fp,
      pendingHostKeyType: keyType,
      hostKeyMismatch: mismatch,
    };
  }

  /**
   * SSH 克隆：解析主机/端口 → 取已信任指纹 → 导出私钥 PEM → 调 native
   *
   * 三处前置条件都必须明确报错，不能让用户对着「认证失败」猜：
   * ① 未选 SSH 密钥；② 私钥已加密但未配置口令；③ 主机指纹未信任（先走 TOFU）。
   */
  private async cloneOverSsh(url: string, config: GitConfig): Promise<GitResult> {
    const target: SshUrlTarget | null = SshUrlTarget.parse(url);
    if (target === null) {
      return {
        success: false,
        error: Strings.get('git_ssh_url_unparsed_clone'),
      };
    }
    const auth: SshAuthResolution = await this.resolveSshAuth(config, target.host, target.port);
    if (!auth.ok) {
      return { success: false, error: auth.error };
    }

    hilog.info(DOMAIN, TAG, 'cloneOverSsh: %{public}s:%{public}d path=%{public}s',
      target.host, target.port, this.getRepoPath());
    const result: NativeResult = await this.callNativeGit('gitCloneSsh',
      [url, this.getRepoPath(), auth.pem, auth.passphrase, auth.fingerprint]);
    if (result.success) {
      return { success: true, error: '' };
    }
    const rawErr: string = result.error;
    // 原始错误必须先落日志再映射：映射后的文案只覆盖已知几类，
    // 遇到新形态（如主机密钥反复被拒）时日志里没有原文就无从定位
    hilog.warn(DOMAIN, TAG, 'cloneOverSsh raw error: %{public}s', rawErr);
    const hostKey: GitResult | null = GitClient.parseHostKeyError(rawErr);
    if (hostKey !== null) {
      return hostKey;
    }
    if (rawErr.includes('exists and is not an empty directory')) {
      return {
        success: false,
        error: Strings.get('git_clone_dir_not_empty'),
      };
    }
    if (rawErr.includes('authentication') || rawErr.includes('auth fail')
        || rawErr.includes('publickey')) {
      return { success: false, error: Strings.get('git_ssh_auth_failed') };
    }
    return { success: false, error: GitClient.friendlySshRemoteError(rawErr) };
  }

  /**
   * 克隆远程仓库
   * @param remoteUrl 远程 URL（https:// 或 git@host:path SSH 格式）
   *
   * HTTPS 走 libgit2 的 mbedTLS 传输（凭据取 GitConfig 的用户名/Token）；
   * SSH 走 libgit2 的 libssh2 传输（私钥来自 HUKS，主机密钥按 known_hosts 校验）。
   */
  async clone(remoteUrl: string): Promise<GitResult> {
    if (remoteUrl.trim().length === 0) {
      return { success: false, error: Strings.get('git_err_url_empty') };
    }

    const url: string = remoteUrl.trim();
    const isSsh: boolean = url.startsWith('git@') || url.startsWith('ssh://') || url.startsWith('ssh+git://');
    const isHttps: boolean = url.startsWith('https://') || url.startsWith('http://');

    if (!isSsh && !isHttps) {
      return {
        success: false,
        error: Strings.get('git_err_url_scheme'),
      };
    }

    const bridge = NativeBridge.getInstance();
    if (bridge.isAvailable()) {
      const config: GitConfig = await SettingsRepository.getInstance().loadGitConfig();

      if (isSsh) {
        // SSH 克隆走 libgit2 的 libssh2 传输：私钥从 HUKS 解封后以 PEM 文本传入内存，
        // 主机指纹必须已信任（先经「测试连接」的 TOFU 流程写入 known_hosts）
        return await this.cloneOverSsh(url, config);
      }

      // HTTPS 凭据
      const username: string = isHttps ? config.username : '';
      const password: string = isHttps ? config.password : '';
      const result: NativeResult = await this.callNativeGit('gitClone',
        [url, this.getRepoPath(), username, password, config.proxyUrl]);
      if (result.success) {
        return { success: true, error: '' };
      }

      // 翻译 native 错误为可操作的友好提示
      const rawErr: string = result.error;
      if (rawErr.includes('exists and is not an empty directory')) {
        return {
          success: false,
          error: Strings.get('git_clone_dir_not_empty'),
        };
      }
      if (rawErr.includes('unsupported URL protocol') || rawErr.includes('unsupported protocol')) {
        // 当前 native 层的 libgit2 **没有编入 SSH 传输**（third_party/libgit2 未链接 libssh2，
        // 产出的 .so 里连 git_transport_ssh_libssh2_global_init 都没有），
        // 所以 git@host:path / ssh:// 一律报「不支持的协议」。
        // 别把这条错误写成「请检查 SSH 密钥是否已配置」——那会让用户去反复配密钥，
        // 而真正可行的路径是 HTTPS + 访问令牌。
        return {
          success: false,
          error: isHttps
            ? Strings.get('git_clone_https_tls_unready')
            : Strings.get('git_clone_ssh_unsupported'),
        };
      }
      if (rawErr.includes('401') || rawErr.includes('authentication') || rawErr.includes('credential')) {
        return {
          success: false,
          error: Strings.get('git_clone_auth_failed'),
        };
      }
      // native 已就绪但克隆失败：返回真实错误
      return { success: false, error: rawErr };
    }
    hilog.info(DOMAIN, TAG, 'clone: %{public}s (native bridge unavailable)', url);
    return { success: false, error: 'Git native library not yet available' };
  }

  /**
   * 拉取远程更新并合并（HTTPS 凭据自动传递）
   */
  async pull(): Promise<GitResult> {
    if (!this.isGitRepo()) {
      return { success: false, error: Strings.get('gitlog_not_repo') };
    }
    const bridge = NativeBridge.getInstance();
    if (bridge.isAvailable()) {
      const config: GitConfig = await SettingsRepository.getInstance().loadGitConfig();
      const remoteUrl: string = await this.effectiveRemoteUrl(config);
      const isHttps: boolean = remoteUrl.startsWith('https://') || remoteUrl.startsWith('http://');
      // 拉取方式取自「仓库管理 → 拉取时进行变基」
      const rebase: boolean = SettingsRepository.getInstance().getSettings().gitPullRebase;
      // SSH 远端要带私钥/口令/已信任指纹，否则 native 侧只有 HTTPS 凭据回调，
      // 认证必然失败（表现为「克隆成功但拉取/推送报认证失败」）
      const ssh: SshAuthResolution = isHttps
        ? { ok: true, error: '', pem: '', passphrase: '', fingerprint: '' }
        : await this.resolveSshAuthForRemote(config, remoteUrl);
      if (!ssh.ok) {
        return { success: false, error: ssh.error };
      }
      const result: NativeResult = await this.callNativeGit('gitPull',
        [this.getRepoPath(), isHttps ? config.username : '',
          isHttps ? config.password : '', config.proxyUrl, rebase ? '1' : '0',
          ssh.pem, ssh.passphrase, ssh.fingerprint]);
      if (result.success) {
        // 拉取可能带来新条目/新目录，通知根页面重读仓库（一键同步、弹窗拉取、
        // 启动自动同步都走这里，集中一处才不会有哪条路径忘了刷新）
        RepoChangeNotifier.connect().bump();
        return { success: true, error: '' };
      }
      const rawErr: string = result.error;
      // 主机密钥未信任/不匹配：带出指纹给上层弹 TOFU 确认（与克隆同语义）
      const hostKey: GitResult | null = GitClient.parseHostKeyError(rawErr);
      if (hostKey !== null) {
        return hostKey;
      }
      const authErr: string = GitClient.translateAuthError(rawErr);
      if (authErr.length > 0) {
        return { success: false, error: Strings.fmt('git_pull_failed', authErr) };
      }
      return { success: false, error: rawErr };
    }
    hilog.info(DOMAIN, TAG, 'pull: native library not yet available');
    return { success: false, error: 'Git native library not yet available' };
  }

  /**
   * 推送本地提交到远程（HTTPS 凭据自动传递）
   * @param force true 时强制推送（refspec 加 '+' 前缀，覆盖远程分支历史）；
   *              仓库管理「强制推送远程」专用，一键同步等常规推送保持 false
   */
  async push(force: boolean = false): Promise<GitResult> {
    if (!this.isGitRepo()) {
      return { success: false, error: Strings.get('gitlog_not_repo') };
    }
    const bridge = NativeBridge.getInstance();
    if (bridge.isAvailable()) {
      const config: GitConfig = await SettingsRepository.getInstance().loadGitConfig();
      const remoteUrl: string = await this.effectiveRemoteUrl(config);
      const isHttps: boolean = remoteUrl.startsWith('https://') || remoteUrl.startsWith('http://');
      const ssh: SshAuthResolution = isHttps
        ? { ok: true, error: '', pem: '', passphrase: '', fingerprint: '' }
        : await this.resolveSshAuthForRemote(config, remoteUrl);
      if (!ssh.ok) {
        return { success: false, error: ssh.error };
      }
      const result: NativeResult = await this.callNativeGit('gitPush',
        [this.getRepoPath(), isHttps ? config.username : '', isHttps ? config.password : '',
          config.proxyUrl, ssh.pem, ssh.passphrase, ssh.fingerprint, force ? '1' : '0']);
      if (result.success) {
        return { success: true, error: '' };
      }
      const rawErr: string = result.error;
      const hostKey: GitResult | null = GitClient.parseHostKeyError(rawErr);
      if (hostKey !== null) {
        return hostKey;
      }
      const authErr: string = GitClient.translateAuthError(rawErr);
      if (authErr.length > 0) {
        return { success: false, error: Strings.fmt('git_push_failed', authErr) };
      }
      return { success: false, error: rawErr };
    }
    hilog.info(DOMAIN, TAG, 'push: native library not yet available');
    return { success: false, error: 'Git native library not yet available' };
  }

  /**
   * 提交全部变更
   * @param message 提交信息（为空时自动生成）
   */
  async commitAll(message: string): Promise<GitResult> {
    if (!this.isGitRepo()) {
      return { success: false, error: Strings.get('gitlog_not_repo') };
    }
    const config: GitConfig = await SettingsRepository.getInstance().loadGitConfig();
    const msg: string = message.length > 0 ? message : this.buildAutoCommitMessage();

    const bridge = NativeBridge.getInstance();
    if (bridge.isAvailable()) {
      const result: NativeResult = await this.callNativeGit('gitCommitAll',
        [this.getRepoPath(), msg, config.committerName, config.committerEmail]);
      if (result.success) {
        return { success: true, error: '' };
      }
      return { success: false, error: result.error };
    }
    hilog.info(DOMAIN, TAG, 'commitAll: %{public}s by %{public}s (native library not yet available)',
      msg, config.committerName);
    return { success: false, error: 'Git native library not yet available' };
  }

  /**
   * 查询仓库状态（分支 / 变更数 / ahead / behind / 冲突）
   */
  async status(): Promise<GitRepoStatus> {
    const empty: GitRepoStatus = {
      isRepo: false,
      branch: '',
      changedCount: 0,
      aheadCount: 0,
      behindCount: 0,
      hasConflicts: false,
    };
    if (!this.isGitRepo()) {
      return empty;
    }
    const bridge = NativeBridge.getInstance();
    if (!bridge.isAvailable()) {
      empty.isRepo = true;
      return empty;
    }
    const result: NativeResult = await this.callNativeGit('gitStatus', [this.getRepoPath()]);
    if (!result.success || result.data.length === 0) {
      empty.isRepo = true;
      return empty;
    }
    try {
      const parsed: GitRepoStatus = JSON.parse(result.data) as GitRepoStatus;
      return parsed;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'status parse failed: %{public}s', JSON.stringify(e));
      empty.isRepo = true;
      return empty;
    }
  }

  /**
   * 查询提交历史
   * @param limit 最大条数
   */
  async log(limit: number): Promise<GitCommitInfo[]> {
    if (!this.isGitRepo()) {
      return [];
    }
    const bridge = NativeBridge.getInstance();
    if (!bridge.isAvailable()) {
      return [];
    }
    const result: NativeResult = await this.callNativeGit('gitLog', [this.getRepoPath(), `${limit}`]);
    if (!result.success || result.data.length === 0) {
      return [];
    }
    try {
      return JSON.parse(result.data) as GitCommitInfo[];
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'log parse failed: %{public}s', JSON.stringify(e));
      return [];
    }
  }

  /**
   * 一键同步：拉取 → 提交（无变更时忽略失败）→ 推送
   *
   * @returns 全部成功时 true；拉取或推送失败时 false
   */
  async syncAll(): Promise<boolean> {
    const pullResult = await this.pull();
    if (!pullResult.success) {
      hilog.warn(DOMAIN, TAG, 'syncAll pull failed: %{public}s', pullResult.error);
      return false;
    }
    const commitResult = await this.commitAll('');
    if (!commitResult.success) {
      // 无变更时提交可能失败，不视为错误
      hilog.info(DOMAIN, TAG, 'syncAll commit skipped: %{public}s', commitResult.error);
    }
    const pushResult = await this.push();
    if (!pushResult.success) {
      hilog.warn(DOMAIN, TAG, 'syncAll push failed: %{public}s', pushResult.error);
      return false;
    }
    hilog.info(DOMAIN, TAG, 'syncAll completed');
    return true;
  }

  /**
   * 自动生成提交信息
   *
   * 前缀是应用名，大小写须与 `app.json5` 的 label 一致（曾写成小写
   * `[harmonypasswordstore]`，在提交历史里与应用名对不上）。
   */
  private buildAutoCommitMessage(): string {
    const now: Date = new Date();
    const pad: (n: number) => string = (n: number) => n.toString().padStart(2, '0');
    return `[HarmonyPasswordStore] ${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())} ${pad(now.getHours())}:${pad(now.getMinutes())}`;
  }
}

/**
 * SSH 远程地址解析（取主机与端口，用于 known_hosts 匹配）
 *
 * 支持与 git 相同的两种写法：
 * - scp 风格 `git@host:user/repo.git`（无端口，默认 22）
 * - URL 风格 `ssh://git@host[:端口]/user/repo.git`
 */
export class SshUrlTarget {
  host: string;
  port: number;

  constructor(host: string, port: number) {
    this.host = host;
    this.port = port;
  }

  static parse(url: string): SshUrlTarget | null {    const raw: string = url.trim();
    if (raw.length === 0) {
      return null;
    }
    let rest: string = raw;
    if (raw.startsWith('ssh://')) {
      rest = raw.substring(6);
    } else if (!raw.includes('@')) {
      return null; // 非 SSH 写法（HTTPS 由另一条路径处理）
    }

    // 去掉 userinfo（user@）
    const at: number = rest.indexOf('@');
    const hostPort: string = at >= 0 ? rest.substring(at + 1) : rest;

    // ':' 后若是纯数字则是端口（URL 风格），否则是 scp 风格里的路径起点
    const colon: number = hostPort.indexOf(':');
    if (colon < 0) {
      return hostPort.length > 0 ? new SshUrlTarget(hostPort, 22) : null;
    }
    const after: string = hostPort.substring(colon + 1);
    const slash: number = after.indexOf('/');
    const portPart: string = slash >= 0 ? after.substring(0, slash) : after;
    const host: string = hostPort.substring(0, colon);
    if (host.length === 0) {
      return null;
    }
    if (portPart.length > 0 && SshUrlTarget.isDigits(portPart)) {
      return new SshUrlTarget(host, parseInt(portPart, 10));
    }
    return new SshUrlTarget(host, 22);
  }

  private static isDigits(s: string): boolean {
    for (let i: number = 0; i < s.length; i++) {
      const c: string = s.charAt(i);
      if (c < '0' || c > '9') {
        return false;
      }
    }
    return true;
  }

  /**
   * 地址里是否**显式**写了端口
   *
   * 用于判断「SSH 端口」表单字段该不该生效：地址自带端口时以地址为准。
   * 曾无条件用表单值覆盖解析结果，于是地址写 `ssh://host:2224/...` 时
   * 测试连接仍去连 22（探测失败只报「获取主机密钥失败」，与真实原因无关）。
   * scp 风格 `git@host:path` 的 ':' 后是路径而非端口，这里按「冒号后到斜杠前
   * 全为数字」判定，天然排除。
   */
  static hasExplicitPort(url: string): boolean {
    const raw: string = url.trim();
    const rest: string = raw.startsWith('ssh://') ? raw.substring(6) : raw;
    const at: number = rest.indexOf('@');
    const hostPort: string = at >= 0 ? rest.substring(at + 1) : rest;
    const colon: number = hostPort.indexOf(':');
    if (colon < 0) {
      return false;
    }
    const after: string = hostPort.substring(colon + 1);
    const slash: number = after.indexOf('/');
    const portPart: string = slash >= 0 ? after.substring(0, slash) : after;
    return portPart.length > 0 && SshUrlTarget.isDigits(portPart);
  }
}
