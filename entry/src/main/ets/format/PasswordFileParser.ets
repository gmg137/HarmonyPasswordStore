import { PasswordContent } from '../model/PasswordEntry';

/** 用户名字段前缀 */
const USER_PREFIX: string = 'user:';
/** 邮箱字段前缀 */
const EMAIL_PREFIX: string = 'email:';
/** 手机号字段前缀 */
const PHONE_PREFIX: string = 'phone:';
/** 备注字段前缀 */
const NOTES_PREFIX: string = 'notes:';
/** 内容匹配：额外内容行里「标签: 值」的标签最大长度（超长视为普通文本，不剥标签） */
const LABEL_MAX: number = 24;
/** 内容匹配：识别 URI scheme 时允许的最大前缀长度（`https`/`git+ssh` 等） */
const URI_SCHEME_MAX: number = 16;
/** 内容匹配命中片段的最大长度（超出截断并加省略号） */
const SNIPPET_MAX: number = 48;

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

  /**
   * 内容搜索用的可搜索文本（供「内容匹配」搜索模式）
   *
   * 需求口径：**匹配除主密码以外的字段内容，不含字段名**。因此：
   * - 只取 `parse` 出的结构化字段**值**（user/email/phone/notes）——标签在解析阶段
   *   就已剥离，天然不参与匹配；
   * - `extraContent` 逐行剥离「标签: 值」的标签，只留值；
   * - 主密码（第一行）与 `rawText`（含第一行）**一律不参与**：密码值永远不会成为
   *   搜索目标，也不会进入内容缓存；
   * - 条目名与目录路径不参与（那是名称匹配阶段的事，两个阶段不混同）。
   *
   * 大小写**原样保留**：调用方匹配时自行转小写（`toLowerCase().includes(...)`），
   * 保留原文是为了命中后能截取片段展示。
   *
   * 额外内容里的标签是任意文本、没有 schema，剥标签只能是启发式，故有四条护栏
   * 避免误伤（详见 `contentValueOfLine`）：URI 行、标签含空白、纯数字标签、空值。
   */
  static searchableText(content: PasswordContent): string {
    const parts: string[] = [];
    PasswordFileParser.pushNonEmpty(parts, content.username);
    PasswordFileParser.pushNonEmpty(parts, content.email);
    PasswordFileParser.pushNonEmpty(parts, content.phone);
    PasswordFileParser.pushNonEmpty(parts, content.notes);

    const lines: string[] = content.extraContent.split('\n');
    for (let i: number = 0; i < lines.length; i++) {
      PasswordFileParser.pushNonEmpty(parts, PasswordFileParser.contentValueOfLine(lines[i]));
    }
    return parts.join('\n');
  }

  /** 去首尾空白后非空才压入（空行对匹配无意义，也会让命中片段截取更难读） */
  private static pushNonEmpty(parts: string[], value: string): void {
    const trimmed: string = value.trim();
    if (trimmed.length > 0) {
      parts.push(trimmed);
    }
  }

  /**
   * 内容匹配的命中片段（列表副标题「这条为什么命中」）
   *
   * 取 `searchableText` 输出里**第一行**含关键词的内容，压平内部空白后截断展示。
   * 输入必须是 `searchableText` 的结果——它已排除主密码，故片段里**不可能出现密码值**；
   * `lowerKeyword` 需已是小写（与匹配同口径）。无命中或空输入返回空串。
   */
  static matchSnippet(searchable: string, lowerKeyword: string, maxLen: number = SNIPPET_MAX): string {
    if (searchable.length === 0 || lowerKeyword.length === 0) {
      return '';
    }
    const lines: string[] = searchable.split('\n');
    for (let i: number = 0; i < lines.length; i++) {
      if (lines[i].toLowerCase().includes(lowerKeyword)) {
        const flat: string = PasswordFileParser.flattenWhitespace(lines[i]);
        return flat.length > maxLen ? `${flat.substring(0, maxLen)}…` : flat;
      }
    }
    return '';
  }

  /** 把行内连续空白压成单个空格（片段只占一行，换行/制表符会把布局顶乱） */
  private static flattenWhitespace(line: string): string {
    let out: string = '';
    let pendingSpace: boolean = false;
    for (let i: number = 0; i < line.length; i++) {
      const c: string = line.charAt(i);
      if (c === ' ' || c === '\t' || c === '\r') {
        pendingSpace = out.length > 0;
        continue;
      }
      if (pendingSpace) {
        out += ' ';
        pendingSpace = false;
      }
      out += c;
    }
    return out;
  }

  /**
   * 额外内容行取「值」部分；非标签行原样返回整行
   *
   * 判定为「标签: 值」需同时满足：首个分隔符位置 > 0、标签非空、标签 ≤ `LABEL_MAX`
   * 且不含空白、标签不是纯数字、值非空。任一不满足就整行保留（宁可多匹配，
   * 也不能把用户真实写下的内容从搜索范围里悄悄抹掉）。
   *
   * 四条护栏各自挡住的真实形态：
   * - `https://example.org`（`isUriLike`）：协议冒号不是字段分隔符；
   * - `营业时间 12:30`（标签含空白）：冒号在值里，不是分隔符；
   * - `12:30`（纯数字标签）：时间/比例一类，不是字段名；
   * - `notes:`（值为空）：整行只有字段名，本行不贡献任何可搜索文本。
   */
  private static contentValueOfLine(line: string): string {
    const trimmed: string = line.trim();
    if (trimmed.length === 0) {
      return '';
    }
    if (PasswordFileParser.isUriLike(trimmed)) {
      return trimmed;
    }
    const sep: number = PasswordFileParser.labelSeparatorIndex(trimmed);
    if (sep <= 0) {
      return trimmed;
    }
    const label: string = trimmed.substring(0, sep).trim();
    const value: string = trimmed.substring(sep + 1).trim();
    if (value.length === 0) {
      // 只有字段名、没有值：该行不贡献可搜索文本（否则「搜字段名」会命中）
      return '';
    }
    if (label.length === 0 || label.length > LABEL_MAX
      || PasswordFileParser.containsWhitespace(label) || PasswordFileParser.isAllDigits(label)) {
      return trimmed;
    }
    return value;
  }

  /** 首个字段分隔符（半角 `:` 或全角 `：`）的位置，无则 -1 */
  private static labelSeparatorIndex(line: string): number {
    const ascii: number = line.indexOf(':');
    const full: number = line.indexOf('：');
    if (ascii < 0) {
      return full;
    }
    if (full < 0) {
      return ascii;
    }
    return ascii < full ? ascii : full;
  }

  /** `scheme://…` 形态（`https://x` 的冒号属于协议，不是字段分隔符） */
  private static isUriLike(line: string): boolean {
    const idx: number = line.indexOf('://');
    if (idx <= 0 || idx > URI_SCHEME_MAX) {
      return false;
    }
    const scheme: string = line.substring(0, idx);
    for (let i: number = 0; i < scheme.length; i++) {
      if (!PasswordFileParser.isSchemeChar(scheme.charAt(i))) {
        return false;
      }
    }
    return true;
  }

  /** URI scheme 允许的字符（RFC 3986：字母/数字/`+`/`-`/`.`） */
  private static isSchemeChar(c: string): boolean {
    const isDigit: boolean = c >= '0' && c <= '9';
    const isLower: boolean = c >= 'a' && c <= 'z';
    const isUpper: boolean = c >= 'A' && c <= 'Z';
    return isDigit || isLower || isUpper || c === '+' || c === '-' || c === '.';
  }

  private static containsWhitespace(s: string): boolean {
    for (let i: number = 0; i < s.length; i++) {
      const c: string = s.charAt(i);
      if (c === ' ' || c === '\t') {
        return true;
      }
    }
    return false;
  }

  private static isAllDigits(s: string): boolean {
    if (s.length === 0) {
      return false;
    }
    for (let i: number = 0; i < s.length; i++) {
      const c: string = s.charAt(i);
      if (c < '0' || c > '9') {
        return false;
      }
    }
    return true;
  }
}
