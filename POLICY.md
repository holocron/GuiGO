# Repository policy

This repository is public. Everything committed to it can be read, copied and
indexed by anyone, forever — deleting a file later does not remove it from the
history. Before every commit and every push, check against this policy.

## What belongs here

- Source code of the protocol package (`packages/diag_protocol/lib`) and the
  app (`apps/guigo/lib`, platform projects under `apps/guigo/ios` and
  `apps/guigo/android`).
- Build files needed to compile it (`pubspec.yaml`, `pubspec.lock`,
  `analysis_options.yaml`, Xcode / Gradle project files).
- App assets the app needs at run time (fonts, icon maps).
- `README.md`, this policy, `SECURITY.md`.

## What never belongs here

1. **Recorded sessions.** No captured DIAG traffic, frame dumps, network
   traces, logs, screenshots of SAP systems, or test data derived from them —
   not even "scrubbed" ones. Byte constants in code must not carry
   identifying values (host names, user or system IDs, addresses).
2. **Credentials and secrets.** No passwords, tokens, keys, certificates,
   provisioning profiles, keystores, `.env` files, or Keychain / keystore
   exports.
3. **Identifying data.** No real SAP system IDs, host names, IP addresses,
   client numbers, user names, personal names, customer or company names,
   in code, comments, file names or commit messages. Use neutral placeholders
   (`SID`, `host`, `USER`).
4. **Tooling and scratch files.** No local utilities, scripts, probes, dumps,
   temporary files, generated reports, or editor/OS artefacts (`.DS_Store`,
   `.idea/`, `build/`, `test/failures/`).
5. **Audit and review reports**, planning notes and AI-session artefacts.
6. **References to private or third-party tools** used during development.

## Before you push

- `git status` and `git diff --cached` — read every file you are about to
  commit.
- Search the staged changes for the categories above, e.g.
  `git diff --cached | grep -niE 'password|secret|token|BEGIN .*KEY'`.
- Commit messages follow the same rules as the code.

If something sensitive was pushed, treat it as disclosed: rotate the secret
first, then remove it from the history and force-push, and tell the
maintainer.

## Contributions

No license is granted (see `README.md`). Unsolicited pull requests may be
declined. Security reports: see `SECURITY.md`.
