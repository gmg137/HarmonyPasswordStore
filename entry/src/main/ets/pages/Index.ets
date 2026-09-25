import { RouteManager } from '../common/RouteManager';
import { BackHandler } from '../common/BackHandler';
import { AppLockManager } from '../utils/AppLockManager';
import { display } from '@kit.ArkUI';
import { ThemeColors, Palette } from '../common/ThemeColors';
import { SettingsRepository } from '../model/SettingsRepository';
import { RouteNames } from '../common/Constants';
import { PasswordListPage } from './PasswordListPage';
import { PasswordDetailPage } from './PasswordDetailPage';
import { PasswordCreatePage } from './PasswordCreatePage';
import { PassgenPage } from './PassgenPage';
import { SettingsPage } from './SettingsPage';
import { PgpKeyManagerPage } from './PgpKeyManagerPage';
import { SshKeyManagerPage } from './SshKeyManagerPage';
import { GitConfigPage } from './GitConfigPage';
import { RepoManagePage } from './RepoManagePage';
import { OnboardingPage } from './OnboardingPage';
import { LockPage } from './LockPage';
import { AutofillFillPage } from './AutofillFillPage';
import { AutofillSettingsPage } from './AutofillSettingsPage';
import { FolderCreatePage } from './FolderCreatePage';
import { MoveEntryPage } from './MoveEntryPage';
import { PrivacyPolicyPage } from './PrivacyPolicyPage';
import { AboutPage } from './AboutPage';

/**
 * Navigation 路由容器入口页
 *
 * 使用 NavPathStack 管理页面路由栈，
 * navDestination builder 将路由名称映射到对应页面组件。
 */
@Entry
@ComponentV2
struct Index {
  @Local pathStack: NavPathStack = new NavPathStack();
  /** 状态栏高度（vp，由 EntryAbility 写入 AppStorage 的 px 值转换） */
  @Local statusBarHeight: number = 0;

  private get colors(): Palette {
    return ThemeColors.getInstance().palette();
  }

  aboutToAppear(): void {
    RouteManager.getInstance().setPathStack(this.pathStack);
    // 读取状态栏高度（px → vp），用于沉浸式布局下避让状态栏
    // px2vp 已废弃，改用 display 密度换算
    const statusBarHeightPx: number = AppStorage.get<number>('statusBarHeightPx') ?? 0;
    try {
      this.statusBarHeight = statusBarHeightPx / display.getDefaultDisplaySync().densityPixels;
    } catch (e) {
      this.statusBarHeight = 0;
    }
    // 首次使用跳转引导页（此时 pathStack 已注入 RouteManager，时序可靠）
    if (SettingsRepository.getInstance().needsOnboarding()) {
      RouteManager.getInstance().pushPath(RouteNames.ONBOARDING);
    }
  }

  /**
   * 返回键/手势转发：Navigation 根内容（密码列表页）内部目录导航
   * 不是 NavDestination，由页面注册的 BackHandler 拦截处理
   */
  onBackPress(): boolean {
    // 锁定态下任何返回都必须被吞掉：解锁页 pop 掉后就是列表页，
    // 等于不校验就能进应用（NavDestination 无 onBackPressed 可用）。
    if (AppLockManager.getInstance().isLocked()) {
      return true;
    }
    return BackHandler.handleBack();
  }

  @Builder
  pageMap(name: string): void {
    if (name === RouteNames.PASSWORD_DETAIL) {
      PasswordDetailPage()
    } else if (name === RouteNames.PASSWORD_CREATE) {
      PasswordCreatePage()
    } else if (name === RouteNames.PASSGEN) {
      PassgenPage()
    } else if (name === RouteNames.SETTINGS) {
      SettingsPage()
    } else if (name === RouteNames.PGP_KEY_MANAGER) {
      PgpKeyManagerPage()
    } else if (name === RouteNames.SSH_KEY_MANAGER) {
      SshKeyManagerPage()
    } else if (name === RouteNames.GIT_CONFIG) {
      GitConfigPage()
    } else if (name === RouteNames.REPO_MANAGE) {
      RepoManagePage()
    } else if (name === RouteNames.ONBOARDING) {
      OnboardingPage()
    } else if (name === RouteNames.LOCK) {
      LockPage()
    } else if (name === RouteNames.AUTOFILL_FILL) {
      AutofillFillPage()
    } else if (name === RouteNames.AUTOFILL_SETTINGS) {
      AutofillSettingsPage()
    } else if (name === RouteNames.FOLDER_CREATE) {
      FolderCreatePage()
    } else if (name === RouteNames.MOVE_ENTRY) {
      MoveEntryPage()
    } else if (name === RouteNames.PRIVACY_POLICY) {
      PrivacyPolicyPage()
    } else if (name === RouteNames.ABOUT) {
      AboutPage()
    }
  }

  build() {
    Navigation(this.pathStack) {
      PasswordListPage()
    }
    .navDestination(this.pageMap)
    .mode(NavigationMode.Stack)
    .hideTitleBar(true)
    .padding({ top: this.statusBarHeight })
    .backgroundColor(this.colors.background)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
  }
}
