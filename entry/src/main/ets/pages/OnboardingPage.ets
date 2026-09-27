import { OnboardingViewModel, RepoSetupOutcome, STEP_WELCOME, STEP_REPO_SETUP, STEP_KEY_IMPORT, STEP_FINISH } from '../viewmodel/OnboardingViewModel';
import { AppTitleBar } from '../views/AppTitleBar';
import { LoadingOverlay } from '../views/LoadingOverlay';
import { HostKeyConfirmDialog } from '../views/HostKeyConfirmDialog';
import { ThemeColors, Palette, FontSize, ButtonSpec, Spacing, Radius, ComponentSize, IconSize, DividerSpec } from '../common/ThemeColors';
import { RouteManager } from '../common/RouteManager';
import { RouteNames } from '../common/Constants';
import { Strings } from '../common/Strings';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** hilog 域 */
const DOMAIN: number = 0x0001;
/** hilog 标签 */
const TAG: string = 'OnboardingPage';

/**
 * 引导页
 *
 * 首次启动时分步引导：
 * 1. 欢迎/功能说明
 * 2. 仓库初始化（新建本地仓库 或 克隆远程仓库）
 * 3. PGP 密钥导入
 * 4. 完成
 */
/** 引导页底部按钮固定宽度（跳过/上一步） */
const ONBOARDING_BUTTON_WIDTH: number = 110;

@ComponentV2
export struct OnboardingPage {
  @Local viewModel: OnboardingViewModel = new OnboardingViewModel();
  /** 主机指纹确认弹窗 id（-1 = 未打开） */
  @Local hostKeyDialogId: number = -1;

  private get colors(): Palette {
    return ThemeColors.getInstance().palette();
  }

  /**
   * 执行仓库初始化，并按结果决定是否弹「本地目录已有内容」确认框
   *
   * 本页没有「保存」按钮，也就没有 Git 配置页那条「保存后询问是否克隆」的路径——
   * 目录非空时必须在**这里**给出「删除并克隆」的入口，否则用户只看到一句
   * 让他去点一个并不存在的按钮的提示。
   */
  private runRepoSetup(): void {
    this.viewModel.setupRepository().then((outcome: RepoSetupOutcome): void => {
      if (outcome === RepoSetupOutcome.NEEDS_CLEAN) {
        this.confirmDeleteAndClone();
      } else {
        // 克隆被主机密钥确认打断时弹指纹确认弹窗（其余失败走 errorMessage）
        this.maybeShowHostKeyDialog();
      }
    });
  }

