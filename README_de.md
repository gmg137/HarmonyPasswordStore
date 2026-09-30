# HarmonyPasswordStore

[简体中文](README.md) | [English](README_en.md) | [Русский](README_ru.md) | [Deutsch] | [繁體中文](README_zh-TW.md)

Nativer HarmonyOS-Client für den Passwort-Manager [pass](https://www.passwordstore.org/), kompatibel mit dem standardmäßigen pass-Repository-Format; das Design orientiert sich an [Android-Password-Store](https://github.com/agrahn/Android-Password-Store). Der angezeigte App-Name lautet **PasswordStore**.

## Funktionen

| Funktion | Beschreibung |
|----------|--------------|
| Vollständige pass-Kompatibilität | Standardverzeichnisstruktur mit GPG-verschlüsselten Einträgen (`.gpg`); in `.gpg-id` ein Schlüssel pro Zeile (Fingerprint / Key ID / E-Mail), einschließlich Kommentare am Zeilenende und `!`-Markierung für erzwungene Subkeys — interoperabel mit pass CLI und Desktop-Ökosystem |
| Post-Quanten-Kryptografie (PQC) | Import und Nutzung von GnuPG-algo-8-Schlüsseln (ML-KEM-768 + X25519 / brainpoolP256r1 / brainpoolP384r1), vollständig interoperabel mit gpg 2.5+; normale und PQC-Schlüssel können als gemischte Empfänger desselben Eintrags dienen |
| Drei Suchmodi | Unscharf / exakt / **Inhaltssuche** — die Inhaltssuche entschlüsselt Einträge und durchsucht alle Feldwerte außer dem Passwort selbst (das Passwort wird nie durchsucht); Trefferzeilen zeigen einen Ausschnitt |
| Passwort-Generator | Kryptografisch sicherer Zufall; Länge, Zeichensätze, Ausschluss mehrdeutiger Zeichen; Diceware-Passphrasen mit Entropiebewertung |
| PGP-Schlüsselverwaltung | Import aus Text oder Datei (armor und Binärformat werden automatisch erkannt), Erzeugung von EdDSA/RSA-Schlüsseln, Ändern der Passphrase, Export als `.asc`, Wahl des Standardschlüssels für Verschlüsselung |
| Git-Synchronisierung | clone / pull / push / commit über SSH und HTTPS; dreistufige TOFU-Prüfung des Host-Fingerprints (Bestätigung bei Erstverbindung / vertraut / Warnung bei Nichtübereinstimmung); erzwungenes Pushen; Pull mit Rebase; HTTPS-Proxy |
| AutoFill | Anbindung an das System-Framework für automatisches Ausfüllen; Zuordnung von Zugangsdaten nach Paketname / Domain |
| Biometrische Entsperrung | Fingerabdruck / Gesichtserkennung (Systemdialog erscheint automatisch); Auto-Sperre nach Sitzungs-Timeout; beim Sperren werden Passphrasen und Entschlüsselungscaches im Speicher gelöscht |
| Dateiverwaltung | Verzeichnisbaum, Verschieben / Umbenennen von Einträgen (automatische Neuverschlüsselung zwischen Verzeichnissen mit unterschiedlichen Schlüsseln), Anlegen und Löschen von Ordnern |
| Dateiformat der Passwörter | Binär (identisch zur Desktop-Ausgabe von pass) oder ASCII-armor, jederzeit umschaltbar (wirkt nur auf neue Schreibvorgänge) |
| Sicherheit der Zwischenablage | Kopierte Passwörter werden nach Ablauf einer Frist automatisch gelöscht; eine kurzfristige Aufgabe stellt sicher, dass die Löschung auch im Hintergrund wirkt |
| Lokalisierung | 简体中文, 繁體中文, English, Deutsch, Русский (folgt der Systemsprache, in der App umschaltbar) |

## Voraussetzungen

- HarmonyOS-Smartphone (API 26+)

## Build und Installation

Vor dem ersten Build die lokale Signaturkonfiguration aus der Vorlage erzeugen (die Datei enthält Pfade und Passwörter der Signaturmaterialien und wird **nicht eingecheckt**):

```bash
cp build-profile.example.json5 build-profile.json5
```

Anschließend das Projekt in DevEco Studio öffnen und über **File → Project Structure → Signing Configs** (Automatically generate signature) das Debug-Signaturmaterial erzeugen lassen (auch Kommandozeilen-Builds hängen von dieser Datei ab).

Danach bauen mit [DevEco Studio](https://developer.huawei.com/consumer/harmonyos/) (mit HarmonyOS SDK) oder über die Kommandozeile (Hvigor):

```bash
hvigorw assembleHap                                            # Debug-HAP
hvigorw -p buildMode=release assembleHap                       # Release (aktiviert ArkTS-Obfuskation)
hvigorw -p product=default -p buildMode=release assembleApp    # Release-.app-Paket
```

Ausgabeorte: HAPs unter `entry/build/default/outputs/default/`, .app unter `build/outputs/default/` im Projektstamm.

Die nativen statischen Bibliotheken für PGP (Rust) und Git (libgit2) liegen vorkompiliert im Repository (aarch64 / x86_64); reguläre Builds benötigen keine Rust-Toolchain. Zum Ändern des nativen Codes siehe `entry/src/main/cpp/rpgp_wrapper/` (Rust-Tests: `cargo test --release`).

## Kompatibilität mit dem pass-Repository-Format

- Ein Eintrag ist `<Verzeichnis>/<Name>.gpg`; die erste entschlüsselte Zeile ist das Passwort, danach folgen die Felder `user:` / `email:` / `phone:` / `notes:` und freier Text
- Die `.gpg-id` im Store-Stamm (oder in jedem Unterverzeichnis) legt die Verschlüsselungsschlüssel fest; mehrere Schlüssel und alle pass-Schreibweisen werden unterstützt
- Die Entschlüsselung wählt den Schlüssel anhand der **tatsächlichen Empfänger im Chiffrat** (gleiches Verhalten wie `pass show`) und meldet einen klaren Fehler, statt erneut nach der Passphrase zu fragen, wenn der Schlüssel fehlt
- Erzeugte Chiffrate lassen sich direkt mit `gpg --decrypt` am Desktop prüfen

## Sicherheitsdesign

- **Lokale Daten zuerst**: keinerlei Cloud-Dienst; Passwörter existieren nur als verschlüsselte Dateien auf dem Gerät und im von Ihnen konfigurierten Git-Remote
- **Lebenszyklus Klartext**: entschlüsselte Inhalte existieren nur im Speicher; der Suchcache enthält nur abgeleiteten Text der Feldwerte (niemals das Passwort); beim Sperren oder Hintergrundwechsel wird alles gelöscht — auch der native Cache entsperrender privater Schlüssel
- **Versiegelte Zugangsdaten**: vertrauliche Daten wie Git-Anmeldeinformationen werden mit HUKS verschlüsselt gespeichert; die Zwischenablage wird zeitgesteuert automatisch geleert
- **Sichere Protokolle**: Protokolle enthalten niemals Passwörter, Schlüssel oder Klartext
- **Härtung beim Import**: armor wird beim Import normalisiert (schützt vor einzeiligem Base64, das das native Parsen brechen würde); binäre Chiffrate werden vor dem Schreiben per CRC24 geprüft

## Unit-Tests

ArkTS (LocalUnit, aus DevEco Studio ausführen; neue Dateien müssen in `List.test.ets` manuell registriert werden):

```
entry/src/test/
├── List.test.ets               # Eingangspunkt der Testsuiten
├── PasswordFileParser.test.ets # pass-Format Parsen / Serialisierungs-Roundtrip / Suchtext & Ausschnitte
├── PgpPacketParser.test.ets    # armor-Umwandlung (CRC24 gegen RFC-4880-Vektoren) & Fingerprints vs. gpg
├── PasswordGenerator.test.ets  # Generator Länge / Zeichensätze / Mehrdeutigkeitsausschluss / Entropie
├── CredentialMatcher.test.ets  # Zuordnung für AutoFill / RP-ID-Prüfung
└── PathSafety.test.ets         # Schutz vor Pfad-Traversierung (Nutzereingabe und Repository-Inhalt)
```

Rust (27 Tests, einschließlich End-to-End mit gpg und PQC-Interoperabilität):

```bash
cd entry/src/main/cpp/rpgp_wrapper && cargo test --release
```

## Verwandte Projekte

- [pass — the standard unix password manager](https://www.passwordstore.org/)
- [Android-Password-Store](https://github.com/agrahn/Android-Password-Store)

## Lizenz

GPL-3.0 (Lizenzinformationen der Drittkomponenten siehe [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md))
