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

### Option B — Share the devcontainer across your existing host repos

The devcontainer is just a Linux shell with your toolchains pre-installed. **One container, many repos** — bind-mount any folder from your host into the container, and work on it without cloning or adding a `.devcontainer/`.

**Important:** because this image runs Docker-in-Docker, the **container** has its own filesystem and the host is **not** reachable from inside the container via `/mnt/...` or any other path. Host paths only enter the container through the explicit `mounts` entries below — that's how Dev Containers wires bind mounts across the DinD boundary.

That said, the `source=...` part of each mount line is interpreted **by the Docker daemon on the host**, not by the container. On plain Docker-in-WSL2, the daemon is a Linux process inside your WSL distro and _can_ see `/mnt/d/...` — that's the path it binds from. On Docker Desktop, the daemon lives in a separate WSL distro and likewise sees `/mnt/d/...`. The container never sees `/mnt`; it only ever sees the `target=` path you choose (e.g. `/workspaces/umactually`).

**1. Declare the host repos you want in `.devcontainer/devcontainer.json`:**

```jsonc
{
  "image": "ghcr.io/stratakit/devcontainer:latest",
  "mounts": [
    "source=${localEnv:HOME}/code/repo-one,target=/workspaces/repo-one,type=bind,consistency=cached",
    "source=/mnt/d/repos/umactually,target=/workspaces/umactually,type=bind,consistency=cached",
  ],
}
```

- The `source` can be any host path — anywhere Docker can bind-mount from. The paths above sit under `$HOME` (the common case), but `~/projects/somewhere/deep/repo-three` shows you can nest as deep as you need under `HOME`. Anything under `${localEnv:HOME}` is portable across hosts and users.
- For repos **outside** `$HOME`, use an absolute path — but **the form of the path must match what the Docker daemon sees on the host**, not what your shell sees. The container itself never sees any of these paths; it only ever sees the `target=` path you assign. Common footguns:
  - **WSL2 + plain Docker Engine in your distro** (the daemon is in your default WSL distro): use the Linux path the daemon can read, e.g. `/mnt/d/repos/umactually`. Windows-style drive letters like `/d/repos/umactually` only exist because WSL's `automount` synthesises them inside your shell — they aren't real Linux paths, and some Docker versions try to "fix" them to `/mnt/d/...` which then fails. Pass the `/mnt/...` form directly.
  - **WSL2 + Docker Desktop** (daemon lives in the hidden `docker-desktop` WSL distro): same rule — use `/mnt/d/repos/umactually`. The daemon mounts your distro's filesystem in, so `/mnt/...` is what it actually sees.
  - **VS Code on Windows, Docker Desktop on Windows** (no WSL): use the Windows path, e.g. `C:\Users\you\elsewhere\repo-four`, or any drive letter like `D:\repos\repo-four`.
  - **macOS Docker Desktop**: `/Users/you/elsewhere/repo-four` or `/Volumes/external/repo-four`.
  - **Linux, native Docker**: any absolute path the daemon can read, e.g. `/srv/repos/repo-four`.

  Quick sanity check — run on the host (in WSL if you're in WSL). This exercises the daemon's view of the path, exactly like the devcontainer's bind mount will:

  ```bash
  docker run --rm -v /mnt/d/repos/umactually:/test alpine test -d /test && echo OK
  ```

  If that prints `OK`, the path is bindable; if it errors, the daemon can't see that exact path and the bind-mount in your devcontainer will fail the same way.

  > **Heads-up on `/d/...` vs `/mnt/d/...`:** some Docker versions silently rewrite `/d/...` to `/mnt/d/...` for you. That's convenient on Docker Desktop and broken on plain Docker-in-WSL — so always write the explicit `/mnt/d/...` form to make it portable and avoid the surprise.

- `${localEnv:HOME}` is resolved by Dev Containers on the **host** before the bind is created, so the resulting `source` is a real host path. The `target` is the in-container path you'll use inside the devcontainer.
- `type=bind,consistency=cached` is the standard recipe on Docker Desktop / WSL2. Drop `,consistency=cached` on native Linux.
- Add or remove entries any time; this file lives in **this template repo**, not in your project repos.

**2. Rebuild the container:** `Ctrl+Shift+P` → **Dev Containers: Rebuild Container**.

**3. Open them all in one window.** In VS Code: **File → Add Folder to Workspace…** → `/workspaces/repo-one`, then **Add Folder to Workspace…** → `/workspaces/repo-two`. Save the workspace (**File → Save Workspace As…**) and you'll have one editor window with shared terminals, search, git UI, and the agent runtime — across every mounted repo.

That's it. Edits on either side hit the same files; no clones, no `.devcontainer/` in your project repos.

### Option C — Per-repo isolated devcontainers (rarely needed)

If you want each project in its **own** devcontainer (truly isolated, separate processes/ports/state per repo), the Dev Containers extension can do that — but every repo needs its own `devcontainer.json` pointing at the image. Skip this unless you specifically need isolation; Option B is almost always the right answer.

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
