# BTRFS, Agents, and the Post-Container Stack
## Unified Presentation — 60 Minutes

**Total: 22 slides | 57 min content + 3 min Q&A**

| Slide | Topic | Time | Cumulative |
|-------|-------|------|------------|
| 1 | Title & Framing | 2 min | 0:02 |
| 2 | The Problem: Model Distribution | 3 min | 0:05 |
| 3 | BTRFS Insight: Filesystem Deltas | 3 min | 0:08 |
| 4 | Replication Architecture | 2 min | 0:10 |
| 5 | Demo Environment Setup | 2 min | 0:12 |
| 6 | Demo: Write → Snapshot → Send | 4 min | 0:16 |
| 7 | Demo: Incremental Send | 4 min | 0:20 |
| 8 | One-to-Many & Performance | 3 min | 0:23 |
| 9 | Comparison: btrfs vs Alternatives | 2 min | 0:25 |
| — | **TRANSITION** | 1 min | 0:26 |
| 10 | The Thesis: Agents as Users | 3 min | 0:29 |
| 11 | Agent-as-User Architecture | 3 min | 0:32 |
| 12 | cloud-init: The Agent Provisioner | 3 min | 0:35 |
| 13 | systemd: Lifecycle Without an Orchestrator | 3 min | 0:38 |
| 14 | Privilege Separation & MCP Config | 3 min | 0:41 |
| 15 | Memory Architecture: Three Tiers | 3 min | 0:44 |
| 16 | Event-Driven Activation & microVMs | 3 min | 0:47 |
| 17 | Transparency & Peer Review | 2 min | 0:49 |
| 18 | The Bridge: btrfs as Universal Replication | 3 min | 0:52 |
| 19 | Why Not Containers? | 2 min | 0:54 |
| 20 | What This Doesn't Solve (Yet) | 3 min | 0:57 |
| 21 | Next Steps | 2 min | 0:59 |
| 22 | Q&A | 1 min | 1:00 |

---

# PART 1: BTRFS Send/Receive for LLM Model Replication

---

## Slide 1: Title & Framing (2 min)

**BTRFS, Agents, and the Post-Container Stack**

Two ideas, one primitive:
1. Replicate LLM models efficiently with filesystem-level deltas
2. Deploy AI agents as Linux users, not containers

The connecting thread: btrfs subvolumes as the universal unit of state,
replication, and isolation.

github.com/davdunc/btrfs-replication-test

---

## Slide 2: The Problem — Model Distribution (3 min)

**Distributing LLM models at scale is expensive**

- A 70B parameter model at fp16 ≈ 140 GB
- Fine-tuning changes a fraction of the weights
- Redeploying the full model to N inference servers = N × 140 GB transferred
- Traditional approaches: S3 sync, rsync, container image layers — all file-level granularity

*Speaker notes: Frame this as a bandwidth and time problem. Every training
iteration that produces updated weights triggers a full redistribution cycle.
At scale with dozens of inference nodes, this becomes the bottleneck.*

---

## Slide 3: The Insight — Filesystem-Level Deltas (3 min)

**BTRFS send computes binary deltas between snapshots**

```
btrfs send -p <parent-snapshot> <child-snapshot>
```

- Copy-on-write filesystem tracks which blocks actually changed
- Send stream contains only modified extents — not file-level diffs
- Receive applies the delta atomically on the target
- No application-level diffing, no rsync checksumming

*Speaker notes: The key differentiator vs rsync is that btrfs knows at the
block level what changed because of CoW. rsync has to checksum every file.
For a 140GB model where 2GB of weights changed, btrfs send transmits ~2GB.
rsync has to read all 140GB to figure that out.*

---

## Slide 4: Replication Architecture (2 min)

