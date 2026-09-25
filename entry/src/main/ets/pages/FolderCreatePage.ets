import { FolderCreateViewModel } from '../viewmodel/FolderCreateViewModel';
import { AppTitleBar } from '../views/AppTitleBar';
import { RouteManager } from '../common/RouteManager';
import { ThemeColors, Palette, Radius, Spacing, FontSize, ButtonSpec, ComponentSize, IconSize } from '../common/ThemeColors';
import { GpgKeyId } from '../model/GpgKeyId';

/**
 * 创建文件夹页
 *
 * 输入文件夹名称并选择 PGP 密钥（可选），
 * 为子目录设置 .gpg-id 覆盖父目录密钥。
 */
@ComponentV2
export struct FolderCreatePage {
  @Local viewModel: FolderCreateViewModel = new FolderCreateViewModel();

  private get colors(): Palette {
    return ThemeColors.getInstance().palette();
  }

  aboutToAppear(): void {
    const param: Object | undefined = RouteManager.getInstance().takeLastParam();
    if (param) {
      const p = param as Record<string, string>;
      this.viewModel.parentDir = p['parentDir'] ?? '';
    }
    this.viewModel.loadKeys();
  }

  @Builder
  keyItem(fingerprint: string, userId: string) {
    Row() {
      Column() {
        Text(userId)
          .fontSize(FontSize.SUBTITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.colors.textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(this.viewModel.formatFingerprint(fingerprint))
          .fontSize(FontSize.CAPTION)
          .fontColor(this.colors.textTertiary)
          .margin({ top: Spacing.XS })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 选中标记
      if (this.viewModel.isKeySelected(fingerprint)) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(FontSize.SUBTITLE)
          .fontColor([this.colors.primary])
      }
    }
    .width('100%')
    .padding({ left: Spacing.ROW_H, right: Spacing.ROW_H, top: Spacing.SM, bottom: Spacing.SM })
    .borderRadius(Radius.CARD)
    .backgroundColor(this.viewModel.isKeySelected(fingerprint)
      ? this.colors.primarySoft : this.colors.inputBackground)
    .margin({ bottom: Spacing.CARD_GAP })
    .stateStyles({
      normal: {
        .backgroundColor(this.viewModel.isKeySelected(fingerprint)
          ? this.colors.primarySoft : this.colors.inputBackground)
      },
      pressed: { .backgroundColor(this.colors.pressed) },
    })
    .onClick(() => {
      this.viewModel.toggleKey(fingerprint);
    })
  }

  build() {
    NavDestination() {
      Column() {
        AppTitleBar({ title: '新建文件夹' })

        Scroll() {
          Column() {
            // 文件夹名称输入
            Text('文件夹名称')
              .fontSize(FontSize.CAPTION)
              .fontColor(this.colors.textSecondary)
              .margin({ bottom: Spacing.SM })

            TextInput({ text: this.viewModel.folderName, placeholder: '输入文件夹名称' })
              .fontSize(FontSize.SUBTITLE)
              .fontColor(this.colors.textPrimary)
              .placeholderFont({ size: FontSize.SUBTITLE })
              .placeholderColor(this.colors.textTertiary)
              .height(ComponentSize.CONTROL)
              .borderRadius(Radius.MD)
              .backgroundColor(this.colors.inputBackground)
              .padding({ left: Spacing.MD, right: Spacing.MD })
              .margin({ bottom: Spacing.LG })
              .onChange((v: string) => {
                this.viewModel.folderName = v;
              })

            // 密钥选择（可选）
            Text('加密密钥（可选，覆盖父目录密钥）')
              .fontSize(FontSize.CAPTION)
              .fontColor(this.colors.textSecondary)
              .margin({ bottom: Spacing.SM })

            if (this.viewModel.keys.length === 0) {
              Text('暂无已导入的 PGP 密钥，将使用父目录密钥')
                .fontSize(FontSize.CAPTION)
                .fontColor(this.colors.textTertiary)
                .padding({ top: Spacing.MD, bottom: Spacing.MD })
            } else {
              ForEach(this.viewModel.keys, (key: GpgKeyId) => {
                this.keyItem(key.fingerprint, key.userId)
              }, (key: GpgKeyId) => key.fingerprint)
            }

            // 创建按钮
            Button('创建文件夹')
              .width('100%')
              .height(ButtonSpec.PRIMARY_HEIGHT)
              .type(ButtonType.Normal)
              .borderRadius(ButtonSpec.PRIMARY_RADIUS)
              .backgroundColor(this.colors.primary)
              .fontColor(this.colors.onPrimary)
              .fontSize(ButtonSpec.FONT_SIZE)
              .fontWeight(ButtonSpec.FONT_WEIGHT)
              .margin({ top: Spacing.LG, bottom: Spacing.LG })
              .enabled(this.viewModel.folderName.trim().length > 0 && !this.viewModel.isSaving)
              .onClick(() => {
                this.viewModel.createFolder().then(() => {
                  if (this.viewModel.toast.length > 0) {
                    RouteManager.getInstance().pop();
                  }
                });
              })

            if (this.viewModel.isSaving) {
              LoadingProgress()
                .width(IconSize.LG)
                .height(IconSize.LG)
                .margin({ bottom: Spacing.MD })
            }

            // 错误信息
            if (this.viewModel.errorMessage.length > 0) {
              Text(this.viewModel.errorMessage)
                .fontSize(FontSize.CAPTION)
                .fontColor(this.colors.danger)
                .margin({ bottom: Spacing.SM })
            }

            // 成功提示
            if (this.viewModel.toast.length > 0) {
              Text(this.viewModel.toast)
                .fontSize(FontSize.CAPTION)
                .fontColor(this.colors.success)
                .margin({ bottom: Spacing.SM })
            }
          }
          .padding(Spacing.PAGE_H)
          .backgroundColor(this.colors.background)
        }
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
        .backgroundColor(this.colors.background)
      }
    }
    .hideTitleBar(true)
    .backgroundColor(this.colors.background)
  }
}
