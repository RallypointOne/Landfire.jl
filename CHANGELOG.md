## Unreleased

## v0.1.3

### Fixes

- Fix version string comparison that crashed on LANDFIRE's non-semver version strings (e.g., "LF2024"). Now uses year extraction instead of `VersionNumber` parsing.

