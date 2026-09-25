import { hilog } from '@kit.PerformanceAnalysisKit';

/** hilog 域 */
const DOMAIN: number = 0x0001;
/** hilog 标签 */
const TAG: string = 'ToastUtil';

/**
 * 统一的 Toast 提示
 *
 * 两件事在这里一次解决：
 * 1. **必须走 UIContext**：全局 `promptAction.showToast` 自 API 18 废弃，且直接调用会
 *    引发「UI 上下文不明确」（Toast 可能显示在错误的窗口上）。
 * 2. **必须包 try/catch**：`showToast` 声明会抛异常（参数错误/内部错误），ArkTS 编译器
 *    对未处理的抛出调用会告警「Function may throw exceptions」，而 Toast 失败本就
 *    不该影响业务流程——记录日志即可。
 *
 * @param uiContext 页面通过 `this.getUIContext()` 传入
 * @param message 提示内容
 * @param duration 显示时长（毫秒）
 */
export function showToastSafe(uiContext: UIContext, message: string, duration: number = 2000): void {
  try {
    uiContext.getPromptAction().showToast({ message: message, duration: duration });
  } catch (e) {
    hilog.error(DOMAIN, TAG, 'showToast failed: %{public}s',
      e instanceof Error ? `${e.name}: ${e.message}` : String(e));
  }
}
