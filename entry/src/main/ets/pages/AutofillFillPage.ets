import { AutofillFillViewModel } from '../viewmodel/AutofillFillViewModel';
import { AppTitleBar } from '../views/AppTitleBar';
import { CredentialMatch } from '../autofill/CredentialMatcher';
import { RouteManager } from '../common/RouteManager';
import { ThemeColors, Palette, ButtonSpec, FontSize, Spacing, Radius, IconSize } from '../common/ThemeColors';
import { EmptyState } from '../views/EmptyState';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'AutofillFillPage';

/**
 * 填充建议页
 *
 * 展示按请求方标识（包名/域名）匹配的凭据候选列表，
 * 用户选择后解密，支持直接返回填充结果或复制降级。
 */
@ComponentV2
export struct AutofillFillPage {
  @Local viewModel: AutofillFillViewModel = new AutofillFillViewModel();

  private get colors(): Palette {
    return ThemeColors.getInstance().palette();
  }

  aboutToAppear(): void {
    const stack = RouteManager.getInstance().getPathStack();
    const path: NavPathInfo | undefined = stack.getParamByIndex(0) as NavPathInfo | undefined;
    let identity: string = '';
    if (path && path.param) {
      const param: Record<string, string> = path.param as Record<string, string>;
      identity = param['identity'] ?? '';
    }
    this.viewModel.load(identity);
  }

  @Builder
  candidateItem(match: CredentialMatch) {
    Row() {
      Column() {
        Text(match.name)
          .fontSize(FontSize.SUBTITLE)
          .fontColor(this.colors.textPrimary)
          .fontWeight(FontWeight.Medium)
        Text(this.viewModel.candidateSubtitle(match))
          .fontSize(FontSize.CAPTION)
          .fontColor(this.colors.textTertiary)
          .margin({ top: Spacing.XS })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.viewModel.isDecrypting && this.viewModel.selectedPath === match.relativePath) {
        LoadingProgress()
          .width(IconSize.ACTION)
          .height(IconSize.ACTION)
      }
    }
    .width('100%')
    .padding(Spacing.CARD)
    .backgroundColor(this.colors.surface)
    .borderRadius(Radius.CARD)
    .margin({ top: Spacing.CARD_GAP })
    .stateStyles({
      normal: { .backgroundColor(this.colors.surface) },
      pressed: { .backgroundColor(this.colors.pressed) },
    })
    .onClick(() => {
      this.onCandidateSelected(match);
    })
  }

  /**
   * 候选被选中：解密成功后展示复制操作区（剪贴板降级路径）
   *
   * native autoFillManager 联调就绪后，此处改为回传 viewData 填充结果。
   */
  private async onCandidateSelected(match: CredentialMatch): Promise<void> {
    const success: boolean = await this.viewModel.select(match);
    if (success) {
      // 解密成功后不立即关闭页面，展示复制操作区供用户选择
      hilog.info(DOMAIN, TAG, 'candidate selected, showing copy options');
    }
  }

  build() {
    NavDestination() {
      Column() {
        AppTitleBar({ title: '填充建议' })

        // 目标身份提示（页内大标题已由标题栏承担，这里只留副标题）
        if (this.viewModel.identity.length > 0) {
          Text(`为 ${this.viewModel.identity} 选择凭据`)
            .fontSize(FontSize.CAPTION)
            .fontColor(this.colors.textTertiary)
            .width('100%')
            .padding({ left: Spacing.PAGE_H, right: Spacing.PAGE_H, top: Spacing.SM, bottom: Spacing.SM })
        }

        Scroll() {
          Column() {
            // 加载中
            if (this.viewModel.isLoading) {
              Row() {
                LoadingProgress()
                  .width(IconSize.MD)
                  .height(IconSize.MD)
                Text('匹配中...')
                  .fontSize(FontSize.CAPTION)
                  .fontColor(this.colors.textTertiary)
                  .margin({ left: Spacing.SM })
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
              .padding(Spacing.XL)
            } else if (this.viewModel.candidates.length === 0) {
              // 无匹配
              EmptyState({
                icon: $r('sys.symbol.magnifyingglass'),
                title: '没有匹配的密码',
                hint: '可在主界面搜索后手动复制',
              })
            } else {
              // 候选列表
              ForEach(this.viewModel.candidates, (match: CredentialMatch) => {
                this.candidateItem(match)
              }, (match: CredentialMatch) => match.relativePath)
            }

            // 错误提示
            if (this.viewModel.errorMessage.length > 0) {
              Text(this.viewModel.errorMessage)
                .fontSize(FontSize.CAPTION)
                .fontColor(this.colors.danger)
                .margin({ top: Spacing.MD })
            }

            // 系统自动填充成功提示
            if (this.viewModel.fillAppliedMessage.length > 0) {
              Text(this.viewModel.fillAppliedMessage)
                .fontSize(FontSize.CAPTION)
                .fontColor(this.colors.success)
                .margin({ top: Spacing.MD })
            }

            // 解密成功后的降级操作（复制）
            if (this.viewModel.result !== null) {
              Column() {
                Text('已解锁，请选择操作')
                  .fontSize(FontSize.CAPTION)
                  .fontColor(this.colors.success)
                  .margin({ bottom: Spacing.SM })

                Row({ space: ButtonSpec.ROW_GAP }) {
                  Button('复制用户名')
                    .type(ButtonType.Normal)
                    .borderRadius(ButtonSpec.SECONDARY_RADIUS)
                    .layoutWeight(1)
                    .height(ButtonSpec.SECONDARY_HEIGHT)
                    .fontSize(ButtonSpec.FONT_SIZE)
                    .backgroundColor(this.colors.inputBackground)
                    .fontColor(this.colors.textPrimary)
                    .onClick(() => {
                      this.viewModel.copyUsername();
                    })

                  Button('复制密码')
                    .type(ButtonType.Normal)
                    .borderRadius(ButtonSpec.SECONDARY_RADIUS)
                    .layoutWeight(1)
                    .height(ButtonSpec.SECONDARY_HEIGHT)
                    .fontSize(ButtonSpec.FONT_SIZE)
                    .backgroundColor(this.colors.primary)
                    .fontColor(this.colors.onPrimary)
                    .onClick(() => {
                      this.viewModel.copyPassword();
                    })
                }
                .width('100%')
              }
              .width('100%')
              .padding(Spacing.CARD)
              .backgroundColor(this.colors.surface)
              .borderRadius(Radius.CARD)
              .margin({ top: Spacing.CARD_GAP })
              .alignItems(HorizontalAlign.Start)
            }

            Blank()
              .height(Spacing.XL)
          }
          .padding({ left: Spacing.PAGE_H, right: Spacing.PAGE_H })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.colors.background)
    }
    .hideTitleBar(true)
    .backgroundColor(this.colors.background)
  }
}
