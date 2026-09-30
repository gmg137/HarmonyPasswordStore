import { SshKeyManagerViewModel } from '../viewmodel/SshKeyManagerViewModel';
import { showToastSafe } from '../utils/ToastUtil';
import { SshKeyInfo } from '../crypto/SshKeyManager';
import { SshKeyType } from '../common/Constants';
import { ThemeColors, Palette, Radius, Spacing, FontSize, IconSize, ComponentSize } from '../common/ThemeColors';
import { SheetFormButtons } from '../views/SheetFormButtons';
import { AppTitleBar } from '../views/AppTitleBar';
import { AppFab } from '../views/AppFab';
import { EmptyState } from '../views/EmptyState';
import { formSheetOptions, menuSheetHeight, panelSheetOptions, themedSheetOptions, SHEET_PAD_TOP, SHEET_PAD_BOTTOM } from '../common/SheetStyles';
import { Strings } from '../common/Strings';
import { SystemInsets } from '../utils/SystemInsets';

/**
 * SSH 密钥管理页
 *
 * SSH 密钥只保留一把：新建/导入都会替换旧密钥，替换前需用户确认。
 * 布局与交互对齐 PGP 密钥管理页：自定义标题栏 + 顶置列表 +
 * 右下角 FAB 半模态动作菜单 + 列表项编辑菜单（bindMenu）。
 */
