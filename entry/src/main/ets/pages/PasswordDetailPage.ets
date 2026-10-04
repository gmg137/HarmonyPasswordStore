import { PasswordDetailViewModel } from '../viewmodel/PasswordDetailViewModel';
import { showToastSafe } from '../utils/ToastUtil';
import { PasswordDetailNavParam, PasswordCreateNavParam } from '../viewmodel/PasswordListViewModel';
import { RouteManager } from '../common/RouteManager';
import { RouteNames } from '../common/Constants';
import { ThemeColors, Palette, ButtonSpec, Spacing, FontSize, Radius, IconSize, ComponentSize, DividerSpec } from '../common/ThemeColors';
import { SystemInsets } from '../utils/SystemInsets';
import { AppTitleBar } from '../views/AppTitleBar';
import { RepoChangeNotifier } from '../common/RepoChangeNotifier';
import { CopyIconButton } from '../views/CopyIconButton';
import { panelSheetOptions, themedSheetOptions, SHEET_PAD_TOP, SHEET_PAD_BOTTOM } from '../common/SheetStyles';
import { Strings } from '../common/Strings';

/** 详情行标签列宽度（固定列宽让值列左缘对齐，不随标签字数跳动） */
const DETAIL_LABEL_W: number = 72;

/**
 * 密码详情页
 *
 * 解密并显示密码条目内容，支持复制密码/用户名/URL到剪贴板。
 * 密码默认隐藏，点击切换可见性。
 */
@ComponentV2
export struct PasswordDetailPage {
  @Local viewModel: PasswordDetailViewModel = new PasswordDetailViewModel();
  @Local isDeleteDialogVisible: boolean = false;
  /**
   * 底部系统栏（导航条/手势条）高度，vp
   *
   * 沉浸式布局下内容延伸到系统栏下方，底部固定操作栏必须避开它——
   * 否则按钮紧贴屏幕下沿（用户反馈「离底太近」）。与半模态弹窗按钮
   * 距面板底部的留白（`SHEET_PAD_BOTTOM`）保持同一视觉口径。
   */
  @Local bottomInset: number = 0;
  /**
   * 仓库变更通知器：编辑页保存后 bump()，详情页监听 nonce 变化
   * 自动重新解密刷新内容（无需 NavDestination.onShown 生命周期）
   */
  @Local notifier: RepoChangeNotifier = RepoChangeNotifier.connect();

  /** 当前调色板（getter 每次构建求值，深浅色切换自动刷新） */
  private get colors(): Palette {
    return ThemeColors.getInstance().palette();
  }

  /**
   * 标签列宽：按当前语言缩放
   *
   * 基准值按汉字定（3 字 ≈ 72vp），拉丁/西里尔字母同字数约占 1.5 倍宽，
   * 不缩放时 `Benutzername`、`Телефон` 这类标签会折行撑高整行（见 Strings.labelWidth）。
   */
  private get labelW(): number {
    return Strings.labelWidth(DETAIL_LABEL_W);
  }

  /** 删除确认面板配置：getter + themedSheetOptions（backgroundColor 随主题刷新，防上拉露旧色） */
  private get deleteSheetOptions(): SheetOptions {
    return themedSheetOptions(this, 'DetailDelete', 
      (): SheetOptions => panelSheetOptions(this.colors.surface, 240, (): void => {
        this.isDeleteDialogVisible = false;
      }),
      this.colors.surface, 240);
  }

  aboutToAppear(): void {
    // 注入 toast 回调：ViewModel 拿不到 UIContext，而全局 promptAction.showToast
    // 已废弃（见 PasswordDetailViewModel.showToast 的注释）
    this.viewModel.onToast = (message: string): void => {
      showToastSafe(this.getUIContext(), message, 2000);
    };
    // 底部系统栏高度：沉浸式布局下底部操作栏据此避让（换算集中见 SystemInsets）
    this.bottomInset = SystemInsets.bottomVp();
    // NavPathInfo.param 在 aboutToAppear 时序下可能未就绪，
    // 改用 RouteManager 暂存的最近一次 push 参数
    const param: Object | undefined = RouteManager.getInstance().takeLastParam();
    if (param) {
      const detailParam = param as PasswordDetailNavParam;
      this.viewModel.init(detailParam.relativePath);
    }
  }

  aboutToDisappear(): void {
    this.viewModel.onDispose();
  }

