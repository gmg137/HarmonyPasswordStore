import { PasswordCreateViewModel } from '../viewmodel/PasswordCreateViewModel';
import { AppTitleBar } from '../views/AppTitleBar';
import { RouteManager } from '../common/RouteManager';
import { PasswordListViewModel } from '../viewmodel/PasswordListViewModel';
import { ThemeColors, Palette, Radius, Spacing, ButtonSpec, FontSize, IconSize, ComponentSize, DividerSpec } from '../common/ThemeColors';
import { Strings } from '../common/Strings';
import { inputMethod } from '@kit.IMEKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** hilog 域 */
const DOMAIN: number = 0x0001;
/** hilog 标签 */
const TAG: string = 'PasswordCreatePage';
/** 表单行标签列宽度（固定列宽让输入区左缘对齐，不随标签字数跳动） */
const FORM_LABEL_W: number = 72;

/**
 * 新建/编辑密码页
 *
 * 创建或编辑密码条目，支持密码生成器，保存时加密写入 .gpg 文件。
 */
@ComponentV2
export struct PasswordCreatePage {
  @Local viewModel: PasswordCreateViewModel = new PasswordCreateViewModel();

  private get colors(): Palette {
    return ThemeColors.getInstance().palette();
  }

  /** 是否编辑模式（标题与初始化流程区分） */
  @Local isEditMode: boolean = false;

  aboutToAppear(): void {
    // NavPathInfo.param 在 aboutToAppear 时序下可能未就绪，
    // 改用 RouteManager 暂存的最近一次 push 参数
    const param: Object | undefined = RouteManager.getInstance().takeLastParam();
    let parentDir: string = '';
    let editPath: string = '';
    if (param) {
      const p = param as Record<string, string>;
      parentDir = p['parentDir'] ?? '';
      editPath = p['editPath'] ?? '';
    }
    if (editPath.length > 0) {
      // 编辑模式：解密原内容填充表单
      this.isEditMode = true;
      this.viewModel.initForEditByPath(editPath);
    } else {
      this.viewModel.initForCreate(parentDir);
    }
  }

  @Builder
  formField(label: string, placeholder: string, valueGetter: () => string, isPassword: boolean, onInput: (v: string) => void) {
    Row() {
      Text(label)
        .fontSize(FontSize.BODY)
        .fontColor(this.colors.textSecondary)
        .width(Strings.labelWidth(FORM_LABEL_W))

      if (isPassword) {
        TextInput({ text: valueGetter(), placeholder: placeholder })
          .type(this.viewModel.isPasswordVisible ? InputType.Normal : InputType.Password)
          .fontSize(FontSize.SUBTITLE)
          .fontColor(this.colors.textPrimary)
          .placeholderColor(this.colors.textTertiary)
          .height(ComponentSize.CONTROL)
          .layoutWeight(1)
          .backgroundColor(Color.Transparent)
          .padding(0)
          .onChange((v: string) => onInput(v))

        // 密码强度（与右边缘保持合理间距；
        // 不再自定义眼睛——InputType.Password 的 TextInput 自带系统原生可见性图标）
        if (this.viewModel.password.length > 0) {
          Text(this.viewModel.getStrengthLabel())
            .fontSize(FontSize.CAPTION)
            .fontColor(this.viewModel.getStrengthColor())
            .fontWeight(FontWeight.Medium)
            .margin({ left: Spacing.SM })
        }
      } else {
        TextInput({ text: valueGetter(), placeholder: placeholder })
          .fontSize(FontSize.SUBTITLE)
          .fontColor(this.colors.textPrimary)
          .placeholderColor(this.colors.textTertiary)
          .height(ComponentSize.CONTROL)
          .layoutWeight(1)
          .backgroundColor(Color.Transparent)
          .padding(0)
          .onChange((v: string) => onInput(v))
      }
    }
    .width('100%')
    .height(ComponentSize.ROW)
    // 密码行与其他行保持一致的内边距（左右均 16vp），
    // 强度文字与右边缘保持合理间距
    .padding({ left: Spacing.CARD, right: Spacing.CARD })
    .backgroundColor(this.colors.surface)
    .borderRadius(Radius.CARD)
    .margin({ top: Spacing.CARD_GAP })
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 收起软键盘
   *
   * 展开密码生成器面板时键盘会挡住面板本身（面板在密码输入框下方），
   * 点「密码生成器」即收起键盘，让用户直接看到参数与「生成密码」按钮。
   */
  private dismissKeyboard(): void {
    try {
      inputMethod.getController().stopInputSession();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'stopInputSession failed: %{public}s',
        e instanceof Error ? e.message : String(e));
    }
  }

