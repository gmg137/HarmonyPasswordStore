import { GitConfigViewModel } from '../viewmodel/GitConfigViewModel';
import { showToastSafe } from '../utils/ToastUtil';
import { GitAuthMode, SshKeyType, sshKeyTypeLabel, RouteNames } from '../common/Constants';
import { RouteManager } from '../common/RouteManager';
import { ThemeColors, Palette, ButtonSpec, Spacing, FontSize, Radius, IconSize, ComponentSize, DividerSpec } from '../common/ThemeColors';
import { SshKeyInfo } from '../crypto/SshKeyManager';
import { panelSheetOptions, themedSheetOptions, SHEET_PAD_TOP, SHEET_PAD_BOTTOM } from '../common/SheetStyles';
import { AppTitleBar } from '../views/AppTitleBar';
import { LoadingOverlay } from '../views/LoadingOverlay';
import { FormRow } from '../views/FormRow';
import { HostKeyConfirmDialog } from '../views/HostKeyConfirmDialog';
import { Strings } from '../common/Strings';
import { SystemInsets } from '../utils/SystemInsets';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** hilog 域 */
const DOMAIN: number = 0x0001;
/** hilog 标签 */
const TAG: string = 'GitConfigPage';

/**
 * Git 配置页
 *
 * 配置远程仓库地址、认证方式（HTTPS/SSH）、committer 身份与网络选项。
 * 布局对齐 HarmonyOS Design：自定义沉浸式标题栏（跟随主题背景）、
 * 分组卡片（16vp 圆角 + 16vp 内边距）、分段控件、语义色状态提示。
 */
@ComponentV2
export struct GitConfigPage {
  @Local viewModel: GitConfigViewModel = new GitConfigViewModel();
  @Local isSshKeyPickerVisible: boolean = false;
  /** 主机指纹确认弹窗 id（-1 = 未打开） */
  @Local hostKeyDialogId: number = -1;
  /** 底部系统栏（导航条/手势条）高度（vp）：沉浸式布局下底部按钮栏据此避让 */
  @Local bottomInset: number = 0;

  private get colors(): Palette {
    return ThemeColors.getInstance().palette();
  }

  /** SSH 密钥选择面板配置：getter + themedSheetOptions（backgroundColor 随主题刷新，防上拉露旧色） */
  private get sshKeyPickerOptions(): SheetOptions {
    return themedSheetOptions(this, 'GitSshPicker', 
      (): SheetOptions => panelSheetOptions(this.colors.surface, 400, (): void => {
        this.isSshKeyPickerVisible = false;
      }),
      this.colors.surface, 400);
  }

  aboutToAppear(): void {
    this.viewModel.load();
    // 沉浸式布局下底部固定栏要避开系统导航条（换算集中见 SystemInsets）
    this.bottomInset = SystemInsets.bottomVp();
  }

