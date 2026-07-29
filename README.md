# Devcontainer Docker-in-Docker Template

A reusable, language-agnostic devcontainer. Spin up a pre-built container — CLI tooling, language runtimes, and the `oh-my-opencode` agent runtime — and work on **any** repo inside it without modifying that repo.

Published image: `ghcr.io/stratakit/devcontainer:latest`

## What's inside

- **Shell:** zsh (default), bash available
- **Toolchains:** node, pnpm, bun, python, gh, docker CLI
- **Agent runtime:** [`oh-my-opencode`](https://github.com/code-yeongyu/oh-my-opencode) + canonical opencode config installed at `$HOME/.config/opencode/`
- **VS Code extensions:** Prettier, Copilot, Error Lens, Path Intellisense, Code Spell Checker, Dotenv, Pretty TS Errors, Iconify, Docker
- **Git:** `core.autocrlf=input`, `core.eol=lf`, `safe.directory=/workspace`, `init.defaultBranch=main`

## Usage

### Option A — Use this template for a new repo

1. Click **"Use this template"** on GitHub.
2. Clone your new repo and open it in VS Code:
   ```bash
   git clone https://github.com/you/your-new-repo
   cd your-new-repo
   code .
   ```
3. When prompted, click **"Reopen in Container"**.

The new repo inherits `.devcontainer/` pointing at the published image. VS Code pulls the image, starts the container, and bind-mounts your repo at `/workspace`.

### Option B — Use the image on an existing repo (without modifying it)

```bash
git clone https://github.com/some/existing-repo
code existing-repo
```

In VS Code: `Ctrl+Shift+P` → **Dev Containers: Clone Repository in Container Volume...** → pick the same repo. The repo is cloned into a Docker volume (no `.devcontainer/` is added). Or use the CLI:

```bash
devcontainer up --image ghcr.io/stratakit/devcontainer:latest /path/to/cloned-repo
```

## Configuration

### `.env` for the agent runtime

`post-create.sh` substitutes `OPENCODE_BASE_URL` and `OPENCODE_API_KEY` into the installed opencode config. Drop a `.env` at any of these locations — first one found wins:

1. `$HOME/.env`
2. `<repo>/.devcontainer/.env`
3. `<repo>/.env`
4. `./.env`

Copy `.env.example` to get started:

```bash
cp .env.example .env
# then edit .env
```

Keep `.env` out of git (it's in `.gitignore`).

### Local overrides

Anything matching `.devcontainer/*.local.*` or `.devcontainer/local-*` is gitignored. Drop a `.devcontainer/local-overrides.sh` for personal tweaks without affecting anyone else.

### Host tooling (lazydocker)

Since the container runs Docker-in-Docker, it has its own daemon and can only see its own containers — not those the host manages. To manage host-side containers (including the devcontainer itself), install [`lazydocker`](https://github.com/jesseduffield/lazydocker) on the **host** (your WSL distro, not inside the devcontainer):

```bash
curl https://raw.githubusercontent.com/jesseduffield/lazydocker/master/scripts/install_update_linux.sh | bash
```

Run `lazydocker` from WSL; it'll talk to the host Docker daemon and show the devcontainer alongside everything else.

## Lifecycle scripts

Both scripts are environment-only — they write to `$HOME`, never to `/workspace`.

| Script           | Runs                        | Purpose                                                                  |
| ---------------- | --------------------------- | ------------------------------------------------------------------------ |
| `on-create.sh`   | Once, on container creation | Git config, SSH/Claude credential checks, `safe.directory=/workspace`    |
| `post-create.sh` | Once after `on-create`      | Install `oh-my-opencode`, bootstrap opencode config from the public gist |

Anything that should run on every container start belongs in the image itself (a `Dockerfile` layer), not in a lifecycle hook.

## Updating the image

`.devcontainer/` is the source of truth. To publish a new image:

```bash
docker build -t ghcr.io/stratakit/devcontainer:latest .devcontainer
docker push ghcr.io/stratakit/devcontainer:latest
```

Consumers pick up the change on their next container rebuild.

## License

MIT.
