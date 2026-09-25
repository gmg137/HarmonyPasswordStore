import { GitAuthMode, SshKeyType } from '../common/Constants';

/**
 * Git 仓库配置
 */
export interface GitConfig {
  /** 远程仓库 URL */
  remoteUrl: string;
  /** 认证方式 */
  authMode: GitAuthMode;
  /** HTTPS 用户名 */
  username: string;
  /** HTTPS 密码或 Token */
  password: string;
  /** SSH 密钥类型 */
  sshKeyType: SshKeyType;
  /** SSH 密钥 ID（HUKS 中的密钥别名） */
  sshKeyAlias: string;
  /**
   * SSH 私钥口令（仅当私钥本身带口令时需要）
   *
   * 导入密钥时的口令不会被保存（私钥文件里仍是加密态），而克隆/同步要用到它，
   * 故与 HTTPS 令牌同样经 HUKS 封装后落盘（见 SettingsRepository 的 seal/unseal）。
   */
  sshKeyPassphrase: string;
  /** SSH 自定义端口（默认 22） */
  sshPort: number;
  /** Git committer 用户名 */
  committerName: string;
  /** Git committer 邮箱 */
  committerEmail: string;
  /** HTTP(S) 代理 URL（如 http://127.0.0.1:7890，空为不使用代理） */
  proxyUrl: string;
  /** 是否在应用启动时自动同步 */
  autoSyncOnLaunch: boolean;
}

/**
 * 默认 Git 配置
 */
/**
 * 归一化 Git 配置：缺字段/类型不对时回落到默认值
 *
 * 落盘 JSON 可能来自更早的版本（字段是后加的）、被属性混淆改过名，
 * 或调用方只改了其中一两个字段。**任何一个 string 字段是 undefined 都会在
 * 传给 native 时被 `GetArgs` 拒绝**（真机实测：proxyUrl 缺失导致「初始化仓库」
 * 报 invalid arguments / native call failed），故读取时统一兜底。
 */
export function normalizeGitConfig(raw: GitConfig | null): GitConfig {
  const d: GitConfig = createDefaultGitConfig();
  if (raw === null) {
    return d;
  }
  return {
    remoteUrl: pickString(raw.remoteUrl, d.remoteUrl),
    authMode: pickNumber(raw.authMode, d.authMode) as GitAuthMode,
    username: pickString(raw.username, d.username),
    password: pickString(raw.password, d.password),
    sshKeyType: pickNumber(raw.sshKeyType, d.sshKeyType) as SshKeyType,
    sshKeyAlias: pickString(raw.sshKeyAlias, d.sshKeyAlias),
    sshKeyPassphrase: pickString(raw.sshKeyPassphrase, d.sshKeyPassphrase),
    sshPort: pickNumber(raw.sshPort, d.sshPort),
    committerName: pickString(raw.committerName, d.committerName),
    committerEmail: pickString(raw.committerEmail, d.committerEmail),
    proxyUrl: pickString(raw.proxyUrl, d.proxyUrl),
    autoSyncOnLaunch: raw.autoSyncOnLaunch === true,
  };
}

/** 取字符串字段，非字符串（含 undefined）时用兜底值 */
function pickString(v: string, fallback: string): string {
  return typeof v === 'string' ? v : fallback;
}

/** 取数值字段，非数值（含 undefined）时用兜底值 */
function pickNumber(v: number, fallback: number): number {
  return typeof v === 'number' && !Number.isNaN(v) ? v : fallback;
}

export function createDefaultGitConfig(): GitConfig {
  return {
    remoteUrl: '',
    authMode: GitAuthMode.HTTPS_PASSWORD,
    username: '',
    password: '',
    sshKeyType: SshKeyType.ED25519,
    sshKeyAlias: '',
    sshKeyPassphrase: '',
    sshPort: 22,
    committerName: '',
    committerEmail: '',
    proxyUrl: '',
    autoSyncOnLaunch: false,
  };
}
