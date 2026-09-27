import { ThemeColors, Palette, Spacing, FontSize, ComponentSize, IconSize } from '../common/ThemeColors';

/**
 * 设置项开关行（行首图标 + 标题 + 说明 + 右侧开关）
 *
 * **行组件，不带卡片外观**：设置页的分组卡片由页面里的 `ListItemGroup` 承载
 * （对齐 HarmonyOS 官方 UX 样例 `HarmonyOSComponentUXExamples` 的 `EfficientList`：
 * 组给背景 + 圆角 + 横向内边距 + 分隔线，行只给高度与内容）。因此本组件
 * 不再有 backgroundColor / borderRadius / margin-top / 横向内边距——横向内边距
 * 若行内再给，文字起点会比样例的「图标 24 + 间距 16」更深，且与分隔线错位。
 *
 * 行高对齐官方阶梯：有说明文字 = 双行 64vp（`ROW_TWO_LINE`），无则单行 56vp
 * （`ROW`）。说明文字很长（如生物识别不可用原因）时仍允许增高。
 *
 * 必须是独立 @ComponentV2 子组件：@Builder 按值传参在参数变化时不会刷新内部 UI
 * （见 FormRow / SheetFormButtons 的同款说明）。「启动时自动同步」的可用性是
 * **异步**算出来的（要读 Git 配置），用 @Builder 时结果永远进不到这一行——
 * 实测表现为：说明文字始终空白、开关始终是禁用态。
 *
 * @Require @Param icon 行首图标（sys.symbol 资源）
 * @Param label 标题
 * @Param sublabel 说明（禁用时放不可用原因）
 * @Param isOn 开关状态
 * @Param isEnabled 是否可用；不可用时整行转次要色并禁用开关
 *   （不能叫 enabled：与 CustomComponent 基类的 enabled 属性重名，编译直接报错）
 * @Param onToggle 切换回调
 */
@ComponentV2
export struct ToggleRow {
  @Require @Param icon: Resource;
  @Param label: ResourceStr = '';
  @Param sublabel: ResourceStr = '';
  @Param isOn: boolean = false;
  @Param isEnabled: boolean = true;
  @Param onToggle: (v: boolean) => void = (v: boolean): void => {};

  private get colors(): Palette {
    return ThemeColors.getInstance().palette();
  }

  /** 双行（有说明）64vp / 单行 56vp，与官方列表行阶梯一致（资源串说明视为有） */
  private get rowMinHeight(): number {
    const hasSub: boolean = typeof this.sublabel === 'string' ? this.sublabel.length > 0 : true;
    return hasSub ? ComponentSize.ROW_TWO_LINE : ComponentSize.ROW;
  }

  build() {
    Row() {
      SymbolGlyph(this.icon)
        .fontSize(IconSize.MD)
        // 行首图标与标题同用次要灰（对齐 FolderTreeView 的行首图标惯例）；
        // 禁用时随标题一起再降一档
        .fontColor([this.isEnabled ? this.colors.textSecondary : this.colors.textTertiary])
        .margin({ right: Spacing.LG })

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
    .constraintSize({ minHeight: this.rowMinHeight })
    .padding({ top: Spacing.MD, bottom: Spacing.MD })
  }
}
