/**
 * 视图模型模块
 *
 * 所有 ViewModel 类放置于此目录。
 * ViewModel 使用 @ObservedV2 装饰，属性使用 @Trace 装饰。
 * ViewModel 负责：
 * - 持有 UI 状态（唯一数据源）
 * - 调用 Repository 完成数据操作
 * - 将 Model 数据转换为 View 所需格式
 * - 处理业务逻辑（过滤、排序、计算）
 */
