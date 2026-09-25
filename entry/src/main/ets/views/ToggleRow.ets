import { ThemeColors, Palette, Spacing, FontSize, ComponentSize, Radius } from '../common/ThemeColors';

/**
 * 设置项开关行（标题 + 说明 + 右侧开关）
 *
 * 必须是独立 @ComponentV2 子组件：@Builder 按值传参在参数变化时不会刷新内部 UI
 * （见 FormRow / SheetFormButtons 的同款说明）。「启动时自动同步」的可用性是
 * **异步**算出来的（要读 Git 配置），用 @Builder 时结果永远进不到这一行——
 * 实测表现为：说明文字始终空白、开关始终是禁用态。
 *
 * @Param label 标题
 * @Param sublabel 说明（禁用时放不可用原因）
 * @Param isOn 开关状态
 * @Param isEnabled 是否可用；不可用时整行转次要色并禁用开关
 *   （不能叫 enabled：与 CustomComponent 基类的 enabled 属性重名，编译直接报错）
 * @Param onToggle 切换回调
 */
@ComponentV2
export struct ToggleRow {
  @Param label: string = '';
  @Param sublabel: string = '';
  @Param isOn: boolean = false;
  @Param isEnabled: boolean = true;
  @Param onToggle: (v: boolean) => void = (v: boolean): void => {};

  private get colors(): Palette {
    return ThemeColors.getInstance().palette();
  }

  build() {
    Row() {
      Column() {
        Text(this.label)
          .fontSize(FontSize.SUBTITLE)
          .fontWeight(FontWeight.Medium)
          // 禁用时整行转次要色，避免「看着能点却没反应」
          .fontColor(this.isEnabled ? this.colors.textPrimary : this.colors.textTertiary)
        Text(this.sublabel)
          .fontSize(FontSize.CAPTION)
          .fontColor(this.colors.textTertiary)
          .margin({ top: Spacing.XS })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 禁用时保留用户已保存的状态（置灰即可）：显示为「关」会让人以为是自己关掉的，
      // 而条件恢复后开关又会自己弹回打开，反而更费解
      Toggle({ type: ToggleType.Switch, isOn: this.isOn })
        .selectedColor(this.colors.primary)
        .enabled(this.isEnabled)
        .onChange((v: boolean) => {
          this.onToggle(v);
        })
    }
    .width('100%')
    .constraintSize({ minHeight: ComponentSize.ROW_TWO_LINE })
    .padding({ left: Spacing.ROW_H, right: Spacing.ROW_H, top: Spacing.MD, bottom: Spacing.MD })
    .borderRadius(Radius.CARD)
    .backgroundColor(this.colors.surface)
    .margin({ top: Spacing.CARD_GAP })
  }
}
