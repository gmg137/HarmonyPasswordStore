import { SshKeyType } from '../common/Constants';
import { socket } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NativeBridge, NativeResult } from '../common/NativeBridge';
import { invokeNativeGit, NativeGitRequest, NativeGitReply } from './NativeGitTask';
import { taskpool } from '@kit.ArkTS';
import { SshKeyManager } from '../crypto/SshKeyManager';
import { KnownHostsStore, KnownHostKey } from './KnownHostsStore';
import { Strings } from '../common/Strings';

/** hilog 域 */
const DOMAIN: number = 0x0001;
/** hilog 标签 */
const TAG: string = 'SshClient';

/**
 * SSH 连接测试结果
 */
export interface SshConnectResult {
  success: boolean;
  error: string;
  /**
   * TOFU 待确认的主机密钥指纹（"SHA256:Base64"）。
   * 仅在 hostKeyState === 'unknown' 时返回：UI 应展示指纹供用户确认，
   * 用户确认后调用 confirmHostKey() 保存，再重新连接。
   */
  hostKeyFingerprint?: string;
  /**
   * TOFU 待确认的主机密钥类型（RSA/ECDSA/Ed25519，与 hostKeyFingerprint 同返）。
   * 确认后随指纹一起写入信任库——同类型指纹变化才算「密钥变了」。
   */
  hostKeyType?: string;
  /**
   * 主机密钥状态：
   * - 'trusted'：known_hosts 匹配，已直连
   * - 'unknown'：首次连接 / 新类型，需用户确认（TOFU）
   * - 'mismatch'：同类型指纹与 known_hosts 不一致，已拒绝（可能中间人）
   * - ''：非 native 路径 / 未涉及主机密钥校验
   */
  hostKeyState?: string;
  /** hostKeyState 为 'mismatch' 时为 true（UI 据此切换告警文案） */
  hostKeyMismatch?: boolean;
}

/**
 * 探测到的服务器主机密钥（指纹 + 类型）
 */
export interface ProbedHostKey {
  /** SHA256:Base64 指纹 */
  fingerprint: string;
  /** 主机密钥类型（RSA/ECDSA/Ed25519，探测失败时可能为空） */
  keyType: string;
}

/**
 * SSH 连接参数
 */
export interface SshConnectParams {
  /** 主机名 */
  host: string;
  /** 端口（默认 22） */
  port: number;
  /** 用户名（通常为 git） */
  username: string;
  /** HUKS 中的密钥别名（公钥认证时使用） */
  keyAlias: string;
  /** 密钥类型 */
  keyType: SshKeyType;
  /** 私钥 passphrase（密钥加密时使用，可选） */
  passphrase?: string;
  /** 密码认证的密码（keyAlias 为空时使用，可选） */
  password?: string;
}

/**
 * SSH 客户端
 *
 * 封装 SSH 连接与认证（用于 Git over SSH）。
 * 优先通过 NAPI 桥接 russh（Rust SSH 实现）做完整握手 + 公钥/密码认证；
 * native 不可用时降级为 TCP 连通性测试。
 */
export class SshClient {
  private static instance: SshClient | null = null;

  private constructor() {
  }

  static getInstance(): SshClient {
    if (!SshClient.instance) {
      SshClient.instance = new SshClient();
    }
    return SshClient.instance;
  }

  /**
   * 统一格式化异常信息
   *
   * 鸿蒙 API 抛出的多为 BusinessError（非 Error 实例），
   * 直接用 String(e) 会得到 "[object Object]"，看不到真实原因。
   */
  static formatError(e: Object): string {
    if (e instanceof Error) {
      return e.message;
    }
    const err = e as Record<string, Object>;
    const msg: Object | undefined = err?.message;
    const code: Object | undefined = err?.code;
    if (msg !== undefined) {
      return code !== undefined ? `${msg} (code=${code})` : `${msg}`;
    }
    try {
      return JSON.stringify(e);
    } catch (jsonErr) {
      return Strings.get('common_unknown_error');
    }
  }

