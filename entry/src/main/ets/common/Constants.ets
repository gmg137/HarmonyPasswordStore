/**
 * 应用全局常量定义
 */

/** 密码仓库根目录名（相对于应用沙箱 filesDir） */
export const PASSWORD_STORE_DIR: string = 'password-store';

/** PGP 密钥加密存储目录名 */
export const PGP_KEYS_DIR: string = '.pgp-keys';

/** 临时文件目录名 */
export const TMP_DIR: string = 'tmp';

/** 默认 GPG 加密文件扩展名 */
export const GPG_FILE_EXT: string = '.gpg';

/** .gpg-id 文件名 */
export const GPG_ID_FILE: string = '.gpg-id';

/** 剪贴板自动清除时间（毫秒），默认 30 秒 */
export const CLIPBOARD_CLEAR_TIMEOUT: number = 30_000;

/** 快速解锁会话过期时间（毫秒），默认 5 分钟 */
export const UNLOCK_SESSION_TIMEOUT: number = 5 * 60_000;

/** Git 操作连接超时（毫秒） */
export const GIT_CONNECT_TIMEOUT: number = 10_000;

/** 密码文件组织方式 */
export enum PasswordFileOrganization {
  /** 文件式：work/example.org/john@doe.org.gpg */
  FILE = 0,
  /** 目录式：work/example.org/john@doe.org/password.gpg */
  DIRECTORY = 1,
}

/** 搜索匹配模式 */
export enum SearchMode {
  /** 模糊匹配（条目完整相对路径包含关键词） */
  FUZZY = 0,
  /** 精确匹配（条目名与关键词全等） */
  EXACT = 1,
  /**
   * 内容匹配（名称匹配同模糊，另外解密条目并匹配字段内容）
   *
   * 「内容」= 除主密码以外的字段值（user/email/phone/notes 与额外内容的**值**，
   * 不含字段名，规则见 `PasswordFileParser.searchableText`）。逐条解密是异步开销，
   * 由 `utils/ContentSearchService` 承担（原生调用一律走 TaskPool），
   * 名称匹配阶段与模糊模式一致。
   */
  CONTENT = 2,
}

/**
 * 密码文件（.gpg）的密文格式
 *
 * - `BIN`：二进制 OpenPGP（`gpg` 的默认输出，体积小约 1/4；git 里显示 Binary files differ）
 * - `ARMOR`：ASCII armor 文本（git diff 可读可 review，体积略大）
 *
 * 两者 gpg/pass 都能读（读取侧一律经 `FileUtils.readOpenPgpAsArmored` 归一化），
 * 该设置只决定**新写入**的文件（新建/编辑/重加密），已存在条目保持原格式不变。
 */
export enum PasswordFileFormat {
  /** 二进制（默认，与桌面 pass 的输出一致） */
  BIN = 0,
  /** ASCII armor 文本 */
  ARMOR = 1,
}

/** 排序方式 */
export enum SortMode {
  /** 按名称字母序 */
  ALPHABETICAL = 0,
  /** 按最近使用时间 */
  RECENTLY_USED = 1,
}

/** Git 认证方式 */
export enum GitAuthMode {
  /** HTTPS 用户名/密码 */
  HTTPS_PASSWORD = 0,
  /** HTTPS Personal Access Token */
  HTTPS_TOKEN = 1,
  /** SSH 密钥认证 */
  SSH_KEY = 2,
}

/** SSH 密钥类型 */
export enum SshKeyType {
  /** RSA */
  RSA = 0,
  /** ECDSA */
  ECDSA = 1,
  /** Ed25519 */
  ED25519 = 2,
}

/** SshKeyType 友好标签 */
export function sshKeyTypeLabel(type: SshKeyType): string {
  switch (type) {
    case SshKeyType.RSA: return 'RSA';
    case SshKeyType.ECDSA: return 'ECDSA';
    case SshKeyType.ED25519: return 'Ed25519';
    default: return 'Unknown';
  }
}

/** 应用主题模式 */
export enum ThemeMode {
  /** 跟随系统 */
  SYSTEM = 0,
  /** 浅色 */
  LIGHT = 1,
  /** 深色 */
  DARK = 2,
}

/** Navigation 路由名称 */
export class RouteNames {
  static readonly PASSWORD_LIST: string = 'PasswordListPage';
  static readonly PASSWORD_DETAIL: string = 'PasswordDetailPage';
  static readonly PASSWORD_CREATE: string = 'PasswordCreatePage';
  static readonly GIT_CONFIG: string = 'GitConfigPage';
  static readonly REPO_MANAGE: string = 'RepoManagePage';
  static readonly PGP_KEY_MANAGER: string = 'PgpKeyManagerPage';
  static readonly SSH_KEY_MANAGER: string = 'SshKeyManagerPage';
  static readonly PASSGEN: string = 'PassgenPage';
  static readonly SETTINGS: string = 'SettingsPage';
  static readonly ONBOARDING: string = 'OnboardingPage';
  static readonly LOCK: string = 'LockPage';
  static readonly FOLDER_CREATE: string = 'FolderCreatePage';
  static readonly MOVE_ENTRY: string = 'MoveEntryPage';
  static readonly PRIVACY_POLICY: string = 'PrivacyPolicyPage';
  static readonly ABOUT: string = 'AboutPage';
}
