# Global Claude Code Rules

> **Note:** These rules apply to ALL projects and are inherited globally. For project-specific rules, create a `CLAUDE.md` file in the project root.

---

## Package Management

- **Python**: Always use UV as the package manager for virtual environments, dependency management, installing packages, and running scripts. Never use pip, venv, or other package managers directly.

## Git & Version Control

- Always use conventional commits (e.g., `feat:`, `fix:`, `docs:`, `refactor:`, `chore:`)
- Always commit when work is finished
- Never push unless explicitly told to do so

## Skills

- Proactively check for relevant skills that might help with the current task, even when not explicitly asked
- Skills provide specialized capabilities and domain knowledge - use them whenever applicable
- When a task aligns with an available skill's purpose, invoke it to ensure best practices and consistency
