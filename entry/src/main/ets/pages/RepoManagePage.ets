import { RepoManageViewModel } from '../viewmodel/RepoManageViewModel';
import { RouteManager } from '../common/RouteManager';
import { RouteNames } from '../common/Constants';
import { ThemeColors, Palette, ButtonSpec, Spacing, FontSize, Radius, IconSize } from '../common/ThemeColors';
import { panelSheetOptions, themedSheetOptions, SHEET_PAD_TOP, SHEET_PAD_BOTTOM } from '../common/SheetStyles';
import { AppTitleBar } from '../views/AppTitleBar';

/**
 * 仓库管理页
 *
 * 管理本地密码仓库的 Git 行为与生命周期：
 * 克隆远程仓库、拉取时变基、删除本地仓库。
 * 布局对齐 HarmonyOS Design：自定义沉浸式标题栏、分组卡片、语义色提示。
 */
@ComponentV2
export struct RepoManagePage {
  @Local viewModel: RepoManageViewModel = new RepoManageViewModel();

  private get colors(): Palette {
    return ThemeColors.getInstance().palette();
  }

  /** 删除确认面板配置：getter + themedSheetOptions（backgroundColor 随主题刷新，防上拉露旧色） */
  private get deleteSheetOptions(): SheetOptions {
    return themedSheetOptions(this, 'RepoDelete', 
      (): SheetOptions => panelSheetOptions(this.colors.surface, 260,
        (): void => this.viewModel.setDeleteDialogVisible(false)),
      this.colors.surface, 260);
  }

  aboutToAppear(): void {
    this.viewModel.load();
  }

