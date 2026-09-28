import { NativePgpRequest, NativePgpReply, runPgp } from './NativePgpDispatch';

/**
 * 在 TaskPool 工作线程里执行 PGP native 调用（模式同 NativeGitTask）
 *
 * 分发逻辑与参数约定见 `NativePgpDispatch.ets`；taskpool.execute 失败时由
 * 调用方（PgpCrypto.callPgp）回退到 `dispatchPgpLocal` 主线程同步执行。
 */
@Concurrent
export function invokeNativePgp(req: NativePgpRequest): NativePgpReply {
  return runPgp(req);
}