@ComponentV2
export struct SshKeyManagerPage {
  @Local viewModel: SshKeyManagerViewModel = new SshKeyManagerViewModel();
  /** 表单切换中：切换 options 会触发 sheet 重建，onDisappear 需跳过复位 */
  @Local isSwitchingForm: boolean = false;

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
    this.viewModel.resetAddSheet();
  }

  /**
   * sheet 配置走 getter + themedSheetOptions（不能写成字段初始化器）：
   * 字段初始化器捕获的 backgroundColor 停留在构造时的主题色，色深变化后面板
   * 被上拉会露出过期色（深色下是白带）。themedSheetOptions 按背景色+高度缓存，
   * 主题没变返回同一对象（稳定引用，不会因重渲染意外弹出）。
   */

  /** add sheet：菜单态 */
  private get addSheetMenuOptions(): SheetOptions {
    const h: number = menuSheetHeight(3, SHEET_PAD_BOTTOM);
    return themedSheetOptions(this, 'SshAddMenu', 
      (): SheetOptions => panelSheetOptions(this.colors.surface, h, (): void => this.resetAddSheet()),
      this.colors.surface, h);
  }

  /** add sheet：表单态撑满面板，键盘只 resize 内容（按钮留在面板底部） */
  private get addSheetFormOptions(): SheetOptions {
    return themedSheetOptions(this, 'SshAddForm', 
      (): SheetOptions => formSheetOptions(this.colors.surface, (): void => this.resetAddSheet()),
      this.colors.surface, 'sshform');
  }

  /**
   * 打开生成/导入表单（先关 sheet，延时以表单态重开）
   */
  private openForm(action: string): void {
    this.isSwitchingForm = true;
    this.viewModel.isAddSheetVisible = false;
    setTimeout(() => {
      if (action === 'generate') {
        this.viewModel.openGenerateForm();
      } else {
        this.viewModel.openImportForm();
      }
    }, 350);
  }

  /**
   * 新建/导入入口：已有密钥时先确认替换
   *
   * 说明文本已合并进导入弹窗（ssh_import_hint 资源），不再单独弹提示框。
   * SSH 密钥只保留一把，替换后旧密钥失效，可能失去服务器访问权限。
   * @param action 'generate' 生成新密钥；'import' 导入密钥
   */
  private requestAction(action: string): void {
    if (!this.viewModel.hasKey()) {
      this.openForm(action);
      return;
    }

    this.getUIContext().showAlertDialog({
      title: $r('app.string.ssh_replace_confirm_title'),
      message: $r('app.string.ssh_replace_confirm_msg'),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      // AlertDialog 无 appear/disappear 回调：弹出时调暗状态栏，
      // onWillDismiss 覆盖点遮罩/返回，按钮 action 覆盖按钮路径，各还原一次
      onWillDismiss: (action: DismissDialogAction): void => {
        action.dismiss();
      },
      // primaryButton 在左、secondaryButton 在右 → 取消 / 替换
      primaryButton: {
        value: $r('app.string.common_cancel'),
        action: (): void => {},
      },
      secondaryButton: {
        value: $r('app.string.ssh_replace_btn'),
        fontColor: this.colors.danger,
        action: (): void => {
          this.openForm(action);
        },
      },
    });
  }

  /**
   * 选中加密私钥后以原生弹窗提示输入口令
   *
   * 用系统 AlertDialog 而非面板内联文本，避免占用表单空间、
   * 也避免被误认为静态说明。
   */
  private showEncryptedKeyHint(): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.ssh_encrypted_key_title'),
      message: $r('app.string.ssh_encrypted_key_msg'),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      onWillDismiss: (action: DismissDialogAction): void => {
        action.dismiss();
      },
      confirm: {
        value: $r('app.string.common_got_it'),
        fontColor: this.colors.primary,
        action: (): void => {},
      },
    });
  }

  /**
   * 导入失败时以原生弹窗展示原因
   *
   * 原来的做法是在按钮上方内联显示错误文本，容易与说明文字混淆；
   * 改为系统 AlertDialog，用户不会漏看。
   */
  private showImportErrorIfAny(): void {
    const msg: string = this.viewModel.errorMessage;
    if (msg.length === 0) {
      return;
    }
    this.viewModel.errorMessage = '';
    this.getUIContext().showAlertDialog({
      title: $r('app.string.common_import_failed'),
      message: msg,
      autoCancel: true,
      alignment: DialogAlignment.Center,
      onWillDismiss: (action: DismissDialogAction): void => {
        action.dismiss();
      },
      confirm: {
        value: $r('app.string.common_got_it'),
        fontColor: this.colors.primary,
        action: (): void => {},
      },
    });
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

  /** 密钥类型分段选项 */
  @Builder
  keyTypeOption(label: string, keyType: SshKeyType) {
    Text(label)
      .fontSize(FontSize.BODY)
      .fontColor(this.viewModel.selectedKeyType === keyType ? this.colors.onPrimary : this.colors.textSecondary)
      .fontWeight(this.viewModel.selectedKeyType === keyType ? FontWeight.Medium : FontWeight.Normal)
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .padding({ top: Spacing.SM, bottom: Spacing.SM })
      .borderRadius(Radius.SM)
      .backgroundColor(this.viewModel.selectedKeyType === keyType ? this.colors.primary : Color.Transparent)
      .stateStyles({
        normal: {
          .backgroundColor(this.viewModel.selectedKeyType === keyType ? this.colors.primary : Color.Transparent)
        },
        pressed: { .backgroundColor(this.colors.pressed) },
      })
      .onClick(() => {
        this.viewModel.selectedKeyType = keyType;
      })
  }

  /** 新建/导入底部菜单与表单 */
  @Builder
  addSheetBuilder() {
    // 根容器撑满面板；表单态把「字段区」与「按钮行」分开：
    // 软键盘弹起会把面板压矮，按钮若随内容流排布就会被裁到屏外点不到。
    Column() {
      if (!this.viewModel.isGenerateFormVisible && !this.viewModel.isImportFormVisible) {
        // 菜单态：动作面板
        Column() {
          this.actionItem($r('sys.symbol.plus'), Strings.get('ssh_generate_new'), (): void => {
            this.requestAction('generate');
          })
          Divider()
            .color(this.colors.divider)
            .margin({ left: Spacing.MD, right: Spacing.MD })
          this.actionItem($r('sys.symbol.doc_text'), Strings.get('ssh_import_key'), (): void => {
            this.requestAction('import');
          })
        }
        .width('100%')
        .borderRadius(Radius.CARD)
        .backgroundColor(this.colors.surface)
      } else if (this.viewModel.isGenerateFormVisible) {
        // 生成新密钥表单：内容固定不滚动，与导入表单结构一致
        Column() {
          this.formTitle(Strings.get('ssh_generate_new'))

          Row() {
            this.keyTypeOption('Ed25519', SshKeyType.ED25519)
            this.keyTypeOption('ECDSA', SshKeyType.ECDSA)
            this.keyTypeOption('RSA', SshKeyType.RSA)
          }
          .width('100%')
          .backgroundColor(this.colors.inputBackground)
          .borderRadius(Radius.SM)
          .padding(Spacing.XS)

          // 注释输入框：紧随密钥类型选择下方
          TextInput({ text: this.viewModel.comment, placeholder: $r('app.string.ssh_comment_ph') })
            .fontSize(FontSize.SUBTITLE)
            .fontColor(this.colors.textPrimary)
            .placeholderColor(this.colors.textTertiary)
            .placeholderFont({ size: FontSize.SUBTITLE })
            .width('100%')
            .height(ComponentSize.CONTROL)
            .borderRadius(Radius.MD)
            .backgroundColor(this.colors.inputBackground)
            .padding({ left: Spacing.MD, right: Spacing.MD })
            .margin({ top: Spacing.MD })
            .onChange((v: string) => {
              this.viewModel.comment = v;
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

        // 按钮行固定在屏幕底部
        SheetFormButtons({
          confirmLabel: Strings.get('ssh_generate_btn'),
          isBusy: this.viewModel.isGenerating,
          canConfirm: true,
          onConfirm: (): void => {
            this.viewModel.generateKeyPair();
          },
          onCancel: (): void => {
            this.viewModel.isAddSheetVisible = false;
          }
        })
      } else {
        // 导入密钥表单：字段直接排布（不包 Scroll），按钮行由下方 Blank() 撑到面板底部
        Column() {
          this.formTitle(Strings.get('ssh_import_key'))

          // 文件选择行：点击选择私钥文件
          Row() {
            SymbolGlyph($r('sys.symbol.folder'))
              .fontSize(IconSize.SM)
              .fontColor([this.colors.primary])

            Text(this.viewModel.selectedFileName.length > 0
              ? this.viewModel.selectedFileName
              : Strings.get('ssh_pick_key_file'))
              .fontSize(FontSize.BODY)
              .fontColor(this.viewModel.selectedFileName.length > 0
                ? this.colors.textPrimary : this.colors.textTertiary)
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ left: Spacing.SM })

            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(IconSize.CHEVRON)
              .fontColor([this.colors.textTertiary])
          }
          .width('100%')
          .height(ComponentSize.ROW)
          .padding({ left: Spacing.MD, right: Spacing.MD })
          .backgroundColor(this.colors.inputBackground)
          .borderRadius(Radius.MD)
          .alignItems(VerticalAlign.Center)
          .stateStyles({
            normal: { .backgroundColor(this.colors.inputBackground) },
            pressed: { .backgroundColor(this.colors.pressed) },
          })
          .onClick(() => {
            // 选中文件后若探测到已加密，用原生弹窗提示输入口令
            this.viewModel.pickPrivateKeyFile().then((picked: boolean) => {
              if (picked && this.viewModel.isSelectedKeyEncrypted) {
                this.showEncryptedKeyHint();
              }
            });
          })

          // 私钥口令：紧随「选择私钥文件」下方
          TextInput({ text: this.viewModel.passphrase, placeholder: $r('app.string.ssh_passphrase_ph') })
            .type(InputType.Password)
            .fontSize(FontSize.SUBTITLE)
            .fontColor(this.colors.textPrimary)
            .placeholderColor(this.colors.textTertiary)
            .placeholderFont({ size: FontSize.SUBTITLE })
            .width('100%')
            .height(ComponentSize.CONTROL)
            .borderRadius(Radius.MD)
            .backgroundColor(this.colors.inputBackground)
            .padding({ left: Spacing.MD, right: Spacing.MD })
            .margin({ top: Spacing.MD })
            .onChange((v: string) => {
              this.viewModel.passphrase = v;
            })

          // PC 端准备私钥的说明：直接显示在口令框下方（原为独立弹窗；多行整句一个资源 key）
          Text($r('app.string.ssh_import_hint'))
            .fontSize(FontSize.CAPTION)
            .fontColor(this.colors.textTertiary)
            .width('100%')
            .margin({ top: Spacing.MD })
        }
        .width('100%')

        // 弹性占位：把按钮撑到屏幕底部
        Blank()
          .layoutWeight(1)

        // 按钮行固定在屏幕底部：占位 + 面板 100% 高度共同保证
        SheetFormButtons({
          confirmLabel: Strings.get('common_import'),
          isBusy: this.viewModel.isImporting,
          canConfirm: this.viewModel.privateKeyText.trim().length > 0,
          onConfirm: (): void => {
            this.viewModel.importPrivateKey().then(() => {
              this.showImportErrorIfAny();
            });
          },
          onCancel: (): void => {
            this.viewModel.isAddSheetVisible = false;
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    // 统一面板内边距：顶部让开 dragBar，底部给按钮行留出与屏幕下沿的距离
    .padding({ top: SHEET_PAD_TOP, left: Spacing.LG, right: Spacing.LG, bottom: SHEET_PAD_BOTTOM })
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(this.colors.surface)
  }

  /** 下拉菜单：列表项编辑动作（bindMenu 弹出） */
  @Builder
  editMenuBuilder() {
    Column() {
      this.actionItem($r('sys.symbol.doc_text'), Strings.get('ssh_copy_pub'), (): void => {
        this.viewModel.copyPublicKey(this.viewModel.editAlias).then((msg: string) => {
          showToastSafe(this.getUIContext(), msg, 2000);
        });
      })
      Divider()
        .color(this.colors.divider)
        .margin({ left: Spacing.MD, right: Spacing.MD })
      this.dangerActionItem($r('sys.symbol.trash'), Strings.get('common_delete_key'), (): void => {
        const alias: string = this.viewModel.editAlias;
        this.viewModel.deleteKey(alias).then((msg: string) => {
          showToastSafe(this.getUIContext(), msg, 2000);
        });
      })
    }
    // 下拉菜单宽度
    .width(ComponentSize.MENU_WIDTH)
    .borderRadius(Radius.CARD)
    .backgroundColor(this.colors.surface)
    .padding({ top: Spacing.XS, bottom: Spacing.XS })
  }

  /** 列表项：主标题=邮箱/标识，副标题=加密方式 · 导入日期 + 编辑按钮 */
  @Builder
  keyItem(key: SshKeyInfo) {
    Row() {
      Column() {
        Row() {
          // 主标题：邮箱 / 标识（未设置时回退文件名）
          Text(this.viewModel.displayName(key))
            .fontSize(FontSize.SUBTITLE)
            .fontColor(this.colors.textPrimary)
            .fontWeight(FontWeight.Medium)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          Text('SSH')
            .fontSize(FontSize.OVERLINE)
            .fontColor(this.colors.onPrimary)
            .backgroundColor(this.colors.primary)
            .borderRadius(Radius.SM)
            .padding({ left: Spacing.SM, right: Spacing.SM, top: Spacing.XS, bottom: Spacing.XS })
            .margin({ left: Spacing.SM })
        }
        .alignItems(VerticalAlign.Center)

        // 副标题：加密方式 · 导入日期
        Text(this.viewModel.subtitle(key))
          .fontSize(FontSize.CAPTION)
          .fontColor(this.colors.textTertiary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
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
          this.viewModel.setEditAlias(key.alias);
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
        AppTitleBar({ title: $r('app.string.ssh_row_title') })

        // ===== 列表区：标题栏下顶置排列 =====
        Scroll() {
          Column() {
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
            } else if (this.viewModel.keys.length === 0) {
              EmptyState({
                icon: $r('sys.symbol.key'),
                title: Strings.get('ssh_empty_title'),
                hint: Strings.get('ssh_empty_hint'),
              })
            } else {
              ForEach(this.viewModel.keys, (key: SshKeyInfo) => {
                this.keyItem(key)
              }, (key: SshKeyInfo) => key.alias)
            }

            // 底部留出 FAB 的高度 + 呼吸间距 + 系统导航条高度：FAB 现在按
            // 「导航条高度 + 呼吸间距」锚定在底部（见其 markAnchor），占位必须同步
            // 加高，否则最后一项会被上移后的浮动按钮压住
            Blank()
              .height(IconSize.FAB + Spacing.XL + SystemInsets.bottomVp())
          }
          .padding(Spacing.PAGE_H)
        }
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
        .align(Alignment.TopStart)
        .backgroundColor(this.colors.background)

        // ===== 右下角 + 号 FAB（与 PGP 页一致） =====
        AppFab({
          onTap: (): void => {
            this.viewModel.openAddSheet();
          },
        })
        // 右缘锚定：FAB 右缘与页面卡片右缘平齐（右距 Spacing.XL），
        // 写法与首页一致（x:'82%' 左缘百分比会随屏宽漂移，见 PasswordListPage 注释）。
        // 底边按「导航条高度 + 呼吸间距」锚定，不用百分比（理由见 PasswordListPage）
        .position({ x: '100%', y: '100%' })
        .markAnchor({
          x: IconSize.FAB + Spacing.PAGE_H,
          y: IconSize.FAB + Spacing.XL + SystemInsets.bottomVp(),
        })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.colors.background)
      .bindSheet(this.viewModel.isAddSheetVisible, this.addSheetBuilder(),
        (this.viewModel.isGenerateFormVisible || this.viewModel.isImportFormVisible)
          ? this.addSheetFormOptions : this.addSheetMenuOptions)
    }
    .hideTitleBar(true)
  }
}
