# Development

- Run tests: `julia --project -e 'using Pkg; Pkg.test()'`
- Build docs: `quarto render docs`
- Quarto YAML reference: https://quarto.org/docs/reference/
- Never edit Project.toml or Manifest.toml manually — use Pkg

# Docs Sidebar

- `api.qmd` must always be the last item before the "Reference" section in `_quarto.yml`
- `api.qmd` lives in its own `part: "API"` to visually separate it from other doc pages
- `index.qmd` must always begin with `## Overview` and `## Quickstart` sections

# Style

- 4-space indentation
- Docstrings on all public names
- Use `### Examples` for inline docs examples
- Segment code sections with `#-----------------------------------------------------------------------------# Title`

# Releases

- Preflight: tests must pass and git status must be clean
- If current version has no git tag, release it as-is (don't bump)
- If current version is already tagged, bump based on commit log:
  - **Major**: major rewrites (ask user if major bump is ok)
  - **Minor**: new features, exports, or API additions
  - **Patch**: fixes, docs, refactoring, dependency updates (default)
- Commit message: `bump version for new release: {x} to {y}`
- Generate release notes from commits since last tag (group by features, fixes, etc.)
- For major/minor bumps, release notes must include "breaking changes" section
- Update CHANGELOG.md with each release (prepend new entry under `# Unreleased` or version heading)
- Register via:
  ```
  gh api repos/{owner}/{repo}/commits/{sha}/comments -f body='@JuliaRegistrator register

  Release notes:

  <release notes here>'
  ```
