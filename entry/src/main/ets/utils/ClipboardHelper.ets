import { pasteboard } from '@kit.BasicServicesKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { SettingsRepository } from '../model/SettingsRepository';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** hilog 域 */
const DOMAIN: number = 0x0001;
/** hilog 标签 */
const TAG: string = 'ClipboardHelper';

/**
 * 敏感数据剪贴板
 *
 * 项目里有多处复制密码/私钥到剪贴板的地方，此前只有详情页的复制做了定时清除，
 * 其余（密码生成器、自动填充、PGP 密钥导出）复制后永久留在剪贴板。
 * 统一走本类，保证两件事：
 * 1. 写入后必定排定自动清除；
 * 2. 页面销毁时强制清除——否则定时器被取消，敏感内容就永久留着了。
 *
 * **真机上「自动清除不生效」的原因**：清除原本只靠一个进程内 `setTimeout`。
 * 用户复制密码后必然切到别的应用去粘贴，而应用进入后台会被系统**冻结**（更久则被
 * 回收）——被冻结的进程里定时器不会执行，密码就留在剪贴板里，直到用户再回到应用。
 * 现改为复制时**申请短时任务**（`requestSuspendDelay`，需
 * `ohos.permission.KEEP_BACKGROUND_RUNNING`），让进程在后台不被冻结、定时器真正
 * 有机会执行；并在短时任务即将到期（系统会在超时前约 6 秒回调）时**立即清除**
 * ——宁可早清，也不能把密码留在剪贴板里。
 */
export class ClipboardHelper {
  private static instance: ClipboardHelper | null = null;
  /** 待触发的清除定时器（-1 表示无） */
  private clearTimer: number = -1;
  /** 已申请的短时任务 ID（-1 表示无） */
  private suspendRequestId: number = -1;

  private constructor() {
  }

  static getInstance(): ClipboardHelper {
    if (!ClipboardHelper.instance) {
      ClipboardHelper.instance = new ClipboardHelper();
    }
    return ClipboardHelper.instance;
  }

  /**
   * 复制文本到剪贴板，并排定自动清除
   */
  async copy(text: string): Promise<boolean> {
    try {
      const pasteData: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      await pasteboard.getSystemPasteboard().setData(pasteData);
      this.scheduleClear();
      return true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'copy failed: %{public}s', JSON.stringify(e));
      return false;
    }
  }

  /**
   * 立即清除剪贴板并取消待执行的定时器与短时任务
   */
  clearNow(): void {
    this.cancelScheduled();
    this.cancelTransientTask();
    try {
      pasteboard.getSystemPasteboard().clearData();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'clearNow failed: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 页面销毁时调用
   *
   * 只取消定时器是不够的：那样敏感内容会永久留在剪贴板。必须顺带清掉。
   */
  onDispose(): void {
    this.clearNow();
  }

  private scheduleClear(): void {
    this.cancelScheduled();
    const timeoutMs: number = SettingsRepository.getInstance().getSettings().clipboardTimeout;
    const delay: number = timeoutMs > 0 ? timeoutMs : 30_000;
    this.requestTransientTask();
    this.clearTimer = setTimeout(() => {
      this.clearTimer = -1;
      this.clearClipboard('scheduled');
    }, delay);
  }

  /**
   * 申请短时任务：让进程在后台不被冻结，定时器才有机会执行
   *
   * 申请失败（当日配额用尽等）不阻断复制流程——前台场景下普通定时器仍然有效。
   */
  private requestTransientTask(): void {
    try {
      const info: backgroundTaskManager.DelaySuspendInfo =
        backgroundTaskManager.requestSuspendDelay('清空剪贴板中的敏感内容', () => {
          // 系统在短时任务到期前约 6 秒回调：此刻进程马上要被冻结，
          // 立即清除（宁可早清，也不能把密码留在剪贴板里）
          hilog.info(DOMAIN, TAG, 'transient task expiring, clearing clipboard now');
          this.suspendRequestId = -1;
          this.clearClipboard('transient-expiring');
        });
      this.suspendRequestId = info.requestId;
      hilog.info(DOMAIN, TAG, 'transient task requested id=%{public}d delay=%{public}dms',
        info.requestId, info.actualDelayTime);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'requestSuspendDelay failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 清除剪贴板并释放短时任务（reason 仅用于日志定位） */
  private clearClipboard(reason: string): void {
    try {
      pasteboard.getSystemPasteboard().clearData();
      hilog.info(DOMAIN, TAG, 'clipboard cleared (%{public}s)', reason);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'clipboard clear failed (%{public}s): %{public}s', reason, JSON.stringify(e));
    }
    this.cancelTransientTask();
  }

  private cancelTransientTask(): void {
    if (this.suspendRequestId === -1) {
      return;
    }
    try {
      backgroundTaskManager.cancelSuspendDelay(this.suspendRequestId);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'cancelSuspendDelay failed: %{public}s', JSON.stringify(e));
    }
    this.suspendRequestId = -1;
  }

  private cancelScheduled(): void {
    if (this.clearTimer !== -1) {
      clearTimeout(this.clearTimer);
      this.clearTimer = -1;
    }
  }
}
