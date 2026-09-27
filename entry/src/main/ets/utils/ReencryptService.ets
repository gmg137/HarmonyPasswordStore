import { PasswordRepository } from '../model/PasswordRepository';
import { PasswordEntry } from '../model/PasswordEntry';
import { PgpKeyManager } from '../crypto/PgpKeyManager';
import { PgpCrypto } from '../crypto/PgpCrypto';
import { GpgKeyId } from '../model/GpgKeyId';
import { RepoChangeNotifier } from '../common/RepoChangeNotifier';
import { GitClient } from './GitClient';
import { Strings } from '../common/Strings';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** hilog 域 */
const DOMAIN: number = 0x0001;
/** hilog 标签 */
const TAG: string = 'Reencrypt';

/**
 * 单条条目的重加密计划
 */
export interface ReencryptItem {
  /** 相对路径（不含 .gpg） */
  relativePath: string;
  /** 该条目当前由哪些密钥加密（PKESK 的 Key ID） */
  currentKeyIds: string[];
  /** 是否真的需要重加密（当前收件人 != 目标收件人） */
  needsReencrypt: boolean;
  /**
   * 可解开该条目的已导入密钥指纹（空数组 = 没有可用私钥，必须跳过）
   *
   * 必须是**全部**匹配的密钥而非只取第一把：多接收方条目（如 .gpg-id 里同时
   * 有普通密钥与 gpgPqc 密钥）任一把都能解密，只取第一把可能正好是用户
   * 没解锁/没口令的那把，于是「明明有能解的密钥却报解密失败」。
   */
  decryptKeys: string[];
}

/**
 * 预扫结果：动文件之前先让用户看清代价
 */
export interface ReencryptPlan {
  /** 受该目录 .gpg-id 管辖的全部条目 */
  items: ReencryptItem[];
  /** 需要重加密的条数 */
  needsCount: number;
  /** 因缺少私钥而无法重加密的条数 */
  missingKeyCount: number;
  /** 执行前需要解锁的密钥指纹（去重，按出现顺序） */
  requiredKeys: string[];
  /** 目标收件人的 Key ID 集合 */
  targetKeyIds: string[];
  /** 预扫失败原因（'' = 正常） */
  error: string;
}

/** 单条失败记录 */
export interface ReencryptFailure {
  relativePath: string;
  error: string;
}

/** 执行结果 */
export interface ReencryptOutcome {
  success: boolean;
  /** 已重加密的条数 */
  reencrypted: number;
  /** 因缺私钥跳过的条数 */
  skipped: number;
  failures: ReencryptFailure[];
  /** 是否已写入新的 .gpg-id（全部成功才写） */
  gpgIdWritten: boolean;
  error: string;
}

/**
 * 目录密钥重加密服务（「换默认密钥」与「修改目录密钥」共用）
 *
 * ## 语义对齐 `pass init`
 *
 * `pass init <新密钥>` 会调用 `reencrypt_path`：遍历子树里每个 `.gpg`，
 * **按该文件最近的 `.gpg-id`** 算出目标收件人；再用 `gpg --decrypt --list-only`
 * 读出**当前收件人**，两者不同才真正解密+重加密。本服务的算法与之一致：
 *
 * 1. 递归收集子树里的条目；
 * 2. 逐条取「管辖它的 `.gpg-id` 所在目录」——**不等于本次要改的目录就跳过**
 *    （子目录自带 `.gpg-id` 的条目收件人不变，无需动，也不用口令）；
 * 3. 用密文的 PKESK Key ID 判断当前收件人，与目标集合比较，相同则跳过；
 * 4. 需要换的才解密（要旧密钥口令）→ 用目标密钥重加密 → 原子替换；
 * 5. **全部成功后才写 `.gpg-id`**。
 *
 * 第 5 步比 `pass` 更严：`pass` 先写 `.gpg-id` 再重加密，中途失败会留下
 * 「`.gpg-id` 已指向新密钥、部分条目仍旧密钥」的不一致状态。
 * 本服务在部分失败时保留原 `.gpg-id`；已成功换掉的条目也不会白费——下次执行会
 * 因「当前收件人已等于目标」而跳过，且解密一律按密文收件人判定（见 `PgpCrypto`），
 * 故中途失败不会让任何条目变得打不开。
 */
export class ReencryptService {
  private static instance?: ReencryptService;

  static getInstance(): ReencryptService {
    if (!ReencryptService.instance) {
      ReencryptService.instance = new ReencryptService();
    }
    return ReencryptService.instance;
  }

