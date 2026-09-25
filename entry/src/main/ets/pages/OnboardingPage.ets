import { OnboardingViewModel, RepoSetupOutcome, STEP_WELCOME, STEP_REPO_SETUP, STEP_KEY_IMPORT, STEP_FINISH } from '../viewmodel/OnboardingViewModel';
import { AppTitleBar } from '../views/AppTitleBar';
import { LoadingOverlay } from '../views/LoadingOverlay';
import { HostKeyConfirmDialog } from '../views/HostKeyConfirmDialog';
import { ThemeColors, Palette, FontSize, ButtonSpec, Spacing, Radius, ComponentSize, IconSize } from '../common/ThemeColors';
import { RouteManager } from '../common/RouteManager';
import { RouteNames } from '../common/Constants';
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
      ? '警告：主机密钥与已保存记录不一致'
      : (keyType.length > 0 ? `首次连接：确认服务器${keyType}密钥指纹` : '首次连接：确认服务器指纹');
    const hostLine: string = `主机 ${this.viewModel.pendingHost}:${this.viewModel.pendingPort} 的密钥指纹`
      + (keyType.length > 0 ? `（${keyType}）` : '') + '：';
    const explanation: string = mismatch
      ? '该主机已有信任记录，但本次同类型密钥的指纹不同。这可能是服务器更换了密钥，也可能是中间人攻击——'
        + '请与服务器管理员核对后再决定；确认后将覆盖该类型记录。'
      : '服务器提供多把不同类型的主机密钥，这是尚未记录的一把。确认后追加为本机信任记录；'
        + '同类型密钥的指纹变化仍会被拒绝（防中间人攻击）。';
    const fingerprint: string = this.viewModel.pendingHostKeyFp;
    const confirmLabel: string = mismatch ? '仍要信任并克隆' : '信任并克隆';
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
      title: '本地目录已有内容',
      message: '克隆要求目标目录为空，当前目录中已有文件（可能是上次克隆的残留或旧仓库）。\n\n'
        + '继续将删除该目录下的全部内容，再从远程仓库重新克隆。此操作不可撤销。',
      autoCancel: false,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: (): void => {},
      },
      secondaryButton: {
        value: '删除并克隆',
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
          .width(this.viewModel.currentStep === step ? 10 : 8)
          .height(this.viewModel.currentStep === step ? 10 : 8)
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
      Text('欢迎使用 HarmonyPasswordStore')
        .fontSize(FontSize.DISPLAY_MD)
        .fontWeight(FontWeight.Bold)
        .textAlign(TextAlign.Center)

      Text('与 pass 命令行工具完全兼容的密码管理器。密码以 GPG 加密文件存储，可通过 Git 在多设备间同步。')
        .fontSize(FontSize.BODY)
        .fontColor(this.colors.textSecondary)
        .lineHeight(22)
        .textAlign(TextAlign.Center)
        .margin({ top: Spacing.LG })

      Column() {
        Text('· 标准 pass 目录结构与 .gpg 加密文件')
          .fontSize(FontSize.CAPTION)
          .fontColor(this.colors.textTertiary)
          .margin({ bottom: Spacing.SM })
        Text('· PGP 加密，密钥由 HUKS 安全管理')
          .fontSize(FontSize.CAPTION)
          .fontColor(this.colors.textTertiary)
          .margin({ bottom: Spacing.SM })
        Text('· Git 同步，支持 HTTPS 与 SSH')
          .fontSize(FontSize.CAPTION)
          .fontColor(this.colors.textTertiary)
          .margin({ bottom: Spacing.SM })
        Text('· 内置密码生成器与口令词组')
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
      Text('初始化密码仓库')
        .fontSize(FontSize.TITLE)
        .fontWeight(FontWeight.Bold)

      Text('新建一个空仓库，或从远程 Git 仓库克隆已有密码库。')
        .fontSize(FontSize.CAPTION)
        .fontColor(this.colors.textTertiary)
        .margin({ top: Spacing.SM })

      // 方式选择
      Row() {
        Column() {
          Text('新建仓库')
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
          width: 2,
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
          Text('克隆远程')
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
          width: 2,
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
          placeholder: 'git@host:用户名/仓库.git'
        })
          .fontSize(FontSize.SUBTITLE)
          .placeholderFont({ size: FontSize.SUBTITLE })
          .placeholderColor(this.colors.textTertiary)
          .width('100%')
          .height(ComponentSize.CONTROL)
          .borderRadius(Radius.MD)
          .backgroundColor(this.colors.inputBackground)
          .margin({ top: Spacing.LG })
          .onChange((v: string) => {
            this.viewModel.remoteUrl = v;
          })

        // SSH 密钥配置卡片：左侧密钥状态（未配置/已配置的密钥名），右侧配置按钮
        Row() {
          Text(this.viewModel.sshKeyLabel.length > 0
            ? this.viewModel.sshKeyLabel : '未配置SSH密钥')
            .fontSize(FontSize.BODY)
            .fontColor(this.viewModel.sshKeyLabel.length > 0
              ? this.colors.textPrimary : this.colors.textTertiary)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          Button('配置SSH密钥')
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
      Text('设置 PGP 密钥')
        .fontSize(FontSize.TITLE)
        .fontWeight(FontWeight.Bold)

      Text('点击「浏览」进入 PGP 密钥管理页，在那里新建或导入密钥（.asc / .pgp 文件或粘贴文本）。'
        + '私钥将由系统 HUKS 安全保管，不会明文落盘。')
        .fontSize(FontSize.CAPTION)
        .fontColor(this.colors.textTertiary)
        .lineHeight(20)
        .margin({ top: Spacing.SM })

      // 文件选择 + 导入按钮
      Column() {
        Row() {
          // 「浏览」按钮前显示已导入的密钥名称（从密钥管理页返回后由 onShown 刷新）
          Text(this.viewModel.importedKeyLabel.length > 0
            ? this.viewModel.importedKeyLabel
            : '尚未设置 PGP 密钥')
            .fontSize(FontSize.BODY)
            .fontColor(this.viewModel.importedKeyLabel.length > 0
              ? this.colors.textPrimary : this.colors.textTertiary)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          Button('浏览')
            .type(ButtonType.Normal)
            .borderRadius(ButtonSpec.SMALL_RADIUS)
            .height(ButtonSpec.SMALL_HEIGHT)
            .backgroundColor(this.colors.primarySoft)
            .fontColor(this.colors.primary)
            .enabled(!this.viewModel.isWorking)
            .onClick(() => {
              RouteManager.getInstance().pushPath(RouteNames.PGP_KEY_MANAGER);
            })
        }
        .width('100%')

      }
      .width('100%')
      .padding(Spacing.CARD)
      .backgroundColor(this.colors.inputBackground)
      .borderRadius(Radius.CARD)
      .border({ width: 1, color: this.colors.divider })
      .margin({ top: Spacing.LG })

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
      Text('设置完成')
        .fontSize(FontSize.DISPLAY_MD)
        .fontWeight(FontWeight.Bold)

      Text('一切就绪！现在可以开始管理您的密码了。')
        .fontSize(FontSize.BODY)
        .fontColor(this.colors.textSecondary)
        .margin({ top: Spacing.MD })

      Column() {
        Text(this.viewModel.isRepoReady ? '✓ 密码仓库已初始化' : '· 密码仓库未初始化（可稍后在设置中完成）')
          .fontSize(FontSize.CAPTION)
          .fontColor(this.viewModel.isRepoReady ? this.colors.success : this.colors.textTertiary)
          .margin({ bottom: Spacing.SM })
        Text(this.viewModel.isKeyReady ? '✓ PGP 密钥已导入' : '· PGP 密钥未导入（可稍后在设置中完成）')
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
        AppTitleBar({ title: '初始设置' })

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
            Button('跳过')
              .type(ButtonType.Normal)
              .borderRadius(ButtonSpec.SECONDARY_RADIUS)
              .width(110)
              .height(ButtonSpec.SECONDARY_HEIGHT)
              .fontSize(ButtonSpec.FONT_SIZE)
              .backgroundColor(this.colors.neutralButton)
              .fontColor(this.colors.textPrimary)
              .enabled(!this.viewModel.isWorking)
              .onClick(() => {
                this.viewModel.finish();
              })
          } else {
            Button('上一步')
              .type(ButtonType.Normal)
              .borderRadius(ButtonSpec.SECONDARY_RADIUS)
              .width(110)
              .height(ButtonSpec.SECONDARY_HEIGHT)
              .fontSize(ButtonSpec.FONT_SIZE)
              .backgroundColor(this.colors.neutralButton)
              .fontColor(this.colors.textPrimary)
              .enabled(!this.viewModel.isWorking)
              .onClick(() => {
                this.viewModel.prevStep();
              })
          }

          Button(this.viewModel.currentStep === STEP_WELCOME ? '开始' :
            this.viewModel.currentStep === STEP_REPO_SETUP ? '初始化仓库' :
            this.viewModel.currentStep === STEP_KEY_IMPORT
              ? (this.viewModel.isKeyConfigured() ? '下一步' : '跳过') : '完成')
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
            text: this.viewModel.clonePercent >= 100 ? '正在检出文件…' : '正在克隆远程仓库…',
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
