import { BiometricHelper } from '../utils/BiometricHelper';
import { AppTitleBar } from '../views/AppTitleBar';
import { SettingsRepository } from '../model/SettingsRepository';
import { PasswordRepository } from '../model/PasswordRepository';
import { ThemeColors, Palette, FontSize, Spacing, Radius, ComponentSize } from '../common/ThemeColors';

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
        AppTitleBar({ title: '自动填充' })

      Scroll() {
        Column() {
          // 服务状态
          Column() {
            Row() {
              Text('填充服务状态')
                .fontSize(FontSize.SUBTITLE)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.colors.textPrimary)
                .layoutWeight(1)
              Text(this.storeInitialized ? '仓库就绪' : '仓库未初始化')
                .fontSize(FontSize.CAPTION)
                .fontColor(this.storeInitialized ? this.colors.success : this.colors.warning)
            }
            .width('100%')

            Row() {
              Text('可用密码条目')
                .fontSize(FontSize.CAPTION)
                .fontColor(this.colors.textTertiary)
                .layoutWeight(1)
              Text(`${this.passwordCount} 条`)
                .fontSize(FontSize.CAPTION)
                .fontColor(this.colors.textPrimary)
            }
            .width('100%')
            .margin({ top: Spacing.SM })

            Row() {
              Text('生物识别能力')
                .fontSize(FontSize.CAPTION)
                .fontColor(this.colors.textTertiary)
                .layoutWeight(1)
              Text(this.biometricSupport.length > 0 ? `支持${this.biometricSupport}` : '不支持')
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
          this.infoCard('如何启用自动填充', [
            '1. 打开系统设置 → 更多设置 → 密码与填充（或"自动填充服务"）',
            '2. 选择"密码仓库（HarmonyPasswordStore）"作为填充服务',
            '3. 在应用或浏览器中点击输入框时，系统将弹出填充建议',
          ])

          // 匹配规则
          this.infoCard('匹配规则', [
            '· 按请求方应用包名或网页域名与密码条目名称/路径匹配',
            '· 完全匹配的条目优先展示，同分按最近使用排序',
            '· 匹配过程不解密文件，仅在您选择后才会解密',
          ])

          // 安全说明
          this.infoCard('安全说明', [
            '· 填充候选默认只显示名称与用户名，不显示密码',
            '· 解密后的密码仅短暂存在于内存中',
            '· 填充成功会记录使用时间，用于优化候选排序',
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
