// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

/// Bumped with each release tag — the tag is the version of record (pre-1.0
/// minors are breaking by family convention: a new or changed gate is a minor).
/// The release workflow refuses to publish a tag that disagrees with this
/// constant.
///
/// Lives in its own file, not main.swift: a top-level global in a main file
/// initializes only when the top-level code runs, so under XCTest it would be
/// read uninitialized — every `--json` report stamps it via `emitJSON`.
let duetToolsVersion = "0.16.0"