```
┌─────────────────────┐       btrfs send        ┌─────────────────────┐
│   TRAINING NODE     │ ──────────────────────▶  │  INFERENCE NODE 1   │
│   (p5.48xlarge)     │   incremental deltas     │  (r7i.4xlarge)      │
│                     │   over SSH / netcat       │                     │
│  /data (btrfs)      │                          │  /data (btrfs)      │
│   └─ model/         │        ┌──────────────▶  │   └─ model-snap-v2/ │
│   └─ model-snap-v1/ │        │                 └─────────────────────┘
│   └─ model-snap-v2/ │  tee ──┤
│                     │        │                 ┌─────────────────────┐
└─────────────────────┘        └──────────────▶  │  INFERENCE NODE N   │
                                                 └─────────────────────┘
```

- One-to-many via `tee` — single read, parallel delivery
- For large fan-out (50+ nodes): relay tree topology

---

## Slide 5: Demo Environment (2 min)

**Fedora Cloud Base 43 on EC2 — two instances, btrfs data volumes**

```bash
# User data: runs at boot
dnf install -y btrfs-progs

mkfs.btrfs -f -L btrfs-data /dev/nvme1n1
mkdir -p /data
mount -o noatime /dev/nvme1n1 /data

# Source only: create the model subvolume
btrfs subvolume create /data/model
```

- AMI: Fedora-Cloud-Base-AmazonEC2.x86_64-43
- Separate user-data for source (creates subvolume) and target (receives only)
- 50 GB gp3 volumes formatted as btrfs

---

## Slide 6: Demo — Write, Snapshot, Full Send (4 min)

**Populate → snapshot → stream to target**

```bash
# Write model data
dd if=/dev/urandom of=/data/model/weights.bin bs=1M count=100
echo '{"model":"test-llm","version":"1.0"}' > /data/model/config.json

# Read-only snapshot (required for send)
btrfs subvolume snapshot -r /data/model /data/model-snap-v1

# Full send to target over SSH (protocol v2, compressed)
btrfs send --proto 2 --compressed-data /data/model-snap-v1 | \
  ssh fedora@target 'sudo btrfs receive /data/'
```

- Snapshot is instantaneous — CoW metadata operation
- `--proto 2 --compressed-data`: sends compressed extents without decompressing (kernel 6.0+)
- Target receives an identical read-only snapshot

---

## Slide 7: Demo — Incremental Send (4 min)

**After fine-tuning, send only what changed**

```bash
# Model updated by training
dd if=/dev/urandom of=/data/model/weights.bin bs=1M count=100
echo '{"model":"test-llm","version":"2.0"}' > /data/model/config.json

# New snapshot
btrfs subvolume snapshot -r /data/model /data/model-snap-v2

# Incremental: only the delta between v1 and v2
btrfs send --proto 2 --compressed-data \
  -p /data/model-snap-v1 /data/model-snap-v2 | \
  ssh fedora@target 'sudo btrfs receive /data/'
```

- `-p` flag: compute difference against parent snapshot
- Only changed blocks are transmitted
- Target must have the parent snapshot (received in step 1)

**Critical: never flip received read-only snapshots to read-write** —
this breaks `received_uuid` and future incremental sends.
Create a new writable snapshot instead:

```bash
# On target: writable copy for serving
btrfs subvolume snapshot /data/model-snap-v2 /data/model
```

---

## Slide 8: One-to-Many & Performance (3 min)

**Fan out to multiple inference servers simultaneously**

```bash
btrfs send -p /data/model-snap-v1 /data/model-snap-v2 | \
  tee >(ssh fedora@target2 'sudo btrfs receive /data/') \
      >(ssh fedora@target3 'sudo btrfs receive /data/') | \
  ssh fedora@target4 'sudo btrfs receive /data/'
```

| Operation | Time | Network cost |
|-----------|------|-------------|
| Snapshot creation | O(1) — metadata only | None |
| Full send (100 GB model) | O(data size) | ~100 GB |
| Incremental send (2% blocks touched) | O(delta) | ~2% of model |
| Writable snapshot on target | O(1) | None |
| Rollback to previous version | O(1) | None |

Add `mount -o compress=zstd` for 15-30% savings on model weights.

---

## Slide 9: The Elephant in the Room (3 min)

**CoW tracks *writes*, not *value changes*.**

