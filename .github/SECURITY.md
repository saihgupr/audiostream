# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| Latest  | ✅        |
| Older   | ❌        |

AudioStream is a personal jailbreak utility. Only the latest release receives security attention.

## Reporting a Vulnerability

**Please do not file public GitHub Issues for security vulnerabilities.**

To report a security issue responsibly, use **GitHub Private Vulnerability Reporting**:

1. Go to the [Security tab](https://github.com/saihgupr/AudioStream/security) of this repository.
2. Click **"Report a vulnerability"** to open a private advisory draft.
3. Describe the issue with as much detail as possible (steps to reproduce, impact, affected versions).

You can expect an acknowledgement within **5 business days**. We will work with you to understand and address the issue before any public disclosure.

## Scope

This project runs exclusively on **jailbroken iOS devices** in a personal, local-network context. Relevant security concerns include:

- Unauthenticated HTTP endpoints exposed on the local network
- Sensitive file access via the daemon (`audiostreamerd`)
- Hardcoded credentials or secrets in scripts

Thank you for helping keep AudioStream safe.
