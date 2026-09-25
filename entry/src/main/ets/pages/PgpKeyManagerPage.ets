import { PgpKeyManagerViewModel, KeyExportResult } from '../viewmodel/PgpKeyManagerViewModel';
import { showToastSafe } from '../utils/ToastUtil';
import { GpgKeyId } from '../model/GpgKeyId';
import { ThemeColors, Palette, Radius, Spacing, FontSize, IconSize, ComponentSize, DividerSpec } from '../common/ThemeColors';
import { promptAction } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SheetFormButtons } from '../views/SheetFormButtons';
import { AppTitleBar } from '../views/AppTitleBar';
import { AppFab } from '../views/AppFab';
import { EmptyState } from '../views/EmptyState';
import { formSheetOptions, menuSheetHeight, panelSheetOptions, themedSheetOptions, SHEET_PAD_TOP, SHEET_PAD_BOTTOM } from '../common/SheetStyles';
import { PasswordRepository } from '../model/PasswordRepository';
import { PgpCrypto, UnlockResult } from '../crypto/PgpCrypto';
import { RepoChangeNotifier } from '../common/RepoChangeNotifier';
import { ReencryptService, ReencryptPlan, ReencryptOutcome } from '../utils/ReencryptService';

/** hilog 域 */
const DOMAIN: number = 0x0001;
/** hilog 标签 */
const TAG: string = 'PgpKeyManagerPage';

/**
 * PGP 密钥管理页
 *
 * 标题栏下直接展示密钥列表（顶置排列），右下角 + 号 FAB 弹出
 * 鸿蒙半模态动作菜单（导入文本密钥/从文件导入密钥/创建新密钥）；
 * 密钥尾部编辑按钮（dot_grid_1x2）弹出编辑菜单
 * （修改密钥/导出备份/导出公钥/删除）。
 */

@ComponentV2
export struct PgpKeyManagerPage {
  @Local viewModel: PgpKeyManagerViewModel = new PgpKeyManagerViewModel();
  /** 新建/导入底部菜单可见 */
  @Local isAddSheetVisible: boolean = false;
  /** 编辑菜单绑定的密钥指纹（'' 表示编辑菜单关闭） */
  @Local editFingerprint: string = '';
  /** 编辑菜单可见 */
  @Local isEditSheetVisible: boolean = false;
  /** 导入文本密钥表单可见（add sheet 内切换） */
  @Local isImportFormVisible: boolean = false;
  /** 创建密钥表单可见（add sheet 内切换） */
  @Local isGenerateFormVisible: boolean = false;
  /** 菜单→表单切换中（跳过 onDisappear 复位） */
  @Local isSwitchingForm: boolean = false;
  /** 编辑操作表单态：change-pw / backup / export-pub（'' 表示菜单态） */
  @Local editAction: string = '';

  // 导入表单字段（VM 复用）
  // viewModel.armoredKey / passphrase / errorMessage / isImporting

  private get colors(): Palette {
    return ThemeColors.getInstance().palette();
  }

  aboutToAppear(): void {
    this.viewModel.load();
  }

  /** add sheet 公共 onDisappear（复位状态，保证可再次弹出） */
  private resetAddSheet(): void {
    if (this.isSwitchingForm) {
      this.isSwitchingForm = false;
      return;
    }
    this.isAddSheetVisible = false;
    this.isImportFormVisible = false;
    this.isGenerateFormVisible = false;
    this.viewModel.armoredKey = '';
    this.viewModel.passphrase = '';
    this.viewModel.errorMessage = '';
  }

  /** edit sheet 公共 onDisappear */
  private resetEditSheet(): void {
    if (this.isSwitchingForm) {
      this.isSwitchingForm = false;
      return;
    }
    this.isEditSheetVisible = false;
    this.editAction = '';
    this.editFingerprint = '';
    this.viewModel.errorMessage = '';
  }

  /**
   * 各 sheet 配置走 getter + themedSheetOptions（不能写成字段初始化器）：
   * 字段初始化器捕获的 backgroundColor 停留在构造时的主题色，色深变化后面板
   * 被上拉会露出过期色（深色下是白带）。themedSheetOptions 按背景色+高度缓存，
   * 主题没变返回同一对象（稳定引用，不会因重渲染意外弹出）。
   */

  /** add sheet：菜单态 */
  private get addSheetMenuOptions(): SheetOptions {
    const h: number = menuSheetHeight(3, SHEET_PAD_BOTTOM);
    return themedSheetOptions(this, 'PgpAddMenu', 
      (): SheetOptions => panelSheetOptions(this.colors.surface, h, (): void => this.resetAddSheet()),
      this.colors.surface, h);
  }

  /** add sheet：表单态撑满面板，键盘只 resize 内容（按钮留在面板底部） */
  private get addSheetFormOptions(): SheetOptions {
    return themedSheetOptions(this, 'PgpAddForm', 
      (): SheetOptions => formSheetOptions(this.colors.surface, (): void => this.resetAddSheet()),
      this.colors.surface, 'addform');
  }

  /** edit sheet：菜单态 */
  private get editSheetMenuOptions(): SheetOptions {
    const h: number = menuSheetHeight(4, SHEET_PAD_BOTTOM);
    return themedSheetOptions(this, 'PgpEditMenu', 
      (): SheetOptions => panelSheetOptions(this.colors.surface, h, (): void => this.resetEditSheet()),
      this.colors.surface, h);
  }