| Checkpoint pattern | Incremental send result |
|---|---|
| ❌ `torch.save()` / safetensors write | Full model (all blocks new) |
| ❌ `save_pretrained()` to new file | Full model |
| ✅ mmap + partial write (in-place) | Only touched blocks |
| ✅ Sharded model — unchanged shards | Zero bytes |
| ✅ Agent session memory (append/update) | Only new blocks |

Standard ML checkpointing defeats the delta. This is not a btrfs limitation — it's a format problem.

*Speaker notes: This is the slide where you get ahead of the question. Anyone who has
trained models knows torch.save writes a new file. Be direct: "If you torch.save a 140GB
model, btrfs send transmits 140GB. Full stop." Then pivot to the next slide.*

---

## Slide 10: Making the Delta Real (3 min)

**btrfs as transport primitive + CoW-friendly format**

The interesting research question: design a checkpoint format where `btrfs send -p` = semantic diff.

- **Flat mmap'd tensor files** with stable offsets per layer
- Fine-tuning writes only to modified layer pages
- LoRA adapters: base weights never written → zero delta
- GGUF already supports mmap for *inference* — extend to checkpointing

btrfs is the transport. The format makes it efficient.

*Speaker notes: This is where the talk becomes a research contribution rather than
just a demo. The format doesn't exist yet for checkpointing — but the pieces are there.
GGUF mmap for inference, safetensors for zero-copy loading. The missing piece is
mmap-based checkpointing with stable tensor offsets. That's a tractable problem.*

---

## Slide 11: Comparison with Alternatives (2 min)

| Approach | Full deploy | Incremental | Rollback | Overhead |
|----------|-----------|-------------|----------|----------|
| S3 sync + download | O(model) | File-level | Re-download | Low |
| rsync | O(model) checksum | Block-level | Re-sync | Medium |
| Container layers | O(layer) | Layer-level | Tag swap | High |
| **btrfs send/receive** | **O(model)** | **Block-level (CoW)*** | **Instant** | **None** |

*Block-level delta requires CoW-friendly write pattern. Full-file rewrites send the full file.

Where btrfs wins unconditionally: rollback, fan-out (tee to N hosts), zero-overhead snapshots, no checksumming pass.

*Speaker notes: After the honesty of slides 9-10, this comparison lands with credibility.
You've shown the limitation AND the path forward. The audience trusts the comparison now.*

---

# TRANSITION (1 min)

**We just showed btrfs as a replication primitive for model weights.
Now: what if we use the same primitive for everything — agent state,
memory, work products? And what if the agents themselves are just
Linux users?**

---

# PART 2: Agents as Service Account Users

---

## Slide 12: The Thesis (3 min)

**Containers solved packaging. Agents don't have a packaging problem.**

- An agent is: a runtime + a model + memory + tools
- A Linux user account already provides: isolation (UID/GID), resource limits
  (cgroups), filesystem boundary (home dir), credential scope
- Kubernetes orchestrates *where* things run. Agents decide *what* to do.
- Orchestrating decision-makers with a decision-making system is redundant.

```
2006: EC2 user-data — shell scripts to configure instances
2010: cloud-init — declarative instance configuration
2015: Dockerfiles — declarative container configuration
2018: Helm charts — declarative container orchestration
2026: cloud-init agents — declarative agent provisioning
         │
         └─ Full circle: back to users, processes, and filesystems
            but now the users are agents and the filesystems are smart
```

---

## Slide 13: Agent-as-User Architecture (3 min)

