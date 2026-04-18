# Security Policy

## Supported Versions

| Version | Supported          |
|---------|--------------------|
| latest  | :white_check_mark: |

## Reporting a Vulnerability

If you discover a security vulnerability in this project, please report it responsibly.

**Do NOT open a public GitHub issue for security vulnerabilities.**

Instead, please use one of the following methods:

1. **GitHub Private Vulnerability Reporting**: Use the [Security tab](https://github.com/pichuang/deadman-pwsh/security/advisories/new) to report a vulnerability privately.
2. **Email**: Contact the maintainer directly.

### What to include

- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

### Response timeline

- **Acknowledgment**: Within 48 hours
- **Initial assessment**: Within 7 days
- **Fix or mitigation**: Dependent on severity

### Scope

This project is a host monitoring tool using ICMP/TCP ping. Security concerns may include:

- Command injection via configuration file parsing
- Unintended code execution
- Information disclosure through log files
- Denial of service through resource exhaustion

## Security Best Practices for Users

- Run with least-privilege permissions
- Use TCP ping (which requires elevated privileges) only when necessary
- Restrict access to configuration files and log directories
- Review configuration files before use, especially from untrusted sources
