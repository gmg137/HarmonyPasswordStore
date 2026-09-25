import { PasswordRepository } from '../model/PasswordRepository';
import { PasswordEntry } from '../model/PasswordEntry';
import { SettingsRepository } from '../model/SettingsRepository';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** hilog 域 */
const DOMAIN: number = 0x0001;
/** hilog 标签 */
const TAG: string = 'CredentialMatcher';

/**
 * 凭据匹配结果
 */
export interface CredentialMatch {
  /** 密码条目相对路径 */
  relativePath: string;
  /** 显示名称 */
  name: string;
  /** 匹配到的用户名（解密后，可能为空） */
  username: string;
  /** 匹配得分（越高越相关） */
  score: number;
  /** 最后使用时间（毫秒） */
  lastUsed: number;
}

/**
 * 凭据匹配器
 *
 * 按请求方标识（应用包名或网页域名）匹配密码条目：
 * 1. 扫描仓库所有密码文件
 * 2. 用条目名称 / 路径段 / URL 字段与标识做域名相似度比较
 * 3. 得分高于阈值的条目作为填充候选
 *
 * 匹配策略（不涉及解密，保证性能与安全）：
 *   - 条目名称包含域名主体（如 example.org）→ 高分
 *   - 路径任一段包含域名主体 → 中分
 *   - 仅模糊相关 → 低分（可用作兜底建议）
 */
export class CredentialMatcher {
  private static instance: CredentialMatcher | null = null;

  /** 最低匹配得分阈值 */
  private static readonly MIN_SCORE: number = 30;

  private constructor() {
  }

  static getInstance(): CredentialMatcher {
    if (!CredentialMatcher.instance) {
      CredentialMatcher.instance = new CredentialMatcher();
    }
    return CredentialMatcher.instance;
  }

  /**
   * 从包名提取域名主体
   *
   * Android 风格包名 `org.example.app` → `example.org`
   * 鸿蒙包名 `com.example.app` → `example.com`
   *
   * @param packageName 应用包名
   * @returns 域名主体（如 example.org），无法提取时返回空
   */
  static extractDomainFromPackage(packageName: string): string {
    const parts: string[] = packageName.split('.');
    if (parts.length < 2) return '';
    // 反转前两段：com.example → example.com
    const tld: string = parts[0];
    const main: string = parts[1];
    if (tld.length === 0 || main.length === 0) return '';
    return `${main}.${tld}`;
  }

  /**
   * 从 URL 或域名文本中提取注册域名
   *
   * `https://login.example.org/path` → `login.example.org`
   * 保留子域以便精确匹配，比较时再逐级放宽。
   *
   * @param urlOrDomain URL 或域名文本
   * @returns 主机部分（小写）
   */
  static extractHost(urlOrDomain: string): string {
    let text: string = urlOrDomain.trim().toLowerCase();
    // 去掉协议
    const protoIdx: number = text.indexOf('://');
    if (protoIdx >= 0) {
      text = text.substring(protoIdx + 3);
    }
    // 去掉路径与端口
    const slashIdx: number = text.indexOf('/');
    if (slashIdx >= 0) {
      text = text.substring(0, slashIdx);
    }
    const colonIdx: number = text.indexOf(':');
    if (colonIdx >= 0) {
      text = text.substring(0, colonIdx);
    }
    return text;
  }

  /**
   * 计算两个域名的匹配得分
   *
   * 完全相等 → 100；主域相同 → 80；请求方是条目域的子域 → 70；否则 0。
   *
   * **不做子串包含**。曾用 `hostA.includes(hostB)` 给 60 分，而阈值只有 30，
   * 于是 `evil-example.com` 能匹配到 `example.com` 的条目、`a.com` 能命中大量条目——
   * 自动填充场景下这等于把 A 站的密码明文送到 B 站。
   */
  static scoreDomain(hostA: string, hostB: string): number {
    if (hostA.length === 0 || hostB.length === 0) return 0;
    if (hostA === hostB) return 100;

    const mainA: string = CredentialMatcher.getRegistrableDomain(hostA);
    const mainB: string = CredentialMatcher.getRegistrableDomain(hostB);
    if (mainA.length > 0 && mainA === mainB) return 80;

    // 子域关系：必须是「以点分隔的右侧后缀」，而非任意子串。
    // login.example.com 归 example.com，但 evil-example.com 不归。
    if (CredentialMatcher.isSubdomainOf(hostA, hostB) || CredentialMatcher.isSubdomainOf(hostB, hostA)) {
      return 70;
    }
    return 0;
  }

  /**
   * 判断 child 是否为 parent 的子域（要求以 `.` 边界分隔）
   */
  static isSubdomainOf(child: string, parent: string): boolean {
    if (child.length <= parent.length) return false;
    // 必须以 "." + parent 结尾，避免 evil-example.com 命中 example.com
    return child.endsWith(`.${parent}`);
  }