```
┌─────────────────────────────────────────────────────────┐
│                    Linux Host / microVM                  │
│                                                         │
│  /etc/agent-config/          ← system-managed, root-owned│
│  ├── agent-build/mcp.json      (agents can read,        │
│  ├── agent-review/mcp.json      not write)              │
│  └── agent-deploy/mcp.json                              │
│                                                         │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐              │
│  │ agent-01 │  │ agent-02 │  │ agent-03 │  ← UIDs      │
│  │ (build)  │  │ (review) │  │ (deploy) │              │
│  ├──────────┤  ├──────────┤  ├──────────┤              │
│  │ ~/memory │  │ ~/memory │  │ ~/memory │  ← btrfs     │
│  │ ~/tools  │  │ ~/tools  │  │ ~/tools  │    subvols   │
│  │ ~/work   │  │ ~/work   │  │ ~/work   │              │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘              │
│       │              │              │                    │
│       └──────────────┼──────────────┘                    │
│                      │                                   │
│              ┌───────▼────────┐                          │
│              │   Event Bus    │  ← systemd socket        │
│              │  (socket act.) │    activation            │
│              └───────┬────────┘                          │
│                      │                                   │
│         ┌────────────┼────────────┐                      │
│         ▼            ▼            ▼                      │
│   ┌──────────┐ ┌──────────┐ ┌──────────┐               │
│   │ Extended │ │  Model   │ │  Audit   │               │
│   │ Memory   │ │  Store   │ │   Log    │               │
│   │(AgentCor)│ │ (btrfs)  │ │(journal) │               │
│   └──────────┘ └──────────┘ └──────────┘               │
└─────────────────────────────────────────────────────────┘
```

- Each agent = Linux system user
- Home directory = btrfs subvolume (agent-writable state)
- MCP config at `/etc/agent-config/` (root-owned, agent-readable)
- Agents cannot modify their own tool permissions — like sshd_config
- Event bus = systemd socket activation

---

## Slide 14: cloud-init — The Agent Provisioner (3 min)

```yaml
#cloud-config
users:
  - name: agent-build
    system: true
    shell: /usr/bin/agent-shell
    groups: [agents]
    no_create_home: true

runcmd:
  # btrfs subvolume as home directory
  - btrfs subvolume create /data/agents/agent-build
  - mkdir -p /data/agents/agent-build/{memory,tools,work}
  - chown -R agent-build:agents /data/agents/agent-build
  - mount --bind /data/agents/agent-build /home/agent-build

  # MCP config — root-owned, agent-readable (not writable)
  - mkdir -p /etc/agent-config/agent-build
  - install -m 0644 -o root -g agents \
      /dev/stdin /etc/agent-config/agent-build/mcp.json

  # Append-only audit log
  - touch /home/agent-build/work/actions.log
  - chattr +a /home/agent-build/work/actions.log

  - systemctl enable --now agent@build
```

```json
// /etc/agent-config/agent-build/mcp.json
{
  "mcpServers": {
    "filesystem": {
      "command": "mcp-fs",
      "args": ["--root", "/home/agent-build"],
      "env": {}
    },
    "btrfs": {
      "command": "mcp-btrfs",
      "args": ["--subvolume", "/data/agents/agent-build"]
    }
  },
  "permissions": {
    "allowedPaths": ["/home/agent-build", "/data/model"],
    "deniedPaths": ["/etc", "/root", "/home/agent-*"],
    "allowedCommands": ["btrfs subvolume snapshot", "btrfs send"]
  }
}
```

- MCP config is the agent's capability manifest — what tools it can use
- Root-owned, group-readable: agents read their config but can't escalate
- Same pattern as `/etc/ssh/sshd_config` — system policy, not user preference

---

## Slide 15: systemd — Lifecycle Without an Orchestrator (3 min)

```ini
# /etc/systemd/system/agent@.service
[Service]
Type=notify
User=agent-%i
Group=agents
WorkingDirectory=/home/agent-%i
ExecStart=/usr/libexec/agent-monitor --config /etc/agent-config/agent-%i/mcp.json
Restart=always

# Resource isolation — the "container" is a cgroup
CPUQuota=200%
MemoryMax=8G

# Security — the "sandbox" is systemd
ProtectSystem=strict
ProtectHome=tmpfs
BindReadOnlyPaths=/etc/agent-config/agent-%i
BindPaths=/home/agent-%i
PrivateTmp=true
NoNewPrivileges=true
```

- `BindReadOnlyPaths` for MCP config — agent can read, not modify
- `BindPaths` for home — agent's writable workspace
- `agent-monitor` is the privileged parent (see next slide)

---

## Slide 16: Privilege Separation & MCP Config (3 min)

**The OpenSSH model, applied to agents**

