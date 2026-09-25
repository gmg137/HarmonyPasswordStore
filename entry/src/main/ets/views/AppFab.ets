import { ThemeColors, Palette, IconSize, Radius } from '../common/ThemeColors';

/**
 * 浮动操作按钮（FAB）
 *
 * 对齐鸿蒙规范：56vp 圆形、强调色底、白色 28vp 加号图标、外阴影。
 * 抽成独立组件的原因：此前三个页面各自内联同一份字面量（`width(56)/height(56)`、
 * `fontSize(28)`、`shadow radius 8`、`position({x:'82%',y:'88%'})`），
 * 改一处样式要改三处、且极易走样。
 *
 * 定位（`position`）仍由父容器负责——各页的列表结构不同，FAB 需要贴在各自的容器上。
 */
@ComponentV2
export struct AppFab {
  /** 点击回调 */
  @Param onTap: () => void = (): void => {};

  private get colors(): Palette {
    return ThemeColors.getInstance().palette();
  }

  build() {
    Button({ type: ButtonType.Circle, stateEffect: true }) {
      Text('+')
        .fontSize(IconSize.FAB_GLYPH)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.colors.onPrimary)
    }
    .width(IconSize.FAB)
    .height(IconSize.FAB)
    .backgroundColor(this.colors.primary)
    .shadow({ radius: Radius.SM, color: this.colors.primarySoft, offsetY: 2 })
    .onClick(() => {
      this.onTap();
    })
  }
}
