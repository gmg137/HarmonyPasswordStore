import { ThemeColors, Palette, FontSize, Radius, ComponentSize } from '../common/ThemeColors';
import { Strings } from '../common/Strings';

/**
 * 卡片内表单行：左标签 + 右输入框
 *
 * 必须是独立 @ComponentV2 子组件：@Builder 按值传参在参数变化时不会刷新内部 UI
 * （见 SheetFormButtons 的同款说明）。Git 配置页的字段由**异步** load() 填充
 * （Preferences 读取 + HUKS 解封都要 await），首帧渲染时值还是空的；用 @Builder
 * 时这些值填不进去——实测「远程地址」保存后再进页面永远是空白，用户以为没存上。
 * @Param 装饰的 value 随视图模型实时更新，输入框才能显示已保存的配置。
 *
 * @Param label 左侧标签
 * @Param placeholder 占位提示
 * @Param value 当前值（双向效果由 onInput 回写视图模型实现）
 * @Param isPassword 是否作为口令掩码显示
 * @Param onInput 输入回调
 */
@ComponentV2
export struct FormRow {
  @Param label: ResourceStr = '';
  @Param placeholder: ResourceStr = '';
  @Param value: string = '';
  @Param isPassword: boolean = false;
  /** 标签列宽（默认容纳「远程地址」「SSH 密钥」等 4 字标签；无对应宽度令牌） */
  @Param labelWidth: number = 84;
  @Param onInput: (v: string) => void = (v: string): void => {};

  private get colors(): Palette {
    return ThemeColors.getInstance().palette();
  }

  /**
   * 实际标签列宽：按当前语言缩放
   *
   * 传进来的基准值按汉字定（4 字 ≈ 84vp），而拉丁/西里尔字母同字数约占 1.5 倍宽
   * ——不缩放时 `Benutzername`、`Имя пользователя` 这类标签会在列里折行、把整行撑高。
   */
  private get resolvedLabelWidth(): number {
    return Strings.labelWidth(this.labelWidth);
  }

  build() {
    Row() {
      Text(this.label)
        .fontSize(FontSize.BODY)
        .fontColor(this.colors.textSecondary)
        .width(this.resolvedLabelWidth)
        // 兜底：极端长词（如俄语复合词）宁可省略号，也不要折行撑高整行
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      TextInput({ text: this.value, placeholder: this.placeholder })
        .type(this.isPassword ? InputType.Password : InputType.Normal)
        .fontSize(FontSize.SUBTITLE)
        .fontColor(this.colors.textPrimary)
        .placeholderColor(this.colors.textTertiary)
        .placeholderFont({ size: FontSize.SUBTITLE })
        .height(ComponentSize.CONTROL)
        .borderRadius(Radius.MD)
        .backgroundColor(Color.Transparent)
        .padding({ left: 0 })
        .layoutWeight(1)
        .onChange((v: string) => {
          this.onInput(v);
        })
    }
    .width('100%')
    .height(ComponentSize.ROW)
    .alignItems(VerticalAlign.Center)
  }
}