  /**
   * 从 Git 远程 URL 解析 SSH 连接参数
   *
   * 支持格式：
   *   ssh://git@host:port/path
   *   git@host:path
   *
   * @param remoteUrl 远程 URL
   * @returns 连接参数（无法解析时返回 null）
   */
  static parseSshUrl(remoteUrl: string): SshConnectParams | null {
    const trimmed: string = remoteUrl.trim();

    // ssh://git@host:port/path
    if (trimmed.startsWith('ssh://')) {
      const rest: string = trimmed.substring(6);
      const slashIdx: number = rest.indexOf('/');
      if (slashIdx < 0) return null;
      const hostPart: string = rest.substring(0, slashIdx);
      const atIdx: number = hostPart.lastIndexOf('@');
      const userInfo: string = atIdx >= 0 ? hostPart.substring(0, atIdx) : 'git';
      const hostPort: string = atIdx >= 0 ? hostPart.substring(atIdx + 1) : hostPart;
      const colonIdx: number = hostPort.lastIndexOf(':');
      let host: string = hostPort;
      let port: number = 22;
      if (colonIdx >= 0) {
        host = hostPort.substring(0, colonIdx);
        const parsed: number = parseInt(hostPort.substring(colonIdx + 1), 10);
        if (!isNaN(parsed)) port = parsed;
      }
      const params: SshConnectParams = {
        host: host,
        port: port,
        username: userInfo,
        keyAlias: '',
        keyType: SshKeyType.ED25519,
      };
      return params;
    }

    // git@host:path（SCP 风格）
    const atIdx: number = trimmed.indexOf('@');
    const colonIdx: number = trimmed.indexOf(':');
    if (atIdx > 0 && colonIdx > atIdx) {
      const params: SshConnectParams = {
        username: trimmed.substring(0, atIdx),
        host: trimmed.substring(atIdx + 1, colonIdx),
        port: 22,
        keyAlias: '',
        keyType: SshKeyType.ED25519,
      };
      return params;
    }

    return null;
  }

  /**
   * 测试 SSH 连接（完整握手 + 认证，TOFU 主机密钥校验）
   *
   * 流程：
   * 1. known_hosts 无记录 → 先探测指纹，返回 hostKeyState='unknown' + hostKeyFingerprint，
   *    由 UI 展示指纹供用户确认（用户确认后调 confirmHostKey 再重连）
   * 2. known_hosts 匹配 → 带期望指纹直连（native 端二次校验，防 TOFU 窗口竞态）
   * 3. known_hosts 不匹配 → 直接拒绝，返回 hostKeyState='mismatch'（可能中间人）
   *
   * 优先走 native russh；native 不可用或密钥不可导出时降级为 TCP 连通性测试。
   */
  /**
   * 通过 TaskPool 调用**阻塞的** native SSH 接口（SSH 握手/认证是同步网络 IO）
   *
   * 与 GitClient.callNativeGit 同理：放在主线程上会把界面卡死并被系统杀掉。
   */
  private async callNativeSsh(fn: string, args: string[]): Promise<NativeResult> {
    const req: NativeGitRequest = { fn: fn, args: args };
    try {
      const reply: NativeGitReply = await taskpool.execute(invokeNativeGit, req) as NativeGitReply;
      const result: NativeResult = { success: reply.success, error: reply.error, data: reply.data };
      return result;
    } catch (e) {
      // 与 GitClient.callNativeGit 同款：execute 本身失败时转成失败结果，不让异常上抛
      hilog.error(DOMAIN, TAG, 'callNativeSsh(%{public}s) failed: %{public}s', fn,
        e instanceof Error ? `${e.name}: ${e.message}` : String(e));
      return { success: false, error: Strings.get('common_native_call_failed'), data: '' };
    }
  }

