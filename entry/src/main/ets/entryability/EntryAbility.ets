/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { FileUtils } from '../utils/FileUtils';
import { KnownHostsStore } from '../utils/KnownHostsStore';
import { SettingsRepository } from '../model/SettingsRepository';
import { ThemeMode } from '../common/Constants';
import { PasswordRepository } from '../model/PasswordRepository';
import { PgpKeyManager } from '../crypto/PgpKeyManager';
import { RouteManager } from '../common/RouteManager';
import { RouteNames } from '../common/Constants';
import { AppLockManager } from '../utils/AppLockManager';
import { ThemeColors, Palette, SYSTEM_DARK_KEY } from '../common/ThemeColors';
import { Strings } from '../common/Strings';
import { SystemBars } from '../common/SystemBars';
import { GitClient } from '../utils/GitClient';
import { PgpCrypto, CryptoResult } from '../crypto/PgpCrypto';

const DOMAIN: number = 0x0001;
const TAG: string = 'EntryAbility';

export default class EntryAbility extends UIAbility {
  private windowStage: window.WindowStage | null = null;
  /**
   * 当前已应用的**系统**颜色模式（NOT_SET = 跟随系统）
   *
   * 两个作用：① 值未变时不再重复 setColorMode；② onConfigurationUpdate 里区分
   * 「这个回调是系统色深变化触发的」还是「我们自己 setColorMode 触发的」——
   * 后者写进 AppStorage 会把「跟随系统」的判定污染成刚设置的值。
   */
  private appColorMode: ConfigurationConstant.ColorMode = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
  /**
   * 上一次见到的应用语言（Configuration.language）
   *
   * onConfigurationUpdate 里与 newConfig.language 比对，检测系统语言变化：
   * 跟随系统（未钉扎）时系统改语言会触发本回调，`$r` 资源由框架自动重解析，
   * 但 `Strings.get` 取出的普通字符串要靠 `notifyLocaleChanged` 驱动整体重建才会刷新，
   * 不补这一下会出现同一页面新旧语言混排（钉扎过语言的系统不再回调，见 Strings 注释）。
   */
  private lastLanguage: string = '';

