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

That said, the `source=...` part of each mount line is interpreted **by the Docker daemon on the host**, not by the container. On plain Docker-in-WSL2, the daemon is a Linux process inside your WSL distro and only sees real Linux paths — `/mnt/d/...` for Windows drives. On Docker Desktop, the daemon lives in a separate WSL distro and understands the WSL automount form directly — `/d/...` for Windows drives. The container never sees any of this; it only ever sees the `target=` path you choose (e.g. `/workspaces/myrepo`).

**1. Declare the host repos you want in `.devcontainer/devcontainer.json`:**

```jsonc
{
  "image": "ghcr.io/stratakit/devcontainer:latest",
  "mounts": [
    "source=${localEnv:HOME}/code/repo-one,target=/workspaces/repo-one,type=bind,consistency=cached",

    // Docker Desktop (WSL2 backend) — use the WSL automount form:
    "source=/d/repos/myrepo,target=/workspaces/myrepo,type=bind,consistency=cached",

    // Plain Docker-in-WSL — use the /mnt/d/... form (the daemon can't resolve /d/...):
    // "source=/mnt/d/repos/myrepo,target=/workspaces/myrepo,type=bind,consistency=cached",
  ],
}
```

- The `source` can be any host path — anywhere Docker can bind-mount from. The paths above sit under `$HOME` (the common case), but `~/projects/somewhere/deep/repo-three` shows you can nest as deep as you need under `HOME`. Anything under `${localEnv:HOME}` is portable across hosts and users.
- For repos **outside** `$HOME`, use an absolute path — but **the form of the path must match what the Docker daemon sees on the host**, not what your shell sees. The container itself never sees any of these paths; it only ever sees the `target=` path you assign. Common footguns:
  - **WSL2 + plain Docker Engine in your distro** (the daemon is in your default WSL distro): use the Linux path the daemon can read, e.g. `/mnt/d/repos/myrepo`. Windows-style drive letters like `/d/repos/myrepo` only exist because WSL's `automount` synthesises them inside your shell — they aren't real Linux paths to the daemon, so the bind will fail. Pass the `/mnt/...` form directly.
  - **WSL2 + Docker Desktop** (daemon lives in the hidden `docker-desktop` WSL distro): use the WSL-style path, e.g. `/d/repos/myrepo`. Docker Desktop understands the WSL automount form (`/d/...`) directly here — it's the path the daemon actually sees for your Windows drives, and is shorter to type than the `/mnt/d/...` equivalent.
  - **VS Code on Windows, Docker Desktop on Windows** (no WSL): use the Windows path, e.g. `C:\Users\you\elsewhere\repo-four`, or any drive letter like `D:\repos\repo-four`.
  - **macOS Docker Desktop**: `/Users/you/elsewhere/repo-four` or `/Volumes/external/repo-four`.
  - **Linux, native Docker**: any absolute path the daemon can read, e.g. `/srv/repos/repo-four`.

  Quick sanity check — run on the host (in WSL if you're in WSL). This exercises the daemon's view of the path, exactly like the devcontainer's bind mount will. Pick the form that matches your setup:

  ```bash
  # Docker Desktop (WSL2 backend):
  docker run --rm -v /d/repos/myrepo:/test alpine test -d /test && echo OK

  # Plain Docker-in-WSL:
  # docker run --rm -v /mnt/d/repos/myrepo:/test alpine test -d /test && echo OK
  ```

  If that prints `OK`, the path is bindable; if it errors, the daemon can't see that exact path and the bind-mount in your devcontainer will fail the same way.

  > **Heads-up on `/d/...` vs `/mnt/d/...`:** they are **not** interchangeable. On **Docker Desktop** (WSL2 backend), use `/d/repos/...` — the daemon understands the WSL automount form and that's what it binds from. On **plain Docker-in-WSL**, use `/mnt/d/repos/...` — the `/d/...` form is just a shell-level symlink that the daemon can't resolve, and the bind will fail. Pick the form that matches your setup above.

- `${localEnv:HOME}` is resolved by Dev Containers on the **host** before the bind is created, so the resulting `source` is a real host path. The `target` is the in-container path you'll use inside the devcontainer.
- `type=bind,consistency=cached` is the standard recipe on Docker Desktop / WSL2. Drop `,consistency=cached` on native Linux.
- Add or remove entries any time; this file lives in **this template repo**, not in your project repos.

**2. Rebuild the container:** `Ctrl+Shift+P` → **Dev Containers: Rebuild Container**.

**3. Open them all in one window.** In VS Code: **File → Add Folder to Workspace…** → `/workspaces/repo-one`, then **Add Folder to Workspace…** → `/workspaces/repo-two`. Save the workspace (**File → Save Workspace As…**) and you'll have one editor window with shared terminals, search, git UI, and the agent runtime — across every mounted repo.

That's it. Edits on either side hit the same files; no clones, no `.devcontainer/` in your project repos.

### Option C — Per-repo isolated devcontainers (rarely needed)

If you want each project in its **own** devcontainer (truly isolated, separate processes/ports/state per repo), the Dev Containers extension can do that — but every repo needs its own `devcontainer.json` pointing at the image. Skip this unless you specifically need isolation; Option B is almost always the right answer.

## Installing on a Windows host

If you want the same opencode + omo configuration on a bare **Windows host** (no WSL, no devcontainer — running `opencode` directly on Windows), use the bundled PowerShell installer. It pulls the same gist the devcontainer's `post-create.sh` uses, and writes the same files into `%USERPROFILE%`.

**Prerequisites:**

- **PowerShell 7+** (`pwsh`). Windows PowerShell 5.1 (the default on Windows 10) is not supported. Install with `winget install Microsoft.PowerShell` or from <https://github.com/PowerShell/PowerShell/releases>.
- **git** (recommended) or curl.exe (Windows 10 1803+ ships it; or bundled with `git for Windows`). The script falls back to `Invoke-WebRequest` if neither is installed.
- A `.env` file with `OPENCODE_BASE_URL` and `OPENCODE_API_KEY` (see [Configuration](#configuration) below for the search order).

**Run it:**

```powershell
# From a clone of this template, or any directory that has the .devcontainer folder:
pwsh -ExecutionPolicy Bypass -File .\.devcontainer\omo-installer-win-host.ps1

# If substitution fails silently, add -ShowDetails to see the actual jq error
# and a file-lock diagnostic (OneDrive sync, antivirus, or a running opencode
# process are the usual suspects):
pwsh -ExecutionPolicy Bypass -File .\.devcontainer\omo-installer-win-host.ps1 -ShowDetails
```

The installer is idempotent — re-running it purges old variants and re-installs the current gist contents. It does **not** modify the registry, environment variables, or anything outside `%USERPROFILE%`.

**What it installs:**

| File                                                | Purpose                                          |
| --------------------------------------------------- | ------------------------------------------------ |
| `%USERPROFILE%\.config\opencode\opencode.json`      | opencode config (provider, model list, plugins)  |
| `%USERPROFILE%\.local\share\opencode\auth.json`     | opencode auth (your LLM API key)                 |
| `%USERPROFILE%\.omo\omo.json`                       | omo category/agent/team configuration            |

After install, run `opencode` from PowerShell or CMD. To uninstall, just delete those three directories.

**Differences from the devcontainer install:**

- The Windows installer does **not** create a devcontainer — it only configures opencode. If you want the full toolchain (node, bun, gh, etc.), use the devcontainer (Options A/B above).
- Substitutions are the same: `$env:OPENCODE_BASE_URL` and `$env:OPENCODE_API_KEY` in a `.env` (search order matches the bash installer exactly).
- The installer does **not** run on every shell start; re-run it manually if you change the gist.

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

Container-side scripts (run inside the devcontainer) are environment-only — they write to `$HOME`, never to `/workspace`.

| Script                            | Runs                        | Purpose                                                                  |
| --------------------------------- | --------------------------- | ------------------------------------------------------------------------ |
| `on-create.sh`                    | Once, on container creation | Git config, SSH/Claude credential checks, `safe.directory=/workspace`    |
| `post-create.sh`                  | Once after `on-create`      | Install `oh-my-opencode`, bootstrap opencode config from the public gist |
| `omo-installer.sh`                | Manual (any time)           | Re-run the devcontainer-side install (purge + reinstall from gist)       |
| `omo-installer-win-host.ps1`      | Manual, on a Windows host   | Windows host install — same gist, no devcontainer required               |

`omo-installer.sh` and `omo-installer-win-host.ps1` are paired: the `.sh` runs in a Linux devcontainer, the `.ps1` runs on a bare Windows host. They both pull the same gist and produce the same three config files. Anything that should run on every container start belongs in the image itself (a `Dockerfile` layer), not in a lifecycle hook.

## Updating the image

`.devcontainer/` is the source of truth. To publish a new image:

```bash
docker build -t ghcr.io/stratakit/devcontainer:latest .devcontainer
docker push ghcr.io/stratakit/devcontainer:latest
```

Consumers pick up the change on their next container rebuild.

## License

MIT.
