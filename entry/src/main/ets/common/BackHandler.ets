/**
 * 返回手势/返回键处理器
 *
 * Navigation 根内容（PasswordListPage）不是 NavDestination，
 * 系统边缘滑动返回与返回键不会自动生效；根页面注册处理器，
 * @Entry 页在 onBackPress 中统一转发。
 */
export class BackHandler {
  private static handler: (() => boolean) | null = null;

  /** 注册返回拦截（返回 true 表示已消费返回事件） */
  static set(handler: (() => boolean) | null): void {
    BackHandler.handler = handler;
  }

  static handleBack(): boolean {
    return BackHandler.handler !== null ? BackHandler.handler() : false;
  }
}