  /** edit sheet：表单态（修改密钥密码/导出备份），与 add sheet 表单同构 */
  private get editSheetFormOptions(): SheetOptions {
    return themedSheetOptions(this, 'PgpEditForm', 
      (): SheetOptions => formSheetOptions(this.colors.surface, (): void => this.resetEditSheet()),
      this.colors.surface, 'editform');
  }

  // ===== 换默认密钥时的「重加密根目录」流程状态 =====

  /** 旧密钥口令输入面板可见性 */
  @Local isRootKeySheetVisible: boolean = false;
  /** 旧密钥口令输入值 */
  @Local rootKeyPassphrase: string = '';
  /** 口令错误提示 */
  @Local rootKeyError: string = '';
  /** 重加密进行中 */
  @Local rootKeyBusy: boolean = false;
  /** 待执行：新默认密钥指纹与预扫结果 */
  private pendingRootKey: string = '';
  private pendingRootPlan: ReencryptPlan | null = null;

  /** 旧密钥口令面板：与既有表单面板同构（字段直接排布 + Blank 撑按钮行） */
  private get rootKeySheetOptions(): SheetOptions {
    return themedSheetOptions(this, 'PgpRootKey', (): SheetOptions => formSheetOptions(this.colors.surface, (): void => {
      this.isRootKeySheetVisible = false;
      this.rootKeyPassphrase = '';
      this.rootKeyError = '';
      this.pendingRootKey = '';
      this.pendingRootPlan = null;
    }), this.colors.surface, 'rootkey');
  }

  /** 动作面板行：图标 20vp + 标题 16fp Medium，行高 56vp，按压态反馈 */
  @Builder
  actionItem(icon: Resource, label: string, onTap: () => void) {
    Row() {
      SymbolGlyph(icon)
        .fontSize(IconSize.ACTION)
        .fontColor([this.colors.primary])

      Text(label)
        .fontSize(FontSize.SUBTITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.colors.textPrimary)
        .margin({ left: Spacing.MD })
    }
    .width('100%')
    .height(ComponentSize.ROW)
    .padding({ left: Spacing.MD, right: Spacing.MD })
    .borderRadius(Radius.SM)
    .stateStyles({
      normal: { .backgroundColor(Color.Transparent) },
      pressed: { .backgroundColor(this.colors.pressed) },
    })
    .onClick(onTap)
  }

  /** 危险动作面板行（删除）：图标/文字用 danger 色 */
  @Builder
  dangerActionItem(icon: Resource, label: string, onTap: () => void) {
    Row() {
      SymbolGlyph(icon)
        .fontSize(IconSize.ACTION)
        .fontColor([this.colors.danger])

      Text(label)
        .fontSize(FontSize.SUBTITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.colors.danger)
        .margin({ left: Spacing.MD })
    }
    .width('100%')
    .height(ComponentSize.ROW)
    .padding({ left: Spacing.MD, right: Spacing.MD })
    .borderRadius(Radius.SM)
    .stateStyles({
      normal: { .backgroundColor(Color.Transparent) },
      pressed: { .backgroundColor(this.colors.pressed) },
    })
    .onClick(onTap)
  }

