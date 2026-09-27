import { ThemeColors, Palette, Spacing, ButtonSpec } from '../common/ThemeColors';
import { Strings } from '../common/Strings';

/**
 * 半模态表单底部按钮行（取消 / 确认）
 *
 * 必须是独立 @ComponentV2 子组件：@Builder 按值传参在参数变化时
 * 不会刷新内部 UI（官方 FAQ faqs-arkui-1078），会导致确认按钮永不激活。
 * @Param 装饰的 canConfirm/isBusy 随父组件状态实时更新。
 *
 * SSH 密钥管理页与 PGP 密钥管理页共用，保证两个弹窗的底部按钮行为一致。
 */
@ComponentV2
export struct SheetFormButtons {
  @Param confirmLabel: string = '';
  @Param isBusy: boolean = false;
  @Param canConfirm: boolean = false;
  @Param onConfirm: () => void = (): void => {};
  @Param onCancel: () => void = (): void => {};

  private get colors(): Palette {
    return ThemeColors.getInstance().palette();
  }

  build() {
    Row({ space: ButtonSpec.ROW_GAP }) {
      // 次操作：中性底 + 强调色文字（鸿蒙规范里 TEXTUAL/NORMAL 两种都可，此处用 NORMAL）
      Button($r('app.string.common_cancel'))
        .type(ButtonType.Normal)
        .borderRadius(ButtonSpec.SECONDARY_RADIUS)
        .layoutWeight(1)
        .height(ButtonSpec.SECONDARY_HEIGHT)
        .backgroundColor(this.colors.neutralButton)
        .fontSize(ButtonSpec.FONT_SIZE)
        .fontWeight(ButtonSpec.FONT_WEIGHT)
        .fontColor(this.colors.primary)
        .onClick(() => {
          this.onCancel();
        })

      // 主操作：强调色底 + onPrimary 文字（不要用 Color.White：深色主题下需随调色板走）
      Button(this.isBusy ? Strings.get('common_processing') : this.confirmLabel)
        .type(ButtonType.Normal)
        .borderRadius(ButtonSpec.PRIMARY_RADIUS)
        .layoutWeight(1)
        .height(ButtonSpec.PRIMARY_HEIGHT)
        .backgroundColor(this.colors.primary)
        .fontSize(ButtonSpec.FONT_SIZE)
        .fontWeight(ButtonSpec.FONT_WEIGHT)
        .fontColor(this.colors.onPrimary)
        .enabled(this.canConfirm && !this.isBusy)
        .opacity(this.canConfirm ? 1 : 0.4)
        .onClick(() => {
          this.onConfirm();
        })
    }
    .width('100%')
  }
}