  async onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): Promise<void> {
    // 初始化文件工具上下文
    FileUtils.init(this.context);
    // 初始化 SSH known_hosts 存储上下文（替代已废弃的 getContext）
    KnownHostsStore.getInstance().init(this.context);

    // 初始化设置仓库（Preferences 持久化）
    const settings: SettingsRepository = SettingsRepository.getInstance();
    await settings.init(this.context);

    // 初始化字符串资源助手（非 UI 代码取串走它）并应用已保存的语言偏好：
    // 必须先于 loadContent，首帧渲染即用目标语言；设置未就绪前不能读偏好，
    // 而 onCreate 里已 await settings.init，此处读到的就是持久化值
    Strings.init(this.context.getApplicationContext());
    Strings.applyStoredLanguage(this.context);
    // 记录初始应用语言，供 onConfigurationUpdate 检测后续语言变化（见字段注释）
    this.lastLanguage = this.context.config.language ?? '';

    // 同步主题模式到全局调色板（读取系统 colorMode，SYSTEM 模式跟随系统）
    const isSystemDark: boolean = this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    // 先写 AppStorage，让「跟随系统」在后续任何 syncMode 调用中都能读到真实系统色深
    AppStorage.setOrCreate(SYSTEM_DARK_KEY, isSystemDark);
    ThemeColors.getInstance().syncMode(isSystemDark);
    // 把用户选定的主题同步给**系统**颜色模式：系统绘制的部件（NavDestination 系统标题栏、
    // 系统弹窗、输入法）按系统色深渲染，与应用内调色板是两套东西。
    // 曾固定 setColorMode(COLOR_MODE_NOT_SET)，于是应用内选「深色」时系统标题栏仍是浅色
    // 主题的黑字，压在纯黑页面上等于标题不可见。
    this.applyAppColorMode();

    // 初始化密码仓库目录
    const repo: PasswordRepository = PasswordRepository.getInstance();
    if (!settings.getSettings().storeInitialized) {
      const initResult = repo.initStore();
      if (initResult.success && initResult.data) {
        await settings.updateSetting('storePath', initResult.data);
        await settings.updateSetting('storeInitialized', true);
        hilog.info(DOMAIN, TAG, 'Password store initialized at %{public}s', initResult.data);
      } else {
        hilog.error(DOMAIN, TAG, 'Failed to init store: %{public}s', initResult.error);
      }
    }

    // 初始化 PGP 密钥管理器
    const keyManager: PgpKeyManager = PgpKeyManager.getInstance();
    keyManager.init();

    // 注入加解密回调：PgpCrypto（native rpgp 桥接）→ PasswordRepository
    // 未注入时 PasswordRepository.isCryptoAvailable() 为 false，新建/读取密码会报
    // 'PGP crypto not available'
    const pgpCrypto: PgpCrypto = PgpCrypto.getInstance();
    PasswordRepository.getInstance().setCryptoCallbacks(
      (plaintext: string, keyFingerprints: string[]): Promise<string> => {
        return pgpCrypto.encrypt(plaintext, keyFingerprints).then((r: CryptoResult): string => {
          if (!r.success) {
            throw new Error(r.error);
          }
          return r.data;
        });
      },
      (ciphertext: string, candidateFingerprints: string[]): Promise<string> => {
        return pgpCrypto.decrypt(ciphertext, candidateFingerprints).then((r: CryptoResult): string => {
          if (!r.success) {
            throw new Error(r.error);
          }
          return r.data;
        });
      },
    );

    hilog.info(DOMAIN, TAG, 'Ability onCreate completed');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, 'Ability onWindowStageCreate');
    this.windowStage = windowStage;

    // 沉浸式布局：内容延伸到状态栏/导航栏后，由 setWindowSystemBarProperties 控制颜色
    try {
      const mainWindow: window.Window = windowStage.getMainWindowSync();
      mainWindow.setWindowLayoutFullScreen(true);
      // 状态栏/导航栏颜色取自主题调色板，与页面背景保持一致（深浅色均适配）
      const palette: Palette = ThemeColors.getInstance().palette();
      // 系统栏统一走 SystemBars：条带保持透明，页面底色与弹窗遮罩自然铺到条带之下
      // （不透明条带会被系统画在遮罩之上，弹窗时出现「状态栏先跳色、页面后变暗」）
      SystemBars.getInstance().attach(mainWindow);
      SystemBars.getInstance().applyBase(palette);
      // 注册主题变更回调：应用内切换主题时同步更新状态栏/导航栏颜色
      ThemeColors.getInstance().addChangeListener(() => {
        this.updateSystemBarColors();
      });
      // 沉浸式布局下记录状态栏高度（px），供页面设置顶部 padding 避让
      const systemAvoidArea: window.AvoidArea = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      AppStorage.setOrCreate('statusBarHeightPx', systemAvoidArea.topRect.height);
      // 底部系统栏高度取「系统栏」与「导航条指示器」的较大值：手势导航下
      // TYPE_SYSTEM 的 bottomRect 可能为 0，实际避让区在 NAVIGATION_INDICATOR 里；
      // 三键导航则相反。页面内底部固定的操作栏据此避让（详情页底部按钮「离底太近」即此因）
      const indicatorAvoidArea: window.AvoidArea =
        mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      const bottomInsetPx: number = Math.max(systemAvoidArea.bottomRect.height,
        indicatorAvoidArea.bottomRect.height);
      AppStorage.setOrCreate('bottomInsetPx', bottomInsetPx);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'setWindowSystemBarProperties failed: %{public}s', JSON.stringify(err));
    }

    const settings: SettingsRepository = SettingsRepository.getInstance();

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'Succeeded in loading the content.');

      // 必须等设置加载完成再读配置：框架不会等待 async onCreate，本回调比
      // init() 里的 await 早约 100ms，那时 getSettings() 还是默认值
      // （实测「启动时自动同步」永远读到 false，开关形同虚设）。
      SettingsRepository.getInstance().whenReady().then(() => {
        // setLanguage 的文档口径要求窗口与页面加载完成后再调用；onCreate 里那次
        // 保证首帧即目标语言，这里幂等补一次（同值重复设置无副作用）
        Strings.applyStoredLanguage(this.context);
        // needsOnboarding 同样要在设置就绪后再判断（否则读到的仓库路径是默认值）
        const needsOnboarding: boolean = settings.needsOnboarding();
        // 引导页跳转由 Index.aboutToAppear 处理（pathStack 在该时机才就绪）
        if (needsOnboarding) {
          hilog.info(DOMAIN, TAG, 'needsOnboarding=true, onboarding handled by Index');
          return;
        }
        hilog.info(DOMAIN, TAG, 'needsOnboarding=false, skip onboarding');

        // 冷启动锁定：已开启生物识别且设备可用时，启动即要求解锁
        // （PIN 已彻底移除，应用锁只有生物识别一种方式，判断是同步的）
        if (AppLockManager.getInstance().hasUnlockMethod()) {
          AppLockManager.getInstance().lock();
          RouteManager.getInstance().pushPath(RouteNames.LOCK);
        }

        // 启动自动同步（后台执行，失败静默记录日志，不阻塞 UI）
        if (settings.getSettings().autoSyncOnLaunch) {
          hilog.info(DOMAIN, TAG, 'launch auto sync: pull + commit + push');
          GitClient.getInstance().syncAll().then((ok: boolean) => {
            hilog.info(DOMAIN, TAG, 'launch auto sync done: ok=%{public}d', ok ? 1 : 0);
          });
        }
      });
    });
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    // 系统深浅色切换时同步全局调色板（仅 SYSTEM 模式生效）
    const isSystemDark: boolean = newConfig.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    // 只有「跟随系统」时，newConfig.colorMode 才代表真实系统色深。应用内显式选了
    // 浅/深色时本回调由我们自己的 setColorMode 触发，此时写 AppStorage 会让之后
    // 切回「跟随系统」读到的是我们自己刚设置的值。
    if (this.appColorMode === ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET) {
      AppStorage.setOrCreate(SYSTEM_DARK_KEY, isSystemDark);
    }
    ThemeColors.getInstance().syncMode(isSystemDark);
    hilog.info(DOMAIN, TAG, 'onConfigurationUpdate: colorMode=%{public}d', newConfig.colorMode);

    // 语言变化（仅跟随系统模式会收到：钉扎过语言的系统不再回调本应用）。
    // 必须在检测到变化时通知 UI 整体重建，否则 Strings.get 文本停留在旧语言（见字段注释）。
    // 我们自己 setLanguage 触发的回调也走这里：更新记录值，重复 notify 无副作用。
    const language: string = newConfig.language ?? '';
    if (language.length > 0 && language !== this.lastLanguage) {
      this.lastLanguage = language;
      Strings.notifyLocaleChanged();
    }

    // 同步状态栏/导航栏颜色到新主题
    this.updateSystemBarColors();
  }

  /** 更新状态栏/导航栏颜色以匹配当前主题 */
  private updateSystemBarColors(): void {
    // 状态栏/导航栏颜色取自主题调色板，与页面背景保持一致（深浅色均适配）
    SystemBars.getInstance().applyBase(ThemeColors.getInstance().palette());
    // 系统部件（系统标题栏/系统弹窗）的颜色模式也要跟着应用内主题走
    this.applyAppColorMode();
  }

  /**
   * 把应用内主题设置同步为**系统**颜色模式
   *
   * 应用内调色板（ThemeColors）只影响我们自绘的 UI；系统标题栏、系统弹窗、输入法
   * 由系统按应用的颜色模式渲染。两者不一致时会出现「应用内深色 + 系统标题栏黑字」。
   * 跟随系统时传 COLOR_MODE_NOT_SET，交回系统决定。
   */
  private applyAppColorMode(): void {
    const mode: ThemeMode = SettingsRepository.getInstance().getSettings().themeMode;
    let colorMode: ConfigurationConstant.ColorMode = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    if (mode === ThemeMode.DARK) {
      colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    } else if (mode === ThemeMode.LIGHT) {
      colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    }
    if (colorMode === this.appColorMode) {
      return;
    }
    // 必须先落标记再调用：setColorMode 会**同步**触发 onConfigurationUpdate，
    // 而该回调链会经 ThemeColors 的变更通知再次回到这里，不先落标记就是无限递归
    // （实测栈溢出，ability 被 AMS 以 killId 2003 杀掉）。
    this.appColorMode = colorMode;
    try {
      this.context.getApplicationContext().setColorMode(colorMode);
      hilog.info(DOMAIN, TAG, 'applyAppColorMode: themeMode=%{public}d -> colorMode=%{public}d',
        mode, colorMode);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'setColorMode failed. Cause: %{public}s', JSON.stringify(err));
    }
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'Ability onForeground');
    // 超时锁定判断：后台超时后需要重新解锁
    const needLock: boolean = AppLockManager.getInstance().onForeground();
    if (needLock) {
      RouteManager.getInstance().pushPath(RouteNames.LOCK);
    }
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'Ability onBackground');
    AppLockManager.getInstance().onBackground();
  }
}
