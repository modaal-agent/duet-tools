# Contributing

- **Docs state the present rule, not the transition.** README sections and
  verb help text are forward-looking: state what the verb does and the action
  the reader takes. Do not frame behavior as a replacement of past practice
  ("X replaces Y", "previously", "no longer") — the reader has no such past.
  Historical contrast belongs in `CHANGELOG.md` and commit messages, where
  the change itself is the subject.
- **CHANGELOG entries describe the CLI surface in its own terms.** An entry
  names the verb or flag and its observable behavior; it does not cite
  external planning documents.
- **A release cut sets the version in the commit that gets tagged** (the
  family convention — see the `duet` repo's CONTRIBUTING, rule 7). The version
  of record is `duetToolsVersion` in `Sources/duet/main.swift`; `duet version`
  and every `--json` report are stamped with it.
- **Pushing a bare semver tag publishes the prebuilt binary** (`release`
  workflow): it refuses to publish when the tag and `duetToolsVersion`
  disagree, and attaches `duet-macos-arm64.zip` and its `.sha256` to that
  tag's Release. To publish the asset for a tag that already exists, run the
  workflow manually and give it the tag.
- **Licensing**: MIT, inbound = outbound; submitting a PR means your
  contribution is licensed under the [MIT License](LICENSE).