  /** 分组标题（Subtitle_S 14fp Medium 次要色，上下留白对齐规范 28/8） */
  @Builder
  sectionTitle(title: string, isFirst: boolean) {
    Text(title)
      .fontSize(FontSize.SECTION)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.colors.textSecondary)
      .width('100%')
      .padding({
        // 首个分组紧跟标题栏，用更小的上间距，否则正文整体偏低
        top: isFirst ? Spacing.SECTION_TOP_FIRST : Spacing.SECTION_TOP,
        // 下方间距取卡片间距：标题与所属卡片是一个整体，标题到卡片、卡片到卡片
        // 用同一个值，视觉节奏才连续（原先 8 比卡片间距还小）
        bottom: Spacing.CARD_GAP,
        // 与卡片内容左缘对齐（卡片内边距同为 16vp）
        left: Spacing.ROW_H,
      })
  }

  /** 状态提示行 */
  @Builder
  statusRow(message: string, success: boolean) {
    Row() {
      SymbolGlyph(success ? $r('sys.symbol.checkmark_circle_fill') : $r('sys.symbol.xmark_circle_fill'))
        .fontSize(IconSize.XS)
        .fontColor([success ? this.colors.success : this.colors.danger])
      Text(message)
        .fontSize(FontSize.CAPTION)
        .fontColor(success ? this.colors.success : this.colors.danger)
        .layoutWeight(1)
        .margin({ left: Spacing.SM })
    }
    .width('100%')
    .padding(Spacing.MD)
    .backgroundColor(success ? this.colors.primarySoft : this.colors.dangerSoft)
    .borderRadius(Radius.CARD)
    .margin({ top: Spacing.SM })
    .alignItems(VerticalAlign.Center)
  }

  build() {
    NavDestination() {
      Column() {
        // ===== 自定义标题栏（40vp 圆形返回按钮 + 标题，见 AppTitleBar） =====
        AppTitleBar({ title: '仓库管理' })

        Scroll() {
          Column() {
            // ===== 仓库状态 =====
            this.sectionTitle('仓库状态', true)

            Column() {
              Row() {
                Column() {
                  Text(this.viewModel.isGitRepo ? '已克隆远程仓库' : '未克隆远程仓库')
                    .fontSize(FontSize.SUBTITLE)
                    .fontColor(this.colors.textPrimary)
                  Text(this.viewModel.remoteUrl.length > 0 ? this.viewModel.remoteUrl : '尚未配置远程地址')
                    .fontSize(FontSize.CAPTION)
                    .fontColor(this.colors.textTertiary)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .margin({ top: Spacing.XS })
                  Text(this.viewModel.statusSummary)
                    .fontSize(FontSize.CAPTION)
                    .fontColor(this.colors.textTertiary)
                    .margin({ top: Spacing.XS })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
              }
              .width('100%')
              .padding({ top: Spacing.MD, bottom: Spacing.MD })
              .alignItems(VerticalAlign.Center)
            }
            .width('100%')
            .padding({ left: Spacing.CARD, right: Spacing.CARD })
            .backgroundColor(this.colors.surface)
            .borderRadius(Radius.CARD)

            // ===== 同步行为 =====
            this.sectionTitle('同步行为', false)

            Column() {
              Row() {
                Column() {
                  Text('拉取时进行变基')
                    .fontSize(FontSize.SUBTITLE)
                    .fontColor(this.colors.textPrimary)
                  Text('拉取远程更新时使用变基（--rebase）保持线性历史')
                    .fontSize(FontSize.CAPTION)
                    .fontColor(this.colors.textTertiary)
                    .margin({ top: Spacing.XS })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Toggle({ type: ToggleType.Switch, isOn: this.viewModel.pullRebase })
                  .selectedColor(this.colors.primary)
                  .onChange((v: boolean) => {
                    this.viewModel.setPullRebase(v);
                  })
              }
              .width('100%')
              .padding({ top: Spacing.MD, bottom: Spacing.MD })
              .alignItems(VerticalAlign.Center)
            }
            .width('100%')
            .padding({ left: Spacing.CARD, right: Spacing.CARD })
            .backgroundColor(this.colors.surface)
            .borderRadius(Radius.CARD)

            // ===== 仓库操作 =====
            this.sectionTitle('仓库操作', false)

            Column() {
              Row() {
                Column() {
                  Text('Git 配置')
                    .fontSize(FontSize.SUBTITLE)
                    .fontColor(this.colors.textPrimary)
                  Text('远程地址 / 认证方式 / 提交身份')
                    .fontSize(FontSize.CAPTION)
                    .fontColor(this.colors.textTertiary)
                    .margin({ top: Spacing.XS })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                SymbolGlyph($r('sys.symbol.chevron_right'))
                  .fontSize(IconSize.XS)
                  .fontColor([this.colors.textTertiary])
              }
              .width('100%')
              .padding({ top: Spacing.MD, bottom: Spacing.MD })
              .alignItems(VerticalAlign.Center)
              .stateStyles({
                normal: { .backgroundColor(Color.Transparent) },
                pressed: { .backgroundColor(this.colors.pressed) },
              })
              .onClick(() => {
                RouteManager.getInstance().pushPath(RouteNames.GIT_CONFIG);
              })
            }
            .width('100%')
            .padding({ left: Spacing.CARD, right: Spacing.CARD })
            .backgroundColor(this.colors.surface)
            .borderRadius(Radius.CARD)

            // ===== 危险操作 =====
            this.sectionTitle('危险操作', false)

            Column() {
              Row() {
                Column() {
                  Text('删除本地仓库目录及全部密码文件，操作不可撤销')
                    .fontSize(FontSize.CAPTION)
                    .fontColor(this.colors.textTertiary)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
              }
              .width('100%')
              .padding({ top: Spacing.MD, bottom: Spacing.MD })

              Button(this.viewModel.isBusy ? '处理中...' : '删除本地仓库')
                .type(ButtonType.Normal)
                .borderRadius(ButtonSpec.DANGER_RADIUS)
                .width('100%')
                .height(ButtonSpec.DANGER_HEIGHT)
                .backgroundColor(this.colors.dangerSoft)
                .fontColor(this.colors.danger)
                .fontSize(ButtonSpec.FONT_SIZE)
                .fontWeight(ButtonSpec.FONT_WEIGHT)
                .enabled(!this.viewModel.isBusy)
                .margin({ bottom: Spacing.MD })
                .onClick(() => {
                  this.viewModel.setDeleteDialogVisible(true);
                })
            }
            .width('100%')
            .padding({ left: Spacing.CARD, right: Spacing.CARD })
            .backgroundColor(this.colors.surface)
            .borderRadius(Radius.CARD)

            // ===== 结果提示 =====
            if (this.viewModel.resultMessage.length > 0) {
              this.statusRow(this.viewModel.resultMessage, this.viewModel.lastSuccess)
            }
          }
          .width('100%')
          .padding({ left: Spacing.PAGE_H, right: Spacing.PAGE_H, bottom: Spacing.XL })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
        .align(Alignment.Top)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.colors.background)
    }
    .hideTitleBar(true)
    // 从「克隆 / Git 配置」返回时重读状态：克隆完成后本页仍在导航栈里，
    // 不刷新就会一直显示「未克隆远程仓库 / 尚未配置远程地址」
    .onShown(() => {
      this.viewModel.load();
    })
    // 删除确认：危险操作二次确认（半模态，点遮罩可取消）
    // options 走 getter+themedSheetOptions：backgroundColor 过期会在面板拉高后露出旧色
    .bindSheet(this.viewModel.isDeleteDialogVisible, this.deleteConfirmBuilder(),
      this.deleteSheetOptions)
  }

  /** 删除仓库确认面板 */
  @Builder
  deleteConfirmBuilder() {
    Column() {
      Text('删除本地仓库')
        .fontSize(FontSize.SUBTITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.colors.textPrimary)
        .width('100%')
        .textAlign(TextAlign.Center)

      Text('将删除本地仓库目录及其中全部密码文件，此操作不可撤销。')
        .fontSize(FontSize.CAPTION)
        .fontColor(this.colors.textSecondary)
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ top: Spacing.MD })

      // 弹性占位：把按钮行撑到面板底部（与其它半模态弹窗一致）
      Blank()
        .layoutWeight(1)

      Row({ space: ButtonSpec.ROW_GAP }) {
        Button('取消')
          .type(ButtonType.Normal)
          .borderRadius(ButtonSpec.SECONDARY_RADIUS)
          .layoutWeight(1)
          .height(ButtonSpec.SECONDARY_HEIGHT)
          .backgroundColor(this.colors.neutralButton)
          .fontColor(this.colors.textSecondary)
          .fontSize(ButtonSpec.FONT_SIZE)
          .onClick(() => {
            this.viewModel.setDeleteDialogVisible(false);
          })

        Button('删除')
          .type(ButtonType.Normal)
          .borderRadius(ButtonSpec.DANGER_RADIUS)
          .layoutWeight(1)
          .height(ButtonSpec.DANGER_HEIGHT)
          .backgroundColor(this.colors.danger)
          .fontColor(this.colors.onPrimary)
          .fontSize(ButtonSpec.FONT_SIZE)
          .fontWeight(ButtonSpec.FONT_WEIGHT)
          .onClick(() => {
            this.viewModel.deleteRepo();
          })
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    // 统一面板内边距：顶部让开 dragBar，底部给按钮行留出与屏幕下沿的距离
    .padding({ top: SHEET_PAD_TOP, left: Spacing.PAGE_H, right: Spacing.PAGE_H, bottom: SHEET_PAD_BOTTOM })
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(this.colors.surface)
  }
}
