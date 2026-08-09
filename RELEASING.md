# Versioning and releases

Insightful uses Semantic Versioning. The release number has three parts in the form `MAJOR.MINOR.PATCH`.

- Use a patch release for a compatible fix, such as `0.1.0` to `0.1.1`.
- Use a minor release for a compatible feature, such as `0.1.1` to `0.2.0`.
- Use a major release for a change that breaks existing behavior or settings, such as `0.2.0` to `1.0.0`.

The `VERSION` file is the release version. KOReader also needs a literal version in `_meta.lua`, so the bump script updates both files and the checks reject any mismatch.

## Commit messages

Use Conventional Commit prefixes so the history explains the type of change.

- Use `fix: ...` for a compatible fix.
- Use `feat: ...` for a compatible feature.
- Use `feat!: ...` or a `BREAKING CHANGE:` footer for an incompatible change.
- Use `docs: ...`, `test: ...`, `refactor: ...`, or `chore: ...` when the change does not set the next release size by itself.

Keep the version bump in its own commit. For example, a patch release can use the following commands.

```sh
./scripts/bump-version.sh patch
./scripts/test.sh
./scripts/package.sh
git add VERSION _meta.lua
git commit -m "chore(release): v0.1.1"
git tag -a v0.1.1 -m "Insightful v0.1.1"
git push origin main v0.1.1
```

Use `minor` or `major` instead of `patch` when needed. You can also set an exact version, including a prerelease version.

```sh
./scripts/bump-version.sh 0.2.0-beta.1
```

Do not move a published tag. Make another patch release when a release needs a correction.

## Release checks

A tag named `vX.Y.Z` starts the release workflow. The workflow checks that the tag, `VERSION`, and `_meta.lua` agree. It then runs the host tests and parses every Lua file.

The workflow creates `insightful.koplugin-vX.Y.Z.zip` and a SHA-256 checksum. The ZIP contains one top level directory named `insightful.koplugin`, and it never contains the private `configuration.lua` file.

GitHub marks tags with a prerelease suffix as prereleases. Stable tags create stable releases.

## ZenPM compatibility

ZenPM reads GitHub release metadata for KOReader plugins. The release ZIP follows its current rules:

- The GitHub release has a semantic version tag.
- The release has one installable ZIP asset.
- The ZIP contains the `insightful.koplugin` directory.
- The installed `_meta.lua` version matches the release.
- GitHub supplies the asset digest, and the workflow also publishes a checksum file.

ZenPM's public catalog has its own discovery rules. A compatible release can still be installed from a custom ZenPM source before the repository qualifies for the public catalog.
