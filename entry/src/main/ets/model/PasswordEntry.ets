import { PasswordFileOrganization } from '../common/Constants';

/**
 * 密码条目实体 —— 对应 pass 仓库中的一个 .gpg 文件
 */
export interface PasswordEntry {
  /** 相对路径（不含 .gpg 扩展名），如 work/example.org/john@doe.org */
  relativePath: string;
  /** 完整文件路径（含 .gpg 扩展名） */
  fullPath: string;
  /** 显示名称（路径最后一段） */
  name: string;
  /** 所在目录相对路径 */
  parentDir: string;
  /** 是否为目录 */
  isDirectory: boolean;
  /** 子条目（仅目录有值） */
  children: PasswordEntry[];
  /** 最后修改时间（毫秒时间戳） */
  lastModified: number;
  /** 最后使用时间（毫秒时间戳，0 表示未使用过） */
  lastUsed: number;
}

/**
 * 密码文件内容 —— 解密后的 pass 文件格式
 *
 * pass 文件格式：
 * 第一行：主密码
 * 后续行：额外内容（键值对或自由文本）
 */
export interface PasswordContent {
  /** 主密码（第一行） */
  password: string;
  /** 额外内容（后续行） */
  extraContent: string;
  /** 解析出的用户名（从 extraContent 中提取） */
  username: string;
  /** 解析出的邮箱（从 extraContent 中提取） */
  email: string;
  /** 解析出的手机号（从 extraContent 中提取） */
  phone: string;
  /** 解析出的备注（从 extraContent 中提取） */
  notes: string;
  /** 原始完整文本 */
  rawText: string;
}
