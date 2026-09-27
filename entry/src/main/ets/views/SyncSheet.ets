import { SyncViewModel } from '../viewmodel/SyncViewModel';
import { GitLogView } from './GitLogView';
import { Strings } from '../common/Strings';
import { ThemeColors, Palette, ButtonSpec, FontSize, Spacing, Radius, IconSize } from '../common/ThemeColors';
import { SHEET_PAD_TOP, SHEET_PAD_BOTTOM } from '../common/SheetStyles';

/**
 * Git 同步操作面板
 *
 * 提供拉取/推送/提交按钮、仓库状态摘要、冲突提示。
 * 「一键同步」不在此处——它是首页右上角菜单的第一项，避免同一动作有两个入口。
 * 支持深浅色双模式，通过 ThemeColors 调色板驱动。
 */
@ComponentV2
export struct SyncSheet {
  @Param viewModel: SyncViewModel = new SyncViewModel();
  /**
   * 提交历史刷新令牌
   *
   * 拉取/提交成功后自增，GitLogView 以 @Param 接收并用 @Monitor 监听——
   * 提交历史是子组件自己的视图模型，父组件改不了它的状态，只能这样通知它重读。
   */
  @Local logRefreshToken: number = 0;

  private get colors(): Palette {
    return ThemeColors.getInstance().palette();
  }

  aboutToAppear(): void {
    this.viewModel.refreshStatus();
  }

  /** 操作成功则让提交历史重读（失败时保持原样，避免看起来像刷新过了） */
  private refreshLogIfOk(): void {
    if (this.viewModel.lastOperationSuccess) {
      this.logRefreshToken += 1;
    }
  }

  build() {
    Column() {
      // 标题
      Row() {
        Text($r('app.string.group_git'))
          .fontSize(FontSize.TITLE)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.colors.textPrimary)
          .layoutWeight(1)

        // 状态摘要
        Text(this.viewModel.getStatusSummary())
          .fontSize(FontSize.CAPTION)
          .fontColor(this.colors.textTertiary)
      }
      .width('100%')
      .padding({ left: Spacing.CARD, right: Spacing.CARD, bottom: Spacing.SM })

      // 冲突提示
      if (this.viewModel.conflictMessage.length > 0) {
        Text(this.viewModel.conflictMessage)
          .fontSize(FontSize.BODY)
          .fontColor(this.colors.danger)
          .padding({ left: Spacing.CARD, right: Spacing.CARD, bottom: Spacing.SM })
      }

      // 操作中提示
      if (this.viewModel.isSyncing) {
        Row() {
          LoadingProgress()
            .width(IconSize.ACTION)
            .height(IconSize.ACTION)
            .margin({ right: Spacing.SM })
          Text(this.viewModel.operationText)
            .fontSize(FontSize.BODY)
            .fontColor(this.colors.textSecondary)
        }
        .width('100%')
        .padding({ left: Spacing.CARD, right: Spacing.CARD, bottom: Spacing.SM })
      }

      // 操作结果提示
      if (this.viewModel.resultToast.length > 0) {
        Text(this.viewModel.resultToast)
          .fontSize(FontSize.BODY)
          .fontColor(this.viewModel.lastOperationSuccess ? this.colors.success : this.colors.danger)
          .padding({ left: Spacing.CARD, right: Spacing.CARD, bottom: Spacing.SM })
      }

      // TOFU：拉取/推送遇到未信任主机密钥时的指纹确认
      if (this.viewModel.pendingHostKeyFp.length > 0) {
        Column() {
          Row() {
            SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
              .fontSize(IconSize.SM)
              .fontColor([this.viewModel.pendingHostKeyMismatch
                ? this.colors.danger : this.colors.warning])
            Text(this.viewModel.pendingHostKeyMismatch
              ? Strings.get('sync_hostkey_mismatch_title')
              : (this.viewModel.pendingHostKeyType.length > 0
                ? Strings.fmt('sync_hostkey_first_type', this.viewModel.pendingHostKeyType)
                : Strings.get('sync_hostkey_first')))
              .fontSize(FontSize.SUBTITLE)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.colors.textPrimary)
              .margin({ left: Spacing.SM })
          }
          .alignItems(VerticalAlign.Center)

          Text(Strings.fmt('sync_hostkey_fp_label', this.viewModel.pendingHost, this.viewModel.pendingPort))
            .fontSize(FontSize.CAPTION)
            .fontColor(this.colors.textSecondary)
            .margin({ top: Spacing.SM })

          Text(this.viewModel.pendingHostKeyFp)
            .fontSize(FontSize.CAPTION)
            .fontFamily('monospace')
            .fontColor(this.colors.textPrimary)
            .backgroundColor(this.colors.inputBackground)
            .borderRadius(Radius.SM)
            .padding(Spacing.MD)
            .width('100%')
            .margin({ top: Spacing.SM })

          Text(this.viewModel.pendingHostKeyMismatch
            ? $r('app.string.gitcfg_hostkey_mismatch_explain')
            : $r('app.string.sync_hostkey_new_detail'))
            .fontSize(FontSize.CAPTION)
            .fontColor(this.viewModel.pendingHostKeyMismatch
              ? this.colors.danger : this.colors.textTertiary)
            .margin({ top: Spacing.SM })

          Row({ space: Spacing.SM }) {
            Button($r('app.string.sync_reject'))
              .type(ButtonType.Normal)
              .borderRadius(ButtonSpec.SECONDARY_RADIUS)
              .layoutWeight(1)
              .height(ButtonSpec.SECONDARY_HEIGHT)
              .backgroundColor(this.colors.inputBackground)
              .fontColor(this.colors.textSecondary)
              .fontSize(ButtonSpec.FONT_SIZE)
              .onClick(() => {
                this.viewModel.rejectHostKey();
              })

            Button(this.viewModel.pendingHostKeyMismatch
              ? $r('app.string.sync_trust_retry_mismatch') : $r('app.string.sync_trust_retry'))
              .type(ButtonType.Normal)
              .borderRadius(ButtonSpec.PRIMARY_RADIUS)
              .layoutWeight(1)
              .height(ButtonSpec.PRIMARY_HEIGHT)
              .backgroundColor(this.colors.primary)
              .fontColor(this.colors.onPrimary)
              .fontSize(ButtonSpec.FONT_SIZE)
              .enabled(!this.viewModel.isSyncing)
              .onClick(() => {
                this.viewModel.confirmHostKey();
              })
          }
          .width('100%')
          .margin({ top: Spacing.SM })
        }
        .width('100%')
        .padding({ left: Spacing.CARD, right: Spacing.CARD, top: Spacing.SM, bottom: Spacing.SM })
        .backgroundColor(this.colors.surface)
        .borderRadius(Radius.CARD)
        .margin({ top: Spacing.XS })
        .alignItems(HorizontalAlign.Start)
      }

