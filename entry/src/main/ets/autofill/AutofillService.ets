import { CredentialMatcher, CredentialMatch } from './CredentialMatcher';
import { AutofillBridge } from './AutofillBridge';
import { RouteManager } from '../common/RouteManager';
import { RouteNames } from '../common/Constants';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** hilog 域 */
const DOMAIN: number = 0x0001;
/** hilog 标签 */
const TAG: string = 'AutofillService';

/**
 * 表单字段类型
 */
export enum FieldType {
  UNKNOWN = 0,
  USERNAME = 1,
  PASSWORD = 2,
}

/**
 * 解析后的表单字段
 */
export interface ParsedField {
  /** 字段类型 */
  type: FieldType;
  /** 字段 hint（autofill hint 文本） */
  hint: string;
  /** 当前值（已填内容） */
  value: string;
}

/**
 * 保存请求解析结果
 */
export interface SaveContext {
  /** 请求方应用包名 */
  packageName: string;
  /** 请求方网页域名 */
  webDomain: string;
  /** 解析出的用户名 */
  username: string;
  /** 解析出的密码 */
  password: string;
}

/**
 * 解析后的填充请求上下文
 */
export interface FillContext {
  /** 请求方应用包名 */
  packageName: string;
  /** 请求方网页域名（浏览器场景） */
  webDomain: string;
  /** 表单字段列表 */
  fields: ParsedField[];
}

/**
 * 自动填充服务
 *
 * 处理系统 AutofillExtensionAbility 转发的填充/保存请求：
 * 1. 解析 FillRequest 中的表单字段 hint（用户名/密码）
 * 2. 用 CredentialMatcher 按包名/域名匹配密码条目
 * 3. 返回填充候选（由 UI 层展示给用户选择）
 *
 * 说明：鸿蒙 autofill 扩展的具体回调签名以 SDK 为准，
 * 这里以接口层封装，native 联调时只需适配参数转换。
 */
export class AutofillService {
  private static instance: AutofillService | null = null;

  private constructor() {
  }

  static getInstance(): AutofillService {
    if (!AutofillService.instance) {
      AutofillService.instance = new AutofillService();
    }
    return AutofillService.instance;
  }

  /**
   * 处理填充请求
   *
   * @param request 系统 FillRequest，包含包名与 viewData 节点列表
   * @returns 填充上下文（供 UI 层使用）
   */
  handleFillRequest(request: object): FillContext | null {
    const context: FillContext | null = this.parseFillRequest(request);
    if (context === null) {
      hilog.warn(DOMAIN, TAG, 'fill request parse failed');
      return null;
    }

    // 确定匹配用的标识（优先域名，其次包名）
    const identity: string = context.webDomain.length > 0 ? context.webDomain : context.packageName;
    const matches: CredentialMatch[] = CredentialMatcher.getInstance().match(identity);

    hilog.info(DOMAIN, TAG, 'fill request: %{public}s, %{public}d candidates', identity, matches.length);

    if (matches.length > 0) {
      this.presentCandidates(context, matches);
    }

    return context;
  }

