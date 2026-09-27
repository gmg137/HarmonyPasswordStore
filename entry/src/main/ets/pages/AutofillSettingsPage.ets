import { BiometricHelper } from '../utils/BiometricHelper';
import { AppTitleBar } from '../views/AppTitleBar';
import { SettingsRepository } from '../model/SettingsRepository';
import { PasswordRepository } from '../model/PasswordRepository';
import { ThemeColors, Palette, FontSize, Spacing, Radius, ComponentSize } from '../common/ThemeColors';
import { Strings } from '../common/Strings';

/**
 * 自动填充设置页
 *
 * 说明系统自动填充的启用方式、服务状态与匹配规则，
 * 提供填充服务相关的说明性信息。
 */
@ComponentV2
export struct AutofillSettingsPage {
  @Local storeInitialized: boolean = false;
  @Local passwordCount: number = 0;
  @Local biometricSupport: string = '';

  private get colors(): Palette {
    return ThemeColors.getInstance().palette();
  }

  aboutToAppear(): void {
    const settings: SettingsRepository = SettingsRepository.getInstance();
    this.storeInitialized = settings.getSettings().storeInitialized;

    const repo: PasswordRepository = PasswordRepository.getInstance();
    const result = repo.searchEntries('');
    if (result.success && result.data) {
      this.passwordCount = result.data.filter((e) => !e.isDirectory).length;
    }

    this.biometricSupport = BiometricHelper.getInstance().checkBiometricSupport();
  }

  @Builder
  infoCard(title: string, lines: string[]) {
    Column() {
      Text(title)
        .fontSize(FontSize.SUBTITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.colors.textPrimary)
      ForEach(lines, (line: string) => {
        Text(line)
          .fontSize(FontSize.BODY)
          .fontColor(this.colors.textSecondary)
          .lineHeight(20)
          .margin({ top: Spacing.XS })
      }, (line: string) => line)
    }
    .width('100%')
    .padding(Spacing.CARD)
    .backgroundColor(this.colors.surface)
    .borderRadius(Radius.CARD)
    .margin({ top: Spacing.CARD_GAP })
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    NavDestination() {
      Column() {
        AppTitleBar({ title: $r('app.string.autofill_settings_title') })

      Scroll() {
        Column() {
          // 服务状态
          Column() {
            Row() {
              Text($r('app.string.autofill_svc_status'))
                .fontSize(FontSize.SUBTITLE)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.colors.textPrimary)
                .layoutWeight(1)
              Text(this.storeInitialized ? Strings.get('autofill_repo_ready') : Strings.get('autofill_repo_not_init'))
                .fontSize(FontSize.CAPTION)
                .fontColor(this.storeInitialized ? this.colors.success : this.colors.warning)
            }
            .width('100%')

            Row() {
              Text($r('app.string.autofill_entry_count_label'))
                .fontSize(FontSize.CAPTION)
                .fontColor(this.colors.textTertiary)
                .layoutWeight(1)
              Text(Strings.fmt('autofill_entry_count', this.passwordCount))
                .fontSize(FontSize.CAPTION)
                .fontColor(this.colors.textPrimary)
            }
            .width('100%')
            .margin({ top: Spacing.SM })

            Row() {
              Text($r('app.string.autofill_biometric_cap'))
                .fontSize(FontSize.CAPTION)
                .fontColor(this.colors.textTertiary)
                .layoutWeight(1)
              Text(this.biometricSupport.length > 0 ? Strings.fmt('autofill_biometric_support', this.biometricSupport) : Strings.get('autofill_biometric_unsupported'))
                .fontSize(FontSize.CAPTION)
                .fontColor(this.biometricSupport.length > 0 ? this.colors.success : this.colors.textTertiary)
            }
            .width('100%')
            .margin({ top: Spacing.SM })
          }
          .width('100%')
          .padding(Spacing.CARD)
          .backgroundColor(this.colors.surface)
          .borderRadius(Radius.CARD)

          // 启用说明
          this.infoCard(Strings.get('autofill_howto_title'), [
            Strings.get('autofill_howto_step1'),
            Strings.get('autofill_howto_step2'),
            Strings.get('autofill_howto_step3'),
          ])

          // 匹配规则
          this.infoCard(Strings.get('autofill_rule_title'), [
            Strings.get('autofill_rule_match'),
            Strings.get('autofill_rule_priority'),
            Strings.get('autofill_rule_nodecrypt'),
          ])

          // 安全说明
          this.infoCard(Strings.get('autofill_sec_title'), [
            Strings.get('autofill_sec_fields'),
            Strings.get('autofill_sec_memory'),
            Strings.get('autofill_sec_usage'),
          ])

          Blank()
            .height(ComponentSize.CONTROL_SMALL)
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
