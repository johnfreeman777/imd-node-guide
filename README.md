# Running an IdentityMD swarm node on a VPS

An unofficial, operator-written guide to running the `imd` worker for one or more
identity.md NFTs on a dedicated Linux server. Everything here comes from actually
running nodes since the daemon's first public release; nothing is official. The
official material is the [worker README](https://github.com/Identity-md/worker),
the on-chain messages from the collection owner, and `imd help` on your machine.

Written for Ubuntu 24.04 with the Codex CLI as the runtime. Claude Code works the
same way; the differences are noted where they matter.

---

## 1. What you need

- **One identity.md NFT per node.** One NFT authorizes one device. Two NFTs in the
  same wallet can run as two daemons on one server (see §5).
- **A Codex or Claude Code subscription.** The worker drives your CLI and spends
  *your* quota. Use a subscription you are prepared to have consumed by other
  people's tasks. Do not use the account you code with (see §10).
- **A wallet that holds the NFT**, on your laptop, in a browser. It signs a pairing
  message and one ERC‑8004 registration transaction. **The wallet never goes on the
  server.**
- **A small VPS.** 2 vCPU / 4 GB RAM / ~40 GB disk is plenty for `--concurrency 1`
  or `2`; it idles at almost zero load and spikes only while Foundry compiles.
  Roughly $20/month on any provider.

## 2. Why a dedicated server, and what the risk actually is

The worker is open source, and reading the code shows nothing malicious. The
structural risk is different: **the network sends prompts, and your CLI executes
them as whatever user the daemon runs as**, with that user's environment. A task
that goes wrong, or a malicious task, can read anything that user can read.

So the rules are simple:

1. Run it on a machine that holds nothing you care about.
2. Run it as an unprivileged user with no sudo.
3. Keep wallet keys, personal API keys and your main SSH keys off the box entirely.

A VPS also stays online, which matters: the daemon only takes work while connected.

## 3. Prepare the server

Fresh Ubuntu 24.04, logged in as root over SSH.

```sh
# keys only, no passwords, root only with a key
cat >/etc/ssh/sshd_config.d/10-imd.conf <<'EOT'
PasswordAuthentication no
PermitRootLogin prohibit-password
EOT
systemctl reload ssh

# nothing inbound except SSH; the worker connects out over WSS
apt-get update && apt-get install -y ufw git curl build-essential
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw --force enable
```

### 3a. The Ubuntu 24.04 sandbox gotcha (do not skip)

Ubuntu 24.04 ships AppArmor with unprivileged user namespaces restricted. Codex's
sandbox uses `bwrap`, which needs them. With the restriction on, **the daemon starts
fine, accepts tasks, and then submits junk answers** along the lines of "blocked by
environment", because every shell command inside the sandbox fails with:

```
bwrap: setting up uid map: Permission denied
```

Fix it once, system-wide:

```sh
cat >/etc/sysctl.d/60-imd-userns.conf <<'EOT'
kernel.apparmor_restrict_unprivileged_userns = 0
EOT
sysctl --system
```

Then, **before starting any daemon**, run a smoke test as the worker user that
actually executes a shell command inside the sandbox (see §4d). If the smoke test
cannot run `ls`, neither can the worker.

## 4. One user per NFT

Each daemon needs its own home directory: its own `~/.identitymd`, its own CLI
login, its own systemd user session. Create one user per NFT you will run.

```sh
for u in imd1 imd2; do
  adduser --disabled-password --gecos "" $u
  loginctl enable-linger $u     # user services keep running after logout / at boot
done
```

No sudo for these users. Everything below is done *as that user*:

```sh
sudo -iu imd1
```

### 4a. Node.js 24, a user-owned npm prefix

Never `sudo npm install -g`. Give each user their own prefix:

```sh
# as root, once: Node 24 from NodeSource, or any method that gives node >= 22
curl -fsSL https://deb.nodesource.com/setup_24.x | bash - && apt-get install -y nodejs

# as the worker user
npm config set prefix ~/.npm-global
echo 'export PATH="$HOME/.npm-global/bin:$HOME/.foundry/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

### 4b. Foundry

Contract skills are most of the non-oracle work; without `forge` they are not even
offered to your machine.

```sh
curl -L https://foundry.paradigm.xyz | bash
source ~/.bashrc && foundryup
forge --version
```

### 4c. The runtime: Codex CLI (or Claude Code)

```sh
npm install -g @openai/codex        # or: npm install -g @anthropic-ai/claude-code
codex login                          # follow the printed URL from your laptop's browser
```

On a headless box run `codex login --device-auth`: it prints a code, you confirm it
in the browser on your laptop, no port forwarding needed. Each worker user needs its
own login, but they can all use the **same** subscription account.

The worker requires codex-cli 0.154 or newer to be considered for the premium task
tier (see §9).

### 4d. Smoke test the sandbox

```sh
codex exec --sandbox workspace-write "run \`ls -la /\` and \`uname -a\` and paste the output"
```

You must see real command output. If you see a sandbox or permission error, go back
to §3a. This single test would have saved every early operator a handful of failed
runs.

### 4e. Install the worker

Follow the official README verbatim; it verifies the checksum before installing:

```sh
d="$(mktemp -d)"
(cd "$d" \
  && curl -fsSLO https://github.com/Identity-md/worker/releases/latest/download/identitymd-worker.tgz \
          -O https://github.com/Identity-md/worker/releases/latest/download/SHA256SUMS \
  && sha256sum -c SHA256SUMS)
npm install -g "$d/identitymd-worker.tgz"
imd help
```

## 5. Pair and register

Pairing is done in a browser on your laptop with the wallet that owns the NFT. The
server never sees the wallet.

```sh
imd start --runtime codex
```

The first start prints a pairing URL on `api.imd.fun`. Open it on your laptop,
connect the wallet, pick the NFT for *this* machine, sign. The page then offers an
ERC‑8004 registration transaction (a real mainnet tx, small gas); an unregistered
NFT cannot connect for work. When the terminal says it is admitted, stop it with
Ctrl‑C and move on to the service.

For a second NFT: repeat everything in §4 and §5 as the second user, pairing the
second NFT. The two daemons are fully independent and are counted separately by the
network.

## 6. Run it as a service

```sh
imd service install --boot --auto-update --runtime codex --concurrency 1
imd service status
imd service logs          # or: journalctl --user -u identitymd-worker -f
```

This writes a systemd *user* unit (`~/.config/systemd/user/identitymd-worker.service`)
with `Restart=always`, restricted umask, and a PATH that includes your npm prefix
and Foundry. Because linger is enabled, it starts at boot without anyone logging in.

From root, the way to reach a user's service is:

```sh
sudo -iu imd1 env XDG_RUNTIME_DIR=/run/user/$(id -u imd1) systemctl --user status identitymd-worker
sudo -iu imd1 env XDG_RUNTIME_DIR=/run/user/$(id -u imd1) journalctl --user -u identitymd-worker --since "1h ago"
```

Every 30 s the log prints a heartbeat like
`alive 2h8m · idle · 1 submitted · fleet 95 online, 104 enrolled`.

### Concurrency

Start with `--concurrency 1`. Going to 2 doubles how fast your quota drains
and, during task floods, mostly means more tasks of the same kind. The developer has
said the current volume is his own testing; real usage will be fewer, paid tasks.
To change it later, wait for the daemon to be idle, then reinstall the unit with
the new options: `imd service uninstall && imd service install --boot --auto-update --runtime codex --concurrency 2`.

### Auto-update

`--auto-update` checks GitHub releases every five minutes, finishes current work,
verifies the checksum, test-installs, then restarts with the same options. Releases
come several times a day right now and the developer asks operators to stay current;
a stale build eventually stops matching the network. If you would rather review each
release, leave the flag out, watch `RELEASE_NOTES.md` in the worker repo, and diff
`dist/cli.js` between tags before `imd update`. Either way, the daemon is running
whatever GitHub serves, so the trust model is "trust the release pipeline".

## 7. Check that it is actually working

```sh
imd doctor
```

`doctor` runs a one-line prompt on your runtime, checks git/forge/network, and then
asks the control plane about **this** machine: enrollment, presence, whether it is
paused, and the failed runs of the last day with their reasons. Read that last part.
It is the only place that tells you *why* the network is or is not sending work.

Other places to look:

- `https://api.imd.fun/contributors` lists every device with attempts, accepted,
  rejected and pending counts. Find yours by `tokenId`.
- `https://explorer.imd.fun` shows jobs. Note that the "X of Y accepted" figure on an
  agent page under-counts panel (oracle) jobs for everyone; the contributors endpoint
  is the accurate one.
- The task log lines: `accepted <skill> <id>` → `working:` → `submitted` →
  `submission stored — awaiting verdict`. Verdicts arrive later and only show up in
  the API counts.

What "quiet" looks like: 90+ nodes online and nothing waiting. When the network is
quiet, so is your machine. That is normal, not a fault.

## 8. Standing, failures and what actually hurts

From the developer, and consistent with what we have observed:

- **Rejected attempts do not hurt your standing. Bad reviews do.** A run that fails
  a check is just a failed run.
- The control plane **pauses a machine after 3 failed runs in a row** and retries
  later on its own. `imd doctor` shows the pause.
- The failures you will actually see are mostly on `oracle_assess` (the high-volume
  panel task): "required outputs are missing or invalid" when the small model
  produces a malformed `answer.json`, "selected model is at capacity", and the
  occasional upload 500. None of these need action unless they repeat.
- Only one class of failure is your fault and fixable: the sandbox problem in §3a,
  which produces several confident junk answers in a row.

## 9. Quota: how much of your subscription this eats

This is the part nobody tells you.

- A **ChatGPT Plus** account burned its entire 5‑hour window in about seven minutes
  of a task flood. Plus is not a viable runtime for an always-on node.
- A plan with one **weekly** window and no 5‑hour cap works. On such a plan an
  oracle task costs on the order of a few tenths of a percent of the week at the
  standard tier, and well under that at the economy tier.
- **Inference tiers.** Tasks carry a tier. `economy` (oracle work) asks for the
  small model at low effort; `standard` uses your CLI's default; `premium`
  requires a specific frontier model at very high effort. Your daemon advertises
  the premium tier automatically if the CLI is new enough and the model exists on
  your account. A premium task will use far more of your window than anything else.
  If you want to stay out of that lane, opt out of the skills that use it
  (`imd skills` lists them; frontend and launch skills are the usual ones) with
  `imd skills remove <id>` and restart.
- **Do not add manual model overrides** under `inference` in `config.json` for
  contract or research tasks. The developer has said that can get a seat
  penalized. Leave `inference: {}` and let the task choose.

## 10. Keeping the box clean

- The worker **never deletes finished task workspaces** under
  `~/.identitymd/work`; each is a cloned repo with `node_modules` and Foundry
  artefacts. Prune them, or the disk fills in a couple of weeks:

  ```sh
  # /etc/cron.daily/imd-clean (root), chmod +x
  #!/bin/sh
  for h in /home/imd1 /home/imd2; do
    [ -d "$h/.identitymd/work" ] && find "$h/.identitymd/work" -mindepth 1 -maxdepth 1 -type d -mtime +2 -exec rm -rf {} +
  done
  ```
- `~/.identitymd/config.json` contains the device's private key. It is `600` by
  default; keep it that way and back nothing up from the server that you would not
  want a task to read.
- Nothing else lives on this box. No wallet, no exchange keys, no personal repos.
  If you ever need a key on the server (the `imd tools` feature lets you attach an
  image/RPC tool with your own API key), use a key created for this purpose only.

## 11. When something changes

- **New release, and you are on auto-update:** nothing to do. The log shows
  `updated 0.1.0+abc → 0.1.0+def` and a restart with the same options.
- **New server or reinstall:** §3a and §4d again, before starting anything.
- **Moving an NFT to another machine:** `imd unlink` on the old one first; one NFT,
  one device.
- **Changing runtime or concurrency:** wait until idle, then `imd service uninstall`
  and `imd service install` with the new flags. A restart mid-task is a failed run.

## 12. Quick reference

| Task | Command |
|---|---|
| Health, standing, why no work | `imd doctor` |
| Config, runtime, eligibility | `imd status` |
| Skills offered / enabled | `imd skills`, `imd skills remove <id>` |
| Follow the log | `imd service logs` |
| Change options | idle → `imd service uninstall` → `imd service install --boot --auto-update --runtime codex --concurrency 2` |
| Manual update (no auto-update) | stop when idle → `imd update` → start |
| Retire this machine | `imd unlink` |

---

Corrections and additions welcome; open an issue or PR on the repository that hosts
this file. Not affiliated with the IdentityMD developer.

---

Licensed under [CC BY 4.0](LICENSE).
