# Security Policy

## Reporting a vulnerability

Please report security problems **privately** through
[GitHub's private vulnerability reporting](https://github.com/pklnx/dokumentum/security/advisories/new).
Do not open a public issue.

Include what you found, how to reproduce it (device, OS version, steps) and
what an attacker could do with it.

## Supported versions

Only the latest state of the `main` branch is supported. There is no release
yet, and there are no maintained older versions.

## What to expect

This is a hobby project maintained in spare time. Reports are handled on a
best-effort basis, without fixed response times. You will be credited in the
advisory unless you prefer otherwise.

CI scans every pull request and every push to `main` for committed
credentials (gitleaks, check `secret-scan`).

This project is entirely AI-written. Independent review is welcome.

## Scope

Dokumentum keeps documents on the device and in the owner's private iCloud
(the private CloudKit database). It has no server, no accounts and no
external services.

In scope, for example:

- Documents, their text or metadata leaving the device by any path other than
  the owner's private CloudKit database, or any network access the app should
  not make
- Another app, extension or process reading documents through the app group,
  the share extension's queue or files the app writes
- Document content, titles, names or paths in system logs (the app's logging
  rules: [docs/development/index.md](docs/development/index.md#logging))
- Documents of one iCloud account reaching another account
- Deleting documents permanently without the owner's confirmation

Out of scope:

- Attacks that need a jailbroken device or physical access to an unlocked
  device
- The security of iCloud, CloudKit or the operating system themselves
- Vulnerabilities in dependencies without a demonstrated impact on this project
