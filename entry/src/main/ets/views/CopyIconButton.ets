import { ThemeColors, Palette, ComponentSize, IconSize, Spacing } from '../common/ThemeColors';

/**
 * 圆形复制图标按钮（详情页各字段行共用）
 *
 * 必须统一成一个组件，而不是各行内联 SymbolGlyph——内联时很容易漏掉包裹层，
 * 于是同一个图标在不同卡片里**右缘对不齐、热区大小也不同**：
 * 裸 SymbolGlyph 只有 ~22vp 宽（手指不好点），而带 32vp 圆形 Button 包裹的行
 * 图标会再内缩约 5vp，两者放在一起肉眼可见地不齐（实测用户名行 vs 备注行）。
 *
 * 统一口径：32vp 圆形透明 Button（`ComponentSize.CONTROL_SMALL`）+
 * 图标 `IconSize.SM` + 左侧 `Spacing.SM`。透明底是为了不破坏卡片观感，
 * 按压反馈由 `stateEffect` 提供。
 */
@ComponentV2
export struct CopyIconButton {
  /** 无障碍朗读文本（如「复制用户名」） */
  @Param label: string = '复制';
  @Param onTap: () => void = (): void => {};

  private get colors(): Palette {
    return ThemeColors.getInstance().palette();
  }

  build() {
    Button({ type: ButtonType.Circle, stateEffect: true }) {
      SymbolGlyph($r('sys.symbol.plus_square_dashed_on_square'))
        .fontSize(IconSize.SM)
        .fontColor([this.colors.textPrimary])
    }
    .width(ComponentSize.CONTROL_SMALL)
    .height(ComponentSize.CONTROL_SMALL)
    .backgroundColor(Color.Transparent)
    .margin({ left: Spacing.SM })
    .accessibilityText(this.label)
    .onClick(() => {
      this.onTap();
    })
  }
}
