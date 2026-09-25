import { AppLockViewModel } from '../viewmodel/AppLockViewModel';
import { ThemeColors, Palette, Spacing, FontSize, Radius } from '../common/ThemeColors';

/** 应用图标尺寸（vp）——锁屏页的主视觉，居中显示 */
const APP_ICON_SIZE: number = 96;
/** 图标圆角（对齐系统应用图标的圆角比例，约为边长的 22%） */
const APP_ICON_RADIUS: number = 22;

/**
 * 解锁页
 *
 * 应用超时锁定 / 冷启动后的解锁入口。**只有生物识别一种方式**（PIN 已彻底移除）：
 * 进入即自动拉起系统认证，不再放「使用指纹解锁」按钮——按钮与自动弹框重复，
 * 且真机上用户根本不需要点它。
 *
 * 交互：认证失败/取消后，轻触应用图标重试（配合下方提示文字说明），
 * 这样去掉按钮也不会让用户卡在无法解锁的页面上。
 */
@ComponentV2
export struct LockPage {
  @Local viewModel: AppLockViewModel = new AppLockViewModel();

  private get colors(): Palette {
    return ThemeColors.getInstance().palette();
  }

  aboutToAppear(): void {
    this.viewModel.init();
  }

  /**
   * 状态提示文案
   *
   * 优先显示错误（失败原因），其次是设备不可用的原因，最后是「正在验证」。
   */
  private statusText(): string {
    if (this.viewModel.errorMessage.length > 0) {
      return this.viewModel.errorMessage;
    }
    if (this.viewModel.biometricReason.length > 0) {
      return this.viewModel.biometricReason;
    }
    return this.viewModel.isVerifying ? '正在验证…' : '轻触图标重新验证';
  }

  /** 提示是否属于错误（决定配色） */
  private isErrorState(): boolean {
    return this.viewModel.errorMessage.length > 0 || this.viewModel.biometricReason.length > 0;
  }

  build() {
    // 返回拦截由 Index 的 onBackPress 统一处理（锁定态直接消费返回事件）：
    // NavDestination 没有 onBackPressed 可用，只能在 @Entry 层拦。
    NavDestination() {
      Column() {
        // 应用图标：居中主视觉（背景层 + 前景层叠加，与桌面图标一致）
        Stack() {
          Image($r('app.media.background'))
            .width(APP_ICON_SIZE)
            .height(APP_ICON_SIZE)
            .objectFit(ImageFit.Cover)

          Image($r('app.media.foreground'))
            .width(APP_ICON_SIZE)
            .height(APP_ICON_SIZE)
            .objectFit(ImageFit.Cover)
        }
        .width(APP_ICON_SIZE)
        .height(APP_ICON_SIZE)
        .borderRadius(APP_ICON_RADIUS)
        .clip(true)
        .stateStyles({
          normal: { .backgroundColor(Color.Transparent) },
          pressed: { .backgroundColor(this.colors.pressed) },
        })
        .onClick(() => {
          // 去掉按钮后，图标即重试入口
          this.viewModel.authenticateBiometric();
        })

        Text($r('app.string.app_locked'))
          .fontSize(FontSize.TITLE)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.colors.textPrimary)
          .margin({ top: Spacing.XL })

        Text(this.statusText())
          .fontSize(FontSize.BODY)
          .fontColor(this.isErrorState() ? this.colors.danger : this.colors.textTertiary)
          .textAlign(TextAlign.Center)
          .margin({ top: Spacing.SM })
      }
      .width('100%')
      .height('100%')
      // 内容整体居中（上下留白由 justifyContent 均分，图标即落在屏幕中部）
      .justifyContent(FlexAlign.Center)
      .padding({ left: Spacing.XL, right: Spacing.XL })
      .backgroundColor(this.colors.background)
    }
    .title('解锁')
    .hideTitleBar(true)
  }
}
