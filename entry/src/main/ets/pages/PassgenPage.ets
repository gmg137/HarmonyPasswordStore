import { PassgenViewModel, GenMode } from '../viewmodel/PassgenViewModel';
import { AppTitleBar } from '../views/AppTitleBar';
import { RouteManager } from '../common/RouteManager';
import { ThemeColors, Palette, ButtonSpec, FontSize, Radius, Spacing, ComponentSize } from '../common/ThemeColors';

/**
 * 密码生成器页
 *
 * 支持两种生成模式：
 * - 随机密码：指定长度和字符集
 * - Diceware 口令词组：基于 EFF 词表生成易记口令
 */
@ComponentV2
export struct PassgenPage {
  @Local viewModel: PassgenViewModel = new PassgenViewModel();

  private get colors(): Palette {
    return ThemeColors.getInstance().palette();
  }

  @Builder
  modeTab(label: string, mode: GenMode) {
    Text(label)
      .fontSize(FontSize.SUBTITLE)
      .fontWeight(this.viewModel.mode === mode ? FontWeight.Bold : FontWeight.Normal)
      .fontColor(this.viewModel.mode === mode ? this.colors.onPrimary : this.colors.textSecondary)
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .padding(Spacing.SM)
      .backgroundColor(this.viewModel.mode === mode ? this.colors.primary : Color.Transparent)
      .borderRadius(Radius.SM)
      .stateStyles({
        normal: {
          .backgroundColor(this.viewModel.mode === mode ? this.colors.primary : Color.Transparent)
        },
        pressed: { .backgroundColor(this.colors.pressed) },
      })
      .onClick(() => {
        this.viewModel.setMode(mode);
      })
  }

