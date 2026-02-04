LocalAI BC-250 Container Manager👇

---

````md
# LocalAI BC-250 Container Manager

A LocalAI AIO launcher for Podman-based systems.

This project provides a single-entrypoint script that builds a host-matched LocalAI containe image

and orchestrates Master, Federated, and Worker roles in a peer-to-peer (P2P) inference cluster.

The command parser intentionally supports multiple roles in a single invocation, allowing

any combination of services to be launched on the same host.

---

## Key Design Principle

Every argument is processed in order.

The script uses a while loop over all CLI arguments.
 Each recognized command (`master`, `fed`, `worker`, etc.) is executed independently, not exclusively.

This means:

- There is no “mode”
- There is no mutual exclusion
- You can launch multiple roles at once
- Order does not matter

---

## Requirements

- Fedora 43+ Server or Bazzite 42 *not recomended due to window manager overhead
- Podman (Check the Container based Managemnt box when installing Fedora 43 Server)
- ASUS BC-250
- `/dev/dri` access
- Host networking allowed

---

## Installation

```bash
chmod +x localai.sh
./localai.sh install
````
---

## ⚠️ Security Disclaimer: Static P2P Token

This manager utilizes a **static P2P Token** hardcoded within the script to facilitate seamless communication between your BC-250 nodes (Master, Federated, and Workers).

* **Intended Use:** This configuration is designed for **private, local-only MCP networks** (e.g., dedicated 5GbE backplane).
* **Security Risk:** If your host ports (specifically `4001`) are exposed to the public internet, anyone with this token could potentially join your P2P inference cluster.
* **Production recommendation:** It is highly recommended to update the `RAW_TOKEN` variable inside `localai.sh` with a unique string generated via `openssl rand -base64 32` if deploying outside of a strictly firewalled environment.

---

This applies:

* Network tuning for P2P RPC
* Firewall rules
* SELinux device permissions

Builds the LocalAI container image (once)

---

## Command Syntax

```bash
./localai.sh [command] [command] [command] ...
```

There is no limit to combinations of commands you pass.

---

## Available Commands

| Command        | Description                                   |
| -------------- | --------------------------------------------- |
| install        | Apply host tuning and build image             |
| master         | Run LocalAI API + P2P coordinator (port 8080) |
| fed            | Run federated API participant (port 8081)     |
| worker         | Run P2P execution worker (no API)             |
| status         | Show running LocalAI containers               |
| debug `<role>` | Stream logs for a role                        |
| shell `<role>` | Open a shell inside a running container       |
| stop `[role]`  | Stop a role or all roles                      |
| uninstall      | Stop everything and remove artifacts          |

---

## Role Definitions

**Master**

* Runs LocalAI API server
* Acts as P2P coordinator
* Listens on `0.0.0.0:8080`

**Fed**

* Runs LocalAI Federated server
* Participates in federation
* Listens on `0.0.0.0:8081`

**Worker**

* Runs `p2p-llama-cpp-rpc`
* Executes inference only
* No HTTP API

---

## Multi-Role Execution (IMPORTANT)

Because arguments are processed sequentially, you can start multiple roles in one command.

### Examples

Run all roles on one host:

```bash
./localai.sh master fed worker
```

Federated + Worker node:

```bash
./localai.sh fed worker
```

Master + Worker (common single-node setup):

```bash
./localai.sh master worker
```

Start roles incrementally:

```bash
./localai.sh master
./localai.sh worker
```

All of these are valid and equivalent.

---

## What Actually Happens Internally

Each role:

* Builds the image if missing
* Uses a fixed container name:

  * `localai-master`
  * `localai-fed`
  * `localai-worker`
* Uses `podman run --replace`
* Runs independently of other roles

Launching multiple roles:

* Does not share a container
* Does not override other roles
* Does not require coordination

---

## Operations & Debugging

Stream logs:

```bash
./localai.sh debug master
./localai.sh debug fed
./localai.sh debug worker
```

Open an interactive shell:

```bash
./localai.sh shell master
```

Status:

```bash
./localai.sh status
```

Shows all running LocalAI-related containers.

---

## Stopping Services

```bash
./localai.sh stop master
./localai.sh stop fed
./localai.sh stop worker
```

Stop everything:

```bash
./localai.sh stop
```

---

## Uninstall

```bash
./localai.sh uninstall
```

* Stops all LocalAI containers
* Removes the container image
* Deletes stored node IDs
* Removes the generated Containerfile

