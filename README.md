<div align="center">


# DevStore

**Native macOS manager for development environments that live in their own mountable APFS volumes.**

English | [简体中文](README.zh-CN.md)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square)](LICENSE)
![Swift](https://img.shields.io/badge/Swift-6.2+-F05138?style=flat-square&logo=swift&logoColor=white)
![Platform](https://img.shields.io/badge/macOS-26+-000000?style=flat-square&logo=apple&logoColor=white)

</div>

SDKs, package managers and their caches usually spread across your home folder and your main disk. DevStore keeps each environment in one writable APFS sparse bundle, mounted at a fixed path. An environment can sit on an external SSD, be unmounted when you are not using it, and be compacted or archived as a single unit.

DevStore comes with a command line tool, an MCP server for coding agents, and a SwiftUI app.

## Features

- **One volume per environment.** The SDK, tools, state and caches stay together in a writable APFS volume, mounted at `~/.local/dev/<kind>/<slot>`.
- **Multiple slots.** Keep several slots of the same kind and mount them at the same time. The default slot is `current`.
- **Space recovery.** `compact` works on an APFS clone, compares a content digest and only then swaps the images. If anything differs, the original stays untouched.
- **Checkpoints.** `archive` creates a compressed read-only DMG, with optional AES-256 encryption. `export` copies it to cold storage and verifies its SHA-256.
- **Verification.** Each adapter has a test suite that runs sandboxed and offline, and the result is recorded with the image.
- **Plans before changes.** Every change starts as a hashed plan. Only you can approve it, in an interactive terminal, so an agent cannot approve its own plan.
- **Leases.** Leases stop two hosts from using one image. A lease left behind by a reboot is reclaimed automatically; a lease from another host is never removed without your approval.

## Supported environments

| Adapter | Environment | How it gets its SDK |
|---|---|---|
| `miniconda` | Miniconda / conda | `install-sdk`, or `import` an existing image |
| `go` | Go | `install-sdk` with an official `.tar.gz` |
| `rust` | Rust / cargo | `copy-sdk` |
| `dotnet` | .NET | `copy-sdk` |
| `flutter` | Flutter / Dart | `copy-sdk` |
| `android` | Android SDK, NDK and Gradle | `copy-sdk` |
| `empty` | A new empty environment | `create` |

`copy-sdk` only reads the original installation.

## Requirements

- macOS 26 or later
- Swift 6.2 or later, to build from source

## Install

```bash
git clone https://github.com/Kazuma-Kobayashi01/DevStore.git
cd DevStore
scripts/install.sh
```

This builds a release and installs `/Applications/DevStore.app`, plus `devstore` and `devstore-mcp` in `~/.local/bin`. Quit DevStore first if it is running. The app is ad-hoc signed and not notarized.

To register the skill and MCP server with Claude Code and Codex:

```bash
scripts/install-agents.sh
```

## Quick start

```bash
# Register a store: any folder, including one on an external SSD
devstore store add /Volumes/SSD/DevStore --create

# Create an empty environment and mount it
devstore create --store /Volumes/SSD/DevStore --kind go --name "Go" --size 20
devstore mount go/current

# Install the official SDK you downloaded, checked against its SHA-256
devstore install-sdk go/current --installer go1.27.3.darwin-arm64.tar.gz --sha256 <sha256>

# Run a command with the environment's variables
devstore run go/current -- go version

# See what is managed
devstore status
```

An environment can be named by its ID, its `kind/slot` or its display name.

### Approving agent requests

Agents create plans but cannot approve them. Run these yourself in a terminal:

```bash
devstore plans
devstore approve <planId>
```

To allow an agent to mount and unmount one environment without asking each time:

```bash
devstore policy allow go/current
```

## Commands

| Command | Purpose |
|---|---|
| `store add`, `store list` | Register and list stores |
| `create`, `import`, `delete` | Add or remove environments; `delete` moves files to the Trash |
| `install-sdk`, `copy-sdk` | Fill a mounted empty environment |
| `mount`, `unmount` | Attach or detach an environment; unmounting is never forced |
| `run`, `env` | Run a command with the session variables, or print them |
| `verify` | Run the adapter's verification suite |
| `compact`, `archive`, `checkpoints`, `export` | Reclaim space and manage backups |
| `status`, `inspect`, `journal` | Read the current state and history |
| `plans`, `approve`, `reject`, `apply`, `policy` | Manage plans and authorization |
| `lease clear` | Remove a lease that is not in use on this host |

Any command that makes a change accepts `--plan-only [--json]`, which prints the plan without running it. See [CLI and MCP](docs/CLI与MCP.md) (in Chinese) for details.

## Agent integration

`devstore-mcp` speaks JSON-RPC 2.0 over stdio. It exposes read-only tools, tools that create plans, and `devstore_apply`, which only runs with your approval or a policy. No tool can approve a plan.

`devstore run` is not a security boundary. `--confine` blocks reads of the original installs, and the approval check relies on `isatty`, so it stops accidental self-approval rather than a malicious local process.

## Development

```bash
swift build
swift test
DEVSTORE_INTEGRATION=1 swift test   # also runs against real hdiutil
scripts/build-app.sh                # builds build/DevStore.app
```

| Path | Contents |
|---|---|
| `Sources/DevStoreCore` | Data model, adapters, operations, authorization and verification |
| `Sources/devstore` | Command line tool |
| `Sources/DevStoreMCP`, `Sources/devstore-mcp` | MCP server |
| `Sources/DevStoreApp` | SwiftUI app |
| `skills/devstore` | Agent skill |
| `docs` | Design records, experiment reports and issues (in Chinese) |

Start with the [documentation index](docs/README.md) and the [current design](docs/reports/单卷独立环境挂载方案-v3.md).

## License

[MIT](LICENSE)