  @Builder
  toggleRow(label: string, isOn: boolean, onToggle: () => void) {
    Row() {
      Text(label)
        .fontSize(FontSize.BODY)
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
        AppTitleBar({ title: '密码生成器' })

      Scroll() {
        Column() {
          // 结果显示区
          Column() {
            Text(this.viewModel.result || '点击下方按钮生成密码')
              .fontSize(FontSize.TITLE)
              .fontFamily('monospace')
              .fontColor(this.viewModel.result.length > 0 ? this.colors.textPrimary : this.colors.textTertiary)
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding(Spacing.CARD)
              .maxLines(3)
              .textOverflow({ overflow: TextOverflow.Ellipsis })

            if (this.viewModel.result.length > 0) {
              Row() {
                Text('熵值')
                  .fontSize(FontSize.CAPTION)
                  .fontColor(this.colors.textTertiary)
                Text(`${this.viewModel.entropy} bits`)
                  .fontSize(FontSize.CAPTION)
                  .fontColor(this.colors.textSecondary)
                  .margin({ left: Spacing.XS })
                Text('·')
                  .fontSize(FontSize.CAPTION)
                  .fontColor(this.colors.divider)
                  .margin({ left: Spacing.XS })
                Text(this.viewModel.getStrengthLabel())
                  .fontSize(FontSize.CAPTION)
                  .fontColor(this.viewModel.getStrengthColor())
                  .fontWeight(FontWeight.Bold)
                  .margin({ left: Spacing.XS })
              }
              .margin({ top: Spacing.XS })
            }
          }
          .width('100%')
          .padding(Spacing.CARD)
          .backgroundColor(this.colors.surface)
          .borderRadius(Radius.CARD)

          // 复制提示
          if (this.viewModel.copyToast.length > 0) {
            Text(this.viewModel.copyToast)
              .fontSize(FontSize.CAPTION)
              .fontColor(this.colors.primary)
              .margin({ top: Spacing.SM })
          }

          // 生成 + 复制按钮
          Row({ space: ButtonSpec.ROW_GAP }) {
            Button('生成')
              .type(ButtonType.Normal)
              .borderRadius(ButtonSpec.PRIMARY_RADIUS)
              .layoutWeight(1)
              .height(ButtonSpec.PRIMARY_HEIGHT)
              .fontSize(ButtonSpec.FONT_SIZE)
              .backgroundColor(this.colors.primary)
              .fontColor(this.colors.onPrimary)
              .onClick(() => {
                this.viewModel.generate();
              })

            if (this.viewModel.result.length > 0) {
              Button(this.viewModel.isCopied ? '已复制' : '复制')
                .type(ButtonType.Normal)
                .borderRadius(ButtonSpec.SECONDARY_RADIUS)
                .width(100)
                .height(ButtonSpec.SECONDARY_HEIGHT)
                .fontSize(ButtonSpec.FONT_SIZE)
                .backgroundColor(this.viewModel.isCopied ? this.colors.success : this.colors.textTertiary)
                .fontColor(this.colors.onPrimary)
                .enabled(!this.viewModel.isCopied)
                .onClick(() => {
                  this.viewModel.copyResult();
                })
            }
          }
          .width('100%')
          .margin({ top: Spacing.MD })

          // 模式切换 Tab
          Row() {
            this.modeTab('随机密码', GenMode.RANDOM)
            this.modeTab('口令词组', GenMode.DICEWARE)
          }
          .width('100%')
          .backgroundColor(this.colors.inputBackground)
          .borderRadius(Radius.SM)
          .margin({ top: Spacing.LG, bottom: Spacing.MD })

          // 随机密码参数面板
          if (this.viewModel.mode === GenMode.RANDOM) {
            Column() {
              // 长度：标题 + 拖动条 + 数字（一行）
              Row() {
                Text('长度')
                  .fontSize(FontSize.BODY)
                  .fontColor(this.colors.textSecondary)
                  .width(40)

                Slider({
                  value: this.viewModel.randomParams.length,
                  min: 6,
                  max: 30,
                  step: 1,
                })
                  .layoutWeight(1)
                  .onChange((v: number) => {
                    this.viewModel.updateRandomParam('length', Math.round(v));
                  })

                Text(`${this.viewModel.randomParams.length}`)
                  .fontSize(FontSize.SUBTITLE)
                  .fontColor(this.colors.primary)
                  .fontWeight(FontWeight.Bold)
                  .width(30)
                  .textAlign(TextAlign.Center)
              }
              .width('100%')
              .padding({ left: Spacing.CARD, right: Spacing.CARD, top: Spacing.MD })

              this.toggleRow('大写字母 A-Z', this.viewModel.randomParams.includeUppercase,
                () => { this.viewModel.updateRandomParam('includeUppercase', !this.viewModel.randomParams.includeUppercase); })
              this.toggleRow('小写字母 a-z', this.viewModel.randomParams.includeLowercase,
                () => { this.viewModel.updateRandomParam('includeLowercase', !this.viewModel.randomParams.includeLowercase); })
              this.toggleRow('数字 0-9', this.viewModel.randomParams.includeDigits,
                () => { this.viewModel.updateRandomParam('includeDigits', !this.viewModel.randomParams.includeDigits); })
              this.toggleRow('特殊符号 !@#$', this.viewModel.randomParams.includeSymbols,
                () => { this.viewModel.updateRandomParam('includeSymbols', !this.viewModel.randomParams.includeSymbols); })
              this.toggleRow('排除歧义字符 (0/O, 1/l)', this.viewModel.randomParams.excludeAmbiguous,
                () => { this.viewModel.updateRandomParam('excludeAmbiguous', !this.viewModel.randomParams.excludeAmbiguous); })
            }
            .width('100%')
            .backgroundColor(this.colors.surface)
            .borderRadius(Radius.CARD)
            .padding({ bottom: Spacing.MD })
          }

          // Diceware 参数面板
          if (this.viewModel.mode === GenMode.DICEWARE) {
            Column() {
              // 词组数量
              Row() {
                Text('词组数量')
                  .fontSize(FontSize.BODY)
                  .layoutWeight(1)
                Text(`${this.viewModel.dicewareParams.wordCount}`)
                  .fontSize(FontSize.BODY)
                  .fontColor(this.colors.primary)
                  .fontWeight(FontWeight.Bold)
                  .width(40)
                  .textAlign(TextAlign.End)
              }
              .width('100%')
              .padding({ left: Spacing.CARD, right: Spacing.CARD, top: Spacing.MD })

              Slider({
                value: this.viewModel.dicewareParams.wordCount,
                min: 3,
                max: 8,
                step: 1,
              })
                .width('100%')
                .padding({ left: Spacing.SM, right: Spacing.SM })
                .onChange((v: number) => {
                  this.viewModel.updateDicewareParam('wordCount', Math.round(v));
                })

              // 分隔符
              Row() {
                Text('分隔符')
                  .fontSize(FontSize.BODY)
                  .layoutWeight(1)
                TextInput({ text: this.viewModel.dicewareParams.separator })
                  .width(60)
                  .height(ComponentSize.CONTROL)
                  .fontSize(FontSize.SUBTITLE)
                  .borderRadius(Radius.MD)
                  .backgroundColor(this.colors.inputBackground)
                  .textAlign(TextAlign.Center)
                  .onChange((v: string) => {
                    this.viewModel.updateDicewareParam('separator', v);
                  })
              }
              .width('100%')
              .padding({ left: Spacing.CARD, right: Spacing.CARD, top: Spacing.SM, bottom: Spacing.SM })

              this.toggleRow('首字母大写', this.viewModel.dicewareParams.capitalize,
                () => { this.viewModel.updateDicewareParam('capitalize', !this.viewModel.dicewareParams.capitalize); })
              this.toggleRow('词间插入数字', this.viewModel.dicewareParams.includeDigits,
                () => { this.viewModel.updateDicewareParam('includeDigits', !this.viewModel.dicewareParams.includeDigits); })
            }
            .width('100%')
            .backgroundColor(this.colors.surface)
            .borderRadius(Radius.CARD)
            .padding({ bottom: Spacing.MD })
          }

          // 熵值说明
          if (this.viewModel.entropy > 0) {
            Text(`预计熵值: ${this.viewModel.entropy} bits — ${this.viewModel.getStrengthLabel()}`)
              .fontSize(FontSize.CAPTION)
              .fontColor(this.colors.textTertiary)
              .margin({ top: Spacing.LG, bottom: Spacing.XL })
          } else {
            Text('生成后将显示熵值估算')
              .fontSize(FontSize.CAPTION)
              .fontColor(this.colors.textTertiary)
              .margin({ top: Spacing.LG, bottom: Spacing.XL })
          }
        }
        .padding(Spacing.PAGE_H)
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