  /**
   * 预扫：不改动任何文件，只算出「要换几条、缺哪把私钥、需要哪些口令」
   *
   * @param dirPath 目标目录相对路径（'' = 仓库根）；该目录及其**未被更深 .gpg-id 覆盖**的
   *                子目录下的条目都属于本次范围
   * @param targetFingerprints 目标接收方指纹（新密钥）
   */
  plan(dirPath: string, targetFingerprints: string[]): ReencryptPlan {
    const plan: ReencryptPlan = {
      items: [],
      needsCount: 0,
      missingKeyCount: 0,
      requiredKeys: [],
      targetKeyIds: this.targetKeyIds(targetFingerprints),
      error: '',
    };
    if (targetFingerprints.length === 0) {
      plan.error = Strings.get('reencrypt_no_key_selected');
      return plan;
    }
    if (plan.targetKeyIds.length === 0) {
      // 目标密钥没有可用的加密子密钥（例如只导入了公钥、或曲线不支持）
      plan.error = Strings.get('reencrypt_no_enc_subkey');
      return plan;
    }
    const repo: PasswordRepository = PasswordRepository.getInstance();
    const paths: string[] = [];
    this.collect(repo, dirPath, paths);

    const crypto: PgpCrypto = PgpCrypto.getInstance();
    for (let i: number = 0; i < paths.length; i++) {
      const relativePath: string = paths[i];
      // 只处理「由本目录 .gpg-id 管辖」的条目：更深层自带 .gpg-id 的条目收件人不变
      if (repo.findGpgIdDir(relativePath) !== dirPath) {
        continue;
      }
      const ciphertext: string = repo.readCiphertext(relativePath);
      if (ciphertext.length === 0) {
        continue;
      }
      const current: string[] = crypto.recipientKeyIds(ciphertext);
      const needs: boolean = !ReencryptService.sameIdSet(current, plan.targetKeyIds);
      const decryptKeys: string[] = crypto.keysForCiphertext(ciphertext);
      const item: ReencryptItem = {
        relativePath: relativePath,
        currentKeyIds: current,
        needsReencrypt: needs,
        decryptKeys: decryptKeys,
      };
      plan.items.push(item);
      if (needs) {
        plan.needsCount++;
        if (decryptKeys.length === 0) {
          plan.missingKeyCount++;
        } else {
          // 全部登记：解锁弹窗按「任一已解锁即可」判断，避免为一把解不开的密钥白索口令
          for (let k: number = 0; k < decryptKeys.length; k++) {
            ReencryptService.addUnique(plan.requiredKeys, decryptKeys[k]);
          }
        }
      }
    }
    hilog.info(DOMAIN, TAG, 'plan: %{public}d entries, %{public}d need re-encrypt, %{public}d missing key',
      plan.items.length, plan.needsCount, plan.missingKeyCount);
    return plan;
  }

