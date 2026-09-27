import { ThemeColors, Palette, Spacing, FontSize, Radius, IconSize, ComponentSize } from '../common/ThemeColors';
import { AppTitleBar } from '../views/AppTitleBar';
import { Strings } from '../common/Strings';
import { bundleManager } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** hilog 域 */
const DOMAIN: number = 0x0001;
/** hilog 标签 */
const TAG: string = 'AboutPage';

/**
 * 关于本应用页面
 *
 * 展示应用名称、版本号、开源协议、仓库链接、致谢。
 */
/** 关于页应用图标尺寸（vp）：圆角取约边长 22%，对齐系统图标观感（同 LockPage） */
const ABOUT_ICON_SIZE: number = 72;
const ABOUT_ICON_RADIUS: number = 16;

@ComponentV2
export struct AboutPage {
  private get colors(): Palette {
    return ThemeColors.getInstance().palette();
  }

  /** 应用版本号（由 aboutToAppear 从包信息读取） */
  @Local versionName: string = '';
  /** 应用构建版本 */
  @Local versionCode: string = '';
  /** 开源仓库地址 */
  private readonly repoUrl: string = 'https://github.com/gmg137/HarmonyPasswordStore';

  /**
   * 版本号从包信息读，不写死
   *
   * 原先写死 `versionName='1.0.0'` / `versionCode='1'`，而 app.json5 里 versionCode 是
   * 1000000——版本一升，「关于」页显示的就与实际安装包不一致（且两者还会互相矛盾）。
   */
  aboutToAppear(): void {
    try {
      const info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      this.versionName = info.versionName;
      this.versionCode = `${info.versionCode}`;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'read bundle version failed: %{public}s',
        e instanceof Error ? e.message : String(e));
    }
  }

  @Builder
  infoRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(FontSize.BODY)
        .fontColor(this.colors.textSecondary)
        // 固定标签列宽：无对应令牌，4字标签需要更宽列
        .width(Strings.labelWidth(80))
      Text(value)
        .fontSize(FontSize.BODY)
        .fontColor(this.colors.textPrimary)
        .layoutWeight(1)
    }
    .width('100%')
    .height(ComponentSize.ROW)
    .padding({ left: Spacing.ROW_H, right: Spacing.ROW_H })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  sectionCard(title: string, body: string) {
    Column() {
      Text(title)
        .fontSize(FontSize.SUBTITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.colors.textPrimary)
        .margin({ bottom: Spacing.SM })

      Text(body)
        .fontSize(FontSize.BODY)
        .fontColor(this.colors.textSecondary)
        .lineHeight(20)
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
        AppTitleBar({ title: $r('app.string.about_title') })

      Scroll() {
        Column() {
          // 应用图标 + 名称
          Column() {
            // 应用图标：背景层 + 前景层叠加（与桌面图标、锁屏页同一处理），
            // 系统图标资源本身是方形，必须自己加圆角遮罩再 clip
            Stack() {
              Image($r('app.media.background'))
                .width(ABOUT_ICON_SIZE)
                .height(ABOUT_ICON_SIZE)
                .objectFit(ImageFit.Cover)

              Image($r('app.media.foreground'))
                .width(ABOUT_ICON_SIZE)
                .height(ABOUT_ICON_SIZE)
                .objectFit(ImageFit.Cover)
            }
            .width(ABOUT_ICON_SIZE)
            .height(ABOUT_ICON_SIZE)
            .borderRadius(ABOUT_ICON_RADIUS)
            .clip(true)
            .margin({ bottom: Spacing.MD })

            Text('HarmonyPasswordStore')
              .fontSize(FontSize.TITLE)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.colors.textPrimary)

            Text(`v${this.versionName} (${this.versionCode})`)
              .fontSize(FontSize.CAPTION)
              .fontColor(this.colors.textTertiary)
              .margin({ top: Spacing.XS })
          }
          .width('100%')
          .padding({ top: Spacing.LG, bottom: Spacing.LG })
          .alignItems(HorizontalAlign.Center)

          // 基本信息
          Column() {
            this.infoRow(Strings.get('about_app_name'), 'HarmonyPasswordStore')
            this.infoRow(Strings.get('about_version'), `${this.versionName} (build ${this.versionCode})`)
            this.infoRow(Strings.get('about_license'), 'GPL-3.0')
            this.infoRow(Strings.get('about_target_os'), 'HarmonyOS 5.0+')
          }
          .width('100%')
          .backgroundColor(this.colors.surface)
          .borderRadius(Radius.CARD)
          .margin({ bottom: Spacing.CARD_GAP })

          // 项目简介
          this.sectionCard(Strings.get('about_intro_title'), Strings.get('about_intro_body'))

          // 开源依赖
          this.sectionCard(Strings.get('about_deps_title'), Strings.get('about_deps_body'))

          // 仓库链接
          this.sectionCard(Strings.get('about_source_title'),
            Strings.fmt('about_source_body', this.repoUrl))

          Text('© 2026 HarmonyPasswordStore Contributors')
            .fontSize(FontSize.CAPTION)
            .fontColor(this.colors.textTertiary)
            // 上间距与「源代码」卡片一致（原先由已移除的隐私政策卡片提供）
            .margin({ top: Spacing.CARD_GAP, bottom: Spacing.LG })
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
