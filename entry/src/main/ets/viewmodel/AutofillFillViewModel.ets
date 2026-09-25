import { CredentialMatcher, CredentialMatch } from '../autofill/CredentialMatcher';
import { PasswordRepository } from '../model/PasswordRepository';
import { PasswordContent } from '../model/PasswordEntry';
import { AutofillBridge, FillApplyResult } from '../autofill/AutofillBridge';
import { autoFillManager } from '@kit.AbilityKit';
import { ClipboardHelper } from '../utils/ClipboardHelper';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** hilog 域 */
const DOMAIN: number = 0x0001;
/** hilog 标签 */
const TAG: string = 'AutofillFillVM';

/**
 * 填充建议视图模型
 *
 * 展示按标识匹配的凭据候选，用户选择后解密并返回填充结果。
 * 候选按匹配得分 + 最近使用排序。
 *
 * 填充路径：
 * 1. 系统 autoFillManager 请求（requestFill 拿到 viewData）→ applyCredentials 回填
 * 2. 无系统请求时降级为剪贴板复制
 */
@ObservedV2
export class AutofillFillViewModel {
  /** 请求方标识（包名或域名） */
  @Trace identity: string = '';
  /** 匹配到的候选列表 */
  @Trace candidates: CredentialMatch[] = [];
  /** 是否正在加载 */
  @Trace isLoading: boolean = false;
  /** 已选中的候选路径 */
  @Trace selectedPath: string = '';
  /** 是否正在解密 */
  @Trace isDecrypting: boolean = false;
  /** 错误提示 */
  @Trace errorMessage: string = '';
  /** 解密后的结果（选择成功时填充） */
  @Trace result: PasswordContent | null = null;
  /** 回填结果提示（系统填充路径成功时展示） */
  @Trace fillAppliedMessage: string = '';

  private matcher: CredentialMatcher = CredentialMatcher.getInstance();
  private bridge: AutofillBridge = AutofillBridge.getInstance();
  /** pending 的系统 viewData（requestFill 成功后暂存，候选选中时回填） */
  private pendingViewData: autoFillManager.ViewData | null = null;

  /**
   * 初始化：按标识匹配候选
   *
   * @param identity 包名或域名
   */
  async load(identity: string): Promise<void> {
    this.identity = identity;
    this.isLoading = true;
    this.errorMessage = '';
    try {
      this.candidates = this.matcher.match(identity);
    } catch (e) {
      this.errorMessage = '加载候选失败';
      hilog.error(DOMAIN, TAG, 'load failed: %{public}s', JSON.stringify(e));
    }
    this.isLoading = false;
  }

  /**
   * 设置 pending 的系统 viewData（由入口调用方传入 requestFill 的回调结果）
   */
  setPendingViewData(viewData: autoFillManager.ViewData): void {
    this.pendingViewData = viewData;
  }

  /**
   * 选择候选并解密
   *
   * 解密成功后：有 pending 系统请求则回填节点，否则走剪贴板降级。
   *
   * @param match 选中的候选
   * @returns 是否成功
   */
  async select(match: CredentialMatch): Promise<boolean> {
    this.selectedPath = match.relativePath;
    this.isDecrypting = true;
    this.errorMessage = '';
    this.fillAppliedMessage = '';

    const result = await PasswordRepository.getInstance().readPassword(match.relativePath);
    this.isDecrypting = false;

    if (!result.success || !result.data) {
      this.errorMessage = result.error.length > 0 ? result.error : '解密失败';
      this.selectedPath = '';
      return false;
    }

    this.result = result.data;

    // 记录最近使用（供下次排序）
    this.matcher.recordUsage(match.relativePath);

    // 系统填充路径：回填 viewData 节点
    if (this.pendingViewData !== null) {
      const username: string = result.data.username.length > 0 ? result.data.username : '';
      const password: string = result.data.password;
      const applied: FillApplyResult = this.bridge.applyCredentials(this.pendingViewData, username, password);
      this.pendingViewData = null;
      if (applied.success) {
        this.fillAppliedMessage = `已自动填充 ${applied.filledCount} 个字段`;
        hilog.info(DOMAIN, TAG, 'fill applied: %{public}d fields', applied.filledCount);
      } else {
        this.errorMessage = '自动填充失败，可使用复制';
        hilog.warn(DOMAIN, TAG, 'fill apply failed: %{public}s', applied.error);
      }
    }

    hilog.info(DOMAIN, TAG, 'selected: %{public}s', match.relativePath);
    return true;
  }

  /**
   * 复制用户名到剪贴板（无法直接回填时的降级路径）
   */
  async copyUsername(): Promise<void> {
    if (!this.result) return;
    await this.copyText(this.result.username.length > 0 ? this.result.username : '');
  }

  /**
   * 复制密码到剪贴板（无法直接回填时的降级路径）
   */
  async copyPassword(): Promise<void> {
    if (!this.result) return;
    await this.copyText(this.result.password);
  }

  /**
   * 复制文本到剪贴板
   */
  private async copyText(text: string): Promise<void> {
    if (text.length === 0) return;
    // 密码/用户名入剪贴板后必须排定自动清除
    await ClipboardHelper.getInstance().copy(text);
  }

  /**
   * 候选副标题（用户名或路径）
   */
  candidateSubtitle(candidate: CredentialMatch): string {
    if (candidate.username.length > 0) return candidate.username;
    return candidate.relativePath;
  }
}
