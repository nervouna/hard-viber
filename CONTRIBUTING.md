# Contributing

Quota is a personal project, but bug reports and fixes are welcome.

## Issues

- **Bugs:** use the bug report form. For a row that shows an error or is missing, include what 诊断 (Diagnostics) in the right-click menu says, and the matching lines of `~/Library/Logs/Quota/collector.log`. Remove account details before you post them.
- **A provider changed its output:** that is a bug too. Say which tool and version you use.
- **Security problems:** report them privately, see [SECURITY.md](SECURITY.md).
- **Feature ideas and new providers:** open an issue to discuss it first.

## How the project is developed

Most of the code is written by AI coding agents on branches merged into `main`. [CLAUDE.md](CLAUDE.md) holds the rules they follow; they apply to human contributions too. In short:

- `scripts/test.sh` passes (the Node suites and `swift test`), and `bash scripts/build.sh` builds. Run both before you send a change.
- `scripts/subscriptions.json` is the only list of rows and their labels; never hard-code row ids, names or plans in Swift or JavaScript.
- Tools are searched for, never assumed at one path. Check discovery the way an app opened from Finder sees it: `env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin node scripts/collect-usage.mjs`.
- Keep the merge rules and the refresh policy pure functions with tests.
- The interface text is Chinese. Code, comments, docs and commit messages are English.
- Commit messages follow Conventional Commits in lowercase, for example `fix: keep the last value while a refresh runs`.
- Never commit signing settings; `scripts/release.sh` reads them from outside the repository.

## Pull requests

Describe the change, list the commands you ran and their results, and note anything you could not check, such as a provider tool you do not have.
