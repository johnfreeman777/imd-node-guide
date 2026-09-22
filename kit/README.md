# imd-node.sh

A single script that does what the [guide](../README.md) describes. It takes a fresh
Ubuntu or Debian VPS to a running IdentityMD worker node. It stops at the two steps only
you can do: signing the CLI in to your subscription, and pairing the NFT with your
wallet in your own browser.

Unofficial. Read it before you run it; it is one file of plain bash.

Tested end to end on a fresh Ubuntu 24.04 VPS (1 vCPU, 2 GB RAM): `setup --seats 2`
took about 70 seconds. A second run skips what is done. The settings survive a
reboot. With the sandbox fix `bwrap` runs; without it you get the exact
`setting up uid map: Permission denied` failure described in the guide.

## Quick start

On the server, as root:

```sh
curl -fsSLO https://raw.githubusercontent.com/johnfreeman777/imd-node-guide/main/kit/imd-node.sh
less imd-node.sh                      # read it first
bash imd-node.sh setup --seats 2 --harden-ssh
```

`--seats` is how many NFTs this server will run: one Linux user per NFT (`imd1`,
`imd2`, …). Then, for each seat:

```sh
bash imd-node.sh login 1     # prints a code; confirm it in the browser on your computer
bash imd-node.sh check 1     # the agent must run a shell command inside its sandbox
bash imd-node.sh pair 1      # open the pairing link on your computer, sign, register, Ctrl-C
bash imd-node.sh service 1   # background service: starts at boot, auto-updates
```

Everyday use:

```sh
bash imd-node.sh status      # every seat: NFT, service state, version, last heartbeat
bash imd-node.sh logs 1      # follow a seat's log; Ctrl-C closes the viewer, not the worker
```

## What `setup` does

| Step | Detail |
|---|---|
| Checks the machine | OS, RAM, free disk; warns below 2 GB RAM or 10 GB disk |
| Packages | `git`, `curl`, `build-essential`, `ufw`, `unattended-upgrades` |
| Swap | 4 GB swap file if the server has none, so Foundry builds are not OOM-killed |
| Firewall | ufw: deny inbound, allow outbound, allow your current SSH port |
| SSH (`--harden-ssh`) | keys only, but only if root already has an authorized key, and only if `sshd -t` accepts the change |
| Sandbox fix | on Ubuntu 24.04, allows unprivileged user namespaces so Codex's `bwrap` sandbox can run (see guide §3a) |
| Node.js | Node 24 from NodeSource if node is missing or older than 22 |
| Worker | downloads the latest release and verifies its SHA-256 before installing anything |
| Seats | one user per NFT, no sudo, home `700`, linger on, user-owned npm prefix, the worker, the CLI (`codex` or `claude`) and Foundry |
| Cleanup | `/etc/cron.daily/imd-clean` deletes task workspaces older than two days |

`setup` is safe to run again: it skips what is already done. Run it again with a
higher `--seats` to add NFTs to the same server.

Options: `--runtime claude` (default is `codex`), `--no-foundry`, `--no-firewall`,
`--no-userns-fix`.

## What `check` proves

`imd doctor` asks the runtime for a one-word reply with no tools. That passes even
when the sandbox cannot run a single command, which is exactly how a node ends up
submitting several junk answers in a row. `check` has the agent write a file with a
shell command inside the sandbox, then verifies the file exists. Only then does it
run `imd doctor`. It spends a few thousand tokens.

## What it never does

- Touch a wallet, a seed phrase or a private key. There is nothing to paste.
- Open inbound ports. The worker only dials out.
- Give the seat users sudo.
- Change model settings. `inference` in the worker config stays empty, as the
  developer recommends.

## Service options

```sh
bash imd-node.sh service 1 --concurrency 2       # two tasks at once (drains quota faster)
bash imd-node.sh service 1 --no-auto-update      # update by hand with imd update
```

Change options only while the seat is idle. A restart in the middle of a task counts
as a failed run.
