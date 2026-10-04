import { RepoManageViewModel } from '../viewmodel/RepoManageViewModel';
import { RouteManager } from '../common/RouteManager';
import { RouteNames } from '../common/Constants';
import { ThemeColors, Palette, ButtonSpec, Spacing, FontSize, Radius, IconSize, ComponentSize, DividerSpec } from '../common/ThemeColors';
import { AppTitleBar } from '../views/AppTitleBar';
import { LoadingOverlay } from '../views/LoadingOverlay';
import { HostKeyConfirmDialog } from '../views/HostKeyConfirmDialog';
import { showToastSafe } from '../utils/ToastUtil';
import { Strings } from '../common/Strings';
import { SystemInsets } from '../utils/SystemInsets';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** hilog 域 */
const DOMAIN: number = 0x0001;
/** hilog 标签 */
const TAG: string = 'RepoManagePage';

/**
 * 仓库管理页
 *
 * 管理本地密码仓库的 Git 行为与生命周期：克隆远程仓库、拉取时变基、
 * 强制推送远程、删除本地仓库。
 *
 * 布局对齐设置页的同款模式：整页是一个 `List`，每个分组一张 `ListItemGroup`
 * 卡片——**组**承载背景/圆角/横向内边距/组内分隔线，**行**只负责内容。
 * 本页行内没有图标（与设置页的 icon 行不同），故组横向内边距取 `Spacing.CARD`、
 * 分隔线 startMargin 与之对齐。
 */
@ComponentV2
export struct RepoManagePage {
  @Local viewModel: RepoManageViewModel = new RepoManageViewModel();

  /** TOFU 指纹确认弹窗 id（-1 = 未弹出；openCustomDialog 返回，closeCustomDialog 用） */
  private hostKeyDialogId: number = -1;

  private get colors(): Palette {
    return ThemeColors.getInstance().palette();
  }

  aboutToAppear(): void {
    this.viewModel.load();
  }