  /**
   * 处理保存请求
   *
   * 应用提交表单后系统询问是否保存凭据。
   * 支持两种输入：
   * 1. 类型化 autoFillManager.SaveRequest（含 viewData.pageNodeInfos）→ 精确提取
   * 2. 原始对象（Record）→ 宽松解析（联调兜底）
   *
   * @param request 系统 SaveRequest
   * @returns 解析出的用户名和密码（供 UI 层使用）
   */
  handleSaveRequest(request: object): SaveContext {
    const context: SaveContext = { packageName: '', webDomain: '', username: '', password: '' };

    try {
      // 类型化路径：autoFillManager.SaveRequest（viewData.pageNodeInfos 带 autoFillType）
      const typed: autoFillManager.SaveRequest | undefined = request as autoFillManager.SaveRequest;
      if (typed.viewData !== undefined && typed.viewData.pageNodeInfos !== undefined) {
        context.username = AutofillService.extractUsernameFromNodes(typed.viewData);
        context.password = AutofillService.extractPasswordFromNodes(typed.viewData);
        context.packageName = typed.viewData.bundleName ?? '';
        context.webDomain = this.extractDomainFromUrl(typed.viewData.pageUrl ?? '');
        hilog.info(DOMAIN, TAG, 'save request (typed): pkg=%{public}s user=%{public}s pass=%{public}s',
          context.packageName, context.username.length > 0 ? 'yes' : 'no', context.password.length > 0 ? 'yes' : 'no');
        return context;
      }

      // 宽松路径：原始 Record 解析（联调兜底）
      const req: Record<string, Object> = request as Record<string, Object>;
      const pkg: Object | undefined = req['bundleName'] ?? req['packageName'];
      if (pkg !== undefined) {
        context.packageName = pkg as string;
      }

      const viewData: Object | undefined = req['viewData'];
      if (viewData !== undefined) {
        const fields: ParsedField[] = this.extractFieldsFromViewData(viewData);
        for (let i: number = 0; i < fields.length; i++) {
          if (fields[i].type === FieldType.USERNAME && context.username.length === 0) {
            context.username = fields[i].value;
          } else if (fields[i].type === FieldType.PASSWORD && context.password.length === 0) {
            context.password = fields[i].value;
          }
        }
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'handleSaveRequest failed: %{public}s', e instanceof Error ? e.message : String(e));
    }

    hilog.info(DOMAIN, TAG, 'save request: pkg=%{public}s user=%{public}s pass=%{public}s',
      context.packageName, context.username.length > 0 ? 'yes' : 'no', context.password.length > 0 ? 'yes' : 'no');

    return context;
  }

  /**
   * 从 viewData 节点提取用户名（类型化 autoFillType 匹配）
   */
  private static extractUsernameFromNodes(viewData: autoFillManager.ViewData): string {
    const nodes: autoFillManager.PageNodeInfo[] = viewData.pageNodeInfos;
    for (let i: number = 0; i < nodes.length; i++) {
      if (nodes[i].autoFillType === autoFillManager.AutoFillType.USER_NAME) {
        return nodes[i].value;
      }
    }
    return '';
  }

  /**
   * 从 viewData 节点提取密码（类型化 autoFillType 匹配，PASSWORD 或 NEW_PASSWORD）
   */
  private static extractPasswordFromNodes(viewData: autoFillManager.ViewData): string {
    const nodes: autoFillManager.PageNodeInfo[] = viewData.pageNodeInfos;
    for (let i: number = 0; i < nodes.length; i++) {
      const t: autoFillManager.AutoFillType = nodes[i].autoFillType;
      if (t === autoFillManager.AutoFillType.PASSWORD || t === autoFillManager.AutoFillType.NEW_PASSWORD) {
        return nodes[i].value;
      }
    }
    return '';
  }

