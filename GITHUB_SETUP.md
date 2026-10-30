# Pip repository workflow

Clone the source into any local folder. The `desktop/` directory contains native
macOS code; it is not a path to a user's Desktop.

Use a feature branch and a pull request into `master`, the default branch.
Follow CONTRIBUTING.md for setup, validation and contribution steps. The
repository's `.gitignore` excludes runtime data, install plans, builds and the old
provider artwork. The original Pip mascot is included.

From a clean checkout, create a contribution branch:

```sh
git switch master
git pull --ff-only
git switch -c feature/describe-your-change
```

After making and checking the change, stage the intended files, commit, push
the branch, and open a PR into `master`. Use `.github/pull_request_template.md`
as an outline.

The repository owner can invite developers through collaborator settings.
If the GitHub plan supports protected branches in private repositories, configure
`master` to require reviewed PRs and resolved review conversations, with force
pushes and branch deletion disabled. Private-repository branch protection requires
GitHub Pro, Team or Enterprise. See
[GitHub's documentation](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches).

The GitHub Actions workflow `.github/workflows/pip-session-links.yml` runs the VS Code helper and
TypeScript app checks on Windows and macOS, plus the native Mac checks on macOS, for pull requests
that touch those areas. Contributors also run `./scripts/check.sh` from the repository root and
include results in their PR.
