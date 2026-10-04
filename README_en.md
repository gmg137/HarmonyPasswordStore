# HarmonyPasswordStore

[简体中文](README.md) | [English] | [Русский](README_ru.md) | [Deutsch](README_de.md) | [繁體中文](README_zh-TW.md)

A native HarmonyOS client for the [pass](https://www.passwordstore.org/) password manager, compatible with the standard pass repository format and modeled after [Android-Password-Store](https://github.com/agrahn/Android-Password-Store). The app's display name is **PasswordStore**.

## Features

| Feature | Description |
|---------|-------------|
| Full pass compatibility | Standard directory layout with GPG-encrypted entries (`.gpg`); `.gpg-id` accepts one key per line (fingerprint / Key ID / email), including trailing comments and `!` forced-subkey markers — interoperates with the pass CLI and desktop ecosystem |
| Post-quantum crypto (PQC) | Import and use GnuPG algo 8 keys (ML-KEM-768 + X25519 / brainpoolP256r1 / brainpoolP384r1), fully interoperable with gpg 2.5+; regular and PQC keys can be mixed recipients of the same entry |
| Three search modes | Fuzzy / exact / **content match** — content match decrypts entries and searches all field values except the password itself (the password is never searched); hit rows show a snippet |
| Password generator | Cryptographically secure randomness; length, character sets, ambiguous-character exclusion; Diceware passphrases with entropy estimation |
| PGP key management | Import from text or file (armor and binary auto-detected), generate EdDSA/RSA keys, change passphrases, export `.asc` files, choose the default encryption key |
| Git sync | clone / pull / push / commit over SSH and HTTPS; three-state TOFU host-key verification (first-connect confirm / trusted / same-type mismatch alert); force push; pull with rebase; HTTPS proxy |
| Biometric unlock | Fingerprint / face (system prompt raised automatically on lock); session timeout auto-lock; locking wipes in-memory passphrases and decryption caches |
| File management | Directory tree, move / rename entries (auto re-encryption across key directories), create and delete folders |
| Password file format | Binary (identical to desktop pass output) or ASCII armor, switchable anytime (only affects new writes) |
| Clipboard safety | Copied passwords are cleared automatically after a timeout; a transient task keeps the clearing effective even when the app is backgrounded |
| Localization | 简体中文, 繁體中文, English, Deutsch, Русский (follows the system; switchable in-app) |

## Requirements

- HarmonyOS phone (API 26+)

## Build & Install

Before the first build, create the local signing config from the template (it holds signing material paths and passwords and is **not committed**):

```bash
cp build-profile.example.json5 build-profile.json5
```

Then open the project in DevEco Studio and let **File → Project Structure → Signing Configs** (Automatically generate signature) create the debug signing material in that file (command-line builds depend on it too).

After that, build with [DevEco Studio](https://developer.huawei.com/consumer/harmonyos/) (with the HarmonyOS SDK) or from the command line (Hvigor):

```bash
hvigorw assembleHap                                            # debug HAP
hvigorw -p buildMode=release assembleHap                       # release (enables ArkTS obfuscation)
hvigorw -p product=default -p buildMode=release assembleApp    # release .app package
```

Output locations: HAPs under `entry/build/default/outputs/default/`, .app under `build/outputs/default/` in the project root.

The native static libraries for PGP (Rust) and Git (libgit2) are pre-built in the repository (aarch64 / x86_64); regular builds need no Rust toolchain. To modify native code, see `entry/src/main/cpp/rpgp_wrapper/` (Rust tests: `cargo test --release`).

## pass Repository Compatibility

- An entry is `<directory>/<name>.gpg`; the decrypted first line is the password, followed by `user:` / `email:` / `phone:` / `notes:` fields and free-form text
- `.gpg-id` at the store root (or any subdirectory) selects the encryption key(s); multiple keys and all pass-style notations are supported
- Decryption picks the key by the **actual recipients in the ciphertext** (same behavior as `pass show`) and reports a clear error instead of re-prompting when the key is missing
- Produced ciphertexts can be verified directly with desktop `gpg --decrypt`

## Security Design

- **Local first**: no cloud service whatsoever; passwords exist only as encrypted files on the device and in the Git remote you configure
- **Plaintext lifetime**: decrypted content lives only in memory; the search cache stores only derived text of field values (never the password); locking or backgrounding the app wipes it all, including the native unlocked-private-key cache
- **Credential sealing**: sensitive data such as Git credentials is encrypted at rest with HUKS; the clipboard is cleared automatically on a timer
- **Log safety**: logs never contain passwords, keys, or plaintext
- **Import hardening**: armor is normalized on import (prevents single-line base64 from breaking native parsing); binary ciphertext is CRC24-checked before being written

## Unit Tests

ArkTS (LocalUnit, run from DevEco Studio; new files must be registered in `List.test.ets`):

```
entry/src/test/
├── List.test.ets               # suite entry
├── PasswordFileParser.test.ets # pass format parse / serialize round-trip / searchable text & snippets
├── PgpPacketParser.test.ets    # armor conversion (CRC24 against RFC 4880 vectors) & fingerprint vs. gpg
├── PasswordGenerator.test.ets  # generator length / charsets / ambiguity exclusion / entropy
├── RepoExport.test.ets         # export archive name (local time, zero-padded, 0-based getMonth)
└── PathSafety.test.ets         # path traversal protection (user input and repo content)
```

Rust (27 tests, including end-to-end gpg and PQC interop):

```bash
cd entry/src/main/cpp/rpgp_wrapper && cargo test --release
```

## Related Projects

- [pass — the standard unix password manager](https://www.passwordstore.org/)
- [Android-Password-Store](https://github.com/agrahn/Android-Password-Store)

## License

GPL-3.0 (see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for third-party component licenses)
