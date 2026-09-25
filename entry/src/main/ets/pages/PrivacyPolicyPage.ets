import { ThemeColors, Palette, Spacing, FontSize, Radius } from '../common/ThemeColors';
import { AppTitleBar } from '../views/AppTitleBar';

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
    .backgroundColor(this.colors.inputBackground)
    .borderRadius(Radius.CARD)
    .margin({ bottom: Spacing.CARD_GAP })
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    NavDestination() {
      Column() {
        AppTitleBar({ title: '隐私政策' })

      Scroll() {
        Column() {
          Text('HarmonyPasswordStore 隐私政策')
            .fontSize(FontSize.TITLE)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.colors.textPrimary)
            .margin({ bottom: Spacing.MD })

          Text('更新日期：2026 年 9 月 16 日')
            .fontSize(FontSize.CAPTION)
            .fontColor(this.colors.textTertiary)
            .margin({ bottom: Spacing.LG })

          this.section('概述',
            'HarmonyPasswordStore 是一款开源的密码管理工具，兼容标准 pass 仓库格式。' +
            '本应用以"本地优先、隐私至上"为设计原则：您的密码数据始终加密存储在本地设备，' +
            '不会上传至任何第三方服务器。')

          this.section('数据存储',
            '所有密码条目以 GPG 加密文件（.gpg）形式存储在本地文件系统中，加密密钥由您掌握。' +
            'PGP/SSH 私钥通过 HarmonyOS HUKS（统一密钥管理）管理，永不以明文落盘。' +
            '解密后的明文仅存在于运行内存中，应用进入后台时自动清除敏感缓存。')

          this.section('数据同步',
            '如需多设备同步，可通过内置 Git 功能将密码仓库推送至您自有的 Git 服务器（GitHub/Gitee/自建）。' +
            '同步通道支持 HTTPS（mbedTLS 加密）与 SSH（russh 加密），' +
            '认证凭据（Token/SSH 密钥）仅存储在本地，不经过任何中间服务器。')

          this.section('生物识别解锁',
            '应用锁只支持生物识别（指纹/面容）：解锁仅在本机完成身份验证，生物特征数据由系统安全模块管理，' +
            '本应用无法访问原始生物信息，也不保存任何 PIN/口令摘要。' +
            '验证失败的次数限制由系统侧负责。')

          this.section('剪贴板',
            '复制密码到剪贴板后，应用会在可配置的时间（默认 30 秒）后自动清除剪贴板内容，防止其他应用读取。')

          this.section('日志',
            '应用日志（hilog）不记录任何密码、密钥或解密后的明文内容，仅记录操作状态与文件路径用于调试。')

          this.section('不收集的数据',
            '本应用不收集任何个人身份信息（PII）、不嵌入分析 SDK、不嵌入广告 SDK、不上传任何用户数据。')

          this.section('开源协议',
            '本应用基于 GPL-3.0 协议开源，源代码可在 GitHub 仓库审查：\n' +
            'https://github.com/gmg137/HarmonyPasswordStore')
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
