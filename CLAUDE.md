# CLAUDE.md — AI Assistant Guide for Common

This file provides guidance for AI assistants (Claude and others) working in this repository.

## Repository Overview

**Name:** Common
**Owner:** L-Manning
**Purpose:** A shared common utilities/modules repository (currently in early setup).
**State:** Newly initialized — no application code exists yet. This is the starting point.

## Repository Structure

```
Common/
├── CLAUDE.md        # This file — AI assistant guide
└── README.md        # Project overview
```

As the project grows, update this structure diagram to reflect new directories and files.

## Git Workflow

### Branch Naming

Feature branches follow the convention:

```
claude/<description>-<session-id>
```

Example: `claude/add-claude-documentation-pn4c3`

The default/primary branch is `main` (on the remote) and `master` (local alias).

### Commit Messages

Write clear, descriptive commit messages in the imperative mood:

```
Add authentication middleware
Fix null pointer in user service
Update README with setup instructions
```

### Push Commands

Always push with tracking:

```bash
git push -u origin <branch-name>
```

If a push fails due to network errors, retry with exponential backoff: 2s → 4s → 8s → 16s (up to 4 retries).

### Pull Requests

- Develop on a feature branch
- Keep commits focused and atomic
- Push when changes are complete

## Development Conventions

Since this repository has no established stack yet, the following conventions should be adopted when code is added:

### General

- Prefer clarity over cleverness
- Keep functions small and single-purpose
- Avoid over-engineering — solve the current problem, not hypothetical future ones
- Do not add features or abstractions beyond what is explicitly requested

### Adding New Code

When the first code is added to this repo:
1. Update this CLAUDE.md with the language/framework used
2. Document build, test, and lint commands in the **Commands** section below
3. Update the repository structure diagram above

### File Organization

- Group related files in clearly named directories
- Keep configuration at the project root
- Place shared utilities in a `common/` or `lib/` subdirectory

## Commands

> No build system or tooling is configured yet. Update this section when a language/framework is chosen.

Placeholder for future commands:

```bash
# Install dependencies
# <command here>

# Run tests
# <command here>

# Lint/format
# <command here>

# Build
# <command here>
```

## Security Notes

- Never commit secrets, credentials, API keys, or tokens
- Use environment variables for sensitive configuration
- Do not log sensitive data

## Working with This Repository

### For AI Assistants

1. **Read before editing** — always read a file before modifying it
2. **Minimal changes** — only change what is necessary; do not refactor surrounding code
3. **No speculative features** — only implement what is explicitly requested
4. **Commit clearly** — write commit messages that describe what changed and why
5. **Push to the right branch** — confirm the branch name before pushing; it must start with `claude/`
6. **Ask before destructive operations** — deletion, force pushes, and branch resets require explicit user approval

### Questions to Answer Before Starting Work

- What branch should I develop on?
- Are there existing tests I should run before and after my changes?
- Is there a linter or formatter I should run?

As tooling is added to this repo, update this CLAUDE.md with the answers.

## Updating This File

Keep CLAUDE.md current as the project evolves:

- When new directories or major modules are added, update the structure diagram
- When build/test/lint commands are established, fill in the Commands section
- When new conventions are adopted, document them here