  @Builder
  genParamToggle(label: string, isOn: boolean, onToggle: () => void) {
    Row() {
      Text(label)
        .fontSize(FontSize.BODY)
        .fontColor(this.colors.textPrimary)
        .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: isOn })
        .onChange((v: boolean) => onToggle())
    }
    .width('100%')
    .padding({ left: Spacing.CARD, right: Spacing.CARD, top: Spacing.SM, bottom: Spacing.SM })
  }

  build() {
    NavDestination() {
      Column() {
        AppTitleBar({ title: this.isEditMode ? $r('app.string.create_edit_title') : $r('app.string.password_create') })

        Scroll() {
          Column() {
          // 所在目录
          if (this.viewModel.parentDir.length > 0) {
            Row() {
              Text($r('app.string.create_dir_label'))
                .fontSize(FontSize.BODY)
                .fontColor(this.colors.textSecondary)
                .width(Strings.labelWidth(FORM_LABEL_W))
              Text(this.viewModel.parentDir)
                .fontSize(FontSize.SUBTITLE)
                .fontColor(this.colors.textPrimary)
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .height(ComponentSize.ROW)
            .padding({ left: Spacing.CARD, right: Spacing.CARD })
            .backgroundColor(this.colors.surface)
            .borderRadius(Radius.CARD)
            .margin({ top: Spacing.CARD_GAP })
            .alignItems(VerticalAlign.Center)
          }

          // 名称
          this.formField(Strings.get('common_name'), Strings.get('create_name_placeholder'), (): string => this.viewModel.name, false,
            (v: string) => { this.viewModel.name = v; })

          // 密码
          this.formField(Strings.get('common_password'), Strings.get('create_password_placeholder'), (): string => this.viewModel.password, true,
            (v: string) => { this.viewModel.onPasswordInput(v); })

          // 生成器面板切换
          Row() {
            Text($r('app.string.passgen'))
              .fontSize(FontSize.SUBTITLE)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.colors.textPrimary)
              .layoutWeight(1)
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(IconSize.CHEVRON)
              .fontColor([this.colors.textTertiary])
              .rotate({ angle: this.viewModel.isGeneratorVisible ? 90 : 0 })
          }
          .width('100%')
          .height(ComponentSize.ROW)
          .padding({ left: Spacing.ROW_H, right: Spacing.ROW_H })
          .backgroundColor(this.colors.surface)
          .borderRadius(Radius.CARD)
          .margin({ top: Spacing.CARD_GAP })
          .alignItems(VerticalAlign.Center)
          .stateStyles({
            normal: { .backgroundColor(this.colors.surface) },
            pressed: { .backgroundColor(this.colors.pressed) },
          })
          .onClick(() => {
            this.dismissKeyboard();
            this.viewModel.toggleGenerator();
          })

          // 生成器面板
          if (this.viewModel.isGeneratorVisible) {
            Column() {
              // 长度：标题 + 拖动条 + 数字（一行）
              Row() {
                Text($r('app.string.passgen_length'))
                  .fontSize(FontSize.BODY)
                  .fontColor(this.colors.textSecondary)
                  .width(40)

                Slider({ value: this.viewModel.genParams.length, min: 6, max: 30, step: 1 })
                  .layoutWeight(1)
                  .onChange((v: number) => {
                    this.viewModel.updateGenParam('length', Math.round(v));
                  })

                Text(`${this.viewModel.genParams.length}`)
                  .fontSize(FontSize.SUBTITLE)
                  .fontColor(this.colors.primary)
                  .fontWeight(FontWeight.Bold)
                  .width(30)
                  .textAlign(TextAlign.Center)
              }
              .width('100%')
              .padding({ left: Spacing.CARD, right: Spacing.CARD, top: Spacing.MD })

              this.genParamToggle(Strings.get('create_gen_upper'), this.viewModel.genParams.includeUppercase,
                () => { this.viewModel.updateGenParam('includeUppercase', !this.viewModel.genParams.includeUppercase); })
              this.genParamToggle(Strings.get('create_gen_lower'), this.viewModel.genParams.includeLowercase,
                () => { this.viewModel.updateGenParam('includeLowercase', !this.viewModel.genParams.includeLowercase); })
              this.genParamToggle(Strings.get('create_gen_digits'), this.viewModel.genParams.includeDigits,
                () => { this.viewModel.updateGenParam('includeDigits', !this.viewModel.genParams.includeDigits); })
              this.genParamToggle(Strings.get('create_gen_symbols'), this.viewModel.genParams.includeSymbols,
                () => { this.viewModel.updateGenParam('includeSymbols', !this.viewModel.genParams.includeSymbols); })
              this.genParamToggle(Strings.get('passgen_exclude_ambiguous'), this.viewModel.genParams.excludeAmbiguous,
                () => { this.viewModel.updateGenParam('excludeAmbiguous', !this.viewModel.genParams.excludeAmbiguous); })

              Button($r('app.string.create_generate'))
                .type(ButtonType.Normal)
                .borderRadius(ButtonSpec.SECONDARY_RADIUS)
                .width('100%')
                .height(ButtonSpec.SECONDARY_HEIGHT)
                .margin({ top: Spacing.MD, bottom: Spacing.SM })
                .onClick(() => {
                  this.dismissKeyboard();
                  this.viewModel.generatePassword();
                })
            }
            .width('100%')
            .padding({ left: Spacing.CARD, right: Spacing.CARD, bottom: Spacing.SM })
            .backgroundColor(this.colors.surface)
            .borderRadius(Radius.CARD)
            .margin({ top: Spacing.XS })
          }

          // 用户名
          this.formField(Strings.get('common_username'), Strings.get('create_username_placeholder'), (): string => this.viewModel.username, false,
            (v: string) => { this.viewModel.username = v; })

          // 邮箱
          this.formField(Strings.get('common_email'), Strings.get('create_email_placeholder'), (): string => this.viewModel.email, false,
            (v: string) => { this.viewModel.email = v; })

          // 手机号
          this.formField(Strings.get('common_phone'), Strings.get('create_phone_placeholder'), (): string => this.viewModel.phone, false,
            (v: string) => { this.viewModel.phone = v; })

          // 备注
          this.formField(Strings.get('common_notes'), Strings.get('create_notes_placeholder'), (): string => this.viewModel.notes, false,
            (v: string) => { this.viewModel.notes = v; })

          // 额外内容
          Column() {
            Text($r('app.string.common_extra_content'))
              .fontSize(FontSize.BODY)
              .fontColor(this.colors.textSecondary)
            TextArea({ text: this.viewModel.extraContent, placeholder: $r('app.string.create_extra_placeholder') })
              .fontSize(FontSize.BODY)
              .fontColor(this.colors.textPrimary)
              .placeholderColor(this.colors.textTertiary)
              .fontFamily('monospace')
              .width('100%')
              .margin({ top: Spacing.XS })
              .onChange((v: string) => { this.viewModel.extraContent = v; })
          }
          .width('100%')
          .padding(Spacing.CARD)
          .backgroundColor(this.colors.surface)
          .borderRadius(Radius.CARD)
          .margin({ top: Spacing.CARD_GAP })
          .alignItems(HorizontalAlign.Start)

          // 错误提示
          if (this.viewModel.errorMessage.length > 0) {
            Text(this.viewModel.errorMessage)
              .fontSize(FontSize.BODY)
              .fontColor(this.colors.danger)
              .padding(Spacing.MD)
          }

          // 保存按钮
          Button($r('app.string.common_save'))
            .type(ButtonType.Normal)
            .borderRadius(ButtonSpec.PRIMARY_RADIUS)
            .width('100%')
            .height(ButtonSpec.PRIMARY_HEIGHT)
            .fontSize(ButtonSpec.FONT_SIZE)
            .fontWeight(ButtonSpec.FONT_WEIGHT)
            .margin({ top: Spacing.LG, bottom: Spacing.XL })
            .enabled(this.viewModel.canSave())
            .onClick(() => {
              this.viewModel.save().then(() => {
                if (this.viewModel.isSaved) {
                  RouteManager.getInstance().pop();
                }
              });
            })

          // 保存中加载
          if (this.viewModel.isSaving) {
            LoadingProgress()
              .width(IconSize.LG)
              .height(IconSize.LG)
              .margin({ bottom: Spacing.LG })
          }
        }
        .padding(Spacing.PAGE_H)
        .backgroundColor(this.colors.background)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .backgroundColor(this.colors.background)
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    .backgroundColor(this.colors.background)
  }
}