  /**
   * 执行重加密
   *
   * @param dirPath 目标目录相对路径
   * @param targetFingerprints 目标接收方指纹
   * @param plan 预扫结果（由 {@link plan} 产出，避免重复解析）
   * @returns 执行结果；**全部需要重加密的条目都成功**才写入 `.gpg-id`
   */
  async run(dirPath: string, targetFingerprints: string[],
    plan: ReencryptPlan): Promise<ReencryptOutcome> {
    const outcome: ReencryptOutcome = {
      success: false,
      reencrypted: 0,
      skipped: 0,
      failures: [],
      gpgIdWritten: false,
      error: '',
    };
    const repo: PasswordRepository = PasswordRepository.getInstance();
    const crypto: PgpCrypto = PgpCrypto.getInstance();

    for (let i: number = 0; i < plan.items.length; i++) {
      const item: ReencryptItem = plan.items[i];
      if (!item.needsReencrypt) {
        continue;
      }
      if (item.decryptKeys.length === 0) {
        // 缺私钥：不阻断其他条目，逐条报告
        outcome.skipped++;
        outcome.failures.push({
          relativePath: item.relativePath,
          error: Strings.fmt('reencrypt_missing_decrypt_key',
            item.currentKeyIds.join(Strings.get('common_list_sep')) || Strings.get('reencrypt_keyids_unlabeled')),
        });
        continue;
      }
      const ciphertext: string = repo.readCiphertext(item.relativePath);
      if (ciphertext.length === 0) {
        outcome.failures.push({ relativePath: item.relativePath, error: Strings.get('move_read_ciphertext_failed') });
        continue;
      }
      // 解密：候选只给「实际能解该密文的密钥」，避免用错密钥白跑；
      // 多接收方条目会有多把候选，decrypt() 会按已解锁优先逐个尝试
      const decrypted = await crypto.decrypt(ciphertext, item.decryptKeys);
      if (!decrypted.success) {
        outcome.failures.push({
          relativePath: item.relativePath,
          error: Strings.fmt('move_decrypt_failed', decrypted.error),
        });
        continue;
      }
      // 重加密到目标接收方（跨类型亦可：解密与加密是两个独立操作，各自只涉及一种密钥）
      const encrypted = await crypto.encrypt(decrypted.data, targetFingerprints);
      if (!encrypted.success) {
        outcome.failures.push({
          relativePath: item.relativePath,
          error: Strings.fmt('reencrypt_encrypt_failed', encrypted.error),
        });
        continue;
      }
      const written = repo.overwriteCiphertext(item.relativePath, encrypted.data);
      if (!written.success) {
        outcome.failures.push({ relativePath: item.relativePath, error: written.error });
        continue;
      }
      outcome.reencrypted++;
    }

    // 只有「需要换的条目全部成功」才落盘新 .gpg-id：否则保持原状，让用户可重试
    if (outcome.failures.length === 0) {
      const setResult = repo.setGpgIdForDir(dirPath, targetFingerprints);
      if (!setResult.success) {
        outcome.error = Strings.fmt('reencrypt_write_gpgid_failed', setResult.error);
        return outcome;
      }
      outcome.gpgIdWritten = true;
      RepoChangeNotifier.connect().bump();
      // 与 pass init 一致：迁移后立即提交一次，git 历史里能看出这次密钥变更
      const label: string = dirPath.length > 0 ? dirPath : '(root)';
      await GitClient.getInstance().commitAll(
        `Reencrypt ${label} using new GPG id ${this.targetKeyIds(targetFingerprints).join(',')}`);
      outcome.success = true;
    } else {
      outcome.error = Strings.fmt('reencrypt_failed_count', outcome.failures.length);
      // 已成功的条目仍然生效（其收件人已是目标），下次执行会跳过
      RepoChangeNotifier.connect().bump();
    }
    hilog.info(DOMAIN, TAG, 'run: reencrypted=%{public}d skipped=%{public}d failures=%{public}d gpgIdWritten=%{public}s',
      outcome.reencrypted, outcome.skipped, outcome.failures.length,
      outcome.gpgIdWritten ? 'yes' : 'no');
    return outcome;
  }

  /**
   * 目标接收方的加密子密钥 Key ID 集合
   *
   * 公开给「移动条目」复用：移动时要用它和条目密文的收件人比较，
   * 判断是否需要按目标目录密钥重加密（比较逻辑与换目录密钥完全同源）
   */
  targetKeyIds(targetFingerprints: string[]): string[] {
    const ids: string[] = [];
    const mgr: PgpKeyManager = PgpKeyManager.getInstance();
    for (let i: number = 0; i < targetFingerprints.length; i++) {
      const key: GpgKeyId | null = mgr.resolveKeyByIdEntry(targetFingerprints[i]);
      if (key !== null && key.encryptionKeyId.length > 0) {
        ReencryptService.addUnique(ids, key.encryptionKeyId.toUpperCase());
      }
    }
    return ids;
  }

  /** 递归收集目录下的条目相对路径（不含 .gpg） */
  private collect(repo: PasswordRepository, relativeDir: string, out: string[]): void {
    const listed = repo.listEntries(relativeDir);
    if (!listed.success) {
      return;
    }
    const entries: PasswordEntry[] | null = listed.data;
    if (entries === null) {
      return;
    }
    for (let i: number = 0; i < entries.length; i++) {
      const entry: PasswordEntry = entries[i];
      if (entry.isDirectory) {
        this.collect(repo, entry.relativePath, out);
      } else {
        out.push(entry.relativePath);
      }
    }
  }

  /** 集合相等（忽略顺序，大小写不敏感）——「是否需要重加密」的判据，移动条目也用它 */
  static sameIdSet(a: string[], b: string[]): boolean {
    if (a.length !== b.length) {
      return false;
    }
    const up: string[] = a.map((s: string) => s.toUpperCase()).sort();
    const bp: string[] = b.map((s: string) => s.toUpperCase()).sort();
    for (let i: number = 0; i < up.length; i++) {
      if (up[i] !== bp[i]) {
        return false;
      }
    }
    return true;
  }

  private static addUnique(arr: string[], v: string): void {
    if (v.length > 0 && !arr.includes(v)) {
      arr.push(v);
    }
  }
}
