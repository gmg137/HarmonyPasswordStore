import { GitLogViewModel } from '../viewmodel/GitLogViewModel';
import { GitCommitInfo } from '../utils/GitClient';
import { ThemeColors, Palette, Spacing, FontSize, IconSize, ComponentSize, DividerSpec } from '../common/ThemeColors';

/**
 * Git 提交历史视图
 *
 * 展示提交记录列表（哈希、摘要、作者、时间），
 * 可嵌入同步面板或独立页面使用。
 */
@ComponentV2
export struct GitLogView {
  @Local viewModel: GitLogViewModel = new GitLogViewModel();
  /** 外部刷新令牌（父组件拉取/提交成功后自增） */
  @Param refreshToken: number = 0;

  private get colors(): Palette {
    return ThemeColors.getInstance().palette();
  }

  aboutToAppear(): void {
    this.viewModel.loadLog();
  }

  /** 父组件完成拉取/提交后自动重读提交历史 */
  @Monitor('refreshToken')
  onRefreshTokenChange(): void {
    this.viewModel.loadLog();
  }

  build() {
    Column() {
      // 标题行
      Row() {
        Text($r('app.string.git_log_title'))
          .fontSize(FontSize.SUBTITLE)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.colors.textPrimary)
          .layoutWeight(1)

        // 可点文字：补足 40vp 可点区域并给按压态（纯 Text 默认无任何反馈）
        Text($r('app.string.refresh'))
          .fontSize(FontSize.BODY)
          .fontColor(this.colors.primary)
          .textAlign(TextAlign.Center)
          .constraintSize({ minWidth: ComponentSize.CONTROL_SMALL * 2, minHeight: ComponentSize.CONTROL_SMALL })
          .stateStyles({
            normal: { .backgroundColor(Color.Transparent) },
            pressed: { .backgroundColor(this.colors.pressed) },
          })
          .borderRadius(ComponentSize.CONTROL_SMALL / 2)
          .onClick(() => {
            this.viewModel.loadLog();
          })
      }
      .width('100%')
      .padding({ left: Spacing.CARD, right: Spacing.CARD, top: Spacing.MD, bottom: Spacing.SM })

      // 加载中
      if (this.viewModel.isLoading) {
        Row() {
          LoadingProgress()
            .width(IconSize.MD)
            .height(IconSize.MD)
          Text($r('app.string.common_loading'))
            .fontSize(FontSize.CAPTION)
            .fontColor(this.colors.textTertiary)
            .margin({ left: Spacing.SM })
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .padding(Spacing.XL)
      } else if (this.viewModel.errorMessage.length > 0) {
        // 错误/非仓库提示
        Text(this.viewModel.errorMessage)
          .fontSize(FontSize.CAPTION)
          .fontColor(this.colors.textTertiary)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding(Spacing.XL)
      } else if (this.viewModel.commits.length === 0) {
        // 空历史
        Text($r('app.string.git_log_empty'))
          .fontSize(FontSize.CAPTION)
          .fontColor(this.colors.textTertiary)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding(Spacing.XL)
      } else {
        // 提交列表
        List() {
          ForEach(this.viewModel.commits, (commit: GitCommitInfo) => {
            ListItem() {
              Row() {
                Column() {
                  Text(commit.summary)
                    .fontSize(FontSize.BODY)
                    .fontColor(this.colors.textPrimary)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })

                  Row() {
                    Text(this.viewModel.shortHash(commit.hash))
                      .fontSize(FontSize.CAPTION)
                      .fontColor(this.colors.primary)
                      .fontFamily('monospace')
                    Text(commit.authorName)
                      .fontSize(FontSize.CAPTION)
                      .fontColor(this.colors.textSecondary)
                      .margin({ left: Spacing.SM })
                    Blank()
                    Text(this.viewModel.formatTime(commit.timestamp))
                      .fontSize(FontSize.CAPTION)
                      .fontColor(this.colors.textTertiary)
                  }
                  .width('100%')
                  .margin({ top: Spacing.XS })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
              }
              .width('100%')
              .height(ComponentSize.ROW_TWO_LINE)
              .padding({ left: Spacing.CARD, right: Spacing.CARD })
              .alignItems(VerticalAlign.Center)
            }
          }, (commit: GitCommitInfo) => commit.hash)
        }
        // 提交之间用缩进分隔线（对齐 comp_divider：1px、文本行缩进 16vp）
        .divider({
          strokeWidth: DividerSpec.STROKE,
          color: this.colors.divider,
          startMargin: DividerSpec.INSET_TEXT,
          endMargin: DividerSpec.INSET_TEXT,
        })
        // 滑到上下边界时给回弹动效反馈
        .edgeEffect(EdgeEffect.Spring)
        .width('100%')
        .constraintSize({ minHeight: ComponentSize.EMPTY_ICON * 2 })
      }
    }
    .width('100%')
  }
}