  /**
   * notifier.nonce 变化时重新解密刷新内容。
   * 编辑页保存成功后调用 RepoChangeNotifier.connect().bump()，
   * nonce 递增触发此回调，详情页自动重新解密——无需依赖 NavDestination.onShown。
   */
  @Monitor('notifier.nonce')
  onRepoChange(): void {
    // 移动/重命名：详情页持有的是旧路径，跟随通知中的新路径重新解密，
    // 避免按旧路径读取失败而误弹"请输入密钥密码"
    if (this.notifier.movedFrom.length > 0 && this.notifier.movedTo.length > 0
      && this.viewModel.relativePath === this.notifier.movedFrom) {
      this.viewModel.init(this.notifier.movedTo);
      return;
    }
    this.viewModel.decrypt();
  }

  /**
   * 删除成功后返回列表页
   */
  private navigateBackAfterDelete(): void {
    if (this.viewModel.isDeleted) {
      RouteManager.getInstance().pop();
    }
  }

  /**
   * 跳转到编辑页（复用创建页，携带 editPath 参数）
   */
  private navigateToEdit(): void {
    const param: PasswordCreateNavParam = { parentDir: '', editPath: this.viewModel.relativePath };
    RouteManager.getInstance().pushPath(RouteNames.PASSWORD_CREATE, param);
  }

  /** 标题栏右侧动作：复制密码（解密成功后可用）+ 编辑 */
  @Builder
  headerActions() {
    if (this.viewModel.isDecrypted && this.viewModel.content) {
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.plus_square_dashed_on_square'))
          .fontSize(IconSize.MD)
          .fontColor([this.colors.textPrimary])
      }
      .width(IconSize.BACK_BUTTON)
      .height(IconSize.BACK_BUTTON)
      .backgroundColor(this.colors.inputBackground)
      .onClick(() => {
        this.viewModel.copyPassword();
      })
    }

