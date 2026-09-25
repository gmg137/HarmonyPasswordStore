/**
 * LazyForEach 数据源基类
 *
 * 实现 IDataSource 接口，包装数组并提供精准的变更通知，
 * 供长列表按需渲染（1000+ 条目滚动流畅）。
 */
export abstract class LazyDataSource<T> implements IDataSource {
  /** 监听器（ArkUI 框架注册） */
  private listeners: DataChangeListener[] = [];

  /** 子类返回底层数组 */
  protected abstract getItems(): T[];

  /**
   * 注册监听器（框架调用）
   */
  registerDataChangeListener(listener: DataChangeListener): void {
    if (!this.listeners.includes(listener)) {
      this.listeners.push(listener);
    }
  }

  /**
   * 注销监听器（框架调用）
   */
  unregisterDataChangeListener(listener: DataChangeListener): void {
    const idx: number = this.listeners.indexOf(listener);
    if (idx >= 0) {
      this.listeners.splice(idx, 1);
    }
  }

  /**
   * 条目总数
   */
  totalCount(): number {
    return this.getItems().length;
  }

  /**
   * 按索引取条目
   */
  getData(index: number): T | undefined {
    return this.getItems()[index];
  }

  /**
   * 整体替换数据（搜索/目录切换场景）
   */
  replaceAll(items: T[]): void {
    this.setItems(items);
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }

  /**
   * 子类设置底层数组
   */
  protected abstract setItems(items: T[]): void;
}

/**
 * 密码条目列表数据源（具体类型版）
 */
export class EntryDataSource<T> extends LazyDataSource<T> {
  private items: T[] = [];

  protected getItems(): T[] {
    return this.items;
  }

  protected setItems(items: T[]): void {
    this.items = items;
  }
}
