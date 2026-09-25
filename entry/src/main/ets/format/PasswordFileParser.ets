import { PasswordContent } from '../model/PasswordEntry';

/** 用户名字段前缀 */
const USER_PREFIX: string = 'user:';
/** 邮箱字段前缀 */
const EMAIL_PREFIX: string = 'email:';
/** 手机号字段前缀 */
const PHONE_PREFIX: string = 'phone:';
/** URL 字段前缀 */
/** 备注字段前缀 */
const NOTES_PREFIX: string = 'notes:';

/**
 * 密码文件解析器
 *
 * pass 文件格式：
 * 第一行：    主密码
 * 第二行起：  额外内容（键值对或自由文本）
 *              常见字段：user: <username>
 *                        notes: <备注>
 *
 * 注：passkey 功能已移除，历史上以 JSON 形式写在第一行的 passkey 文件
 * 不再被特殊解释，会按普通条目解析（第一行即「主密码」）。
 */
export class PasswordFileParser {
  /**
   * 解析解密后的密码文件文本
   * @param rawText 原始文本
   * @returns 解析结果
   */
  static parse(rawText: string): PasswordContent {
    const lines: string[] = rawText.split('\n');
    const password: string = lines[0] ?? '';

    let username: string = '';
    let email: string = '';
    let phone: string = '';
    let notes: string = '';
    const extraLines: string[] = [];

    // 从第二行开始解析；预设字段行被提取到对应字段，不再进入额外内容
    for (let i = 1; i < lines.length; i++) {
      const line: string = lines[i];
      const trimmed: string = line.trim();

      if (trimmed.toLowerCase().startsWith(USER_PREFIX)) {
        username = trimmed.substring(USER_PREFIX.length).trim();
      } else if (trimmed.toLowerCase().startsWith(EMAIL_PREFIX)) {
        email = trimmed.substring(EMAIL_PREFIX.length).trim();
      } else if (trimmed.toLowerCase().startsWith(PHONE_PREFIX)) {
        phone = trimmed.substring(PHONE_PREFIX.length).trim();
      } else if (trimmed.toLowerCase().startsWith(NOTES_PREFIX)) {
        notes = trimmed.substring(NOTES_PREFIX.length).trim();
      } else {
        // 非预设字段行才归入额外内容
        extraLines.push(line);
      }
    }

    const extraContent: string = extraLines.join('\n');

    return {
      password,
      extraContent,
      username,
      email,
      phone,
      notes,
      rawText,
    };
  }

  /**
   * 将密码内容序列化为 pass 文件格式文本
   *
   * 顺序：第一行密码 → 结构化字段（user/email/phone/notes，仅非空者）→ extraContent。
   *
   * **结构化字段与 extraContent 必须都写**。曾写成「extraContent 非空时只写它、
   * 丢弃结构化字段」，于是编辑一条带自由文本行的桌面条目时，表单里填的备注、
   * 用户名、URL 等全部被静默丢弃（用户看到什么就存不进去什么）。解析阶段已把
   * 带前缀的行提取进字段、不会进入 extraContent，因此两者不会重复。
   */
  static serialize(password: string, username: string, email: string, phone: string, notes: string, extraContent: string): string {
    const lines: string[] = [password];

    if (username.length > 0) {
      lines.push(`${USER_PREFIX} ${username}`);
    }
    if (email.length > 0) {
      lines.push(`${EMAIL_PREFIX} ${email}`);
    }
    if (phone.length > 0) {
      lines.push(`${PHONE_PREFIX} ${phone}`);
    }
    if (notes.length > 0) {
      lines.push(`${NOTES_PREFIX} ${notes}`);
    }
    // 无法识别的原始行原样保留（放在字段之后，保持「结构化在前、自由文本在后」）
    if (extraContent.trim().length > 0) {
      lines.push(extraContent);
    }

    return lines.join('\n');
  }
}
