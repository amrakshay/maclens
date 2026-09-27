# Security Policy

MacLens can terminate processes and delete files, so safety bugs matter. That includes:
- a way around the deletion guard or kill policy,
- deleting something that isn't what the user confirmed,
- privilege problems.

## Reporting a vulnerability

Please **don't open a public issue**.
- Use GitHub's private reporting: **Security → Report a vulnerability** on this repository.
- Include:
  - macOS version and MacLens version,
  - steps to reproduce,
  - what you expected and what happened.
- You'll get an acknowledgement within a few days. Fixes are released as soon as practical, and reporters are credited unless they'd rather not be.

## Supported versions

Only the latest release gets security fixes.
