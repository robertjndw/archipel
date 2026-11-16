# Security policy

## Reporting a vulnerability

Please don't open a public issue for security problems. Report them privately
through [GitHub's private vulnerability reporting](https://github.com/robertjndw/archipel/security/advisories/new)
instead.

Include what you found, how to reproduce it and which version you tested. I'll
try to answer within a week.

## Supported versions

Only the latest release, stable or beta, gets security fixes. Archipel updates
itself, so a fix reaches installed copies with the next release.

## Scope

I'm most interested in:

- The hook socket in `~/Library/Application Support/Archipel`, and anything
  that lets another local process inject agent events or commands.
- The update pipeline: the Sparkle appcast, update signing and the release
  workflow.
- Running project scripts or agent commands that the user didn't ask for.