  async testConnection(params: SshConnectParams): Promise<SshConnectResult> {
    if (params.host.length === 0) {
      return { success: false, error: Strings.get('ssh_host_required') };
    }

    const native: NativeBridge = NativeBridge.getInstance();
    if (native.isAvailable()) {
      const knownHosts: KnownHostsStore = KnownHostsStore.getInstance();
      const knownKeys: KnownHostKey[] = await knownHosts.getHostKeys(params.host, params.port);

      // 已有信任记录：先比对指纹列表
      if (knownKeys.length > 0) {
        const probe = await this.probeFingerprint(params);
        if (probe === null) {
          return { success: false, error: Strings.get('ssh_probe_failed') };
        }
        const state: string = await knownHosts.hostKeyState(params.host, params.port,
          probe.keyType, probe.fingerprint);
        if (state === 'trusted') {
          // 指纹已信任：走认证连接（native 端带期望指纹二次校验，防 TOFU 窗口竞态）
          return await this.authenticate(params, probe.fingerprint);
        }
        if (state === 'mismatch') {
          hilog.warn(DOMAIN, TAG, 'testConnection: HOST KEY MISMATCH for %{public}s', params.host);
          return {
            success: false,
            error: Strings.get('ssh_hostkey_mismatch_rejected'),
            hostKeyState: 'mismatch',
          };
        }
        // 新类型（服务器多把主机密钥里没钉过的一把）：让 UI 确认后追加，
        // 不算攻击——同类型指纹变化才是中间人告警
        hilog.info(DOMAIN, TAG, 'testConnection: new host key type %{public}s for %{public}s',
          probe.keyType, params.host);
        return {
          success: false,
          error: '',
          hostKeyState: 'unknown',
          hostKeyFingerprint: probe.fingerprint,
          hostKeyType: probe.keyType,
          hostKeyMismatch: false,
        };
      }

      // 无任何记录：探测指纹返回给 UI 确认（TOFU）
      const probe = await this.probeFingerprint(params);
      if (probe === null) {
        return { success: false, error: Strings.get('ssh_probe_failed') };
      }
      hilog.info(DOMAIN, TAG, 'testConnection: unknown host, fingerprint=%{public}s (%{public}s)',
        probe.fingerprint, probe.keyType);
      return {
        success: false,
        error: '',
        hostKeyState: 'unknown',
        hostKeyFingerprint: probe.fingerprint,
        hostKeyType: probe.keyType,
        hostKeyMismatch: false,
      };
    }

    // 走到这里说明 native 侧没能完成认证（未选密钥 / native 不可用）。
    // **不能退化成「TCP 可达」并报连接成功**：TCP 只证明端口开着，认证可能完全没做，
    // 用户会带着「连接成功」的假象去克隆，然后在克隆处撞上莫名其妙的失败。
    // 故 TCP 结果只作补充提示，成功与否仍然由认证决定。
    hilog.info(DOMAIN, TAG, 'testConnection: 认证未执行，降级为 TCP 连通性探测（不报成功）');
    const reach: SshConnectResult = await this.checkHostReachable(params.host, params.port);
    if (!reach.success) {
      return reach;
    }
    return {
      success: false,
      error: params.keyAlias.length === 0
        ? Strings.get('ssh_tcp_no_key')
        : Strings.get('ssh_tcp_auth_incomplete'),
    };
  }

  /**
   * 探测服务器主机密钥（russh，TOFU）
   *
   * @returns 指纹 + 类型；探测失败返回 null（错误已记录日志）
   */
  private async probeFingerprint(params: SshConnectParams): Promise<ProbedHostKey | null> {
    const probe: NativeResult = await this.callNativeSsh('sshFingerprint',
      [params.host, `${params.port}`]);
    if (!probe.success || probe.data.length === 0) {
      hilog.warn(DOMAIN, TAG, 'testConnection: fingerprint probe failed: %{public}s', probe.error);
      return null;
    }
    // native 返回 "SHA256:Base64|类型"（类型段可能缺失，兼容旧 native）
    const sep: number = probe.data.indexOf('|');
    if (sep >= 0) {
      const out: ProbedHostKey = {
        fingerprint: probe.data.substring(0, sep),
        keyType: probe.data.substring(sep + 1),
      };
      return out;
    }
    const out: ProbedHostKey = { fingerprint: probe.data, keyType: '' };
    return out;
  }

