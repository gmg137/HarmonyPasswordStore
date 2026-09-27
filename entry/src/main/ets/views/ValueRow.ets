import { ThemeColors, Palette, Spacing, FontSize, ComponentSize, IconSize } from '../common/ThemeColors';

/**
 * 设置项取值行（行首图标 + 标题 + 右侧当前值 + 向下三角）
 *
 * 与 `DropdownRow` 的区别：点击**不弹锚定菜单**，而是由调用方从底部弹半模态
 * 选择面板（候选较多/需要标题时用，如语言选择）。右侧值区与向下三角的取值
 * 语义与 DropdownRow 一致（次要灰 + `sys.color.icon_fourth` 三角，右箭头留给导航行）。
 *
 * **必须是独立 @ComponentV2 子组件**（与 FormRow/ToggleRow 同因）：@Builder 按值传参
 * 在参数变化时不会刷新内部 UI，实测「当前值」节点整个不渲染（语言行的
 * 系统默认/简体中文值区为空即此坑）——`@Param` 传值才有可靠的状态驱动。
 *
 * @Require @Param icon 行首图标
 * @Param label 标题
 * @Param valueText 右侧当前值（随应用语言/设置异步变化的用资源串或状态串）
 * @Param onTapped 点击回调（打开选择面板）
 */
@ComponentV2
export struct ValueRow {
  @Require @Param icon: Resource;
  @Param label: ResourceStr = '';
  @Param valueText: ResourceStr = '';
  @Param onTapped: () => void = (): void => {};

  private get colors(): Palette {
    return ThemeColors.getInstance().palette();
  }

  build() {
    Row() {
      SymbolGlyph(this.icon)
        .fontSize(IconSize.MD)
        .fontColor([this.colors.textSecondary])
        .margin({ right: Spacing.LG })

      Text(this.label)
        .fontSize(FontSize.SUBTITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.colors.textPrimary)
        .layoutWeight(1)

      Text(this.valueText)
        .fontSize(FontSize.BODY)
        .fontColor(this.colors.textSecondary)
        .margin({ right: Spacing.SM })

      SymbolGlyph($r('sys.symbol.arrowtriangle_down_fill'))
        .fontSize(FontSize.BODY)
        .fontColor([$r('sys.color.icon_fourth')])
    }
    .width('100%')
    .constraintSize({ minHeight: ComponentSize.ROW })
    .padding({ top: Spacing.MD, bottom: Spacing.MD })
    .alignItems(VerticalAlign.Center)
    .stateStyles({
      normal: { .backgroundColor(Color.Transparent) },
      pressed: { .backgroundColor(this.colors.pressed) },
    })
    .onClick(() => this.onTapped())
  }
}
