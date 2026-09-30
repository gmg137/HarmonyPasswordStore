import { SettingsViewModel } from '../viewmodel/SettingsViewModel';
import { ToggleRow } from '../views/ToggleRow';
import { DropdownRow, DropdownOption } from '../views/DropdownRow';
import { PasswordFileFormat, ThemeMode, SearchMode, RouteNames } from '../common/Constants';
import { ThemeColors, Palette, Radius, Spacing, FontSize, IconSize, ComponentSize, DividerSpec } from '../common/ThemeColors';
import { RouteManager } from '../common/RouteManager';
import { AppTitleBar } from '../views/AppTitleBar';
import { AppLanguage, AppLanguageOption } from '../common/AppLanguage';
import { SystemInsets } from '../utils/SystemInsets';

/**
 * 设置页
 *
 * 通用设置（主题/语言/应用锁定）、搜索模式、
 * PGP 密钥管理、Git 同步配置入口。
 *
 * 布局对齐 HarmonyOS 官方 UX 样例（`HarmonyOSComponentUXExamples` 的
 * `container/list/components/EfficientList.ets`）：整页是一个 `List`，
 * 每个分组是一张 `ListItemGroup` 卡片——**组**承载背景/圆角/横向内边距/
 * 行间分隔线，**行**（`ToggleRow` / `DropdownRow` / `navRow`）只负责内容：
 * 行首图标（`IconSize.MD`）+ 图标文字间距 `Spacing.LG` + 标题/说明 + 右侧后缀。
 * 组间距由 `List({ space })` 提供（12vp = `Spacing.CARD_GAP`）。
 */
@ComponentV2
export struct SettingsPage {
  @Local viewModel: SettingsViewModel = new SettingsViewModel();

  private get colors(): Palette {
    return ThemeColors.getInstance().palette();
  }

  aboutToAppear(): void {
    this.viewModel.load();
  }

  /**
   * 语言可选项（DropdownRow 用）
   *
   * 「系统默认」的标题走资源表随应用语言翻译；具体语言的标题是各自语言的专名，
   * 不翻译（同原半模态面板的口径）。
   */
  private languageOptions(): DropdownOption[] {
    return AppLanguage.OPTIONS.map((opt: AppLanguageOption): DropdownOption => {
      const label: ResourceStr = opt.value === AppLanguage.SYSTEM
        ? $r('app.string.language_system') : opt.nativeTitle;
      return { label: label, value: opt.value };
    });
  }

