import { ThemeColors, Palette, Spacing, FontSize, IconSize, ComponentSize } from '../common/ThemeColors';
import { RouteManager } from '../common/RouteManager';

/**
 * 页面标题栏（返回按钮 + 标题 + 可选右侧动作）
 *
 * 为什么自绘而不直接用 `NavDestination` 的系统标题栏：系统标题栏在深色模式下
 * 会先渲染浅色底再切换，出现白底闪屏，故各页统一 `hideTitleBar(true)` 后自绘。
 *
 * 对齐鸿蒙规范：
 * - 返回按钮是 **40vp 圆形可点区域**（`IconSize.BACK_BUTTON`），图标 24vp，
 *   底色 `inputBackground`（浅色浅灰 / 深色深灰），用 `Button` 以获得系统按压反馈；
 * - 标题 `FontSize.DISPLAY_MD`(24) Bold —— 对应系统标题栏 Title_M 的字号；
 *   根列表页的大标题另用 `FontSize.DISPLAY_LG`(28)；
 * - 水平内边距与页面内容一致（`Spacing.PAGE_H`），标题栏高度 `ComponentSize.TITLE_BAR`(56vp)。
 * **所有页面（含首页/目录页）都必须用本组件**，否则标题字号、栏高与返回按钮样式会各不相同。
 */
@ComponentV2
export struct AppTitleBar {
  /** 标题文字（支持资源串：i18n 页面传 $r('app.string.xxx')） */
  @Param title: ResourceStr = '';
  /** 右侧动作区（可选，不传则不渲染） */
  @BuilderParam actions: () => void = this.noActions;

  @Builder
  noActions() {
  }

  private get colors(): Palette {
    return ThemeColors.getInstance().palette();
  }

  build() {
    Row() {
      // 返回按钮：40vp 圆形，Button 自带按压反馈（Row/SymbolGlyph 作可点区域没有反馈）
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(IconSize.BACK)
          .fontColor([this.colors.textPrimary])
      }
      .width(IconSize.BACK_BUTTON)
      .height(IconSize.BACK_BUTTON)
      .backgroundColor(this.colors.inputBackground)
      .margin({ right: Spacing.MD })
      .onClick(() => {
        RouteManager.getInstance().pop();
      })

      Text(this.title)
        .fontSize(FontSize.DISPLAY_MD)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.colors.textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      this.actions()
    }
    .width('100%')
    // 高度统一取 ComponentSize.TITLE_BAR(56 = 40 圆形返回按钮 + 上下各 8 内边距)，
    // 所有页面标题栏高度一致；不再用 minHeight 让内容撑高
    .height(ComponentSize.TITLE_BAR)
    .padding({
      left: Spacing.PAGE_H,
      right: Spacing.PAGE_H,
      top: Spacing.SM,
      bottom: Spacing.SM,
    })
    .alignItems(VerticalAlign.Center)
  }
}