  /**
   * 保存成功后询问是否立即克隆
   *
   * 配置保存完通常下一步就是克隆，省掉「回仓库管理再找入口」的往返。
   */
  private askCloneAfterSave(): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.gitcfg_saved_title'),
      message: Strings.fmt('gitcfg_clone_after_save_msg', this.viewModel.remoteUrl),
      autoCancel: false,
      alignment: DialogAlignment.Center,
      onWillDismiss: (action: DismissDialogAction): void => {
        action.dismiss();
      },
      primaryButton: {
        value: $r('app.string.common_cancel'),
        action: (): void => {
          RouteManager.getInstance().pop();
        },
      },
      secondaryButton: {
        value: $r('app.string.gitcfg_clone_btn'),
        fontColor: this.colors.primary,
        action: (): void => {
          this.startClone();
        },
      },
    });
  }

  /**
   * 开始克隆；本地已有仓库时先征求确认（git clone 要求目标目录为空）
   */
  private startClone(): void {
    if (!this.viewModel.needsCleanBeforeClone()) {
      this.runClone();
      return;
    }
    this.getUIContext().showAlertDialog({
      title: $r('app.string.gitcfg_needs_clean_title'),
      message: Strings.get('gitcfg_needs_clean_msg'),
      autoCancel: false,
      alignment: DialogAlignment.Center,
      onWillDismiss: (action: DismissDialogAction): void => {
        action.dismiss();
      },
      primaryButton: {
        value: $r('app.string.common_cancel'),
        action: (): void => {},
      },
      secondaryButton: {
        value: $r('app.string.gitcfg_delete_and_clone'),
        fontColor: this.colors.danger,
        action: (): void => {
          this.viewModel.deleteLocalRepoThenClone().then((ok: boolean): void => {
            if (ok) {
              RouteManager.getInstance().pop();
            } else {
              this.maybeShowHostKeyDialog();
            }
          });
        },
      },
    });
  }

  /**
   * TOFU 主机密钥确认：有待确认指纹时弹确认弹窗
   *
   * 曾是页面里的一张卡片：克隆/测试过程中它插在表单下方，指纹和操作按钮
   * 离触发点很远、还不显眼。改为弹窗后「首次连接确认指纹」必须当场决定，
   * 与系统应用的安全确认一致。注意这是**可重入**的——服务器可能提供多把
   * 不同类型的主机密钥，确认一把后继续连接还可能遇到下一把，故克隆/测试
   * 每次返回后都要调一次本方法。
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
        this.viewModel.rejectHostKey();
      },
      onConfirm: (): void => {
        this.closeHostKeyDialog();
        // 确认后继续连接；服务器又出示另一把未记录类型的主机密钥时再弹一次
        this.viewModel.confirmHostKey().then((): void => {
          this.maybeShowHostKeyDialog();
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

  /** 执行克隆（本地目录已可用） */
  private runClone(): void {
    this.viewModel.cloneNow().then((ok: boolean): void => {
      if (ok) {
        // 成功后本页会立即 pop，用 toast 明确告知结果——否则用户只看到页面消失，
        // 不知道到底克隆成功没有（失败时本页会留下红色原因）
        showToastSafe(this.getUIContext(), Strings.get('gitcfg_clone_done_toast'), 2500);
        RouteManager.getInstance().pop();
      } else {
        // 克隆被主机密钥确认打断时弹指纹弹窗（其余失败已写入 cloneMessage 状态行）
        this.maybeShowHostKeyDialog();
      }
    });
  }

  /** SSH 密钥选择面板（bindSheet 方式） */
  @Builder
  sshKeyPickerBuilder() {
    Column() {
      Text($r('app.string.gitcfg_pick_ssh_key'))
        .fontSize(FontSize.TITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.colors.textPrimary)
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ bottom: Spacing.LG })

      List() {
        ForEach(this.viewModel.sshKeyList, (k: SshKeyInfo) => {
          ListItem() {
            Row() {
              Column() {
                Text(this.viewModel.sshKeyDisplayName(k))
                  .fontSize(FontSize.SUBTITLE)
                  .fontColor(this.colors.textPrimary)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(`${sshKeyTypeLabel(k.keyType)} · ${k.alias}`)
                  .fontSize(FontSize.CAPTION)
                  .fontColor(this.colors.textTertiary)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .margin({ top: Spacing.XS })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              if (k.alias === this.viewModel.sshKeyAlias) {
                SymbolGlyph($r('sys.symbol.checkmark'))
                  .fontSize(IconSize.XS)
                  .fontColor([this.colors.primary])
              }
            }
            .width('100%')
            .padding(Spacing.CARD)
            .alignItems(VerticalAlign.Center)
            .stateStyles({
              normal: { .backgroundColor(Color.Transparent) },
              pressed: { .backgroundColor(this.colors.pressed) },
            })
            .onClick(() => {
              this.viewModel.selectSshKey(k.alias);
              this.isSshKeyPickerVisible = false;
            })
          }
        }, (k: SshKeyInfo) => k.alias)
      }
      // 选择列表项之间用缩进分隔线（对齐 comp_divider：1px、文本行缩进 16vp）
      .divider({
        strokeWidth: DividerSpec.STROKE,
        color: this.colors.divider,
        startMargin: DividerSpec.INSET_TEXT,
        endMargin: DividerSpec.INSET_TEXT,
      })
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      // 滑到上下边界时给回弹动效反馈
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    // 统一面板内边距：顶部让开 dragBar，底部与屏幕下沿保持距离
    .padding({ top: SHEET_PAD_TOP, left: Spacing.LG, right: Spacing.LG, bottom: SHEET_PAD_BOTTOM })
    .backgroundColor(this.colors.surface)
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

  /** 卡片内分隔线（对齐 comp_divider：1px，通栏于卡片内容区，不再手写缩进） */
  @Builder
  rowDivider() {
    Divider()
      .strokeWidth(DividerSpec.STROKE)
      .color(this.colors.divider)
  }

  /** 认证方式分段选项 */
  @Builder
  authModeTab(label: string, mode: GitAuthMode) {
    Text(label)
      .fontSize(FontSize.BODY)
      .fontWeight(this.viewModel.authMode === mode ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.viewModel.authMode === mode ? this.colors.onPrimary : this.colors.textSecondary)
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .padding(Spacing.SM)
      .backgroundColor(this.viewModel.authMode === mode ? this.colors.primary : Color.Transparent)
      .borderRadius(Radius.SM)
      .stateStyles({
        normal: {
          .backgroundColor(this.viewModel.authMode === mode ? this.colors.primary : Color.Transparent)
        },
        pressed: { .backgroundColor(this.colors.pressed) },
      })
      .onClick(() => {
        this.viewModel.setAuthMode(mode);
      })
  }

  /**
   * 状态提示行：语义色 + 图标
   * @param kind 'success' | 'error' | 'warning'
   */
  @Builder
  statusRow(message: string, kind: string) {
    Row() {
      SymbolGlyph(kind === 'success' ? $r('sys.symbol.checkmark_circle_fill')
        : (kind === 'error' ? $r('sys.symbol.xmark_circle_fill') : $r('sys.symbol.exclamationmark_circle')))
        .fontSize(IconSize.XS)
        .fontColor([kind === 'success' ? this.colors.success
          : (kind === 'error' ? this.colors.danger : this.colors.warning)])

      Text(message)
        .fontSize(FontSize.CAPTION)
        .fontColor(kind === 'success' ? this.colors.success
          : (kind === 'error' ? this.colors.danger : this.colors.warning))
        .layoutWeight(1)
        .margin({ left: Spacing.SM })
    }
    .width('100%')
    .padding(Spacing.MD)
    .backgroundColor(kind === 'success' ? this.colors.primarySoft
      : (kind === 'error' ? this.colors.dangerSoft : this.colors.primarySoft))
    .borderRadius(Radius.CARD)
    .margin({ top: Spacing.SM })
    .alignItems(VerticalAlign.Center)
  }

  build() {
    NavDestination() {
      Column() {
        // ===== 自定义标题栏（40vp 圆形返回按钮 + 标题，见 AppTitleBar） =====
        AppTitleBar({ title: $r('app.string.git_config') })

        Scroll() {
          Column() {
            // ===== 远程仓库 =====
            this.sectionTitle(Strings.get('gitcfg_section_remote'), true)

            Column() {
              // 认证方式在前：它决定「远程地址」该写成哪种形式（https:// 还是 git@host:path），
              // 也让下面的凭据区（HTTPS 用户名/密码 或 SSH 密钥）紧随其后
              Row() {
                Text(Strings.get('gitcfg_auth_mode'))
                  .fontSize(FontSize.BODY)
                  .fontColor(this.colors.textSecondary)
                  // 与 FormRow 共用同一标签列宽（无对应令牌）；按语言缩放，否则
                  // 德 `Authentifizierung`、俄 `Аутентификация` 会在 84vp 列里折行
                  .width(Strings.labelWidth(84))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })

                Row() {
                  this.authModeTab('HTTPS', GitAuthMode.HTTPS_PASSWORD)
                  this.authModeTab(Strings.get('gitcfg_auth_ssh_tab'), GitAuthMode.SSH_KEY)
                }
                .layoutWeight(1)
                .backgroundColor(this.colors.inputBackground)
                .borderRadius(Radius.SM)
                .padding(Spacing.XS)
              }
              .width('100%')
              .padding({ top: Spacing.MD, bottom: Spacing.MD })
              .alignItems(VerticalAlign.Center)

              this.rowDivider()

              FormRow({
                label: Strings.get('gitcfg_label_url'),
                placeholder: this.viewModel.isHttpsAuth() ? 'https://host/user/repo.git' : 'git@host:user/repo.git',
                value: this.viewModel.remoteUrl,
                onInput: (v: string): void => { this.viewModel.remoteUrl = v; },
              })

              // HTTPS 凭据
              if (this.viewModel.isHttpsAuth()) {
                this.rowDivider()
                FormRow({
                label: Strings.get('common_username'),
                placeholder: $r('app.string.gitcfg_ph_username'),
                value: this.viewModel.username,
                isPassword: false,
                onInput: (v: string): void => { this.viewModel.username = v; },
              })
                this.rowDivider()
                FormRow({
                label: Strings.get('common_password'),
                placeholder: $r('app.string.gitcfg_ph_password'),
                value: this.viewModel.password,
                isPassword: true,
                onInput: (v: string): void => { this.viewModel.password = v; },
              })

                Text($r('app.string.gitcfg_token_hint'))
                  .fontSize(FontSize.CAPTION)
                  .fontColor(this.colors.textTertiary)
                  .width('100%')
                  .padding({ bottom: Spacing.MD })
              } else {
                // SSH 密钥选择
                this.rowDivider()

                Row() {
                  Text(Strings.get('gitcfg_auth_ssh'))
                    .fontSize(FontSize.BODY)
                    .fontColor(this.colors.textSecondary)
                    // 与 fieldRow 共用同一标签列宽（无对应令牌）；按语言缩放（同上）
                    .width(Strings.labelWidth(84))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })

                  if (this.viewModel.sshKeyList.length > 0) {
                    Row() {
                      Text(this.viewModel.sshKeyAlias.length > 0
                        ? this.viewModel.selectedSshKeyDisplayName()
                        : Strings.get('gitcfg_select_ssh_key'))
                        .fontSize(FontSize.BODY)
                        .fontColor(this.viewModel.sshKeyAlias.length > 0
                          ? this.colors.textPrimary : this.colors.textTertiary)
                        .layoutWeight(1)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })

                      SymbolGlyph($r('sys.symbol.chevron_down'))
                        .fontSize(IconSize.CHEVRON)
                        .fontColor([this.colors.textTertiary])
                    }
                    .layoutWeight(1)
                    .height(ComponentSize.CONTROL)
                    .alignItems(VerticalAlign.Center)
                    .stateStyles({
                      normal: { .backgroundColor(Color.Transparent) },
                      pressed: { .backgroundColor(this.colors.pressed) },
                    })
                    .onClick(() => {
                      this.isSshKeyPickerVisible = true;
                    })
                  } else {
                    Row() {
                      Text($r('app.string.gitcfg_no_keys'))
                        .fontSize(FontSize.BODY)
                        .fontColor(this.colors.textTertiary)
                        .layoutWeight(1)
                      Text($r('app.string.gitcfg_go_create'))
                        .fontSize(FontSize.CAPTION)
                        .fontColor(this.colors.primary)
                        .padding({ left: Spacing.XS, right: Spacing.XS })
                        .borderRadius(Radius.SM)
                        .stateStyles({
                          normal: { .backgroundColor(Color.Transparent) },
                          pressed: { .backgroundColor(this.colors.pressed) },
                        })
                        .onClick(() => {
                          RouteManager.getInstance().pushPath(RouteNames.SSH_KEY_MANAGER);
                        })
                    }
                    .layoutWeight(1)
                    .height(ComponentSize.CONTROL)
                    .alignItems(VerticalAlign.Center)
                  }
                }
                .width('100%')
                .height(ComponentSize.ROW)
                .alignItems(VerticalAlign.Center)

                this.rowDivider()
                FormRow({
                  label: Strings.get('gitcfg_label_ssh_port'),
                  placeholder: $r('app.string.gitcfg_ph_ssh_port'),
                  value: `${this.viewModel.sshPort}`,
                  onInput: (v: string): void => {
                    const port: number = parseInt(v, 10);
                    if (!isNaN(port) && port > 0 && port <= 65535) {
                      this.viewModel.sshPort = port;
                    }
                  },
                })

                this.rowDivider()
                // 私钥本身带口令时必填：导入密钥时的口令不会被保存（私钥文件里仍是加密态），
                // 而克隆/同步要用到它。与 HTTPS 令牌一样经 HUKS 封装后落盘。
                FormRow({
                  label: Strings.get('gitcfg_label_key_passphrase'),
                  placeholder: $r('app.string.gitcfg_ph_key_passphrase'),
                  value: this.viewModel.sshKeyPassphrase,
                  isPassword: true,
                  onInput: (v: string): void => { this.viewModel.sshKeyPassphrase = v; },
                })
              }
            }
            .width('100%')
            .padding({ left: Spacing.CARD, right: Spacing.CARD })
            .backgroundColor(this.colors.surface)
            .borderRadius(Radius.CARD)

            // ===== 提交身份 =====
            this.sectionTitle(Strings.get('gitcfg_section_identity'), false)

            Column() {
              FormRow({
                label: Strings.get('gitcfg_label_name'),
                placeholder: $r('app.string.gitcfg_ph_name'),
                value: this.viewModel.committerName,
                isPassword: false,
                onInput: (v: string): void => { this.viewModel.committerName = v; },
              })
              this.rowDivider()
              FormRow({
                label: Strings.get('common_email'),
                placeholder: $r('app.string.gitcfg_ph_email'),
                value: this.viewModel.committerEmail,
                isPassword: false,
                onInput: (v: string): void => { this.viewModel.committerEmail = v; },
              })
            }
            .width('100%')
            .padding({ left: Spacing.CARD, right: Spacing.CARD })
            .backgroundColor(this.colors.surface)
            .borderRadius(Radius.CARD)

            // ===== 网络（仅 HTTPS 需要：libgit2 的代理只作用于 HTTP 传输，SSH 传输不读它） =====
            if (this.viewModel.isHttpsAuth()) {
              this.sectionTitle(Strings.get('gitcfg_section_network'), false)

              Column() {
                FormRow({
                  label: Strings.get('gitcfg_label_proxy'),
                  placeholder: $r('app.string.gitcfg_ph_proxy'),
                  value: this.viewModel.proxyUrl,
                  isPassword: false,
                  onInput: (v: string): void => { this.viewModel.proxyUrl = v; },
                })
              }
              .width('100%')
              .padding({ left: Spacing.CARD, right: Spacing.CARD })
              .backgroundColor(this.colors.surface)
              .borderRadius(Radius.CARD)
            }

            // ===== 克隆进度/结果（保存后的「立即克隆」） =====
            if (this.viewModel.cloneMessage.length > 0) {
              this.statusRow(this.viewModel.cloneMessage,
                this.viewModel.cloneFailed ? 'error' : 'success')
            }

            // ===== 状态提示 =====
            if (this.viewModel.errorMessage.length > 0) {
              this.statusRow(this.viewModel.errorMessage, 'error')
            }
            if (this.viewModel.testResult.length > 0) {
              // 配色按 ViewModel 的成功状态判定，不比较 testResult 文本：
              // 那是展示文案，改措辞就会让比较恒假（详见 testSucceeded 注释）
              this.statusRow(this.viewModel.testResult,
                this.viewModel.testSucceeded ? 'success' : 'warning')
            }

            // TOFU 主机密钥确认已改为原生弹窗（maybeShowHostKeyDialog），不再占页面卡片
          }
          .width('100%')
          // 底部留白：按钮行已移到固定底栏，内容区自己给一段收尾间距
          .padding({ left: Spacing.PAGE_H, right: Spacing.PAGE_H, bottom: Spacing.XL })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
        .align(Alignment.Top)
        // 滑到上下边界时给回弹动效反馈
        .edgeEffect(EdgeEffect.Spring)

        // ===== 固定底部按钮栏（不随内容滚动） =====
        // 作为 Scroll 的兄弟节点即可固定在底部；底部内边距必须自行避让系统导航条
        // （沉浸式布局下内容延伸到导航条下方，只给 16vp 会压在系统手势区上）
        // ===== 操作按钮 =====
        Row({ space: ButtonSpec.ROW_GAP }) {
          Button(this.viewModel.isTesting ? $r('app.string.gitcfg_testing') : $r('app.string.gitcfg_test_btn'))
            .type(ButtonType.Normal)
            .borderRadius(ButtonSpec.SECONDARY_RADIUS)
            .layoutWeight(1)
            .height(ButtonSpec.SECONDARY_HEIGHT)
            .backgroundColor(this.colors.neutralButton)
            .fontColor(this.colors.textPrimary)
            .fontSize(ButtonSpec.FONT_SIZE)
            .fontWeight(ButtonSpec.FONT_WEIGHT)
            .enabled(!this.viewModel.isTesting && !this.viewModel.isSaving)
            .onClick(() => {
              this.viewModel.testConnection().then((): void => {
                this.maybeShowHostKeyDialog();
              });
            })

          Button(this.viewModel.isSaving ? $r('app.string.home_verifying') : $r('app.string.common_save'))
            .type(ButtonType.Normal)
            .borderRadius(ButtonSpec.PRIMARY_RADIUS)
            .layoutWeight(1)
            .height(ButtonSpec.PRIMARY_HEIGHT)
            .backgroundColor(this.colors.primary)
            .fontColor(this.colors.onPrimary)
            .fontSize(ButtonSpec.FONT_SIZE)
            .fontWeight(ButtonSpec.FONT_WEIGHT)
            .enabled(this.viewModel.canSave() && !this.viewModel.isSaving)
            .onClick(() => {
              this.viewModel.save().then(() => {
                if (this.viewModel.isSaved) {
                  this.askCloneAfterSave();
                } else {
                  // 保存前的连接测试被主机密钥确认打断：弹指纹弹窗
                  this.maybeShowHostKeyDialog();
                }
              });
            })
        }
        .width('100%')
        // 底部留白 = 系统导航条高度（`SystemInsets.bottomVp()`），与详情页、移动/重命名页
        // 同一个口径。**不要**退回 `SHEET_PAD_BOTTOM`(24vp)：那是半模态弹窗**面板内部**
        // 按钮行的口径——面板由系统整体抬到导航条之上，它的 24vp 是相对面板底边的；
        // 而页面底栏的 padding 是相对**屏幕下沿**的，只给 24vp 就会压进导航条避让区
        // （AGC 上架审核报的「底部固定控件与导航条互相遮挡」正是此处）。
        // 另：**不要**给底栏加顶边框——那会在按钮上方凭空多出一条分隔线。
        .padding({
          left: Spacing.PAGE_H, right: Spacing.PAGE_H,
          top: Spacing.CARD_GAP,
          bottom: this.bottomInset,
        })
        .backgroundColor(this.colors.background)

        // ===== 克隆进度：全模态遮罩 =====
        // `.position({x:0,y:0})` 把它**移出文档流**、叠在整页之上（同 PasswordListPage
        // 的设置菜单遮罩）。只给 width/height 100% 而不加 position 的话，它会作为
        // Column 的子节点排在前面的内容之后，只盖住下半屏。
        // 返回键另见 onBackPressed（遮罩挡不住系统返回手势）。
        if (this.viewModel.isCloning) {
          // percent >= 0 时渲染环形进度 + 中心百分比；-1 为不确定态（旋转图标）。
          // 进度到 100% 后仍可能有解包/检出阶段（无回调），故文案在此时换成「正在检出文件…」
          LoadingOverlay({
            text: this.viewModel.clonePercent >= 100 ? Strings.get('gitcfg_checkout_files') : Strings.get('gitcfg_cloning_overlay'),
            percent: this.viewModel.clonePercent,
          })
            .position({ x: 0, y: 0 })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.colors.background)
    }
    .hideTitleBar(true)
    // 克隆中吞掉返回（含侧滑返回）：返回 true 表示覆盖默认返回逻辑。
    // 遮罩挡不住系统返回手势，必须在这里拦——否则用户返回后克隆仍在后台跑，
    // 完成后本页已销毁、结果无人接收，用户以为没克隆成功。
    .onBackPressed((): boolean => this.viewModel.isCloning)
    // 不传 options.title：面板内已渲染「选择 SSH 密钥」标题，再给原生标题栏会重复显示两遍；
    // 必须补 onDisappear，否则手势下滑/点遮罩关闭后状态仍为 true，面板无法再次弹出
    .bindSheet(this.isSshKeyPickerVisible, this.sshKeyPickerBuilder(),
      this.sshKeyPickerOptions)
  }
}