  /**
   * TOFU 主机密钥确认：有待确认指纹时弹确认弹窗
   *
   * 曾是克隆表单下方的一张卡片，指纹和确认按钮离触发点很远；改为弹窗后
   * 「首次连接确认指纹」必须当场决定，与系统应用的安全确认一致。
   * 服务器可能提供多把不同类型的主机密钥，确认一把后继续克隆还可能
   * 遇到下一把，故每次克隆相关流程返回后都要调一次本方法。
   *
   * 用自绘弹窗（HostKeyConfirmDialog）而不是 showAlertDialog：系统弹窗内边距
   * 不可调、标题贴顶（实测反馈），且指纹需要等宽字体单独框出便于核对。
   */
  /**
   * 主机指纹确认弹窗内容
   *
   * **必须是页面的 @Builder**：在 openCustomDialog 的普通箭头函数里直接
   * `HostKeyConfirmDialog({...})` 不会被 ArkUI 编译期转换，运行时报
   * `class constructor cannot called without 'new'`（实测整个应用闪退）。
   * 弹窗内容是一次性快照，@Builder 按值传参不刷新在这里无影响。
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
        this.viewModel.cancelHostKeyConfirm();
      },
      onConfirm: (): void => {
        this.closeHostKeyDialog();
        // 确认后继续克隆；服务器又出示另一把未记录类型的主机密钥时再弹一次
        this.viewModel.confirmHostKeyAndClone().then((outcome: RepoSetupOutcome): void => {
          if (outcome === RepoSetupOutcome.NEEDS_CLEAN) {
            this.confirmDeleteAndClone();
          } else {
            this.maybeShowHostKeyDialog();
          }
        });
      },
    })
  }

  private maybeShowHostKeyDialog(): void {
    if (this.viewModel.pendingHostKeyFp.length === 0) {
      return;
    }
    const mismatch: boolean = this.viewModel.pendingHostKeyMismatch;
    const keyType: string = this.viewModel.pendingHostKeyType;
    const title: string = mismatch
      ? Strings.get('sync_hostkey_mismatch_title')
      : (keyType.length > 0 ? Strings.fmt('sync_hostkey_first_type', keyType) : Strings.get('sync_hostkey_first'));
    const hostLine: string = keyType.length > 0
      ? Strings.fmt('gitcfg_hostkey_fp_typed', this.viewModel.pendingHost, this.viewModel.pendingPort, keyType)
      : Strings.fmt('onboarding_hostkey_fp_line', this.viewModel.pendingHost, this.viewModel.pendingPort);
    const explanation: string = mismatch
      ? Strings.get('gitcfg_hostkey_mismatch_explain')
      : Strings.get('sync_hostkey_new_detail');
    const fingerprint: string = this.viewModel.pendingHostKeyFp;
    const confirmLabel: string = mismatch
      ? Strings.get('onboarding_trust_clone_mismatch')
      : Strings.get('onboarding_trust_clone');
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

  /** 本地目录非空：征求确认后删除再克隆（删除不可逆，文案必须说清后果） */
  private confirmDeleteAndClone(): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.onboarding_local_not_empty'),
      message: $r('app.string.onboarding_local_not_empty_msg'),
      autoCancel: false,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: $r('app.string.common_cancel'),
        action: (): void => {},
      },
      secondaryButton: {
        value: $r('app.string.onboarding_delete_clone'),
        fontColor: this.colors.danger,
        action: (): void => {
          this.viewModel.deleteLocalRepoThenClone().then((outcome: RepoSetupOutcome): void => {
            if (outcome !== RepoSetupOutcome.NEEDS_CLEAN) {
              this.maybeShowHostKeyDialog();
            }
          });
        },
      },
    });
  }


  @Builder
  stepIndicator() {
    Row() {
      ForEach([0, 1, 2, 3], (step: number) => {
        Circle()
          .width(this.viewModel.currentStep === step ? IconSize.STEP_DOT_ACTIVE : IconSize.STEP_DOT)
          .height(this.viewModel.currentStep === step ? IconSize.STEP_DOT_ACTIVE : IconSize.STEP_DOT)
          .fill(this.viewModel.currentStep >= step ? this.colors.primary : this.colors.divider)
          .margin({ left: Spacing.XS, right: Spacing.XS })
      }, (step: number) => step.toString())
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
    .margin({ bottom: Spacing.XL })
  }

  @Builder
  welcomeStep() {
    Column() {
      Text($r('app.string.onboarding_welcome_title'))
        .fontSize(FontSize.DISPLAY_MD)
        .fontWeight(FontWeight.Bold)
        .textAlign(TextAlign.Center)

      Text($r('app.string.onboarding_welcome_desc'))
        .fontSize(FontSize.BODY)
        .fontColor(this.colors.textSecondary)
        .lineHeight(22)
        .textAlign(TextAlign.Center)
        .margin({ top: Spacing.LG })

      Column() {
        Text($r('app.string.onboarding_feature_pass'))
          .fontSize(FontSize.CAPTION)
          .fontColor(this.colors.textTertiary)
          .margin({ bottom: Spacing.SM })
        Text($r('app.string.onboarding_feature_huks'))
          .fontSize(FontSize.CAPTION)
          .fontColor(this.colors.textTertiary)
          .margin({ bottom: Spacing.SM })
        Text($r('app.string.onboarding_feature_git'))
          .fontSize(FontSize.CAPTION)
          .fontColor(this.colors.textTertiary)
          .margin({ bottom: Spacing.SM })
        Text($r('app.string.onboarding_feature_passgen'))
          .fontSize(FontSize.CAPTION)
          .fontColor(this.colors.textTertiary)
      }
      .margin({ top: Spacing.XL })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: Spacing.XL, right: Spacing.XL })
  }

  @Builder
  repoSetupStep() {
    Column() {
      Text($r('app.string.onboarding_repo_title'))
        .fontSize(FontSize.TITLE)
        .fontWeight(FontWeight.Bold)

      Text($r('app.string.onboarding_repo_desc'))
        .fontSize(FontSize.CAPTION)
        .fontColor(this.colors.textTertiary)
        .margin({ top: Spacing.SM })

      // 方式选择
      Row() {
        Column() {
          Text($r('app.string.onboarding_mode_new'))
            .fontSize(FontSize.SUBTITLE)
            .fontWeight(this.viewModel.repoMode === 'new' ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(this.viewModel.repoMode === 'new' ? this.colors.primary : this.colors.textSecondary)
        }
        .layoutWeight(1)
        .height(ComponentSize.ROW_TWO_LINE)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.viewModel.repoMode === 'new' ? this.colors.primarySoft : this.colors.inputBackground)
        .borderRadius(Radius.CARD)
        .border({
          width: DividerSpec.SELECTED_STROKE,
          color: this.viewModel.repoMode === 'new' ? this.colors.primary : Color.Transparent
        })
        .stateStyles({
          normal: {
            .backgroundColor(this.viewModel.repoMode === 'new' ? this.colors.primarySoft : this.colors.inputBackground)
          },
          pressed: { .backgroundColor(this.colors.pressed) },
        })
        .onClick(() => {
          this.viewModel.setRepoMode('new');
        })

        Column() {
          Text($r('app.string.onboarding_mode_clone'))
            .fontSize(FontSize.SUBTITLE)
            .fontWeight(this.viewModel.repoMode === 'clone' ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(this.viewModel.repoMode === 'clone' ? this.colors.primary : this.colors.textSecondary)
        }
        .layoutWeight(1)
        .height(ComponentSize.ROW_TWO_LINE)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.viewModel.repoMode === 'clone' ? this.colors.primarySoft : this.colors.inputBackground)
        .borderRadius(Radius.CARD)
        .border({
          width: DividerSpec.SELECTED_STROKE,
          color: this.viewModel.repoMode === 'clone' ? this.colors.primary : Color.Transparent
        })
        .margin({ left: Spacing.MD })
        .stateStyles({
          normal: {
            .backgroundColor(this.viewModel.repoMode === 'clone' ? this.colors.primarySoft : this.colors.inputBackground)
          },
          pressed: { .backgroundColor(this.colors.pressed) },
        })
        .onClick(() => {
          this.viewModel.setRepoMode('clone');
        })
      }
      .width('100%')
      .margin({ top: Spacing.XL })

      // 克隆地址输入
      if (this.viewModel.repoMode === 'clone') {
        TextInput({
          text: this.viewModel.remoteUrl,
          placeholder: $r('app.string.onboarding_url_placeholder')
        })
          .fontSize(FontSize.SUBTITLE)
          .placeholderFont({ size: FontSize.SUBTITLE })
          .placeholderColor(this.colors.textTertiary)
          .width('100%')
          .height(ComponentSize.ROW)
          .borderRadius(Radius.CARD)
          // 浅色模式下 inputBackground(#F1F3F5) 与页面背景(background #F1F3F5)相同，
          // 输入框直接在页面背景上（无卡片包裹）会完全融为一体。
          // 改用 surface(白色) + divider 边框，与 PasswordListPage 搜索框同款处理。
          .backgroundColor(this.colors.surface)
          .border({ width: DividerSpec.STROKE, color: this.colors.divider })
          .margin({ top: Spacing.LG })
          .onChange((v: string) => {
            this.viewModel.remoteUrl = v;
          })

        // SSH 密钥配置卡片：左侧密钥状态（未配置/已配置的密钥名），右侧配置按钮
        Row() {
          Text(this.viewModel.sshKeyLabel.length > 0
            ? this.viewModel.sshKeyLabel : Strings.get('onboarding_ssh_not_configured'))
            .fontSize(FontSize.BODY)
            .fontColor(this.viewModel.sshKeyLabel.length > 0
              ? this.colors.textPrimary : this.colors.textTertiary)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          Button($r('app.string.onboarding_ssh_configure'))
            .type(ButtonType.Normal)
            .borderRadius(ButtonSpec.SMALL_RADIUS)
            .height(ButtonSpec.SMALL_HEIGHT)
            .fontSize(FontSize.CAPTION)
            .backgroundColor(this.colors.primarySoft)
            .fontColor(this.colors.primary)
            .margin({ left: Spacing.SM })
            .onClick(() => {
              RouteManager.getInstance().pushPath(RouteNames.SSH_KEY_MANAGER);
            })
        }
        .width('100%')
        .height(ComponentSize.ROW)
        .padding({ left: Spacing.ROW_H, right: Spacing.SM })
        .backgroundColor(this.colors.surface)
        .borderRadius(Radius.CARD)
        .alignItems(VerticalAlign.Center)
        .margin({ top: Spacing.CARD_GAP })
      }

      // TOFU 主机密钥确认已改为原生弹窗（maybeShowHostKeyDialog），不再占页面卡片

      if (this.viewModel.progressText.length > 0) {
        Row() {
          LoadingProgress()
            .width(IconSize.XS)
            .height(IconSize.XS)
            .margin({ right: Spacing.SM })
          Text(this.viewModel.progressText)
            .fontSize(FontSize.BODY)
            .fontColor(this.colors.textSecondary)
        }
        .margin({ top: Spacing.MD })
      }
    }
    .width('100%')
    .padding({ left: Spacing.XL, right: Spacing.XL })
  }

  @Builder
  keyImportStep() {
    Column() {
      Text($r('app.string.onboarding_pgp_title'))
        .fontSize(FontSize.TITLE)
        .fontWeight(FontWeight.Bold)

      Text($r('app.string.onboarding_pgp_desc'))
        .fontSize(FontSize.CAPTION)
        .fontColor(this.colors.textTertiary)
        .lineHeight(20)
        .margin({ top: Spacing.SM })

      // PGP 密钥浏览卡片：左侧密钥状态（未配置/已配置的密钥名），右侧浏览按钮
      Row() {
        // 「浏览」按钮前显示已导入的密钥名称（从密钥管理页返回后由 onShown 刷新）
        Text(this.viewModel.importedKeyLabel.length > 0
          ? this.viewModel.importedKeyLabel
          : Strings.get('onboarding_pgp_not_set'))
          .fontSize(FontSize.BODY)
          .fontColor(this.viewModel.importedKeyLabel.length > 0
            ? this.colors.textPrimary : this.colors.textTertiary)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Button($r('app.string.onboarding_browse'))
          .type(ButtonType.Normal)
          .borderRadius(ButtonSpec.SMALL_RADIUS)
          .height(ButtonSpec.SMALL_HEIGHT)
          .fontSize(FontSize.CAPTION)
          .backgroundColor(this.colors.primarySoft)
          .fontColor(this.colors.primary)
          .margin({ left: Spacing.SM })
          .enabled(!this.viewModel.isWorking)
          .onClick(() => {
            RouteManager.getInstance().pushPath(RouteNames.PGP_KEY_MANAGER);
          })
      }
      .width('100%')
      .height(ComponentSize.ROW)
      .padding({ left: Spacing.ROW_H, right: Spacing.SM })
      .backgroundColor(this.colors.surface)
      .borderRadius(Radius.CARD)
      .alignItems(VerticalAlign.Center)
      .margin({ top: Spacing.CARD_GAP })

      if (this.viewModel.progressText.length > 0) {
        Row() {
          LoadingProgress()
            .width(IconSize.XS)
            .height(IconSize.XS)
            .margin({ right: Spacing.SM })
          Text(this.viewModel.progressText)
            .fontSize(FontSize.BODY)
            .fontColor(this.colors.textSecondary)
        }
        .margin({ top: Spacing.MD })
      }

    }
    .width('100%')
    .padding({ left: Spacing.XL, right: Spacing.XL })
  }

  @Builder
  finishStep() {
    Column() {
      Text($r('app.string.onboarding_finish_title'))
        .fontSize(FontSize.DISPLAY_MD)
        .fontWeight(FontWeight.Bold)

      Text($r('app.string.onboarding_finish_desc'))
        .fontSize(FontSize.BODY)
        .fontColor(this.colors.textSecondary)
        .margin({ top: Spacing.MD })

      Column() {
        Text(this.viewModel.isRepoReady ? $r('app.string.onboarding_repo_done') : $r('app.string.onboarding_repo_todo'))
          .fontSize(FontSize.CAPTION)
          .fontColor(this.viewModel.isRepoReady ? this.colors.success : this.colors.textTertiary)
          .margin({ bottom: Spacing.SM })
        Text(this.viewModel.isKeyReady ? $r('app.string.onboarding_key_done') : $r('app.string.onboarding_key_todo'))
          .fontSize(FontSize.CAPTION)
          .fontColor(this.viewModel.isKeyReady ? this.colors.success : this.colors.textTertiary)
      }
      .margin({ top: Spacing.XL })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: Spacing.XL, right: Spacing.XL })
  }

  build() {
    NavDestination() {
      Column() {
        AppTitleBar({ title: $r('app.string.onboarding_setup_title') })

        this.stepIndicator()

        // 步骤内容
        if (this.viewModel.currentStep === STEP_WELCOME) {
          this.welcomeStep()
        } else if (this.viewModel.currentStep === STEP_REPO_SETUP) {
          this.repoSetupStep()
        } else if (this.viewModel.currentStep === STEP_KEY_IMPORT) {
          this.keyImportStep()
        } else if (this.viewModel.currentStep === STEP_FINISH) {
          this.finishStep()
        }

        // 错误提示
        if (this.viewModel.errorMessage.length > 0) {
          Text(this.viewModel.errorMessage)
            .fontSize(FontSize.BODY)
            .fontColor(this.colors.danger)
            .margin({ top: Spacing.MD })
        }

        Blank()

        // 底部按钮
        Row({ space: ButtonSpec.ROW_GAP }) {
          if (this.viewModel.currentStep === STEP_WELCOME) {
            // 欢迎页左侧给「跳过」：直接结束初始设置进应用（仓库未初始化也能进，
            // 之后可在「设置 → 重新运行初始设置」里再走一遍）
            // 次要按钮用系统原生风格：中性灰底 + 主文本色（不用次要文本色，太淡）
            Button($r('app.string.onboarding_skip'))
              .type(ButtonType.Normal)
              .borderRadius(ButtonSpec.SECONDARY_RADIUS)
              .width(ONBOARDING_BUTTON_WIDTH)
              .height(ButtonSpec.SECONDARY_HEIGHT)
              .fontSize(ButtonSpec.FONT_SIZE)
              .backgroundColor(this.colors.neutralButton)
              .fontColor(this.colors.textPrimary)
              .enabled(!this.viewModel.isWorking)
              .onClick(() => {
                this.viewModel.finish();
              })
          } else {
            Button($r('app.string.onboarding_prev'))
              .type(ButtonType.Normal)
              .borderRadius(ButtonSpec.SECONDARY_RADIUS)
              .width(ONBOARDING_BUTTON_WIDTH)
              .height(ButtonSpec.SECONDARY_HEIGHT)
              .fontSize(ButtonSpec.FONT_SIZE)
              .backgroundColor(this.colors.neutralButton)
              .fontColor(this.colors.textPrimary)
              .enabled(!this.viewModel.isWorking)
              .onClick(() => {
                this.viewModel.prevStep();
              })
          }

          Button(this.viewModel.currentStep === STEP_WELCOME ? $r('app.string.common_start') :
            this.viewModel.currentStep === STEP_REPO_SETUP ? $r('app.string.onboarding_init_repo') :
            this.viewModel.currentStep === STEP_KEY_IMPORT
              ? (this.viewModel.isKeyConfigured() ? $r('app.string.onboarding_next') : $r('app.string.onboarding_skip'))
              : $r('app.string.onboarding_done'))
            .type(ButtonType.Normal)
            .borderRadius(ButtonSpec.PRIMARY_RADIUS)
            .layoutWeight(1)
            .height(ButtonSpec.PRIMARY_HEIGHT)
            .fontSize(ButtonSpec.FONT_SIZE)
            .backgroundColor(this.colors.primary)
            .fontColor(this.colors.onPrimary)
            .enabled(!this.viewModel.isWorking)
            .onClick(() => {
              if (this.viewModel.currentStep === STEP_REPO_SETUP) {
                this.runRepoSetup();
              } else if (this.viewModel.currentStep === STEP_KEY_IMPORT) {
                // 已配置密钥时按钮是「下一步」，按正常流程推进；
                // 未配置时才是「跳过」（skipKeyImport 会把 isKeyReady 置 false，
                // 已导入的密钥不能被它清掉）
                if (this.viewModel.isKeyConfigured()) {
                  this.viewModel.nextStep();
                } else {
                  this.viewModel.skipKeyImport();
                }
              } else if (this.viewModel.currentStep === STEP_FINISH) {
                this.viewModel.finish();
              } else {
                this.viewModel.nextStep();
              }
            })
        }
        .width('100%')
        .padding({ left: Spacing.XL, right: Spacing.XL, bottom: Spacing.XL })

        // ===== 克隆进度：全模态遮罩 =====
        // `.position({x:0,y:0})` 把它**移出文档流**、叠在整页之上（同 PasswordListPage
        // 的设置菜单遮罩）。曾只给 width/height 100% 而不加 position：作为 Column 的
        // 子节点它被排在前面的内容之后，实测只盖住下半屏、居中的进度卡片还被挤出屏幕。
        // 返回键另见 onBackPressed（遮罩挡不住系统返回手势）。
        if (this.viewModel.isCloning) {
          LoadingOverlay({
            text: this.viewModel.clonePercent >= 100
              ? Strings.get('onboarding_overlay_checkout')
              : Strings.get('onboarding_overlay_cloning'),
            percent: this.viewModel.clonePercent,
          })
            .position({ x: 0, y: 0 })
        }
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    .backgroundColor(this.colors.background)
    // 克隆中吞掉返回（含侧滑返回）：遮罩挡不住系统返回手势。返回 true 表示
    // 覆盖默认返回逻辑——否则用户返回后克隆仍在后台跑，完成后本页已销毁、
    // 结果无人接收，而仓库可能已经克隆好了，用户却以为失败。
    .onBackPressed((): boolean => this.viewModel.isCloning)
    // 从子页（PGP 密钥管理 / SSH 密钥管理）返回时重读：本页一直活着，
    // 不刷新就永远显示旧状态
    .onShown(() => {
      this.viewModel.refreshImportedKey();
      this.viewModel.refreshSshKey();
    })
  }
}
