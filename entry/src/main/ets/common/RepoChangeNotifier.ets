import { AppStorageV2 } from '@kit.ArkUI';

/**
 * 仓库变更通知器
 *
 * 子页面（新建/编辑/删除密码）成功后调用 bump() 递增 nonce，
 * 根页面（PasswordListPage）通过 @Monitor 监听 nonce 变化自动刷新列表。
 */
@ObservedV2
export class RepoChangeNotifier {
  @Trace nonce: number = 0;
  /** 最近一次移动/重命名的原路径（详情页据此跟随新路径） */
  @Trace movedFrom: string = '';
  /** 最近一次移动/重命名的目标路径 */
  @Trace movedTo: string = '';

  bump(): void {
    this.nonce += 1;
  }

  static connect(): RepoChangeNotifier {
    return AppStorageV2.connect(RepoChangeNotifier, 'repoChangeNotifier',
      (): RepoChangeNotifier => new RepoChangeNotifier())!;
  }
}