  /** 带期望指纹发起认证连接（公钥或密码，按参数选择） */
  private async authenticate(params: SshConnectParams, knownFp: string): Promise<SshConnectResult> {
    const password: string = params.password ?? '';
    const passphrase: string = params.passphrase ?? '';
    if (params.keyAlias.length === 0 && password.length > 0) {
      const result: NativeResult = await this.callNativeSsh('sshTestPassword',
        [params.host, `${params.port}`, params.username, password, knownFp]);
      if (result.success) {
        hilog.info(DOMAIN, TAG, 'testConnection: password auth OK (native, host key trusted)');
        return { success: true, error: '', hostKeyState: 'trusted' };
      }
      if (result.error.includes('host key mismatch')) {
        hilog.warn(DOMAIN, TAG, 'testConnection: HOST KEY MISMATCH for %{public}s', params.host);
        return { success: false, error: Strings.get('ssh_hostkey_mismatch_rejected'), hostKeyState: 'mismatch' };
      }
      hilog.warn(DOMAIN, TAG, 'testConnection: native password auth failed: %{public}s', result.error);
      return { success: false, error: result.error };
    }

    // 公钥认证：从 SshKeyManager 内存缓存导出私钥 PEM（不落盘）
    if (params.keyAlias.length > 0) {
      const pem: string = await SshKeyManager.getInstance().exportPrivateKeyPem(params.keyAlias);
      if (pem.length > 0) {
        const result: NativeResult = await this.callNativeSsh('sshTestAuth',
          [params.host, `${params.port}`, params.username, pem, passphrase, knownFp]);
        if (result.success) {
          hilog.info(DOMAIN, TAG, 'testConnection: publickey auth OK (native, host key trusted)');
          return { success: true, error: '', hostKeyState: 'trusted' };
        }
        if (result.error.includes('host key mismatch')) {
          hilog.warn(DOMAIN, TAG, 'testConnection: HOST KEY MISMATCH for %{public}s', params.host);
          return { success: false, error: Strings.get('ssh_hostkey_mismatch_rejected'), hostKeyState: 'mismatch' };
        }
        hilog.warn(DOMAIN, TAG, 'testConnection: native publickey auth failed: %{public}s', result.error);
        return { success: false, error: result.error };
      }
      // 私钥取不出来（未生成、已删除、或 HUKS 解封失败）
      hilog.warn(DOMAIN, TAG, 'testConnection: private key unavailable for alias=%{public}s',
        params.keyAlias);
      return {
        success: false,
        error: Strings.fmt('common_ssh_pem_read_failed', params.keyAlias),
      };
    }

    return {
      success: false,
      error: params.password !== undefined && params.password.length > 0
        ? Strings.get('ssh_params_incomplete')
        : Strings.get('ssh_no_key_unverified'),
    };
  }

  /**
   * TOFU 确认：用户确认指纹后保存到 known_hosts（带类型）
   *
   * @returns 保存是否成功
   */
  async confirmHostKey(host: string, port: number, fingerprint: string,
    keyType: string = ''): Promise<boolean> {
    const ok: boolean = await KnownHostsStore.getInstance()
      .saveHostKey(host, port, { keyType: keyType, fingerprint: fingerprint });
    if (ok) {
      hilog.info(DOMAIN, TAG, 'confirmHostKey: trusted %{public}s:%{public}d (%{public}s)',
        host, port, keyType);
    }
    return ok;
  }

  /**
   * 检查远程 Git 服务器是否可访问（如 github.com 的 ssh 端口）
   */
  async checkHostReachable(host: string, port: number): Promise<SshConnectResult> {
    if (host.length === 0) {
      return { success: false, error: Strings.get('ssh_host_required') };
    }

    const normalizedPort: number = port > 0 ? port : 22;
    hilog.info(DOMAIN, TAG, 'checkHostReachable: %{public}s:%{public}d', host, normalizedPort);

    try {
      const tcpSocket: socket.TCPSocket = socket.constructTCPSocketInstance();
      const connectOption: socket.TCPConnectOptions = {
        address: {
          address: host,
          port: normalizedPort,
          family: 1
        } as socket.NetAddress,
        timeout: 5_000,
      };
      await tcpSocket.connect(connectOption);
      tcpSocket.close();
      hilog.info(DOMAIN, TAG, 'checkHostReachable: connected OK');
      return { success: true, error: '' };
    } catch (e) {
      // 鸿蒙抛出的多为 BusinessError：不是 Error 实例，
      // String(e) 只会得到 "[object Object]"，必须显式取 message/code
      const msg: string = SshClient.formatError(e);
      hilog.warn(DOMAIN, TAG, 'checkHostReachable failed: %{public}s', msg);
      return { success: false, error: Strings.fmt('ssh_tcp_connect_failed', msg) };
    }
  }
}