```
┌─────────────────────────────────────────────────┐
│ OpenSSH privsep                                 │
│                                                 │
│  sshd (root)          ← privileged monitor      │
│    └─ sshd (sshd)     ← unprivileged child      │
│        └─ shell (user) ← user session            │
│                                                 │
│ Agent privsep                                   │
│                                                 │
│  agent-monitor (root)  ← reads /etc/agent-config│
│    └─ agent-runtime    ← drops to agent UID     │
│        (agent-build)     chrooted to ~/          │
│                          MCP tools sandboxed     │
└─────────────────────────────────────────────────┘
```

**How it works:**

1. `agent-monitor` starts as root, reads `/etc/agent-config/agent-build/mcp.json`
2. Forks an unprivileged child, drops to `agent-build` UID
3. Child runs `agent-runtime` in a restricted namespace
4. When the agent needs a privileged operation (mount, snapshot, network),
   it requests it from the monitor over a Unix socket
5. Monitor validates the request against MCP config policy, executes or denies

```
agent-runtime (agent-build)                agent-monitor (root)
        │                                         │
        ├── "snapshot /data/model" ──────────────▶ │
        │                                  check mcp.json:
        │                                  allowedCommands ✅
        │                                  ◀── execute + return ──┤
        │                                         │
        ├── "read /etc/shadow" ──────────────────▶ │
        │                                  check mcp.json:
        │                                  deniedPaths ❌
        │                                  ◀── DENIED ───────────┤
```

**Why `/etc/agent-config/` instead of `~/.config/`:**

- Agents cannot grant themselves new capabilities
- MCP config is system policy, not user preference
- Changing agent permissions requires root — same as `sshd_config`
- cloud-init provisions it at deploy time; updates require a new deployment
- Audit: `ls -la /etc/agent-config/` shows exactly what each agent can do

*Speaker notes: This is the critical security boundary. In the container model,
the container image defines what's inside. Here, the MCP config defines what
the agent can reach. But unlike a container image that the developer builds,
the MCP config is system-administered. The agent can't docker-exec its way
to more permissions. It's the same principle as OpenSSH: the sshd process
that handles your connection can't modify sshd_config to give itself more
access. The privileged monitor is the gatekeeper.*

---

## Slide 17: Memory Architecture — Three Tiers (3 min)

| Tier | Backing | Lifetime | Replication |
|------|---------|----------|-------------|
| Working | tmpfs (RAM) | Minutes — cleared on restart | None (ephemeral) |
| Session | btrfs subvolume | Hours–days | btrfs send/receive |
| Long-term | AgentCore / MemoriesDB | Persistent | Service-managed |

```
~/memory/
├── working/          # tmpfs, cleared on restart
├── session/          # btrfs, snapshotted & replicated
└── long-term/        # mount point for memory service
```

- The agent itself is disposable — kill it, recreate from cloud-init,
  reconnect to long-term memory, pick up where it left off
- **Agents are cattle. Memory is pets.** Invert the container model.

---

## Slide 18: Event-Driven Activation & microVMs (3 min)

```
Agent receives task
         │
         ▼
┌─────────────────────────┐
│ Agent evaluates:        │
│  - Trust level          │
│  - Resource needs       │
│  - Data locality        │
└────────────┬────────────┘
             │
     ┌───────┼───────┐
     ▼       ▼       ▼
  On-host  microVM  Cloud
  process  (125ms)  (EC2 spot)
           boot     + btrfs send
```

- Lightweight tasks: run as the agent user process
- Untrusted/isolated: Firecracker microVM, ~30MB overhead
- Heavy compute: launch EC2 spot, btrfs-send the model volume
- The agent IS the scheduler — no external orchestrator

---

## Slide 19: Transparency & Peer Review (2 min)

```
~/work/
├── 2026-03-05T14:30:00-build-widget/
│   ├── task.json          # what was requested
│   ├── plan.json          # what the agent decided to do
│   ├── actions.log        # what it actually did (append-only)
│   ├── artifacts/         # what it produced
│   └── review-request.json
```

- `actions.log` is append-only (`chattr +a`) — agents can't rewrite history
- Other agents read peers' ~/work/ via group permissions
- btrfs snapshots before/after each task = complete diff
- Better auditability than most human engineers

