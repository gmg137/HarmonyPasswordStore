import { NativeBridge, NativeResult } from '../common/NativeBridge';

/**
 * native git/ssh 调用的跨线程载荷
 *
 * TaskPool 只接受可序列化数据，故用 JSON 友好的结构而不是函数/对象引用。
 */
export interface NativeGitRequest {
  /** native 函数名（与 NativeBridge 的方法名一致） */
  fn: string;
  /** 参数（全部按字符串传递，端口等由 native 侧转换） */
  args: string[];
}

export interface NativeGitReply {
  success: boolean;
  error: string;
  data: string;
}

/**
 * 在 TaskPool 工作线程里执行**阻塞的** native git/ssh 调用
 *
 * 为什么必须离开主线程：libgit2 与 russh 的网络调用是同步阻塞的（DNS 解析、TCP 连接、
 * TLS 握手、传输 packfile，慢网络下可达数十秒）。放在 JS 主线程上会让界面完全无响应，
 * 系统 watchdog 会以 `APP_INPUT_BLOCK` **直接杀掉进程**——实测模拟器上点「测试连接」，
 * 当 DNS 不可达时约 6 秒后应用消失（faultlog 栈停在 getaddrinfo）。
 *
 * 放到工作线程后：界面保持可交互，调用失败会正常返回错误信息。
 */
@Concurrent
export function invokeNativeGit(req: NativeGitRequest): NativeGitReply {
  const bridge: NativeBridge = NativeBridge.getInstance();
  const a: string[] = req.args;
  let r: NativeResult;
  switch (req.fn) {
    case 'gitTestRemote':
      r = bridge.gitTestRemote(a[0], a[1], a[2], a[3], a[4], a[5], a[6]);
      break;
    case 'gitClone':
      r = bridge.gitClone(a[0], a[1], a[2], a[3], a[4]);
      break;
    case 'gitCloneSsh':
      r = bridge.gitCloneSsh(a[0], a[1], a[2], a[3], a[4]);
      break;
    case 'gitPull':
      // rebase 以 '1'/'0' 传递（TaskPool 的载荷是字符串数组）
      r = bridge.gitPull(a[0], a[1], a[2], a[3], a[4] === '1', a[5], a[6], a[7]);
      break;
    case 'gitPush':
      r = bridge.gitPush(a[0], a[1], a[2], a[3], a[4], a[5], a[6]);
      break;
    case 'gitCommitAll':
      r = bridge.gitCommitAll(a[0], a[1], a[2], a[3]);
      break;
    case 'gitLog':
      r = bridge.gitLog(a[0], parseInt(a[1], 10));
      break;
    case 'gitStatus':
      r = bridge.gitStatus(a[0]);
      break;
    case 'sshTestAuth':
      r = bridge.sshTestAuth(a[0], parseInt(a[1], 10), a[2], a[3], a[4], a[5]);
      break;
    case 'sshTestPassword':
      r = bridge.sshTestPassword(a[0], parseInt(a[1], 10), a[2], a[3], a[4]);
      break;
    case 'sshFingerprint':
      r = bridge.sshFingerprint(a[0], parseInt(a[1], 10));
      break;
    default:
      return { success: false, error: `未知的 native 调用: ${req.fn}`, data: '' };
  }
  return { success: r.success, error: r.error, data: r.data };
}