  /**
   * 分组标题（`List` 的一个 `ListItem`，紧跟在所属分组卡片之前）
   *
   * 「上远下近」的归属节奏由两部分拼出来：`List({ space })` 已提供 12vp 的
   * **下间距**（标题 → 卡片），上间距 = space(12) + 这里的上内边距，凑成
   * `Spacing.SECTION_TOP`(24)（首个标题上方没有 space，保持
   * `SECTION_TOP_FIRST`(12)）。左内边距取 `Spacing.MD`，与组内行首图标对齐
   * （组的横向内边距同为 12vp）。
   */
  @Builder
  sectionTitle(title: ResourceStr, isFirst: boolean) {
    Text(title)
      .fontSize(FontSize.SECTION)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.colors.textSecondary)
      .width('100%')
      .padding({
        top: isFirst ? Spacing.SECTION_TOP_FIRST : Spacing.SECTION_TOP - Spacing.CARD_GAP,
        bottom: 0,
        left: Spacing.MD,
      })
  }

  /**
   * 导航行（行首图标 + 标题 + 说明 + 右箭头）
   *
   * 横向内边距与卡片底色由 `ListItemGroup` 承担；常态显式透明
   * （stateStyles 是替换不是叠加），按压才显 `pressed` 色。
   */
  @Builder
  navRow(icon: Resource, label: ResourceStr, sublabel: ResourceStr, onTapped: () => void) {
    Row() {
      SymbolGlyph(icon)
        .fontSize(IconSize.MD)
        .fontColor([this.colors.textSecondary])
        .margin({ right: Spacing.LG })

      Column() {
        Text(label)
          .fontSize(FontSize.SUBTITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.colors.textPrimary)
        Text(sublabel)
          .fontSize(FontSize.CAPTION)
          .fontColor(this.colors.textTertiary)
          .margin({ top: Spacing.XS })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(IconSize.CHEVRON)
        .fontColor([this.colors.textTertiary])
        .margin({ left: Spacing.SM })
    }
    .width('100%')
    .constraintSize({ minHeight: ComponentSize.ROW_TWO_LINE })
    .padding({ top: Spacing.MD, bottom: Spacing.MD })
    .stateStyles({
      normal: { .backgroundColor(Color.Transparent) },
      pressed: { .backgroundColor(this.colors.pressed) },
    })
    .onClick(() => onTapped())
  }

  /**
   * 剪贴板自动清除的可选项
   *
   * 固定四档（15s / 30s / 1min / 2min）。**存量值不在四档内时必须把它补进列表**：
   * 旧版是 10–120s 的滑杆，用户可能停在 45s 这类中间值上，而 `DropdownRow` 找不到
   * 匹配项时当前值区会渲染成空白（看起来像控件坏了）。补一项既显示了真实值，
   * 也让用户能改到四档之一。
   */
  private clipboardTimeoutOptions(): DropdownOption[] {
    const opts: DropdownOption[] = [
      { label: '15s', value: '15' },
      { label: '30s', value: '30' },
      { label: '1min', value: '60' },
      { label: '2min', value: '120' },
    ];
    const current: string = `${this.viewModel.clipboardTimeout}`;
    let matched: boolean = false;
    for (let i: number = 0; i < opts.length; i++) {
      if (opts[i].value === current) {
        matched = true;
        break;
      }
    }
    if (!matched) {
      opts.push({ label: `${current}s`, value: current });
    }
    return opts;
  }

  build() {
    NavDestination() {
      Column() {
        // ===== 标题栏（共享组件：40vp 圆形返回按钮 + 24fp 标题） =====
        AppTitleBar({ title: $r('app.string.settings_title') })

        List({ space: Spacing.CARD_GAP }) {
          // ===== 通用 =====
          ListItem() {
            this.sectionTitle($r('app.string.group_general'), true)
          }

          ListItemGroup() {
            ListItem() {
              DropdownRow({
                icon: $r('sys.symbol.paintpalette'),
                label: $r('app.string.settings_theme'),
                currentValue: `${this.viewModel.themeMode}`,
                options: [
                  { label: $r('app.string.theme_system'), value: `${ThemeMode.SYSTEM}` },
                  { label: $r('app.string.theme_light'), value: `${ThemeMode.LIGHT}` },
                  { label: $r('app.string.theme_dark'), value: `${ThemeMode.DARK}` },
                ],
                onSelect: (v: string): void => {
                  this.viewModel.setThemeMode(Number.parseInt(v) as ThemeMode);
                },
              })
            }

            // 语言选择：与主题行同款的系统下拉菜单（不再用底部半模态面板）。
            // 候选标题里「系统默认」走资源表随应用语言翻译，具体语言是各自语言的专名不翻译；
            // DropdownOption.label 是 ResourceStr，正好混合两类来源。
            ListItem() {
              DropdownRow({
                icon: $r('sys.symbol.translate'),
                label: $r('app.string.settings_language'),
                currentValue: this.viewModel.appLanguage,
                options: this.languageOptions(),
                onSelect: (v: string): void => {
                  this.viewModel.setAppLanguage(v, this.getUIContext());
                },
              })
            }
          }
          .borderRadius(Radius.CARD)
          .backgroundColor(this.colors.surface)
          .padding({ left: Spacing.MD, right: Spacing.MD })
          .clip(true)
          .divider({
            strokeWidth: DividerSpec.STROKE,
            startMargin: DividerSpec.INSET_ICON,
            endMargin: Spacing.MD,
            color: this.colors.divider,
          })

          // ===== 安全 =====
          ListItem() {
            this.sectionTitle($r('app.string.group_security'), false)
          }

          ListItemGroup() {
            ListItem() {
              ToggleRow({
                icon: $r('sys.symbol.touchid'),
                label: $r('app.string.biometric_title'),
                // 不可用时把原因放在副标题里（与「启动时自动同步」一致）
                sublabel: this.viewModel.biometricReason.length > 0
                  ? this.viewModel.biometricReason
                  : $r('app.string.biometric_sub'),
                isOn: this.viewModel.biometricUnlockEnabled,
                // PIN 已彻底移除，应用锁只剩生物识别：设备不支持/未录入时开关置灰，
                // 否则用户打开它却永远不会被锁（或反之被锁住却无法解锁）
                isEnabled: this.viewModel.biometricReason.length === 0,
                onToggle: (v: boolean): void => { this.viewModel.setBiometricEnabled(v); },
              })
            }

            // 剪贴板里留存的是密码明文，清除时机属安全语义，归「安全」分组
            ListItem() {
              DropdownRow({
                icon: $r('sys.symbol.text_clipboard'),
                label: $r('app.string.clipboard_title'),
                sublabel: $r('app.string.clipboard_sub'),
                currentValue: `${this.viewModel.clipboardTimeout}`,
                options: this.clipboardTimeoutOptions(),
                onSelect: (v: string): void => {
                  this.viewModel.setClipboardTimeout(Number.parseInt(v));
                },
              })
            }
          }
          .borderRadius(Radius.CARD)
          .backgroundColor(this.colors.surface)
          .padding({ left: Spacing.MD, right: Spacing.MD })
          .clip(true)
          .divider({
            strokeWidth: DividerSpec.STROKE,
            startMargin: DividerSpec.INSET_ICON,
            endMargin: Spacing.MD,
            color: this.colors.divider,
          })

          // ===== 密码仓库 =====
          ListItem() {
            this.sectionTitle($r('app.string.group_store'), false)
          }

          ListItemGroup() {
            ListItem() {
              DropdownRow({
                icon: $r('sys.symbol.magnifyingglass'),
                label: $r('app.string.search_mode_title'),
                currentValue: `${this.viewModel.searchMode}`,
                options: [
                  { label: $r('app.string.search_fuzzy'), value: `${SearchMode.FUZZY}` },
                  { label: $r('app.string.search_exact'), value: `${SearchMode.EXACT}` },
                  { label: $r('app.string.search_content'), value: `${SearchMode.CONTENT}` },
                ],
                onSelect: (v: string): void => {
                  this.viewModel.setSearchMode(Number.parseInt(v) as SearchMode);
                },
              })
            }

            ListItem() {
              this.navRow($r('sys.symbol.repeat'), $r('app.string.onboarding_row_title'),
                $r('app.string.onboarding_row_sub'),
                () => {
                  this.viewModel.navigateToOnboarding();
                })
            }
          }
          .borderRadius(Radius.CARD)
          .backgroundColor(this.colors.surface)
          .padding({ left: Spacing.MD, right: Spacing.MD })
          .clip(true)
          .divider({
            strokeWidth: DividerSpec.STROKE,
            startMargin: DividerSpec.INSET_ICON,
            endMargin: Spacing.MD,
            color: this.colors.divider,
          })

          // ===== Git 同步 =====
          ListItem() {
            this.sectionTitle($r('app.string.group_git'), false)
          }

          ListItemGroup() {
            ListItem() {
              ToggleRow({
                icon: $r('sys.symbol.arrow_2_circlepath'),
                label: $r('app.string.autosync_title'),
                sublabel: this.viewModel.autoSyncAvailable
                  ? $r('app.string.autosync_sub')
                  : this.viewModel.autoSyncDisabledReason,
                isOn: this.viewModel.autoSyncOnLaunch,
                isEnabled: this.viewModel.autoSyncAvailable,
                onToggle: (v: boolean): void => { this.viewModel.setAutoSync(v); },
              })
            }

            ListItem() {
              this.navRow($r('sys.symbol.externaldrive'), $r('app.string.repo_row_title'),
                $r('app.string.repo_row_sub'),
                () => {
                  this.viewModel.navigateToRepoManage();
                })
            }
          }
          .borderRadius(Radius.CARD)
          .backgroundColor(this.colors.surface)
          .padding({ left: Spacing.MD, right: Spacing.MD })
          .clip(true)
          .divider({
            strokeWidth: DividerSpec.STROKE,
            startMargin: DividerSpec.INSET_ICON,
            endMargin: Spacing.MD,
            color: this.colors.divider,
          })

          // ===== 加密与凭据 =====
          ListItem() {
            this.sectionTitle($r('app.string.group_crypto'), false)
          }

          ListItemGroup() {
            ListItem() {
              this.navRow($r('sys.symbol.key'), $r('app.string.pgp_row_title'),
                $r('app.string.pgp_row_sub'),
                () => {
                  this.viewModel.navigateToPgpKeys();
                })
            }

            ListItem() {
              this.navRow($r('sys.symbol.key_horizontal'), $r('app.string.ssh_row_title'),
                $r('app.string.ssh_row_sub'),
                () => {
                  this.viewModel.navigateToSshKeys();
                })
            }

            ListItem() {
              DropdownRow({
                icon: $r('sys.symbol.doc_plaintext'),
                label: $r('app.string.fileformat_title'),
                sublabel: $r('app.string.fileformat_sub'),
                currentValue: `${this.viewModel.passwordFileFormat}`,
                options: [
                  { label: 'bin', value: `${PasswordFileFormat.BIN}` },
                  { label: 'armor', value: `${PasswordFileFormat.ARMOR}` },
                ],
                onSelect: (v: string): void => {
                  this.viewModel.setPasswordFileFormat(Number.parseInt(v) as PasswordFileFormat);
                },
              })
            }
          }
          .borderRadius(Radius.CARD)
          .backgroundColor(this.colors.surface)
          .padding({ left: Spacing.MD, right: Spacing.MD })
          .clip(true)
          .divider({
            strokeWidth: DividerSpec.STROKE,
            startMargin: DividerSpec.INSET_ICON,
            endMargin: Spacing.MD,
            color: this.colors.divider,
          })

          // ===== 关于 =====
          ListItem() {
            this.sectionTitle($r('app.string.group_about'), false)
          }

          ListItemGroup() {
            ListItem() {
              this.navRow($r('sys.symbol.lock_shield'), $r('app.string.privacy_row_title'),
                $r('app.string.privacy_row_sub'),
                () => {
                  RouteManager.getInstance().pushPath(RouteNames.PRIVACY_POLICY);
                })
            }

            ListItem() {
              this.navRow($r('sys.symbol.info_circle'), $r('app.string.about_row_title'),
                $r('app.string.about_row_sub'),
                () => {
                  RouteManager.getInstance().pushPath(RouteNames.ABOUT);
                })
            }
          }
          .borderRadius(Radius.CARD)
          .backgroundColor(this.colors.surface)
          .padding({ left: Spacing.MD, right: Spacing.MD })
          .clip(true)
          .divider({
            strokeWidth: DividerSpec.STROKE,
            startMargin: DividerSpec.INSET_ICON,
            endMargin: Spacing.MD,
            color: this.colors.divider,
          })

          // 底部留白：改版前的滚动到底余量 + 系统导航条高度。沉浸式布局下内容延伸
          // 到导航条之下，不留出这一截时「滚到底」的最后一行会被导航条压住
          // （原本只有一个固定 48vp 的余量，导航条一高就不够，见 SystemInsets）
          ListItem() {
            Column()
              .width('100%')
              .height(Spacing.XL * 2 + SystemInsets.bottomVp())
          }
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        // 顶部不留白：首个分组标题自身已有 SECTION_TOP_FIRST(12vp) 上边距
        .padding({ left: Spacing.PAGE_H, right: Spacing.PAGE_H, bottom: Spacing.PAGE_H })
        .backgroundColor(this.colors.background)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.colors.background)
    }
    .hideTitleBar(true)
    // 从「Git 配置 / 仓库管理」返回时重新判断自动同步是否可用：
    // 用户可能刚填好远程地址或刚克隆完，开关该随之解除禁用
    .onShown(() => {
      this.viewModel.refreshAutoSyncAvailability();
    })
  }
}
