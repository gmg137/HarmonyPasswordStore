import { ThemeColors, Palette, Radius, Spacing, FontSize, IconSize, ButtonSpec } from '../common/ThemeColors';

/**
 * 主机密钥指纹确认弹窗（TOFU）
 *
 * 用自绘弹窗而不是系统 `showAlertDialog`：后者的内边距由系统决定、改不了，
 * 标题紧贴弹窗上边缘（实测反馈「文字离上边缘太近」）；自绘还能把指纹用
 * 等宽字体单独框出来，方便用户逐字与服务器管理员核对。
 *
 * 打开/关闭由页面负责（`getPromptAction().openCustomDialog/closeCustomDialog`，
 * 两者都要兜异常——同步抛出与 Promise reject 都要处理，否则失败会留下关不掉的遮罩）。
 */
@ComponentV2
export struct HostKeyConfirmDialog {
  /** 标题（首次连接 / 不一致告警） */
  @Param title: string = '';
  /** 主机与密钥类型说明行 */
  @Param hostLine: string = '';
  /** 主机密钥指纹（等宽字体单独展示） */
  @Param fingerprint: string = '';
  /** 解释文案（首次连接与不一致两种口径） */
  @Param explanation: string = '';
  /** 指纹与已有记录不一致（可能中间人）：警示色更重、确认按钮用危险色 */
  @Param mismatch: boolean = false;
  /** 确认按钮文案（克隆流程与测试连接流程的后续动作不同，文案要各自贴合） */
  @Param confirmLabel: string = '信任并连接';
  /** 拒绝（放弃本次连接） */
  @Param onReject: () => void = (): void => {};
  /** 确认（追加/覆盖信任记录后继续连接） */
  @Param onConfirm: () => void = (): void => {};

  private get colors(): Palette {
    return ThemeColors.getInstance().palette();
  }

  build() {
    Column() {
      Row() {
        SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
          .fontSize(IconSize.SM)
          .fontColor([this.mismatch ? this.colors.danger : this.colors.warning])

        Text(this.title)
          .fontSize(FontSize.SUBTITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.colors.textPrimary)
          .layoutWeight(1)
          .margin({ left: Spacing.SM })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(this.hostLine)
        .fontSize(FontSize.CAPTION)
        .fontColor(this.colors.textSecondary)
        .width('100%')
        .margin({ top: Spacing.MD })

      Text(this.fingerprint)
        .fontSize(FontSize.CAPTION)
        .fontFamily('monospace')
        .fontColor(this.colors.textPrimary)
        .backgroundColor(this.colors.inputBackground)
        .borderRadius(Radius.SM)
        .padding(Spacing.MD)
        .width('100%')
        .margin({ top: Spacing.SM })

      Text(this.explanation)
        .fontSize(FontSize.CAPTION)
        .fontColor(this.colors.textTertiary)
        .width('100%')
        .margin({ top: Spacing.SM })

      Row({ space: ButtonSpec.ROW_GAP }) {
        Button('拒绝')
          .type(ButtonType.Normal)
          .borderRadius(ButtonSpec.SECONDARY_RADIUS)
          .layoutWeight(1)
          .height(ButtonSpec.SECONDARY_HEIGHT)
          .fontSize(ButtonSpec.FONT_SIZE)
          // 收紧横向内边距：默认内边距会把 5 字标签（「信任并克隆」）挤成省略号
          .padding({ left: Spacing.SM, right: Spacing.SM })
          .backgroundColor(this.colors.inputBackground)
          .fontColor(this.colors.textPrimary)
          .onClick(() => {
            this.onReject();
          })

        Button(this.confirmLabel)
          .type(ButtonType.Normal)
          .borderRadius(ButtonSpec.PRIMARY_RADIUS)
          .layoutWeight(1)
          .height(ButtonSpec.PRIMARY_HEIGHT)
          .fontSize(ButtonSpec.FONT_SIZE)
          .fontWeight(ButtonSpec.FONT_WEIGHT)
          .padding({ left: Spacing.SM, right: Spacing.SM })
          .backgroundColor(this.mismatch ? this.colors.danger : this.colors.primary)
          .fontColor(this.colors.onPrimary)
          .onClick(() => {
            this.onConfirm();
          })
      }
      .width('100%')
      .margin({ top: Spacing.LG })
    }
    // 与首页密钥口令弹窗同款尺寸/留白：86% 宽 + 24vp 四周内边距（标题不再贴顶）
    .width('86%')
    .padding(Spacing.XL)
    .borderRadius(Radius.LG)
    .backgroundColor(this.colors.surface)
    .alignItems(HorizontalAlign.Start)
  }
}
