# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability, please report it privately via
[GitHub Security Advisories](https://github.com/truvity/ci-workflows/security/advisories/new).

Do NOT open a public issue for security vulnerabilities.

## Supported Versions

Only the latest release is supported with security updates.

## What is in scope

This repository publishes:

- The reusable workflows: `check`, `integration`, `release-public`, `release-private`, `auto-release`, `renovate-fleet` and `parity-fleet`.
- The shared renovate preset, `default.json`.
- The documentation, where it tells an adopter to grant a permission or pass a secret it should not.

Reports that matter most:

- A workflow that asks the caller for wider permissions than it uses, or lets a pull request from a fork reach a credential.
- Injection: an input or event field interpolated into a `run:` step, so that a branch name or pull request title runs code.
- A token, key or secret reaching a log, an artifact, a cache or a pull request comment, including the App keys of the fleet jobs and the release credentials.
- A gate that passes what it should refuse, or `auto-release` cutting a tag it should not.

A finding that depends on how a particular deployment uses this repository
belongs with that deployment's owner.