  /**
   * 分组标题（`List` 的一个 `ListItem`，紧跟在所属分组卡片之前）
   *
   * 间距口径与设置页完全一致：上间距由「上一段的空间」凑成 `SECTION_TOP`(24)——
   * 非首个标题上方已经有 `List({ space })` 的 12vp，故这里只补差额；下间距交给
   * 同一个 space（标题 → 卡片 12vp，与卡片 ↔ 卡片等值），这里不再额外给。
   * 左内边距与卡片内容左缘对齐（组横向内边距同为 16vp）。
   */
  @Builder
  sectionTitle(title: string, isFirst: boolean) {
    Text(title)
      .fontSize(FontSize.SECTION)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.colors.textSecondary)
      .width('100%')
      .padding({
        top: isFirst ? Spacing.SECTION_TOP_FIRST : Spacing.SECTION_TOP - Spacing.CARD_GAP,
        bottom: 0,
        left: Spacing.ROW_H,
      })
  }

  /**
   * 危险操作行（danger 色标题 + 说明 + 右箭头）
   *
   * 常态显式透明（stateStyles 是替换不是叠加），按压才显 `pressed` 色。
   */
  @Builder
  dangerRow(label: ResourceStr, sublabel: ResourceStr, enabled: boolean, onTapped: () => void) {
    Row() {
      Column() {
        Text(label)
          .fontSize(FontSize.SUBTITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.colors.danger)
        Text(sublabel)
          .fontSize(FontSize.CAPTION)
          .fontColor(this.colors.textTertiary)
          .margin({ top: Spacing.XS })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(IconSize.CHEVRON)
        .fontColor([this.colors.textTertiary])
        .margin({ left: Spacing.SM })
    }
    .width('100%')
    .constraintSize({ minHeight: ComponentSize.ROW_TWO_LINE })
    .padding({ top: Spacing.MD, bottom: Spacing.MD })
    .alignItems(VerticalAlign.Center)
    .enabled(enabled)
    .stateStyles({
      normal: { .backgroundColor(Color.Transparent) },
      pressed: { .backgroundColor(this.colors.pressed) },
    })
    .onClick(() => onTapped())
  }

  /**
   * 普通导航行（主色标题 + 说明 + 右箭头，dangerRow 同构）
   *
   * 常态显式透明（stateStyles 是替换不是叠加），按压才显 `pressed` 色。
   */
  @Builder
  navRow(label: ResourceStr, sublabel: ResourceStr, onTapped: () => void) {
    Row() {
      Column() {
        Text(label)
          .fontSize(FontSize.SUBTITLE)
          .fontColor(this.colors.textPrimary)
        Text(sublabel)
          .fontSize(FontSize.CAPTION)
          .fontColor(this.colors.textTertiary)
          .margin({ top: Spacing.XS })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(IconSize.CHEVRON)
        .fontColor([this.colors.textTertiary])
    }
    .width('100%')
    .constraintSize({ minHeight: ComponentSize.ROW_TWO_LINE })
    .padding({ top: Spacing.MD, bottom: Spacing.MD })
    .alignItems(VerticalAlign.Center)
    .stateStyles({
      normal: { .backgroundColor(Color.Transparent) },
      pressed: { .backgroundColor(this.colors.pressed) },
    })
    .onClick(() => onTapped())
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
        AppTitleBar({ title: $r('app.string.repo_row_title') })

        List({ space: Spacing.CARD_GAP }) {
          // ===== 仓库状态 =====
          ListItem() {
            this.sectionTitle(Strings.get('repo_section_status'), true)
          }

          ListItemGroup() {
            ListItem() {
              Column() {
                Text(this.viewModel.isGitRepo ? $r('app.string.repo_status_cloned') : $r('app.string.repo_status_not_cloned'))
                  .fontSize(FontSize.SUBTITLE)
                  .fontColor(this.colors.textPrimary)
                Text(this.viewModel.remoteUrl.length > 0 ? this.viewModel.remoteUrl : Strings.get('repo_no_remote_url'))
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
              .width('100%')
              .padding({ top: Spacing.MD, bottom: Spacing.MD })
              .alignItems(HorizontalAlign.Start)
            }
          }
          .borderRadius(Radius.CARD)
          .backgroundColor(this.colors.surface)
          .padding({ left: Spacing.CARD, right: Spacing.CARD })
          .clip(true)

          // ===== 同步行为 =====
          ListItem() {
            this.sectionTitle(Strings.get('repo_section_sync'), false)
          }

          ListItemGroup() {
            ListItem() {
              Row() {
                Column() {
                  Text(Strings.get('repo_pull_rebase_title'))
                    .fontSize(FontSize.SUBTITLE)
                    .fontColor(this.colors.textPrimary)
                  Text($r('app.string.repo_pull_rebase_sub'))
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
              .constraintSize({ minHeight: ComponentSize.ROW_TWO_LINE })
              .padding({ top: Spacing.MD, bottom: Spacing.MD })
              .alignItems(VerticalAlign.Center)
            }
          }
          .borderRadius(Radius.CARD)
          .backgroundColor(this.colors.surface)
          .padding({ left: Spacing.CARD, right: Spacing.CARD })
          .clip(true)

          // ===== 仓库操作：Git 配置 + 导出仓库，同一个列表组 =====
          ListItem() {
            this.sectionTitle(Strings.get('repo_section_ops'), false)
          }

          ListItemGroup() {
            ListItem() {
              this.navRow($r('app.string.git_config'), $r('app.string.repo_gitcfg_sub'), (): void => {
                RouteManager.getInstance().pushPath(RouteNames.GIT_CONFIG);
              })
            }

            ListItem() {
              this.navRow($r('app.string.repo_export_title'), $r('app.string.repo_export_sub'), (): void => {
                this.viewModel.exportRepo();
              })
            }
          }
          .borderRadius(Radius.CARD)
          .backgroundColor(this.colors.surface)
          .padding({ left: Spacing.CARD, right: Spacing.CARD })
          .clip(true)
          .divider({
            strokeWidth: DividerSpec.STROKE,
            startMargin: Spacing.CARD,
            endMargin: Spacing.CARD,
            color: this.colors.divider,
          })

          // ===== 危险操作：强制推送远程 + 删除本地仓库，同一个列表组 =====
          ListItem() {
            this.sectionTitle(Strings.get('repo_section_danger'), false)
          }

          ListItemGroup() {
            ListItem() {
              this.dangerRow($r('app.string.repo_force_push_title'), $r('app.string.repo_force_push_sub'),
                !this.viewModel.isBusy,
                (): void => {
                  this.onForcePushTapped();
                })
            }

            ListItem() {
              this.dangerRow($r('app.string.repo_delete_btn'), $r('app.string.repo_danger_hint'),
                !this.viewModel.isBusy,
                (): void => {
                  this.showDeleteConfirmDialog();
                })
            }
          }
          .borderRadius(Radius.CARD)
          .backgroundColor(this.colors.surface)
          .padding({ left: Spacing.CARD, right: Spacing.CARD })
          .clip(true)
          .divider({
            strokeWidth: DividerSpec.STROKE,
            startMargin: Spacing.CARD,
            endMargin: Spacing.CARD,
            color: this.colors.divider,
          })

          // ===== 结果提示 =====
          // 只给**失败**留常驻状态行（错误原因需要用户看清、才有可能照着改）；
          // 成功一律走消息气泡（`showToastSafe`）——原先成功也占一块页面，用户还得
          // 手动滑到底才能看到，且成功后它一直杵在页尾。
          if (this.viewModel.resultMessage.length > 0 && !this.viewModel.lastSuccess) {
            ListItem() {
              this.statusRow(this.viewModel.resultMessage, this.viewModel.lastSuccess)
            }
          }

          // 底部留白：滚动到底的余量 + 系统导航条高度（沉浸式布局下内容延伸到导航条
          // 之下，不额外留这一截时最后一行会被导航条压住，见 SystemInsets）
          ListItem() {
            Column()
              .width('100%')
              .height(Spacing.XL * 2 + SystemInsets.bottomVp())
          }
        }
        .layoutWeight(1)
        // 与设置页一致不显示滚动条（`BarState.Off`）：沉浸式页面右侧留一条
        // 常驻灰条既干扰视觉，也与同层级页面的观感不统一
        .scrollBar(BarState.Off)
        // 滑到上下边界时给回弹动效反馈
        .edgeEffect(EdgeEffect.Spring)
        .padding({ left: Spacing.PAGE_H, right: Spacing.PAGE_H, bottom: Spacing.PAGE_H })
        .backgroundColor(this.colors.background)

        // ===== 强制推送：全模态遮罩 =====
        // `.position({x:0,y:0})` 把它移出文档流、叠在整页之上；返回键另见
        // onBackPressed（遮罩挡不住系统返回手势）
        if (this.viewModel.isForcePushing) {
          LoadingOverlay({ text: Strings.get('sync_pushing_remote') })
            .position({ x: 0, y: 0 })
        }

        // ===== 导出仓库：全模态遮罩（打包阶段 + 保存对话框背后的复制阶段） =====
        if (this.viewModel.isExporting) {
          LoadingOverlay({ text: Strings.get('repo_export_zipping') })
            .position({ x: 0, y: 0 })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.colors.background)
    }
    .hideTitleBar(true)
    // 强制推送/导出进行中吞掉返回：中断后遮罩复位，但用户会误以为操作已取消
    // （导出的遮罩还要盖住系统保存对话框打开前后的页面期，对话框本身在独立窗口）
    .onBackPressed((): boolean => this.viewModel.isForcePushing || this.viewModel.isExporting)
    // 从「克隆 / Git 配置」返回时重读状态：克隆完成后本页仍在导航栈里，
    // 不刷新就会一直显示「未克隆远程仓库 / 尚未配置远程地址」
    .onShown(() => {
      this.viewModel.load();
    })
  }

  /**
   * 操作成功改为消息气泡提示
   *
   * 强制推送与删除两条链路都收口在 ViewModel 的 `finish()`，而 ViewModel 拿不到
   * UIContext，气泡必须在页面层弹——用 `@Monitor` 监听结果序号，一处覆盖两条链路
   * （听 `resultNonce` 而非 `resultMessage`：连续两次操作的成功文案相同，值不变
   * 就不会触发第二次监听，第二次操作将无任何反馈）。
   * 失败不在此处理（保留页面里的红色状态行，错误原因需要留在页面上供用户照着改）。
   */
  @Monitor('viewModel.resultNonce')
  onResultMessage(): void {
    if (this.viewModel.lastSuccess && this.viewModel.resultMessage.length > 0) {
      showToastSafe(this.getUIContext(), this.viewModel.resultMessage, 2500);
    }
  }

  /** 点「强制推送远程」：瞬时前置校验通过则弹确认弹窗，否则弹失败原因 */
  private async onForcePushTapped(): Promise<void> {
    const ok: boolean = await this.viewModel.precheckForcePush();
    if (ok) {
      this.showForcePushConfirmDialog();
      return;
    }
    this.showForcePushErrorDialog();
  }

  /**
   * 删除仓库确认（系统原生警告弹窗）
   *
   * 原先是 bindSheet 半模态（自绘标题/正文/双按钮），改用系统 AlertDialog 居中弹窗——
   * 危险操作的二次确认是系统弹窗的典型场景，原生样式自带标题加粗、正文次要色与
   * 双按钮横排。破坏性按钮按系统惯例用红色文字（`fontColor` 设调色板 danger 色）。
   * 文案沿用原面板的键（repo_delete_btn / repo_delete_confirm_msg），内容不变。
   *
   * 触发点在页面按钮上、本页无任何 bindSheet 打开，不踩「面板未关闭时
   * AlertDialog 不进布局树」的坑（见 AGENTS.md）。
   */
  private showDeleteConfirmDialog(): void {
    this.getUIContext().showAlertDialog({
      title: Strings.get('repo_delete_btn'),
      message: Strings.get('repo_delete_confirm_msg'),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: $r('app.string.common_cancel'),
        action: (): void => {},
      },
      secondaryButton: {
        value: $r('app.string.delete'),
        fontColor: this.colors.danger,
        action: (): void => {
          this.viewModel.deleteRepo();
        },
      },
    });
  }

  /** 强制推送确认（系统原生警告弹窗，与删除确认同构；正文写后果——覆盖远端） */
  private showForcePushConfirmDialog(): void {
    this.getUIContext().showAlertDialog({
      title: Strings.get('repo_force_push_title'),
      message: Strings.get('repo_force_push_confirm_msg'),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: $r('app.string.common_cancel'),
        action: (): void => {},
      },
      secondaryButton: {
        value: $r('app.string.repo_force_push_btn'),
        fontColor: this.colors.danger,
        action: (): void => {
          this.runForcePush();
        },
      },
    });
  }

  /** 确认弹窗点「强制推送」：执行（连接测试 + 推送 + TOFU/失败弹窗） */
  private runForcePush(): void {
    this.viewModel.runForcePush().then((): void => {
      if (this.viewModel.pendingHostKeyFp.length > 0) {
        // 主机密钥未信任：弹指纹确认（可重入，见 maybeShowHostKeyDialog 注释）
        this.maybeShowHostKeyDialog();
        return;
      }
      this.showForcePushErrorDialog();
    });
  }

  /** 强制推送失败原因弹窗（含前置校验失败：仓库未初始化 / 远程地址未配置） */
  private showForcePushErrorDialog(): void {
    const message: string = this.viewModel.forcePushError;
    this.viewModel.clearForcePushError();
    if (message.length === 0) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: Strings.get('repo_force_push_failed_title'),
      message: message,
      autoCancel: false,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: $r('app.string.common_got_it'),
        action: (): void => {},
      },
    });
  }

  /**
   * 主机指纹确认弹窗内容
   *
   * **必须是页面的 @Builder**：在 openCustomDialog 的普通箭头函数里直接
   * `HostKeyConfirmDialog({...})` 不会被 ArkUI 编译期转换，运行时报
   * `class constructor cannot called without 'new'`（实测整个应用闪退）。
   */
  @Builder
  hostKeyDialogBuilder(title: string, hostLine: string, fingerprint: string,
    explanation: string, mismatch: boolean, confirmLabel: string) {
    HostKeyConfirmDialog({
      title: title,
      hostLine: hostLine,
      fingerprint: fingerprint,
      explanation: explanation,
      mismatch: mismatch,
      confirmLabel: confirmLabel,
      onReject: (): void => {
        this.closeHostKeyDialog();
        this.viewModel.rejectHostKey();
      },
      onConfirm: (): void => {
        this.closeHostKeyDialog();
        // 保存指纹后整体重试强制推送；服务器又出示另一把未记录类型的主机密钥时再弹一次
        this.viewModel.confirmHostKey().then((): void => {
          if (this.viewModel.pendingHostKeyFp.length > 0) {
            this.maybeShowHostKeyDialog();
            return;
          }
          this.showForcePushErrorDialog();
        });
      },
    })
  }

  /**
   * TOFU 主机密钥确认：有待确认指纹时弹确认弹窗（可重入）
   *
   * 服务器可能提供多把不同类型的主机密钥，确认一把后继续连接还可能遇到下一把，
   * 故每次推送/测试返回后都要调一次本方法。
   */
  private maybeShowHostKeyDialog(): void {
    if (this.viewModel.pendingHostKeyFp.length === 0) {
      return;
    }
    const mismatch: boolean = this.viewModel.pendingHostKeyMismatch;
    const keyType: string = this.viewModel.pendingHostKeyType;
    const title: string = mismatch
      ? Strings.get('sync_hostkey_mismatch_title')
      : (keyType.length > 0 ? Strings.fmt('sync_hostkey_first_type', keyType) : Strings.get('sync_hostkey_first'));
    // 指纹取自实际被拒的那次连接；带类型时在「密钥指纹」后插入（类型）
    const hostLine: string = keyType.length > 0
      ? Strings.fmt('gitcfg_hostkey_fp_typed', this.viewModel.pendingHost, this.viewModel.pendingPort, keyType)
      : Strings.fmt('sync_hostkey_fp_label', this.viewModel.pendingHost, this.viewModel.pendingPort);
    const explanation: string = mismatch
      ? Strings.get('gitcfg_hostkey_mismatch_explain')
      : Strings.get('sync_hostkey_new_detail');
    const fingerprint: string = this.viewModel.pendingHostKeyFp;
    const confirmLabel: string = mismatch ? Strings.get('gitcfg_hostkey_trust_anyway') : Strings.get('gitcfg_hostkey_trust_connect');
    try {
      this.getUIContext().getPromptAction().openCustomDialog({
        builder: (): void => {
          this.hostKeyDialogBuilder(title, hostLine, fingerprint, explanation, mismatch, confirmLabel);
        },
        autoCancel: false,
        alignment: DialogAlignment.Center,
        maskColor: 'rgba(0,0,0,0.4)',
        // 关闭默认背景与模糊层（深色模式下默认模糊层呈黑块），背景由卡片自己承担
        backgroundColor: Color.Transparent,
        backgroundBlurStyle: BlurStyle.NONE,
        isModal: true,
      }).then((dialogId: number) => {
        this.hostKeyDialogId = dialogId;
      }).catch((e: Error) => {
        hilog.error(DOMAIN, TAG, 'openCustomDialog failed: %{public}s', e.message);
      });
    } catch (e) {
      // openCustomDialog 可能同步抛出，直接调用会逃出上面的 Promise 链
      hilog.error(DOMAIN, TAG, 'openCustomDialog threw: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : String(e));
    }
  }

  /** 关闭主机指纹弹窗（同样兜异常，避免关闭失败留下关不掉的遮罩） */
  private closeHostKeyDialog(): void {
    if (this.hostKeyDialogId < 0) {
      return;
    }
    try {
      this.getUIContext().getPromptAction().closeCustomDialog(this.hostKeyDialogId);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'closeCustomDialog failed: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : String(e));
    }
    this.hostKeyDialogId = -1;
  }
}