---

## Slide 20: The Bridge — btrfs as Universal Replication (3 min)

**One primitive for everything**

```bash
# Replicate model weights (Part 1)
btrfs send --proto 2 --compressed-data \
  -p /data/model-snap-v1 /data/model-snap-v2 | \
  ssh target 'sudo btrfs receive /data/'

# Replicate agent session memory (Part 2)
btrfs send --proto 2 --compressed-data \
  -p /data/agents/agent-build/memory/session-snap-prev \
     /data/agents/agent-build/memory/session-snap-curr | \
  ssh target 'sudo btrfs receive /data/agents/agent-build/memory/'

# Migrate entire agent to new host
btrfs send /data/agents/agent-build-snap | \
  ssh new-host 'sudo btrfs receive /data/agents/'
```

Same mechanism for model weights, agent memory, work products, and full
agent migration. No registry. No image layers. Just subvolumes and deltas.

---

## Slide 21: Why Not Containers? (3 min)

| Concern | Container/K8s | Agent-as-user |
|---------|--------------|---------------|
| Isolation | Namespace + cgroup | UID + cgroup + systemd |
| Packaging | Docker image layers | cloud-init user definition |
| Orchestration | Control plane | Agent self-management |
| Scaling | HPA / pod autoscaler | Agent spawns microVM or EC2 |
| State | PVC / StatefulSet | btrfs subvolume per agent |
| Replication | Registry pull | btrfs send/receive (incremental) |
| Observability | Sidecar + aggregator | journald + append-only log |
| Recovery | Pod restart + PVC | cloud-init recreate + memory reconnect |
| Overhead | ~50-100MB per container | ~0 (it's a process) |

*Speaker notes: Containers solved real problems for stateless web services.
But agents are stateful, autonomous, and self-managing. Wrapping them in
containers and orchestrating with k8s is adding two layers of management
to something that can manage itself.*

---

## Slide 22: What This Doesn't Solve (Yet) (3 min)

| Problem | K8s gives you | We'd need to build |
|---------|--------------|-------------------|
| Multi-host coordination | Service discovery, DNS | Agent gossip protocol or registry |
| Horizontal scaling | `replicas: 50` | UID templating — gets awkward |
| Cross-host identity | ServiceAccount + RBAC | SPIFFE/SPIRE or cert-based identity |
| Secret rotation | Secrets + CSI drivers | Vault or kernel keyring per UID |
| GPU sharing | Device plugin + MIG | Manual MIG config outside systemd |
| Memory conflicts | N/A (stateless pods) | No merge strategy — last snapshot wins |
| Admission control | OPA / Gatekeeper | Policy in agent-shell or PAM |
| Observability at scale | Centralized by default | journald is per-host |

**Other edge cases:**
- Rollback is all-or-nothing per subvolume — can't undo one bad decision
- Dynamic task dependencies need workflow coordination beyond systemd ordering
- Filesystem-as-API is slow for complex multi-agent workflows
- Agents can't negotiate resources — they just hit cgroup limits

---

## Slide 23: Next Steps (2 min)

**Building:**
- cloud-init module for agent provisioning (PR to cloud-init upstream)
- agent-shell: custom login shell → agent runtime
- AgentCore adapter for ~/memory/long-term
- SPIFFE integration for cross-host agent identity

**Testing:**
- btrfs send/receive benchmarks on real 70B+ models
- Firecracker microVM integration with systemd socket activation
- Multi-host agent memory replication with conflict detection

**The agent is the new process. The user account is the new container.
cloud-init is the new orchestrator. btrfs is the new registry.**

*But we're not throwing away orchestration — we're moving it inside the agent.*

---

## Slide 24: Q&A (3 min)

**Resources:**
- Repository: github.com/davdunc/btrfs-replication-test
- btrfs docs: btrfs.readthedocs.io
- cloud-init: github.com/canonical/cloud-init
- Firecracker: github.com/firecracker-microvm/firecracker
- AgentCore: aws.amazon.com/agentcore
- SPIFFE: spiffe.io
- Fedora Cloud: fedoraproject.org/cloud
