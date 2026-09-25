import { ThemeColors, Palette, Spacing, FontSize, IconSize, ComponentSize } from '../common/ThemeColors';

/**
 * 空状态占位（图标 + 标题 + 说明）
 *
 * 此前每个列表页各写一份（图标尺寸 48/56 不一、文案层级与间距不一）。
 * 对齐鸿蒙规范：插图 56vp、标题 Subtitle(16) 次要色、说明 Caption(12) 弱化色，
 * 整体在可用区域内居中。
 */
@ComponentV2
export struct EmptyState {
  /** 图标（sys.symbol 资源） */
  @Param icon: Resource = $r('sys.symbol.lock');
  /** 主文案 */
  @Param title: string = '';
  /** 补充说明（可选） */
  @Param hint: string = '';

  private get colors(): Palette {
    return ThemeColors.getInstance().palette();
  }

  build() {
    Column() {
      SymbolGlyph(this.icon)
        .fontSize(IconSize.EMPTY)
        .fontColor([this.colors.textTertiary])

      Text(this.title)
        .fontSize(FontSize.SUBTITLE)
        .fontColor(this.colors.textSecondary)
        .margin({ top: Spacing.MD })

      if (this.hint.length > 0) {
        Text(this.hint)
          .fontSize(FontSize.CAPTION)
          .fontColor(this.colors.textTertiary)
          .margin({ top: Spacing.XS })
      }
    }
    .width('100%')
    .constraintSize({ minHeight: ComponentSize.EMPTY_ICON * 3 })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding(Spacing.XL)
  }
}
