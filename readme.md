# wkhtmltopdf Builder

This project builds [wkhtmltopdf](https://github.com/wkhtmltopdf/wkhtmltopdf) and
its companion `wkhtmltoimage` as **fully static x86-64 (musl) executables**. The
resulting binaries have zero shared-library dependencies — the C library (musl),
libstdc++, the patched Qt, fontconfig, freetype, expat, OpenSSL, zlib, libpng,
libjpeg and the X11 client stack are all linked statically. Because they are
built against musl, they resolve DNS without `nss`, so remote URLs work out of
the box, and they run on any x86-64 Linux distribution regardless of its libc.

The official wkhtmltopdf binaries are no longer maintained, and a fully static
build is convenient to drop into minimal container images and other environments
where matching shared libraries are not available.

## Why Alpine 3.10

The build **must** run inside an **Alpine 3.10** container — no other version
works. Alpine 3.10 ships GCC 8.3, and the patched Qt 4.8.7 that wkhtmltopdf
0.12.5 depends on does not compile cleanly with GCC 9 or newer. Newer Alpine
releases also drop or change the static libraries and toolchain the build relies
on. The version is therefore pinned both here and in the build script.

Everything else the build needs (including the wkhtmltopdf source itself and all
static dependencies) is downloaded and compiled from source by
[`build.sh`](build.sh); Alpine 3.10 provides almost no `*-static` packages, so
the dependencies are built rather than installed.

## Building

### Using Docker (recommended)

The build script is designed to run inside an Alpine 3.10 container, exactly as
the CI does:

```sh
docker run --rm \
  -v "$PWD:/workspace" \
  -w /workspace \
  alpine:3.10 \
  ./build.sh
```

The static `wkhtmltopdf` and `wkhtmltoimage` binaries are written to `./out`.

### Configuration

`build.sh` reads a number of environment variables (all optional, with sensible
defaults). The most useful ones:

| Variable               | Default                | Description                                  |
|------------------------|------------------------|----------------------------------------------|
| `WKHTMLTOPDF_VERSION`  | `0.12.5`               | wkhtmltopdf git tag/branch to build          |
| `WKHTMLTOPDF_REPO`     | upstream GitHub repo   | Source repository to clone from              |
| `SRC_DIR`              | `/tmp/wkhtmltopdf`     | Existing checkout to build (skips the clone) |
| `OUT_DIR`              | `$(pwd)/out`           | Where the finished binaries are written      |

The dependency versions (OpenSSL, zlib, libpng, libjpeg, freetype, fontconfig,
the X11 libraries, …) are pinned at the top of `build.sh` and can likewise be
overridden via environment variables. See the comments in the script for why the
defaults are chosen (several are matched to wkhtmltopdf's own
`packaging/conanfile.txt` so the linked set matches the official static builds).

### Continuous integration

Every push and pull request triggers the
[`Build`](.github/workflows/build.yml) workflow, which runs `build.sh` inside an
Alpine 3.10 container on GitHub Actions and uploads the resulting binaries as a
build artifact.

## Contributing

### Updating the Changelog

The changelog is maintained in the [changelog.md](changelog.md) file, following
the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format. The
changelog is updated incrementally. That is, for every new feature or bugfix,
add an entry to the changelog under the `[Unreleased]` section using an
appropriate sub header (`Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`,
or `Security`).

For example, when adding a new feature:

```markdown
## [Unreleased]
### Added
- Short description of the new feature
```

Entries under these sub headers determine the semantic version bump when the
next release is cut with [relog](https://github.com/jacob-carlborg/relog).

### Creating a New Release

Releases are cut with [relog](https://github.com/jacob-carlborg/relog), driven
by the `[Unreleased]` section of `changelog.md`. relog derives the next version
from the sub headers under `[Unreleased]`:

* `### Fixed` only -> patch bump
* `### Added`, `### Changed`, `### Deprecated` -> minor bump
* `### Removed` (or "Breaking" anywhere in the section) -> major bump

To cut a release, from a clean `master` working tree, run:

```sh
relog
```

To preview the changes without modifying anything:

```sh
relog --dry-run
```

To override the auto-detected version:

```sh
relog X.Y.Z
```

relog rewrites the changelog, commits the result, creates an annotated `vX.Y.Z`
tag, and prompts before pushing. Pushing the `vX.Y.Z` tag triggers the GitHub
Actions workflow defined in
[`.github/workflows/build.yml`](.github/workflows/build.yml), which builds the
static binaries and, in the "Create Release" step, creates a draft GitHub
release using the newly added changelog section as the release notes. Review the
draft release on GitHub and publish it.