  /** 表单标题 */
  @Builder
  formTitle(title: string) {
    Text(title)
      .fontSize(FontSize.TITLE)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.colors.textPrimary)
      .width('100%')
      .textAlign(TextAlign.Center)
      .margin({ bottom: Spacing.LG })
  }

  /** 取消/确认按钮行统一用 SheetFormButtons 子组件（@Builder 按值传参不刷新，见该组件注释） */

  @Builder
  addSheetBuilder() {
    // 根容器撑满面板；表单态把「字段区」与「按钮行」分开：
    // 软键盘弹起会把面板压矮，按钮若随内容流排布就会被裁到屏外点不到，
    // 因此字段区直接排布（不包 Scroll），按钮行由下方 Blank() 占位撑到面板底部。
    Column() {
      if (!this.isImportFormVisible && !this.isGenerateFormVisible) {
        // 菜单态：动作面板
        Column() {
          this.actionItem($r('sys.symbol.doc_text'), '导入文本密钥', (): void => {
            this.isSwitchingForm = true;
            this.isAddSheetVisible = false;
            setTimeout(() => {
              this.isImportFormVisible = true;
              this.isAddSheetVisible = true;
            }, 350);
          })
          Divider()
            .color(this.colors.divider)
            .margin({ left: Spacing.MD, right: Spacing.MD })
          this.actionItem($r('sys.symbol.folder'), '从文件导入密钥', (): void => {
            this.isSwitchingForm = true;
            this.isAddSheetVisible = false;
            // 选择器需等菜单 sheet 关闭后再拉起，否则会与半模态窗口互相遮挡
            setTimeout((): void => {
              this.pickKeyFile();
            }, 350);
          })
          Divider()
            .color(this.colors.divider)
            .margin({ left: Spacing.MD, right: Spacing.MD })
          this.actionItem($r('sys.symbol.plus'), '创建新密钥', (): void => {
            this.isSwitchingForm = true;
            this.isAddSheetVisible = false;
            setTimeout(() => {
              this.isGenerateFormVisible = true;
              this.isAddSheetVisible = true;
            }, 350);
          })
        }
        .width('100%')
        .borderRadius(Radius.CARD)
        .backgroundColor(this.colors.surface)
      } else if (this.isImportFormVisible) {
        // 导入文本密钥表单：内容固定不滚动，与 SSH 导入弹窗结构一致
        Column() {
          // 导入文本密钥表单
          this.formTitle('导入文本密钥')

          TextArea({ text: this.viewModel.armoredKey, placeholder: '-----BEGIN PGP PRIVATE KEY BLOCK-----' })
            .fontSize(FontSize.CAPTION)
            .fontColor(this.colors.textPrimary)
            .placeholderColor(this.colors.textTertiary)
            .fontFamily('monospace')
            .width('100%')
            // 多行 armored 私钥输入区：无对应高度令牌，保留 112vp（约 8 行 monospace 文本）
            .height(112)
            .backgroundColor(this.colors.inputBackground)
            .borderRadius(Radius.MD)
            .padding(Spacing.MD)
            .margin({ bottom: Spacing.MD })
            .onChange((v: string) => {
              this.viewModel.armoredKey = v;
            })

          TextInput({ text: this.viewModel.passphrase, placeholder: '密钥密码（可选）' })
            .type(InputType.Password)
            .fontSize(FontSize.SUBTITLE)
            .fontColor(this.colors.textPrimary)
            .placeholderColor(this.colors.textTertiary)
            .placeholderFont({ size: FontSize.SUBTITLE })
            .width('100%')
            .height(ComponentSize.CONTROL)
            .borderRadius(Radius.MD)
            .backgroundColor(this.colors.inputBackground)
            .onChange((v: string) => {
              this.viewModel.passphrase = v;
            })
        }
        .width('100%')

        // 弹性占位：把下方的错误提示与按钮撑到屏幕底部
        Blank()
          .layoutWeight(1)

        if (this.viewModel.errorMessage.length > 0) {
          Text(this.viewModel.errorMessage)
            .fontSize(FontSize.CAPTION)
            .fontColor(this.colors.danger)
            .width('100%')
            .margin({ top: Spacing.SM })
        }

        // 按钮行固定在屏幕底部：占位 + 面板 100% 高度共同保证
        SheetFormButtons({
          confirmLabel: '导入',
          isBusy: this.viewModel.isImporting,
          canConfirm: this.viewModel.armoredKey.trim().length > 0,
          onConfirm: (): void => {
            this.viewModel.importKey().then(() => {
              if (this.viewModel.toast.length > 0) {
                this.isAddSheetVisible = false;
                // 导入成功但有限制（如加密子密钥算法不受支持）时弹窗说明
                this.consumePendingWarning();
              }
              // 重复导入 / 导入的是公钥：不是表单内的小红字，关掉面板后弹窗告知
              this.consumeImportDialog();
              // toast 此前只被当作成功标志，从不渲染——删除/设为默认等操作零反馈
              this.showToastIfAny();
            });
          },
          onCancel: (): void => {
            this.isAddSheetVisible = false;
          }
        })
      } else {
        // 创建新密钥表单：内容固定不滚动，与导入表单结构一致
        Column() {
          // 创建新密钥表单
          this.formTitle('创建新密钥')

          Row({ space: Spacing.SM }) {
            ForEach(['eddsa', 'rsa4096', 'rsa2048'], (kt: string) => {
              Text(kt === 'eddsa' ? 'EdDSA（推荐）' : (kt === 'rsa4096' ? 'RSA-4096' : 'RSA-2048'))
                .fontSize(FontSize.BODY)
                .fontColor(this.viewModel.genKeyType === kt ? this.colors.onPrimary : this.colors.textSecondary)
                .backgroundColor(this.viewModel.genKeyType === kt ? this.colors.primary : this.colors.inputBackground)
                .borderRadius(Radius.SM)
                .padding({ left: Spacing.MD, right: Spacing.MD, top: Spacing.SM, bottom: Spacing.SM })
                .stateStyles({
                  normal: {
                    .backgroundColor(this.viewModel.genKeyType === kt ? this.colors.primary : this.colors.inputBackground)
                  },
                  pressed: { .backgroundColor(this.colors.pressed) },
                })
                .onClick(() => {
                  this.viewModel.setGenKeyType(kt);
                })
            }, (kt: string) => kt)
          }
          .width('100%')
          .margin({ bottom: Spacing.MD })

          TextInput({ text: this.viewModel.genUserId, placeholder: 'User ID（如 Name <email@example.com>）' })
            .fontSize(FontSize.SUBTITLE)
            .fontColor(this.colors.textPrimary)
            .placeholderColor(this.colors.textTertiary)
            .placeholderFont({ size: FontSize.SUBTITLE })
            .width('100%')
            .height(ComponentSize.CONTROL)
            .borderRadius(Radius.MD)
            .backgroundColor(this.colors.inputBackground)
            .margin({ bottom: Spacing.MD })
            .onChange((v: string) => {
              this.viewModel.genUserId = v;
            })

          TextInput({ text: this.viewModel.genPassphrase, placeholder: '密钥密码（可选，至少 6 位）' })
            .type(InputType.Password)
            .fontSize(FontSize.SUBTITLE)
            .fontColor(this.colors.textPrimary)
            .placeholderColor(this.colors.textTertiary)
            .placeholderFont({ size: FontSize.SUBTITLE })
            .width('100%')
            .height(ComponentSize.CONTROL)
            .borderRadius(Radius.MD)
            .backgroundColor(this.colors.inputBackground)
            .onChange((v: string) => {
              this.viewModel.genPassphrase = v;
            })
        }
        .width('100%')

        // 弹性占位：把下方内容与按钮撑到屏幕底部
        Blank()
          .layoutWeight(1)

        if (this.viewModel.errorMessage.length > 0) {
          Text(this.viewModel.errorMessage)
            .fontSize(FontSize.CAPTION)
            .fontColor(this.colors.danger)
            .width('100%')
            .margin({ top: Spacing.SM })
        }

        if (this.viewModel.isGenerating) {
          LoadingProgress()
            .width(IconSize.MD)
            .height(IconSize.MD)
            .margin({ top: Spacing.SM })
        }

        // 按钮行固定在屏幕底部
        SheetFormButtons({
          confirmLabel: '创建',
          isBusy: this.viewModel.isGenerating,
          canConfirm: this.viewModel.genUserId.trim().length > 0,
          onConfirm: (): void => {
            this.viewModel.generateKey().then(() => {
              if (this.viewModel.toast.length > 0) {
                this.isAddSheetVisible = false;
              }
              this.showToastIfAny();
            });
          },
          onCancel: (): void => {
            this.isAddSheetVisible = false;
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ top: SHEET_PAD_TOP, left: Spacing.LG, right: Spacing.LG, bottom: SHEET_PAD_BOTTOM })
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(this.colors.surface)
  }

  /** 下拉菜单：编辑密钥动作（bindMenu 弹出，非底部 sheet） */
  @Builder
  editMenuBuilder() {
    Column() {
      if (this.canSetDefault(this.editFingerprint)) {
        this.actionItem($r('sys.symbol.star'), '设为默认', (): void => {
          const target: string = this.editFingerprint;
          this.viewModel.setDefaultKey(target).then(() => {
            this.showToastIfAny();
            this.offerSwitchRootKey(target);
          });
        })
        Divider()
          .color(this.colors.divider)
          .margin({ left: Spacing.MD, right: Spacing.MD })
      }
      this.actionItem($r('sys.symbol.lock'), '修改密钥', (): void => {
        this.viewModel.errorMessage = '';
        this.editAction = 'change-pw';
        this.isEditSheetVisible = true;
      })
      Divider()
        .color(this.colors.divider)
        .margin({ left: Spacing.MD, right: Spacing.MD })
      this.actionItem($r('sys.symbol.lock_shield'), '导出私钥', (): void => {
        this.handleExportPrivateKey();
      })
      Divider()
        .color(this.colors.divider)
        .margin({ left: Spacing.MD, right: Spacing.MD })
      this.actionItem($r('sys.symbol.key'), '导出公钥', (): void => {
        this.handleExportPublicKey();
      })
      Divider()
        .color(this.colors.divider)
        .margin({ left: Spacing.MD, right: Spacing.MD })
      this.dangerActionItem($r('sys.symbol.trash'), '删除密钥', (): void => {
        this.handleDeleteKey();
      })
    }
    // 下拉菜单宽度：无对应宽度令牌，保留 220vp
    .width(220)
    .borderRadius(Radius.CARD)
    .backgroundColor(this.colors.surface)
    .padding({ top: Spacing.XS, bottom: Spacing.XS })
  }

  @Builder
  editSheetBuilder() {
    // 与 addSheetBuilder 同构：字段直接排布 + Blank() 占位把按钮行撑到面板底部，
    // 避免软键盘弹起压缩面板后按钮被裁到屏外。
    Column() {
      // 修改密钥密码表单
      // 字段必须直接排布，**不要**包进 Scroll + layoutWeight(1)：键盘弹起时
      // 面板被压缩，系统滚动容器会让内容高度失去约束，实测面板塌陷到约 199px、
      // 两个输入框被完全裁出布局树（连节点都不存在），用户根本无法输入。
      this.formTitle('修改密钥密码')

      TextInput({ placeholder: '当前密钥密码' })
        .type(InputType.Password)
        .fontSize(FontSize.SUBTITLE)
        .fontColor(this.colors.textPrimary)
        .placeholderColor(this.colors.textTertiary)
        .placeholderFont({ size: FontSize.SUBTITLE })
        .width('100%')
        .height(ComponentSize.CONTROL)
        .borderRadius(Radius.MD)
        .backgroundColor(this.colors.inputBackground)
        .margin({ bottom: Spacing.MD })
        .onChange((v: string) => {
          this.oldPw = v;
          this.viewModel.errorMessage = '';
        })

      TextInput({ placeholder: '新密码（留空则去除密码）' })
        .type(InputType.Password)
        .fontSize(FontSize.SUBTITLE)
        .fontColor(this.colors.textPrimary)
        .placeholderColor(this.colors.textTertiary)
        .placeholderFont({ size: FontSize.SUBTITLE })
        .width('100%')
        .height(ComponentSize.CONTROL)
        .borderRadius(Radius.MD)
        .backgroundColor(this.colors.inputBackground)
        .onChange((v: string) => {
          this.newPw = v;
          this.viewModel.errorMessage = '';
        })

      // 失败原因显示在面板内而不是弹窗：面板开着时 AlertDialog 不进布局树（实测不可见），
      // 而口令输错需要就地重试，关面板弹窗反而丢掉上下文
      if (this.viewModel.errorMessage.length > 0) {
        Text(this.viewModel.errorMessage)
          .fontSize(FontSize.CAPTION)
          .fontColor(this.colors.danger)
          .width('100%')
          .margin({ top: Spacing.SM })
      }

      // 弹性占位：把按钮行撑到面板底部（与 add sheet 表单一致）
      Blank()
        .layoutWeight(1)

      // 按钮行
      SheetFormButtons({
        confirmLabel: '确认修改',
        canConfirm: true,
        onConfirm: (): void => {
          this.viewModel.changePassphrase(this.editFingerprint, this.oldPw, this.newPw).then((ok: boolean) => {
            if (ok) {
              this.isEditSheetVisible = false;
            }
          });
        },
        onCancel: (): void => {
          this.isEditSheetVisible = false;
        }
      })
    }
    .width('100%')
    .height('100%')
    .padding({ top: SHEET_PAD_TOP, left: Spacing.LG, right: Spacing.LG, bottom: SHEET_PAD_BOTTOM })
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(this.colors.surface)
  }

  /** 编辑表单临时字段（非 @Trace，仅表单输入用） */
  @Local oldPw: string = '';
  @Local newPw: string = '';

  /**
   * 从文件导入：拉起文件选择器，读入内容后切到导入表单
   *
   * 读入成功后必须打开导入表单——用户需在此确认内容并补填口令，
   * 实际导入由表单的「导入」按钮调用 viewModel.importKey() 完成。
   * 读取失败时用原生弹窗提示原因，避免「没反应」的静默失败。
   */
  private async pickKeyFile(): Promise<void> {
    const ok: boolean = await this.viewModel.importKeyFromFile();
    if (ok) {
      this.isImportFormVisible = true;
      this.isAddSheetVisible = true;
      this.isSwitchingForm = false;
      return;
    }
    // 用户取消选择时 errorMessage 为空，不打扰
    const reason: string = this.viewModel.errorMessage;
    this.isSwitchingForm = false;
    if (reason.length > 0) {
      this.showImportError(reason);
    }
  }

  /** 导入失败提示（原生弹窗，与 SSH 密钥页保持一致） */
  private showImportError(message: string): void {
    this.getUIContext().showAlertDialog({
      title: '导入失败',
      message: message,
      autoCancel: true,
      onWillDismiss: (action: DismissDialogAction): void => {
        action.dismiss();
      },
      confirm: {
        value: '确定',
        action: (): void => {
          this.viewModel.errorMessage = '';
        }
      }
    });
  }

  /**
   * 导入成功但有限制时的提示
   *
   * 例如加密子密钥是 native 不支持的算法：密钥已导入可用，但无法用于加密新条目。
   * 只弹一次，弹完清空 pendingWarning，避免重复打扰。
   */
  private consumePendingWarning(): void {
    const warning: string = this.viewModel.pendingWarning;
    if (warning.length === 0) {
      return;
    }
    this.viewModel.pendingWarning = '';
    this.getUIContext().showAlertDialog({
      title: '导入成功，但有限制',
      message: warning,
      autoCancel: true,
      onWillDismiss: (action: DismissDialogAction): void => {
        action.dismiss();
      },
      confirm: {
        value: '知道了',
        action: (): void => {
        }
      }
    });
  }

  /**
   * 导入失败（非输入类错误）的弹窗提示
   *
   * 用于「密钥已存在」与「导入的是公钥、不含私钥材料」两类——都不是改一下输入
   * 就能通过的错误，放在表单底部的小红字里会被忽略。
   *
   * 必须**先关面板、延时再弹**：`bindSheet` 与 `AlertDialog` 同处 UIContext 顶层，
   * 面板未关闭时 AlertDialog 不进布局树（实测弹了但不可见）。
   * 只弹一次，弹完清空，避免重复打扰。
   */
  private consumeImportDialog(): void {
    const message: string = this.viewModel.pendingDuplicate;
    if (message.length === 0) {
      return;
    }
    this.viewModel.pendingDuplicate = '';
    // 表单里没有可修改的东西，直接收起面板
    this.isAddSheetVisible = false;
    setTimeout((): void => {
      this.getUIContext().showAlertDialog({
        title: '无法导入密钥',
        message: message,
        autoCancel: true,
        onWillDismiss: (action: DismissDialogAction): void => {
          action.dismiss();
        },
        confirm: {
          value: '知道了',
          action: (): void => {
          }
        }
      });
    }, 400);
  }

  /**
   * 导出私钥为 .asc 文件（系统保存对话框）
   *
   * 不再复制到剪贴板：私钥是敏感凭据，剪贴板是明文、其它应用可读；
   * 而 .asc 文件是 pass/gpg 生态里传递密钥的标准形态，落盘后可直接导入还原。
   */
  private handleExportPrivateKey(): void {
    this.viewModel.exportKeyToFile(this.editFingerprint, true).then((r: KeyExportResult): void => {
      if (r.cancelled) {
        return;
      }
      showToastSafe(this.getUIContext(), r.ok ? '私钥已保存为 .asc 文件' : r.error, 2500);
    });
  }

  /** 导出公钥为 .asc 文件（同私钥导出，仅文件名加 -public 后缀） */
  private handleExportPublicKey(): void {
    this.viewModel.exportKeyToFile(this.editFingerprint, false).then((r: KeyExportResult): void => {
      if (r.cancelled) {
        return;
      }
      showToastSafe(this.getUIContext(), r.ok ? '公钥已保存为 .asc 文件' : r.error, 2500);
    });
  }

  /**
   * 呈现 ViewModel 的 toast
   *
   * toast 此前只被当成"操作成功"的布尔标志使用，从不渲染，
   * 删除/设为默认这类无后续页面的操作因此完全没有反馈。
   */
  private showToastIfAny(): void {
    const message: string = this.viewModel.toast;
    if (message.length === 0) return;
    try {
      showToastSafe(this.getUIContext(), message, 2000);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'showToast failed: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 删除密钥（系统悬浮气泡提示结果）
   *
   * 私钥删除不可逆，且会让已有密文永久无法解密，必须有二次确认——
   * 删除密码与删除仓库都有确认弹窗，唯独这里曾经点一下就删。
   */
  private handleDeleteKey(): void {
    const key = this.viewModel.keys.find((k: GpgKeyId): boolean => k.fingerprint === this.editFingerprint);
    const label: string = key !== undefined && key.userId.length > 0 ? key.userId : this.editFingerprint;
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: '删除密钥',
        message: `确定删除「${label}」？删除后用它加密的密码将无法解密，且此操作不可撤销。`,
        buttons: [
          { text: '取消', color: this.colors.textSecondary },
          { text: '删除', color: this.colors.danger },
        ],
        // 状态栏沉浸补偿：遮罩展示期间调暗，消失（按钮/点遮罩/返回）后还原
        onWillAppear: (): void => {
        },
        onDidDisappear: (): void => {},
      }).then((result: promptAction.ShowDialogSuccessResponse) => {
        if (result.index === 1) {
          this.viewModel.deleteKey(this.editFingerprint).then(() => {
            this.showToastIfAny();
          });
        }
      }).catch((e: Error) => {
        hilog.error(DOMAIN, TAG, 'delete confirm dialog failed: %{public}s', JSON.stringify(e));
      });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'showDialog failed: %{public}s', JSON.stringify(e));
      // 弹窗不可用时不静默放弃：退回直接删除会失去保护，改为不执行并记录
    }
  }

  /** 是否可设为默认：私钥且当前不是默认密钥（与菜单项显示条件一致） */
  private canSetDefault(fingerprint: string): boolean {
    if (fingerprint.length === 0 || this.viewModel.isDefaultKey(fingerprint)) {
      return false;
    }
    const key = this.viewModel.keys.find((k: GpgKeyId): boolean => k.fingerprint === fingerprint);
    return key !== undefined && key.isSecret;
  }

  /**
   * 设为默认后：若仓库根目录已有 .gpg-id 且指向别的密钥，询问是否一并切换
   *
   * 「默认加密密钥」的语义就是新建条目的加密密钥，而根目录条目的密钥由根目录
   * .gpg-id 决定（pass 约定）。两者不一致时用户会以为「设了默认却没生效」，
   * 故这里明确询问一次，而不是静默改写仓库内容（.gpg-id 会随同步下发到其他设备）。
   */
  private offerSwitchRootKey(fingerprint: string): void {
    const current: string = this.viewModel.rootGpgIdFingerprint();
    if (current.length === 0 || current === fingerprint) {
      return;
    }
    // 预扫根目录范围：改 .gpg-id 后哪些条目需要重加密、需要哪把旧密钥的口令。
    // 与 pass init 一致：只有「由根 .gpg-id 管辖」的条目会被换；
    // 子目录自带 .gpg-id 的条目收件人不变，自动跳过（连口令都不需要）。
    const plan: ReencryptPlan = ReencryptService.getInstance().plan('', [fingerprint]);
    if (plan.error.length > 0) {
      showToastSafe(this.getUIContext(), plan.error, 2500);
      return;
    }
    const currentLabel: string = this.viewModel.keyLabel(current);
    const targetLabel: string = this.viewModel.keyLabel(fingerprint);
    let message: string = `仓库根目录当前用「${currentLabel}」加密。是否切换为「${targetLabel}」`
      + `并重新加密根目录下的 ${plan.needsCount} 个条目？`;
    if (plan.needsCount === 0) {
      message = `仓库根目录当前用「${currentLabel}」加密。是否切换为「${targetLabel}」？`
        + `（根目录下没有需要重新加密的条目）`;
    }
    if (plan.missingKeyCount > 0) {
      message += `\n注意：${plan.missingKeyCount} 个条目因缺少对应私钥将被跳过。`;
    }
    if (plan.needsCount > 0 && plan.requiredKeys.length > 0) {
      message += '\n需要输入旧密钥的口令。';
    }
    this.getUIContext().showAlertDialog({
      title: '切换根目录加密密钥',
      message: message,
      autoCancel: true,
      alignment: DialogAlignment.Center,
      onWillDismiss: (action: DismissDialogAction): void => {
        action.dismiss();
      },
      primaryButton: {
        value: '仅设为默认',
        action: (): void => {},
      },
      secondaryButton: {
        value: '一并切换',
        fontColor: this.colors.primary,
        action: (): void => {
          this.proceedRootKeySwitch(fingerprint, plan);
        },
      },
    });
  }

  /**
   * 执行根目录密钥切换：先确保旧密钥已解锁（否则弹口令输入），再重加密并落盘 .gpg-id
   */
  private async proceedRootKeySwitch(fingerprint: string, plan: ReencryptPlan): Promise<void> {
    if (plan.needsCount === 0) {
      // 没有条目需要换：只写 .gpg-id
      const written = PasswordRepository.getInstance().setGpgIdForDir('', [fingerprint]);
      showToastSafe(this.getUIContext(), written.success ? '根目录加密密钥已切换' : written.error, 2500);
      if (written.success) {
        RepoChangeNotifier.connect().bump();
      }
      return;
    }
    const crypto: PgpCrypto = PgpCrypto.getInstance();
    let ready: boolean = plan.requiredKeys.length === 0
      || crypto.isUnlockedFor(plan.requiredKeys);
    if (!ready && plan.requiredKeys.length > 0) {
      ready = await crypto.ensureUnlocked(plan.requiredKeys);
    }
    if (ready) {
      await this.runRootReencrypt(fingerprint, plan);
      return;
    }
    // 需要旧密钥口令：弹出输入面板
    this.pendingRootKey = fingerprint;
    this.pendingRootPlan = plan;
    this.rootKeyPassphrase = '';
    this.rootKeyError = '';
    this.isRootKeySheetVisible = true;
  }

  /** 口令面板确认：校验旧密钥口令，成功则继续重加密 */
  private async onRootKeyConfirm(): Promise<void> {
    const plan: ReencryptPlan | null = this.pendingRootPlan;
    if (plan === null || this.rootKeyPassphrase.length === 0 || this.rootKeyBusy) {
      return;
    }
    this.rootKeyBusy = true;
    this.rootKeyError = '';
    let unlocked: boolean = false;
    let failReason: string = '密钥密码错误，请重试';
    for (let i: number = 0; i < plan.requiredKeys.length; i++) {
      const res: UnlockResult = await PgpCrypto.getInstance().unlockPassphrase(
        plan.requiredKeys[i], this.rootKeyPassphrase);
      if (res.success) {
        unlocked = true;
        break;
      }
      if (res.error.length > 0) {
        failReason = res.error;
      }
    }
    this.rootKeyBusy = false;
    if (!unlocked) {
      this.rootKeyError = failReason;
      return;
    }
    const fingerprint: string = this.pendingRootKey;
    this.isRootKeySheetVisible = false;
    this.rootKeyPassphrase = '';
    this.pendingRootKey = '';
    this.pendingRootPlan = null;
    await this.runRootReencrypt(fingerprint, plan);
  }

  /** 逐条重加密根目录条目并落盘；失败条目保持原样，结果以 Toast 汇总 */
  private async runRootReencrypt(fingerprint: string, plan: ReencryptPlan): Promise<void> {
    this.rootKeyBusy = true;
    const outcome: ReencryptOutcome =
      await ReencryptService.getInstance().run('', [fingerprint], plan);
    this.rootKeyBusy = false;
    let message: string;
    if (outcome.success) {
      message = `已切换根目录加密密钥，重加密 ${outcome.reencrypted} 个条目`
        + (outcome.skipped > 0 ? `，跳过 ${outcome.skipped} 个` : '');
    } else {
      message = `重加密未完成：${outcome.error}`;
      if (outcome.failures.length > 0) {
        message += `\n首个失败：${outcome.failures[0].relativePath}（${outcome.failures[0].error}）`;
      }
    }
    showToastSafe(this.getUIContext(), message, 3500);
  }

  /** 旧密钥口令输入面板 */
  @Builder
  rootKeySheetBuilder() {
    Column() {
      Text('输入旧密钥口令')
        .fontSize(FontSize.SUBTITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.colors.textPrimary)
        .width('100%')

      Text('重新加密需要先解开这些条目的旧密钥')
        .fontSize(FontSize.CAPTION)
        .fontColor(this.colors.textTertiary)
        .width('100%')
        .margin({ top: Spacing.XS, bottom: Spacing.LG })

      TextInput({ placeholder: '旧密钥口令', text: this.rootKeyPassphrase })
        .type(InputType.Password)
        .height(ComponentSize.CONTROL)
        .borderRadius(Radius.MD)
        .backgroundColor(this.colors.inputBackground)
        .fontSize(FontSize.SUBTITLE)
        .fontColor(this.colors.textPrimary)
        .placeholderColor(this.colors.textTertiary)
        .placeholderFont({ size: FontSize.SUBTITLE })
        .padding({ left: Spacing.MD, right: Spacing.MD })
        .onChange((v: string) => {
          this.rootKeyPassphrase = v;
          this.rootKeyError = '';
        })

      if (this.rootKeyError.length > 0) {
        Text(this.rootKeyError)
          .fontSize(FontSize.CAPTION)
          .fontColor(this.colors.danger)
          .width('100%')
          .margin({ top: Spacing.SM })
      }

      Blank()
        .layoutWeight(1)

      SheetFormButtons({
        confirmLabel: '开始重加密',
        isBusy: this.rootKeyBusy,
        canConfirm: this.rootKeyPassphrase.length > 0,
        onCancel: (): void => {
          this.isRootKeySheetVisible = false;
        },
        onConfirm: (): void => {
          this.onRootKeyConfirm();
        },
      })
    }
    .width('100%')
    .height('100%')
    .padding({ top: SHEET_PAD_TOP, left: Spacing.LG, right: Spacing.LG, bottom: SHEET_PAD_BOTTOM })
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(this.colors.surface)
  }

  /**
   * 列表第三行：加密方式
   *
   * 取 encryptionAlgorithm（加密子密钥算法，无子密钥时回退主密钥），
   * 而非 algorithm——PGP 惯例是主密钥签名、子密钥加密，
   * 混合密钥（如 Ed25519 主密钥 + Kyber 加密子密钥）只有子密钥算法能反映实际加密方式。
   * 为空时回退「未知算法」，避免显示空白。
   */
  private algorithmText(key: GpgKeyId): string {
    const raw: string = key.encryptionAlgorithm.length > 0
      ? key.encryptionAlgorithm
      : key.algorithm;
    if (raw.length === 0) {
      return '未知算法';
    }
    const text: string = raw.replace(/_/g, ' ').trim();
    return text.length > 0 ? text : '未知算法';
  }

  @Builder
  keyItem(key: GpgKeyId) {
    Row() {
      Column() {
        Row() {
          Text(key.name)
            .fontSize(FontSize.SUBTITLE)
            .fontColor(this.colors.textPrimary)
            .fontWeight(FontWeight.Medium)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          if (this.viewModel.isDefaultKey(key.fingerprint)) {
            Text('默认')
              .fontSize(FontSize.OVERLINE)
              .fontColor(this.colors.onPrimary)
              .backgroundColor(this.colors.primary)
              .borderRadius(Radius.SM)
              .padding({ left: Spacing.SM, right: Spacing.SM, top: Spacing.XS, bottom: Spacing.XS })
              .margin({ left: Spacing.SM })
          }

          if (this.viewModel.isExpired(key)) {
            Text('已过期')
              .fontSize(FontSize.OVERLINE)
              .fontColor(this.colors.onPrimary)
              .backgroundColor(this.colors.danger)
              .borderRadius(Radius.SM)
              .padding({ left: Spacing.SM, right: Spacing.SM, top: Spacing.XS, bottom: Spacing.XS })
              .margin({ left: Spacing.SM })
          }

          // 私钥/公钥改为标签：第三行让位给加密方式
          Text(key.isSecret ? '私钥' : '公钥')
            .fontSize(FontSize.OVERLINE)
            .fontColor(this.colors.textSecondary)
            .borderRadius(Radius.SM)
            .border({ width: DividerSpec.STROKE, color: this.colors.divider })
            .padding({ left: Spacing.SM, right: Spacing.SM, top: Spacing.XS, bottom: Spacing.XS })
            .margin({ left: Spacing.SM })
        }
        .alignItems(VerticalAlign.Center)

        Text(this.viewModel.formatFingerprint(key.fingerprint))
          .fontSize(FontSize.CAPTION)
          .fontColor(this.colors.textTertiary)
          .fontFamily('monospace')
          .margin({ top: Spacing.XS })

        // 第三行：加密方式（如 EdDSA / RSA）
        Text(this.algorithmText(key))
          .fontSize(FontSize.CAPTION)
          .fontColor(this.colors.textTertiary)
          .margin({ top: Spacing.XS })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 编辑按钮：下拉菜单（bindMenu 自动在点击时弹出）
      SymbolGlyph($r('sys.symbol.dot_grid_1x2'))
        .fontSize(IconSize.ACTION)
        .fontColor([this.colors.textSecondary])
        .padding(Spacing.XS)
        .borderRadius(Radius.SM)
        .stateStyles({
          normal: { .backgroundColor(Color.Transparent) },
          pressed: { .backgroundColor(this.colors.pressed) },
        })
        .onClick(() => {
          this.editFingerprint = key.fingerprint;
          this.editAction = '';
        })
        .bindMenu(this.editMenuBuilder())
    }
    .width('100%')
    .padding(Spacing.CARD)
    .backgroundColor(this.colors.surface)
    .borderRadius(Radius.CARD)
    .margin({ top: Spacing.CARD_GAP })
    .alignItems(VerticalAlign.Center)
  }

  build() {
    NavDestination() {
      Column() {
        // ===== 自定义标题栏（40vp 圆形返回按钮 + 标题，见 AppTitleBar） =====
        AppTitleBar({ title: 'PGP 密钥管理' })

        // ===== 列表区：标题栏下顶置排列 =====
        Scroll() {
          Column() {
            if (this.viewModel.isLoading) {
              Row() {
                LoadingProgress()
                  .width(IconSize.MD)
                  .height(IconSize.MD)
                Text('加载中...')
                  .fontSize(FontSize.CAPTION)
                  .fontColor(this.colors.textTertiary)
                  .margin({ left: Spacing.SM })
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
              .padding(Spacing.XL)
            } else if (this.viewModel.keys.length === 0) {
              EmptyState({
                icon: $r('sys.symbol.key'),
                title: '尚未导入任何密钥',
                hint: '点击右下角 + 导入或创建密钥',
              })
            } else {
              ForEach(this.viewModel.keys, (key: GpgKeyId) => {
                this.keyItem(key)
              }, (key: GpgKeyId) => key.fingerprint)
            }

            // 底部留出 FAB 的高度 + 呼吸间距，避免最后一项被浮动按钮压住
            Blank()
              .height(IconSize.FAB + Spacing.XL + Spacing.LG)
          }
          .padding(Spacing.PAGE_H)
        }
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
        .align(Alignment.TopStart)
        .backgroundColor(this.colors.background)

        // ===== 右下角 + 号 FAB（与首页样式一致） =====
        AppFab({
          onTap: (): void => {
            this.isImportFormVisible = false;
            this.isGenerateFormVisible = false;
            this.isAddSheetVisible = true;
          },
        })
        .position({ x: '82%', y: '88%' })
        // 编辑表单 sheet 绑定在 FAB 节点上：同一节点只能挂一个 bindSheet，
        // 两个都绑在根容器时后者会覆盖前者导致 + 号弹窗不弹出
        .bindSheet(this.isEditSheetVisible, this.editSheetBuilder(),
          this.editAction.length > 0 ? this.editSheetFormOptions : this.editSheetMenuOptions)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.colors.background)
      .bindSheet(this.isAddSheetVisible, this.addSheetBuilder(),
        (this.isImportFormVisible || this.isGenerateFormVisible) ? this.addSheetFormOptions : this.addSheetMenuOptions)
    }
    .hideTitleBar(true)
    // 三个半模态必须挂在**三个不同节点**上：同一节点只能挂一个 bindSheet，
    // 后挂的会覆盖先挂的（实测根容器同时挂 add 与 rootKey 时 + 号点了毫无反应）。
    // 故：FAB 节点挂 edit sheet，根容器挂 add sheet，NavDestination 挂 rootKey sheet。
    .bindSheet(this.isRootKeySheetVisible, this.rootKeySheetBuilder(), this.rootKeySheetOptions)
  }
}
