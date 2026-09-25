import { autoFillManager } from '@kit.AbilityKit';
import { UIContext } from '@ohos.arkui.UIContext';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** hilog 域 */
const DOMAIN: number = 0x0001;
/** hilog 标签 */
const TAG: string = 'AutofillBridge';

/**
 * 自动填充回填结果
 */
export interface FillApplyResult {
  success: boolean;
  error: string;
  /** 成功回填的字段数 */
  filledCount: number;
}

/**
 * autoFillManager 桥接
 *
 * 封装 @kit.AbilityKit 的 autoFillManager API：
 * - requestAutoFill：发起填充请求，回调拿到系统 viewData（节点树）
 * - requestAutoSave：发起保存请求
 *
 * 说明：本应用是密码管理器（填充提供方），而 autoFillManager 的
 * requestAutoFill 是"向系统请求填充本应用页面"的 API（请求方视角）。
 * 作为提供方，回填目标页面的节点树由系统传入 callback.onSuccess(viewData)，
 * 本桥接负责把选中的凭据按 autoFillType 写回对应节点。
 */
export class AutofillBridge {
  private static instance: AutofillBridge | null = null;

  private constructor() {
  }

  static getInstance(): AutofillBridge {
    if (!AutofillBridge.instance) {
      AutofillBridge.instance = new AutofillBridge();
    }
    return AutofillBridge.instance;
  }

  /**
   * 发起填充请求（请求方视角）
   *
   * @param uiContext UI 上下文
   * @param fillType 要填充的字段类型（密码/用户名等）
   * @returns 系统 viewData（用户选择凭据后回调返回），取消/失败返回 null
   */
  async requestFill(uiContext: UIContext, fillType: autoFillManager.AutoFillType): Promise<autoFillManager.ViewData | null> {
    return new Promise<autoFillManager.ViewData | null>((resolve) => {
      try {
        const request: autoFillManager.FillRequest = {
          type: fillType,
          viewData: {
            bundleName: '',
            pageUrl: '',
            pageNodeInfos: [],
            pageRect: { left: 0, top: 0, width: 0, height: 0 },
          },
        };

        const callback: autoFillManager.AutoFillCallback = {
          onSuccess: (viewData: autoFillManager.ViewData): void => {
            hilog.info(DOMAIN, TAG, 'requestAutoFill onSuccess: %{public}d nodes', viewData.pageNodeInfos.length);
            resolve(viewData);
          },
          onFailure: (result: autoFillManager.FillFailureResult): void => {
            hilog.warn(DOMAIN, TAG, 'requestAutoFill onFailure: errCode=%{public}d', result.errCode);
            resolve(null);
          },
        };

        autoFillManager.requestAutoFill(uiContext, request, callback);
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'requestAutoFill failed: %{public}s', e instanceof Error ? e.message : String(e));
        resolve(null);
      }
    });
  }

  /**
   * 从 viewData 提取用户名/密码（保存场景）
   *
   * @param viewData 系统 viewData
   * @returns [username, password]（未找到的为空串）
   */
  extractCredentials(viewData: autoFillManager.ViewData): string[] {
    let username: string = '';
    let password: string = '';

    const nodes: autoFillManager.PageNodeInfo[] = viewData.pageNodeInfos;
    for (let i: number = 0; i < nodes.length; i++) {
      const node: autoFillManager.PageNodeInfo = nodes[i];
      switch (node.autoFillType) {
        case autoFillManager.AutoFillType.USER_NAME:
          if (username.length === 0) {
            username = node.value;
          }
          break;
        case autoFillManager.AutoFillType.PASSWORD:
        case autoFillManager.AutoFillType.NEW_PASSWORD:
          if (password.length === 0) {
            password = node.value;
          }
          break;
        default:
          break;
      }
    }

    return [username, password];
  }

  /**
   * 把凭据写入 viewData 对应节点（填充场景回填）
   *
   * @param viewData 系统 viewData（onSuccess 回调返回）
   * @param username 用户名
   * @param password 密码
   * @returns 回填结果（filledCount 为实际写入的节点数）
   */
  applyCredentials(viewData: autoFillManager.ViewData, username: string, password: string): FillApplyResult {
    let filledCount: number = 0;

    const nodes: autoFillManager.PageNodeInfo[] = viewData.pageNodeInfos;
    for (let i: number = 0; i < nodes.length; i++) {
      const node: autoFillManager.PageNodeInfo = nodes[i];
      switch (node.autoFillType) {
        case autoFillManager.AutoFillType.USER_NAME:
          if (username.length > 0) {
            node.value = username;
            filledCount++;
          }
          break;
        case autoFillManager.AutoFillType.PASSWORD:
        case autoFillManager.AutoFillType.NEW_PASSWORD:
          if (password.length > 0) {
            node.value = password;
            filledCount++;
          }
          break;
        default:
          break;
      }
    }

    hilog.info(DOMAIN, TAG, 'applyCredentials: %{public}d nodes filled', filledCount);
    return { success: filledCount > 0, error: filledCount > 0 ? '' : 'no matching nodes', filledCount };
  }
}
