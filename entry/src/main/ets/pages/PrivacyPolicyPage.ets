import { ThemeColors, Palette, Spacing, FontSize, Radius } from '../common/ThemeColors';
import { AppTitleBar } from '../views/AppTitleBar';
import { Strings } from '../common/Strings';

/**
 * 隐私政策页
 *
 * 声明数据收集与处理范围，AppGallery 上架必备。
 */
@ComponentV2
export struct PrivacyPolicyPage {
  private get colors(): Palette {
    return ThemeColors.getInstance().palette();
  }

  @Builder
  section(title: string, body: string) {
    Column() {
      Text(title)
        .fontSize(FontSize.SUBTITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.colors.textPrimary)
        .margin({ bottom: Spacing.SM })

      Text(body)
        .fontSize(FontSize.BODY)
        .fontColor(this.colors.textSecondary)
        .lineHeight(22)
    }
    .width('100%')
    .padding(Spacing.CARD)
    .backgroundColor(this.colors.surface)
    .borderRadius(Radius.CARD)
    .margin({ bottom: Spacing.CARD_GAP })
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    NavDestination() {
      Column() {
        AppTitleBar({ title: $r('app.string.privacy_title') })

      Scroll() {
        Column() {
          Text($r('app.string.privacy_doc_title'))
            .fontSize(FontSize.TITLE)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.colors.textPrimary)
            .margin({ bottom: Spacing.MD })

          Text($r('app.string.privacy_updated'))
            .fontSize(FontSize.CAPTION)
            .fontColor(this.colors.textTertiary)
            .margin({ bottom: Spacing.LG })

          this.section(Strings.get('privacy_s1_title'), Strings.get('privacy_s1_body'))

          this.section(Strings.get('privacy_s2_title'), Strings.get('privacy_s2_body'))

          this.section(Strings.get('privacy_s3_title'), Strings.get('privacy_s3_body'))

          this.section(Strings.get('privacy_s4_title'), Strings.get('privacy_s4_body'))

          this.section(Strings.get('privacy_s5_title'), Strings.get('privacy_s5_body'))

          this.section(Strings.get('privacy_s6_title'), Strings.get('privacy_s6_body'))

          this.section(Strings.get('privacy_s7_title'), Strings.get('privacy_s7_body'))

          this.section(Strings.get('privacy_s8_title'), Strings.get('privacy_s8_body'))
        }
        .padding(Spacing.PAGE_H)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    .backgroundColor(this.colors.background)
  }
}
