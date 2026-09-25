import { describe, it, expect } from '@ohos/hypium';
import { CredentialMatcher } from '../../main/ets/autofill/CredentialMatcher';
import { RelyingPartyVerifier } from '../../main/ets/crypto/RelyingPartyVerifier';

/**
 * 凭据匹配器与 RP 校验器单元测试
 *
 * 覆盖包名↔域名提取、主机得分、RP ID 域匹配规则。
 */
export default function matcherTest() {
  describe('CredentialMatcher', () => {
    it('extractDomainFromPackage_reverses', 0, () => {
      expect(CredentialMatcher.extractDomainFromPackage('com.example.app')).assertEqual('example.com');
      expect(CredentialMatcher.extractDomainFromPackage('org.example.mail')).assertEqual('example.org');
    });

    it('extractDomainFromPackage_singlePart_returns_empty', 0, () => {
      expect(CredentialMatcher.extractDomainFromPackage('localhost')).assertEqual('');
    });

    it('extractHost_strips_protocol_path_port', 0, () => {
      expect(CredentialMatcher.extractHost('https://login.example.org/path?q=1')).assertEqual('login.example.org');
      expect(CredentialMatcher.extractHost('http://example.com:8080/')).assertEqual('example.com');
      expect(CredentialMatcher.extractHost('Example.COM')).assertEqual('example.com');
    });

    it('scoreDomain_exact_higher_than_subdomain', 0, () => {
      const exact: number = CredentialMatcher.scoreDomain('example.org', 'example.org');
      const sub: number = CredentialMatcher.scoreDomain('login.example.org', 'example.org');
      const none: number = CredentialMatcher.scoreDomain('other.com', 'example.org');
      expect(exact).assertEqual(100);
      expect(sub).assertEqual(80);
      expect(none).assertEqual(0);
    });

    it('scoreDomain_rejects_lookalike_suffix_host', 0, () => {
      // 曾经 hostA.includes(hostB) 给 60 分，而阈值仅 30，
      // 于是 evil-example.com 能拿到 example.com 的密码——自动填充下等同于跨站泄密
      expect(CredentialMatcher.scoreDomain('evil-example.com', 'example.com')).assertEqual(0);
      expect(CredentialMatcher.scoreDomain('notexample.com', 'example.com')).assertEqual(0);
      expect(CredentialMatcher.scoreDomain('example.org.evil.net', 'example.org')).assertEqual(0);
      expect(CredentialMatcher.scoreDomain('example.com', 'a.com')).assertEqual(0);
    });

    it('scoreDomain_subdomain_relation_scored', 0, () => {
      // 真实子域仍应匹配（以点分隔的右侧后缀）
      expect(CredentialMatcher.scoreDomain('login.example.com', 'example.com')).assertEqual(80);
    });

    it('scoreDomain_multi_part_suffix_not_degenerated', 0, () => {
      // example.co.uk 若取末两段会退化成 co.uk，使不同站点判为同域
      expect(CredentialMatcher.scoreDomain('a.example.co.uk', 'b.example.co.uk')).assertEqual(80);
      expect(CredentialMatcher.scoreDomain('a.example.co.uk', 'b.other.co.uk')).assertEqual(0);
    });

    it('isSubdomainOf_requires_dot_boundary', 0, () => {
      expect(CredentialMatcher.isSubdomainOf('login.example.com', 'example.com')).assertTrue();
      expect(CredentialMatcher.isSubdomainOf('evil-example.com', 'example.com')).assertFalse();
      expect(CredentialMatcher.isSubdomainOf('example.com', 'example.com')).assertFalse();
    });
  });

  describe('RelyingPartyVerifier', () => {
    it('verifyRpId_exact_origin_allowed', 0, () => {
      expect(RelyingPartyVerifier.verifyRpId('example.com', 'https://example.com/login')).assertTrue();
    });

    it('verifyRpId_parent_domain_allowed', 0, () => {
      expect(RelyingPartyVerifier.verifyRpId('example.com', 'https://login.example.com/auth')).assertTrue();
    });

    it('verifyRpId_subdomain_rp_rejected', 0, () => {
      // rpId 不能是 origin 主机的子域
      expect(RelyingPartyVerifier.verifyRpId('login.example.com', 'https://example.com')).assertFalse();
    });

    it('verifyRpId_unrelated_domain_rejected', 0, () => {
      expect(RelyingPartyVerifier.verifyRpId('evil.net', 'https://example.com')).assertFalse();
    });

    it('verifyRpId_empty_rejected', 0, () => {
      expect(RelyingPartyVerifier.verifyRpId('', 'https://example.com')).assertFalse();
      expect(RelyingPartyVerifier.verifyRpId('example.com', '')).assertFalse();
    });

    it('extractHost_lowercase_normalized', 0, () => {
      expect(RelyingPartyVerifier.extractHost('HTTPS://EXAMPLE.COM/Path')).assertEqual('example.com');
    });
  });
}
