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
  family convention — see the `duet` repo's CONTRIBUTING, rule 7).
- **Licensing**: MIT, inbound = outbound; submitting a PR means your
  contribution is licensed under the [MIT License](LICENSE).