      // 操作按钮
      Row({ space: Spacing.SM }) {
        Button($r('app.string.sync_pull_btn'))
          .type(ButtonType.Normal)
          .borderRadius(ButtonSpec.SECONDARY_RADIUS)
          .layoutWeight(1)
          .height(ButtonSpec.SECONDARY_HEIGHT)
          .fontSize(ButtonSpec.FONT_SIZE)
          .fontWeight(ButtonSpec.FONT_WEIGHT)
          .backgroundColor(this.colors.inputBackground)
          .fontColor(this.colors.textPrimary)
          .enabled(!this.viewModel.isSyncing)
          .onClick(() => {
            this.viewModel.pull().then(() => this.refreshLogIfOk());
          })

        Button($r('app.string.sync_commit_btn'))
          .type(ButtonType.Normal)
          .borderRadius(ButtonSpec.SECONDARY_RADIUS)
          .layoutWeight(1)
          .height(ButtonSpec.SECONDARY_HEIGHT)
          .fontSize(ButtonSpec.FONT_SIZE)
          .fontWeight(ButtonSpec.FONT_WEIGHT)
          .backgroundColor(this.colors.inputBackground)
          .fontColor(this.colors.textPrimary)
          .enabled(!this.viewModel.isSyncing)
          .onClick(() => {
            this.viewModel.commit('').then(() => this.refreshLogIfOk());
          })

        Button($r('app.string.sync_push_btn'))
          .type(ButtonType.Normal)
          .borderRadius(ButtonSpec.SECONDARY_RADIUS)
          .layoutWeight(1)
          .height(ButtonSpec.SECONDARY_HEIGHT)
          .fontSize(ButtonSpec.FONT_SIZE)
          .fontWeight(ButtonSpec.FONT_WEIGHT)
          .backgroundColor(this.colors.inputBackground)
          .fontColor(this.colors.textPrimary)
          .enabled(!this.viewModel.isSyncing)
          .onClick(() => {
            this.viewModel.push().then(() => this.refreshLogIfOk());
          })
      }
      .width('100%')
      .padding({ left: Spacing.CARD, right: Spacing.CARD, top: Spacing.SM })

      // 提交历史（固定高度区域，滚动查看）
      Column() {
        Scroll() {
          GitLogView({ refreshToken: this.logRefreshToken })
        }
        .scrollBar(BarState.Auto)
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ top: Spacing.XS, bottom: Spacing.SM })
    }
    .width('100%')
    .height('100%')
    // 统一面板内边距：顶部让开 dragBar，底部与屏幕下沿保持距离
    .padding({ top: SHEET_PAD_TOP, bottom: SHEET_PAD_BOTTOM })
    .backgroundColor(this.colors.surface)
    .borderRadius({ topLeft: Radius.CARD, topRight: Radius.CARD })
  }
}