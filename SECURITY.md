# Security

Quota runs the command-line tools of your AI providers (Codex, the Grok CLI, the Antigravity CLI and, through Apple's `container`, Kiro) with your account's environment, so they use the credentials they already hold. It reads Claude Desktop's local data, including its HTTP cache, and it runs the executables named in `~/Library/Application Support/Quota/config.json`. It keeps a cache of quota values and a log that can contain the last lines of a tool's error output. It is not sandboxed. Release builds are signed with a Developer ID and notarized.

## Reporting a vulnerability

Please do not open a public issue for a security problem. Report it privately through GitHub: **Security → Report a vulnerability** on this repository ([direct link](https://github.com/nervouna/hard-viber/security/advisories/new)). Include what you did, what happened, your macOS version, and the release or commit you tested.

You will get an answer within a week. Fixes land on `main`; there are no maintained release branches.

## In scope

- A way for a provider tool's output, a cached response or a crafted file to make Quota run something it should not, or crash in a way that can be repeated
- Quota running an executable other than the one it found or the one `config.json` names
- Credentials, account details or Claude Desktop data leaving the Mac through Quota, or ending up in its cache, its log or the shareable image beyond what the list shows
- The cache or the log being readable by other users
- A release build that is not signed and notarized as described

## Out of scope

- Anything that needs an already compromised user account or administrator access, including editing `config.json`, the app bundle or the provider tools
- Vulnerabilities in the provider tools, Claude Desktop or Node.js themselves
- Wrong or missing quota values when a provider changes its output (report those as bugs)
