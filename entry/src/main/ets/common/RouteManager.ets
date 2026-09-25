import { RouteNames } from '../common/Constants';

/**
 * 全局导航路由管理器
 *
 * 持有共享的 NavPathStack 实例，供各 ViewModel 调用页面跳转。
 * 在 Index 页面 aboutToAppear 中初始化。
 */
export class RouteManager {
  private static instance: RouteManager | null = null;
  private pathStack: NavPathStack = new NavPathStack();
  /** 最近一次 push 的参数暂存（NavPathInfo.param 在 aboutToAppear 时序下可能未就绪） */
  private lastParam: Object | undefined = undefined;

  private constructor() {
  }

  /**
   * 设置 NavPathStack（在 Index 页面初始化时调用）
   */
  setPathStack(stack: NavPathStack): void {
    this.pathStack = stack;
  }

  static getInstance(): RouteManager {
    if (!RouteManager.instance) {
      RouteManager.instance = new RouteManager();
    }
    return RouteManager.instance;
  }

  /**
   * 获取 NavPathStack 实例
   */
  getPathStack(): NavPathStack {
    return this.pathStack;
  }

  /**
   * 跳转到指定路由
   * @param routeName 路由名称（RouteNames 中定义）
   * @param param 可选参数
   */
  pushPath(routeName: string, param?: Object): void {
    this.lastParam = param;
    this.pathStack.pushPath({ name: routeName, param: param });
  }

  /**
   * 获取最近一次 push 的参数（目标页 aboutToAppear 中读取）
   */
  takeLastParam(): Object | undefined {
    const p: Object | undefined = this.lastParam;
    this.lastParam = undefined;
    return p;
  }

  /**
   * 替换当前页面
   */
  replacePath(routeName: string, param?: Object): void {
    this.pathStack.replacePath({ name: routeName, param: param });
  }

  /**
   * 返回上一页
   */
  pop(): void {
    this.pathStack.pop();
  }

  /**
   * 返回到指定路由
   */
  popToName(routeName: string): void {
    this.pathStack.popToName(routeName);
  }

  /**
   * 清空路由栈并跳转
   */
  clearAndPush(routeName: string, param?: Object): void {
    this.pathStack.clear();
    this.pathStack.pushPath({ name: routeName, param: param });
  }
}
