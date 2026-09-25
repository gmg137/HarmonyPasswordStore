import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Palette } from './ThemeColors';

const DOMAIN: number = 0x0000;
const TAG: string = 'SystemBars';

/** 系统栏透明：内容（含弹窗遮罩）延伸到状态栏/导航栏之下，由应用自己绘制底色 */
const TRANSPARENT: string = '#00000000';

/**
 * 系统栏（状态栏/导航栏）统一设置
 *
 * ## 为什么必须是透明
 *
 * 曾把 `statusBarColor` 设成页面背景色（不透明），并在弹窗遮罩展示期间把它换成
 * 「遮罩后颜色」来补偿——因为当时实测「遮罩被布局在状态栏避让区内，压不到条带」。
 * 那个结论**是错的**：不透明条带由系统绘制在**应用内容与遮罩之上**，看起来像
 * 「遮罩压不到」，实为条带盖住了遮罩。代价是弹窗弹出时状态栏**先瞬间跳色**、
 * 页面遮罩随后才渐显，视觉上分两步（模拟器实测：条带首帧即 218，页面还在 239→230 渐变）。
 *
 * 正确做法（与 TKeShi 一致）：条带保持**全透明**，让页面底色与弹窗遮罩自然铺到
 * 条带之下。实测透明后弹窗中条带读数 218、页面 230，与遮罩下的页面同步变暗，
 * 无需任何颜色补偿（补偿机制已整体删除）。
 *
 * 只有 `statusBarContentColor`（时间/电量图标的颜色）仍需按主题设置——
 * 条带现在显示的是页面底色，浅色主题配深色图标、深色主题配浅色图标。
 *
 * EntryAbility 启动时 attach + applyBase；主题切换时 applyBase 重新生效。
 */
export class SystemBars {
  private static instance?: SystemBars;

  static getInstance(): SystemBars {
    if (!SystemBars.instance) {
      SystemBars.instance = new SystemBars();
    }
    return SystemBars.instance;
  }

  private mainWindow: window.Window | null = null;
  /** 系统栏图标/文字颜色（跟随主题调色板） */
  private baseContent: string = '#182431';

  /** EntryAbility 拿到主窗口后立即调用；未 attach 前 applyBase 为 no-op */
  attach(mainWindow: window.Window): void {
    this.mainWindow = mainWindow;
  }

  /** 应用主题（启动初始化与主题切换共用）：系统栏保持透明，只更新图标颜色 */
  applyBase(palette: Palette): void {
    this.baseContent = palette.textPrimary;
    this.apply();
  }

  private apply(): void {
    if (this.mainWindow === null) {
      return;
    }
    try {
      this.mainWindow.setWindowSystemBarProperties({
        statusBarColor: TRANSPARENT,
        statusBarContentColor: this.baseContent,
        navigationBarColor: TRANSPARENT,
        navigationBarContentColor: this.baseContent,
      });
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'setWindowSystemBarProperties failed: %{public}s', JSON.stringify(err));
    }
  }
}
