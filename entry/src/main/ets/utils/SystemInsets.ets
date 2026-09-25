import { display } from '@kit.ArkUI';

/**
 * 系统栏避让尺寸
 *
 * 应用是沉浸式布局（`setWindowLayoutFullScreen(true)`），内容会延伸到状态栏与
 * 底部导航条之下，页面内**自己绘制**的固定栏必须自行避让，否则会贴边、
 * 甚至把点按区压在系统手势区上。
 *
 * 高度由 `EntryAbility` 在窗口创建时写入 `AppStorage`（`statusBarHeightPx`
 * 取顶部、`bottomInsetPx` 取 `TYPE_SYSTEM` 与 `TYPE_NAVIGATION_INDICATOR`
 * 两者的较大值——手势导航下前者常为 0、三键导航下后者常为 0，只取一个必漏）。
 *
 * 页面不要各自换算 px→vp，统一走这里；新增姿态变化（折叠屏旋转等）时也只需改一处。
 */
export class SystemInsets {
  /** 状态栏高度（vp；未就绪时为 0，调用方据此退化即可） */
  static topVp(): number {
    return SystemInsets.pxToVp(AppStorage.get<number>('statusBarHeightPx') ?? 0);
  }

  /** 底部系统栏（导航条/手势条）高度（vp） */
  static bottomVp(): number {
    return SystemInsets.pxToVp(AppStorage.get<number>('bottomInsetPx') ?? 0);
  }

  /** px → vp（px2vp 已废弃，改用 display 密度换算；取不到密度时退化为 0） */
  private static pxToVp(px: number): number {
    if (px <= 0) {
      return 0;
    }
    try {
      const density: number = display.getDefaultDisplaySync().densityPixels;
      return density > 0 ? px / density : 0;
    } catch (e) {
      return 0;
    }
  }
}