  /**
   * 解析填充请求上下文
   *
   * 从系统 FillRequest 中提取包名、域名与字段 hint。
   * 遍历 viewData 节点树，按 autofillHints 分类为用户名/密码字段。
   *
   * @param request 系统 FillRequest（原始对象）
   * @returns 解析结果，无法解析时返回 null
   */
  parseFillRequest(request: object): FillContext | null {
    try {
      const req: Record<string, Object> = request as Record<string, Object>;

      // 提取包名
      let packageName: string = '';
      const pkg: Object | undefined = req['bundleName'] ?? req['packageName'];
      if (pkg !== undefined) {
        packageName = pkg as string;
      }

      // 提取域名（浏览器场景可能附加在 viewData 的 url 属性中）
      let webDomain: string = '';
      const url: Object | undefined = req['url'];
      if (url !== undefined) {
        const urlStr: string = url as string;
        const host: string = this.extractDomainFromUrl(urlStr);
        if (host.length > 0) {
          webDomain = host;
        }
      }

      // 提取表单字段
      const fields: ParsedField[] = [];
      const viewData: Object | undefined = req['viewData'];
      if (viewData !== undefined) {
        const extracted: ParsedField[] = this.extractFieldsFromViewData(viewData);
        for (let i: number = 0; i < extracted.length; i++) {
          fields.push(extracted[i]);
        }
      }

      if (packageName.length === 0 && webDomain.length === 0 && fields.length === 0) {
        hilog.warn(DOMAIN, TAG, 'parseFillRequest: no usable data');
        return null;
      }

      return { packageName, webDomain, fields };
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'parseFillRequest failed: %{public}s', e instanceof Error ? e.message : String(e));
      return null;
    }
  }

  /**
   * 从 viewData 节点树提取表单字段
   *
   * viewData 可能是单个节点对象或节点数组。
   * 每个节点含 autofillHints（string[]）和 text/value（当前值）。
   *
   * @param viewData viewData 节点（对象或数组）
   * @returns 解析出的字段列表
   */
  private extractFieldsFromViewData(viewData: Object): ParsedField[] {
    const fields: ParsedField[] = [];

    try {
      // 尝试作为数组处理
      let nodes: Object[] = [];
      if (Array.isArray(viewData)) {
        nodes = viewData as Object[];
      } else {
        // 单个节点
        nodes.push(viewData);
      }

      for (let i: number = 0; i < nodes.length; i++) {
        const node: Record<string, Object> = nodes[i] as Record<string, Object>;

        // 读取 autofillHints
        const hintsObj: Object | undefined = node['autofillHints'];
        if (hintsObj === undefined) continue;
        const hints: string[] = hintsObj as string[];

        // 读取当前值
        let value: string = '';
        const text: Object | undefined = node['text'] ?? node['value'];
        if (text !== undefined) {
          value = text as string;
        }

        // 按 hint 分类
        let fieldType: FieldType = FieldType.UNKNOWN;
        for (let j: number = 0; j < hints.length; j++) {
          fieldType = AutofillService.classifyHint(hints[j]);
          if (fieldType !== FieldType.UNKNOWN) break;
        }

        if (fieldType !== FieldType.UNKNOWN) {
          fields.push({ type: fieldType, hint: hints.length > 0 ? hints[0] : '', value });
        }
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'extractFieldsFromViewData failed: %{public}s', e instanceof Error ? e.message : String(e));
    }

    return fields;
  }

  /**
   * 从 URL 提取域名
   */
  private extractDomainFromUrl(url: string): string {
    let text: string = url.trim().toLowerCase();
    const protoIdx: number = text.indexOf('://');
    if (protoIdx >= 0) {
      text = text.substring(protoIdx + 3);
    }
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
   * 根据字段 hint 判断字段类型
   *
   * @param hint autofill hint 文本（小写）
   * @returns 字段类型
   */
  static classifyHint(hint: string): FieldType {
    const lower: string = hint.toLowerCase();
    if (lower.includes('password')) {
      return FieldType.PASSWORD;
    }
    if (lower.includes('username') || lower.includes('email') || lower.includes('account')
      || lower.includes('phone') || lower.includes('user')) {
      return FieldType.USERNAME;
    }
    return FieldType.UNKNOWN;
  }

  /**
   * 展示填充候选
   *
   * 跳转到 AutofillFillPage，传递 identity 与候选数量，
   * 用户在列表页选择后由 ViewModel 回填表单。
   */
  private presentCandidates(context: FillContext, matches: CredentialMatch[]): void {
    const identity: string = context.webDomain.length > 0 ? context.webDomain : context.packageName;
    const param: Record<string, string> = { 'identity': identity };
    RouteManager.getInstance().pushPath(RouteNames.AUTOFILL_FILL, param);
    hilog.info(DOMAIN, TAG, 'presentCandidates: %{public}d for %{public}s', matches.length, identity);
  }
}