    Button({ type: ButtonType.Circle, stateEffect: true }) {
      SymbolGlyph($r('sys.symbol.square_and_pencil'))
        .fontSize(IconSize.MD)
        .fontColor([this.colors.textPrimary])
    }
    .width(IconSize.BACK_BUTTON)
    .height(IconSize.BACK_BUTTON)
    .backgroundColor(this.colors.inputBackground)
    .margin({ left: Spacing.SM })
    .onClick(() => {
      this.navigateToEdit();
    })
  }

  @Builder
  copyButton(text: string, enabled: boolean, action: () => void) {
    Button(text)
      .type(ButtonType.Normal)
      .borderRadius(ButtonSpec.SMALL_RADIUS)
      .fontSize(FontSize.BODY)
      .fontWeight(ButtonSpec.FONT_WEIGHT)
      .enabled(enabled)
      .layoutWeight(1)
      .height(ButtonSpec.SMALL_HEIGHT)
      .onClick(() => action())
  }

  build() {
    NavDestination() {
      Column() {
        // ===== 标题栏（共享组件）+ 右侧动作（复制密码 / 编辑） =====
        AppTitleBar({
          title: this.viewModel.displayName,
          actions: (): void => {
            this.headerActions();
          },
        })

        if (this.viewModel.isDecrypting) {
          // 解密中
          Column() {
            LoadingProgress()
              .width(IconSize.XL)
              .height(IconSize.XL)
            Text($r('app.string.detail_decrypting'))
              .fontSize(FontSize.BODY)
              .fontColor(this.colors.textTertiary)
              .margin({ top: Spacing.MD })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
        } else if (!this.viewModel.isDecrypted) {
          // 解密失败 / 需要密码
          Column() {
            if (this.viewModel.passphraseDialogVisible) {
              // 密钥密码输入弹窗
              Text($r('app.string.common_enter_passphrase'))
                .fontSize(FontSize.SUBTITLE)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.colors.textPrimary)
                .margin({ bottom: Spacing.MD })

              Text($r('app.string.detail_passphrase_hint'))
                .fontSize(FontSize.CAPTION)
                .fontColor(this.colors.textTertiary)
                .margin({ bottom: Spacing.LG })

              TextInput({ placeholder: $r('app.string.common_passphrase_placeholder') })
                .type(InputType.Password)
                .fontSize(FontSize.BODY)
                .width('100%')
                .height(ComponentSize.CONTROL)
                .borderRadius(Radius.CARD)
                .backgroundColor(this.colors.inputBackground)
                .onChange((v: string) => {
                  this.viewModel.dialogPassphrase = v;
                })

              Row() {
                Button($r('app.string.common_cancel'))
                  .type(ButtonType.Normal)
                  .borderRadius(ButtonSpec.SECONDARY_RADIUS)
                  .layoutWeight(1)
                  .height(ButtonSpec.SECONDARY_HEIGHT)
                  .backgroundColor(this.colors.neutralButton)
                  .fontColor(this.colors.textSecondary)
                  .margin({ right: Spacing.SM })
                  .onClick(() => {
                    this.viewModel.cancelPassphraseDialog();
                  })

                Button($r('app.string.common_confirm'))
                  .type(ButtonType.Normal)
                  .borderRadius(ButtonSpec.SECONDARY_RADIUS)
                  .layoutWeight(1)
                  .height(ButtonSpec.SECONDARY_HEIGHT)
                  .backgroundColor(this.colors.primary)
                  .fontColor(this.colors.onPrimary)
                  .onClick(() => {
                    this.viewModel.confirmPassphraseAndDecrypt();
                  })
              }
              .width('100%')
              .margin({ top: Spacing.LG })
            } else {
              Text($r('app.string.common_decrypt_failed'))
                .fontSize(FontSize.SUBTITLE)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.colors.danger)
              if (this.viewModel.errorMessage.length > 0) {
                Text(this.viewModel.errorMessage)
                  .fontSize(FontSize.BODY)
                  .fontColor(this.colors.textTertiary)
                  .margin({ top: Spacing.SM, left: Spacing.XL, right: Spacing.XL })
                  .textAlign(TextAlign.Center)
              }
            }
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .padding({ left: Spacing.XL, right: Spacing.XL })
        } else if (this.viewModel.content) {
          // 解密成功，显示内容
          Scroll() {
            Column() {
              // 密码行
              Row() {
                Text($r('app.string.common_password'))
                  .fontSize(FontSize.BODY)
                  .fontColor(this.colors.textSecondary)
                  .width(this.labelW)

                if (this.viewModel.isPasswordVisible) {
                  Text(this.viewModel.content.password)
                    .fontSize(FontSize.SUBTITLE)
                    .fontColor(this.colors.textPrimary)
                    .layoutWeight(1)
                    .fontFamily('monospace')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                } else {
                  Text('••••••••••••')
                    .fontSize(FontSize.SUBTITLE)
                    .layoutWeight(1)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .fontColor(this.colors.textTertiary)
                }

                Button({ type: ButtonType.Circle, stateEffect: true }) {
                  SymbolGlyph(this.viewModel.isPasswordVisible
                    ? $r('sys.symbol.eye') : $r('sys.symbol.eye_slash'))
                    .fontSize(IconSize.SM)
                    .fontColor([this.colors.textPrimary])
                }
                .width(ComponentSize.CONTROL_SMALL)
                .height(ComponentSize.CONTROL_SMALL)
                .backgroundColor(Color.Transparent)
                .margin({ left: Spacing.SM })
                .onClick(() => {
                  this.viewModel.togglePasswordVisibility();
                })
              }
              .width('100%')
              .height(ComponentSize.ROW)
              .padding({ left: Spacing.ROW_H, right: Spacing.ROW_H })
              .backgroundColor(this.colors.surface)
              .borderRadius(Radius.CARD)
              .alignItems(VerticalAlign.Center)

              // 用户名
              if (this.viewModel.content.username.length > 0) {
                Row() {
                  Text($r('app.string.common_username'))
                    .fontSize(FontSize.BODY)
                    .fontColor(this.colors.textSecondary)
                    .width(this.labelW)
                  Text(this.viewModel.content.username)
                    .fontSize(FontSize.SUBTITLE)
                    .layoutWeight(1)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })

                  CopyIconButton({
                    label: Strings.get('common_copy_username'),
                    onTap: (): void => {
                      this.viewModel.copyUsername();
                    },
                  })
                }
                .width('100%')
                .height(ComponentSize.ROW)
                .padding({ left: Spacing.ROW_H, right: Spacing.ROW_H })
                .backgroundColor(this.colors.surface)
                .borderRadius(Radius.CARD)
                .margin({ top: Spacing.CARD_GAP })
                .alignItems(VerticalAlign.Center)
              }

              // 邮箱
              if (this.viewModel.content.email.length > 0) {
                Row() {
                  Text($r('app.string.common_email'))
                    .fontSize(FontSize.BODY)
                    .fontColor(this.colors.textSecondary)
                    .width(this.labelW)
                  Text(this.viewModel.content.email)
                    .fontSize(FontSize.SUBTITLE)
                    .layoutWeight(1)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })

                  CopyIconButton({
                    label: Strings.get('common_copy_email'),
                    onTap: (): void => {
                      this.viewModel.copyEmail();
                    },
                  })
                }
                .width('100%')
                .height(ComponentSize.ROW)
                .padding({ left: Spacing.ROW_H, right: Spacing.ROW_H })
                .backgroundColor(this.colors.surface)
                .borderRadius(Radius.CARD)
                .margin({ top: Spacing.CARD_GAP })
                .alignItems(VerticalAlign.Center)
              }

              // 手机号
              if (this.viewModel.content.phone.length > 0) {
                Row() {
                  Text($r('app.string.common_phone'))
                    .fontSize(FontSize.BODY)
                    .fontColor(this.colors.textSecondary)
                    .width(this.labelW)
                  Text(this.viewModel.content.phone)
                    .fontSize(FontSize.SUBTITLE)
                    .layoutWeight(1)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })

                  CopyIconButton({
                    label: Strings.get('common_copy_phone'),
                    onTap: (): void => {
                      this.viewModel.copyPhone();
                    },
                  })
                }
                .width('100%')
                .height(ComponentSize.ROW)
                .padding({ left: Spacing.ROW_H, right: Spacing.ROW_H })
                .backgroundColor(this.colors.surface)
                .borderRadius(Radius.CARD)
                .margin({ top: Spacing.CARD_GAP })
                .alignItems(VerticalAlign.Center)
              }

              // 备注（直接展示，不做遮罩——与「额外内容」同理：它是条目正文而非凭据，
              // 遮起来反而妨碍阅读与核对）
              if (this.viewModel.content.notes.length > 0) {
                Row() {
                  Text($r('app.string.common_notes'))
                    .fontSize(FontSize.BODY)
                    .fontColor(this.colors.textSecondary)
                    .width(this.labelW)
                  Text(this.viewModel.content.notes)
                    .fontSize(FontSize.SUBTITLE)
                    .layoutWeight(1)
                    // 备注是自由文本，可能较长：给两行（64vp 的固定行高放得下），
                    // 再多就省略号——卡片高度必须与其它字段行一致
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })

                  CopyIconButton({
                    label: Strings.get('common_copy_notes'),
                    onTap: (): void => {
                      this.viewModel.copyNotes();
                    },
                  })
                }
                .width('100%')
                .height(ComponentSize.ROW)
                .padding({ left: Spacing.ROW_H, right: Spacing.ROW_H })
                .backgroundColor(this.colors.surface)
                .borderRadius(Radius.CARD)
                .margin({ top: Spacing.CARD_GAP })
                .alignItems(VerticalAlign.Center)
              }

              // 额外内容（直接展示，不做遮罩：它是条目正文而非凭据，遮起来反而妨碍阅读）
              if (this.viewModel.content.extraContent.trim().length > 0) {
                Column() {
                  Row() {
                    Text($r('app.string.common_extra_content'))
                      .fontSize(FontSize.BODY)
                      .fontColor(this.colors.textSecondary)
                      .layoutWeight(1)

                    CopyIconButton({
                      label: Strings.get('common_copy_extra'),
                      onTap: (): void => {
                        this.viewModel.copyExtraContent();
                      },
                    })
                  }
                  .width('100%')
                  .alignItems(VerticalAlign.Center)

                  Text(this.viewModel.content.extraContent)
                    .fontSize(FontSize.BODY)
                    .fontFamily('monospace')
                    .margin({ top: Spacing.SM })
                    .width('100%')
                }
                .width('100%')
                // 水平内边距与字段行一致（ROW_H），复制按钮右缘才能对齐；
                // 垂直留白沿用 MD（多行块比单行卡片需要更多呼吸空间）
                .padding({
                  left: Spacing.ROW_H, right: Spacing.ROW_H,
                  top: Spacing.MD, bottom: Spacing.MD,
                })
                .backgroundColor(this.colors.surface)
                .borderRadius(Radius.CARD)
                .margin({ top: Spacing.CARD_GAP })
                .alignItems(HorizontalAlign.Start)
              }
            }
            .padding({ left: Spacing.CARD, right: Spacing.CARD, top: Spacing.SM, bottom: Spacing.CARD })
          }
          .layoutWeight(1)
          .align(Alignment.TopStart)
          .scrollBar(BarState.Auto)
          // 滑到上下边界时给回弹动效反馈
          .edgeEffect(EdgeEffect.Spring)
        }

        // ===== 固定底部操作栏（不随列表滚动，仅解密成功后显示） =====
        if (this.viewModel.isDecrypted && this.viewModel.content) {
          Row() {
            Button($r('app.string.move_title'))
              .type(ButtonType.Normal)
              .borderRadius(ButtonSpec.SECONDARY_RADIUS)
              .layoutWeight(1)
              .height(ButtonSpec.SECONDARY_HEIGHT)
              .backgroundColor(this.colors.surface)
              .border({ width: 1, color: this.colors.divider, radius: ButtonSpec.SECONDARY_RADIUS })
              .fontColor(this.colors.textPrimary)
              .margin({ right: Spacing.SM })
              .onClick(() => {
                const param: Record<string, string> = { 'path': this.viewModel.relativePath };
                RouteManager.getInstance().pushPath(RouteNames.MOVE_ENTRY, param);
              })

            Button($r('app.string.detail_delete_password'))
              .type(ButtonType.Normal)
              .borderRadius(ButtonSpec.SECONDARY_RADIUS)
              .layoutWeight(1)
              .height(ButtonSpec.SECONDARY_HEIGHT)
              .backgroundColor(this.colors.danger)
              .fontColor(this.colors.onPrimary)
              .enabled(!this.viewModel.isDeleting)
              .onClick(() => {
                this.isDeleteDialogVisible = true;
              })
          }
          .width('100%')
          .padding({
            left: Spacing.CARD, right: Spacing.CARD, top: Spacing.MD,
            // 底部留白 = 系统导航条高度
            bottom: this.bottomInset,
          })
          .backgroundColor(this.colors.background)
          // 不要给底栏加顶边框：那会在按钮上方凭空多出一条分隔线（与页面其它处无对应）
          .alignItems(VerticalAlign.Center)
        }

        // 复制提示已改用系统悬浮气泡（showToast），不再占页面布局
      }
      .width('100%')
      .height('100%')
      .bindSheet(this.isDeleteDialogVisible, this.deleteConfirmBuilder(),
        this.deleteSheetOptions)
    }
    .backgroundColor(this.colors.background)
    .hideTitleBar(true)
  }

  /**
   * 删除确认面板：确认后执行删除，成功则返回列表页
   */
  @Builder
  deleteConfirmBuilder() {
    Column() {
      Text($r('app.string.detail_delete_password'))
        .fontSize(FontSize.SUBTITLE)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.colors.textPrimary)

      Text(Strings.fmt('detail_delete_confirm', this.viewModel.displayName))
        .fontSize(FontSize.BODY)
        .fontColor(this.colors.textSecondary)
        .lineHeight(20)
        .margin({ top: Spacing.MD })

      // 弹性占位：把按钮行撑到面板底部（与其它半模态弹窗一致）
      Blank()
        .layoutWeight(1)

      Row() {
        Button($r('app.string.common_cancel'))
          .type(ButtonType.Normal)
          .borderRadius(ButtonSpec.SECONDARY_RADIUS)
          .layoutWeight(1)
          .height(ButtonSpec.SECONDARY_HEIGHT)
          .backgroundColor(this.colors.neutralButton)
          .fontColor(this.colors.textPrimary)
          .enabled(!this.viewModel.isDeleting)
          .margin({ right: Spacing.SM })
          .onClick(() => {
            this.isDeleteDialogVisible = false;
          })

        Button(this.viewModel.isDeleting ? $r('app.string.common_deleting') : $r('app.string.delete'))
          .type(ButtonType.Normal)
          .borderRadius(ButtonSpec.SECONDARY_RADIUS)
          .layoutWeight(1)
          .height(ButtonSpec.SECONDARY_HEIGHT)
          .backgroundColor(this.colors.danger)
          .fontColor(this.colors.onPrimary)
          .enabled(!this.viewModel.isDeleting)
          .onClick(() => {
            this.viewModel.deleteEntry().then(() => {
              this.navigateBackAfterDelete();
            });
          })
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    // 统一面板内边距：顶部让开 dragBar，底部给按钮行留出与屏幕下沿的距离
    .padding({ top: SHEET_PAD_TOP, left: Spacing.XL, right: Spacing.XL, bottom: SHEET_PAD_BOTTOM })
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(this.colors.surface)
  }
}
