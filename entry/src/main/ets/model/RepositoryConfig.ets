import { PasswordFileOrganization } from '../common/Constants';

/**
 * 密码仓库配置
 */
export interface RepositoryConfig {
  /** 仓库根目录绝对路径 */
  storePath: string;
  /** 文件组织方式 */
  fileOrganization: PasswordFileOrganization;
  /** 仓库是否已初始化 */
  isInitialized: boolean;
  /** 是否为克隆的远程仓库 */
  isCloned: boolean;
}

/**
 * 默认仓库配置
 */
export function createDefaultRepositoryConfig(storePath: string): RepositoryConfig {
  return {
    storePath: storePath,
    fileOrganization: PasswordFileOrganization.FILE,
    isInitialized: false,
    isCloned: false,
  };
}