  /**
   * 常见双段后缀（取最后两段不足以得到可注册域）
   *
   * 只列实际会遇到的，不做完整 PSL：错列会把 `example.co.uk` 退化成 `co.uk`，
   * 使不同站点被判为同域。
   */
  private static readonly MULTI_PART_SUFFIXES: string[] = [
    'co.uk', 'org.uk', 'ac.uk', 'gov.uk', 'com.au', 'net.au', 'org.au',
    'com.cn', 'net.cn', 'org.cn', 'com.br', 'com.mx', 'co.jp', 'or.jp',
    'co.kr', 'com.tw', 'com.hk', 'com.sg', 'co.nz', 'com.tr',
  ];

  /**
   * 获取可注册域（去掉 www / login / mail 等主机前缀）
   */
  private static getRegistrableDomain(host: string): string {
    const parts: string[] = host.split('.');
    if (parts.length <= 2) return host;
    // 双段后缀（如 example.co.uk）需保留三段，否则会退化成 co.uk
    const lastTwo: string = parts.slice(-2).join('.');
    if (CredentialMatcher.MULTI_PART_SUFFIXES.includes(lastTwo) && parts.length >= 3) {
      return parts.slice(-3).join('.');
    }
    return lastTwo;
  }

  /**
   * 匹配指定标识的凭据候选
   *
   * @param identity 包名或域名/URL
   * @returns 按得分与最近使用排序的候选列表
   */
  match(identity: string): CredentialMatch[] {
    if (identity.trim().length === 0) return [];

    const targetHost: string = CredentialMatcher.extractHost(identity);
    // 包名场景：从包名提取域名主体
    const packageDomain: string = identity.includes('.') && !identity.includes('/')
      ? CredentialMatcher.extractHost(CredentialMatcher.extractDomainFromPackage(identity))
      : '';

    const repo: PasswordRepository = PasswordRepository.getInstance();
    const searchResult = repo.searchEntries('');
    if (!searchResult.success || !searchResult.data) {
      return [];
    }

    const matches: CredentialMatch[] = [];
    for (const entry of searchResult.data) {
      if (entry.isDirectory) continue;

      const score: number = this.scoreEntry(entry, targetHost, packageDomain);
      if (score < CredentialMatcher.MIN_SCORE) continue;

      const match: CredentialMatch = {
        relativePath: entry.relativePath,
        name: entry.name,
        username: '',
        score: score,
        lastUsed: 0,
      };
      matches.push(match);
    }

    // 合并最近使用时间（异步加载，尽力而为：无数据时保持 0）
    this.applyUsageTimestamps(matches);

    // 按得分降序，同分按最近使用降序
    matches.sort((a: CredentialMatch, b: CredentialMatch): number => {
      if (a.score !== b.score) return b.score - a.score;
      return b.lastUsed - a.lastUsed;
    });

    hilog.info(DOMAIN, TAG, 'match %{public}s: %{public}d candidates', identity, matches.length);
    return matches;
  }

  /**
   * 将持久化的使用时间表合并到候选列表
   */
  private applyUsageTimestamps(matches: CredentialMatch[]): void {
    SettingsRepository.getInstance().loadUsageMap().then((usageMap: Record<string, number>) => {
      for (const match of matches) {
        const used: number | undefined = usageMap[match.relativePath];
        if (used !== undefined) {
          match.lastUsed = used;
        }
      }
      // 时间表加载后重排（同分按最近使用优先）
      matches.sort((a: CredentialMatch, b: CredentialMatch): number => {
        if (a.score !== b.score) return b.score - a.score;
        return b.lastUsed - a.lastUsed;
      });
    }).catch((e: object) => {
      hilog.warn(DOMAIN, TAG, 'loadUsageMap failed: %{public}s', JSON.stringify(e));
    });
  }

  /**
   * 对单个条目计算匹配得分
   */
  private scoreEntry(entry: PasswordEntry, targetHost: string, packageDomain: string): number {
    let best: number = 0;

    // 1. 条目名称与目标主机比较
    const nameScore: number = CredentialMatcher.scoreDomain(
      CredentialMatcher.extractHost(entry.name), targetHost);
    if (nameScore > best) best = nameScore;

    // 2. 路径各段与目标主机比较（如 work/example.org/john）
    const segments: string[] = entry.relativePath.split('/');
    for (const seg of segments) {
      const segScore: number = CredentialMatcher.scoreDomain(
        CredentialMatcher.extractHost(seg), targetHost);
      if (segScore > best) {
        best = segScore;
      }
    }

    // 3. 包名域名主体与路径段比较（包名反转域名场景）
    if (packageDomain.length > 0) {
      for (const seg of segments) {
        const segScore: number = CredentialMatcher.scoreDomain(
          CredentialMatcher.extractHost(seg), packageDomain);
        // 包名推导的域名得分略降（8 折）
        const adjusted: number = Math.floor(segScore * 0.8);
        if (adjusted > best) {
          best = adjusted;
        }
      }
    }

    return best;
  }

  /**
   * 记录条目使用（填充成功后调用，供最近使用排序）
   *
   * @param relativePath 条目路径
   */
  async recordUsage(relativePath: string): Promise<void> {
    try {
      await SettingsRepository.getInstance().recordEntryUsage(relativePath, Date.now());
      hilog.info(DOMAIN, TAG, 'recordUsage: %{public}s', relativePath);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'recordUsage failed: %{public}s', JSON.stringify(e));
    }
  }
}
