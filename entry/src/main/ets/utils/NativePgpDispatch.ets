import { NativeBridge, NativeResult } from '../common/NativeBridge';

/**
 * native PGP 调用的跨线程载荷（与 NativeGitRequest 同构）
 *
 * TaskPool 只接受可序列化数据，故用 JSON 友好的结构而不是函数/对象引用。
 */
export interface NativePgpRequest {
  /** native 函数名（与 NativeBridge 的方法名一致） */
  fn: string;
  /** 参数（全部按字符串传递） */
  args: string[];
}

export interface NativePgpReply {
  success: boolean;
  error: string;
  data: string;
}

/**
 * PGP native 调用的统一分发
 *
 * 为什么必须离开主线程：目录密钥重加密（`ReencryptService`）会对**每条**条目
 * 逐个做 native 解密/加密/收件人解析——rpgp/gpg_pqc 的 S2K、OCB、ML-KEM 封装
 * 都是 CPU 密集操作，条目多时在主线程累计阻塞可达数十秒，界面完全无响应，
 * 真机实测被系统 watchdog 终止（FreezeDetector 有 freeze 事件记录）。
 * 分发到工作线程后主线程在每条之间可继续渲染与分发输入。
 *
 * 这里只承载「字符串入 → NativeResult 出」的纯调用；候选密钥选择、口令缓存、
 * 密钥匹配等含状态逻辑留在主线程 `PgpCrypto`，工作线程内不持有任何跨线程状态。
 *
 * 本模块单独成文件：@Concurrent 函数只允许引用**导入的**函数（同文件内的
 * 模块级函数引用过不了编译），`invokeNativePgp` 与主线程兜底都导入这里的
 * `runPgp`，switch 只写一份、两端口径一致。
 */
export function runPgp(req: NativePgpRequest): NativePgpReply {
  const bridge: NativeBridge = NativeBridge.getInstance();
  const a: string[] = req.args;
  let r: NativeResult;
  switch (req.fn) {
    case 'pgpRecipientKeyIds':
      r = bridge.pgpRecipientKeyIds(a[0]);
      break;
    case 'pgpDecrypt':
      r = bridge.pgpDecrypt(a[0], a[1], a[2]);
      break;
    case 'pgpDecryptGpgPqc':
      r = bridge.pgpDecryptGpgPqc(a[0], a[1], a[2]);
      break;
    case 'pgpEncrypt':
      r = bridge.pgpEncrypt(a[0], a[1]);
      break;
    case 'pgpEncryptGpgPqc':
      r = bridge.pgpEncryptGpgPqc(a[0], a[1]);
      break;
    case 'pgpEncryptMixed':
      r = bridge.pgpEncryptMixed(a[0], a[1], a[2]);
      break;
    case 'pgpVerifyPassphrase':
      r = bridge.pgpVerifyPassphrase(a[0], a[1]);
      break;
    case 'pgpGpgPqcVerifyPassphrase':
      r = bridge.pgpGpgPqcVerifyPassphrase(a[0], a[1]);
      break;
    default:
      return { success: false, error: `未知的 native 调用: ${req.fn}`, data: '' };
  }
  return { success: r.success, error: r.error, data: r.data };
}

/**
 * 主线程同步兜底：taskpool 分发失败（线程池不可用等）时直调同一份 switch，
 * 保证「正确性优先于流畅性」——宁可在主线程阻塞，也不能让重加密失败。
 */
export function dispatchPgpLocal(fnName: string, args: string[]): NativePgpReply {
  return runPgp({ fn: fnName, args: args });
}
