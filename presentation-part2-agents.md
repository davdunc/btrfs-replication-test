# Part 2: Agents as Service Account Users
## Presentation Outline & Speaker Notes

---

## Slide 1: Title

**Agents as Service Accounts: The Post-Container Deployment Model**

- Agents are processes, not pods
- cloud-init is the orchestrator
- The filesystem is the memory layer
- microVMs for burst, bare metal for steady-state

---

## Slide 2: The Thesis

**Containers solved packaging. Agents don't have a packaging problem.**

- An agent is: a runtime + a model + memory + tools
- A Linux user account already provides: isolation (UID/GID), resource limits (cgroups),
  filesystem boundary (home dir), credential scope (SSH keys, tokens)
- Kubernetes orchestrates *where* things run. Agents decide *what* to do.
- Orchestrating decision-makers with a decision-making system is redundant.

*Speaker notes: The core argument is that containers were designed to isolate
applications that can't manage themselves. Agents can. They can monitor their own
health, restart their own processes, request more resources, and coordinate with
peers. Adding k8s on top is like hiring a manager for a team of managers.*

---

## Slide 3: The Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Linux Host / microVM                  │
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
│              │   Event Bus    │  ← systemd / D-Bus /     │
│              │  (socket act.) │    socket activation     │
│              └───────┬────────┘                          │
│                      │                                   │
│         ┌────────────┼────────────┐                      │
│         ▼            ▼            ▼                      │
│   ┌──────────┐ ┌──────────┐ ┌──────────┐               │
│   │ Extended │ │  Model   │ │  Audit   │               │
│   │ Memory   │ │  Store   │ │   Log    │               │
│   │(MemoryDB)│ │ (btrfs)  │ │(journal) │               │
│   └──────────┘ └──────────┘ └──────────┘               │
└─────────────────────────────────────────────────────────┘
```

*Speaker notes: Each agent is a Linux user. Their home directory is a btrfs
subvolume. Memory is a subdirectory (or a mounted memory service). Tools are
executables in their PATH. Work products go to ~/work for peer review. The event
bus is just systemd socket activation — no message broker needed.*

---

## Slide 4: cloud-init — The Agent Provisioner

**Creating an agent is creating a user**

```yaml
#cloud-config
users:
  - name: agent-build
    system: true
    shell: /usr/bin/agent-shell
    groups: [agents, docker]
    sudo: false
    ssh_authorized_keys: []  # agents don't SSH — they're local

  - name: agent-review
    system: true
    shell: /usr/bin/agent-shell
    groups: [agents]

runcmd:
  # Create btrfs subvolumes for each agent's home
  - btrfs subvolume create /data/agents/agent-build
  - btrfs subvolume create /data/agents/agent-review
  - bindfs --map=root/agent-build /data/agents/agent-build /home/agent-build
  - bindfs --map=root/agent-review /data/agents/agent-review /home/agent-review

  # Bootstrap agent memory and config
  - install -d -o agent-build /home/agent-build/{memory,tools,work}
  - install -d -o agent-review /home/agent-review/{memory,tools,work}

  # Install agent runtimes
  - pip install --target=/home/agent-build/tools agent-runtime
  - systemctl enable --now agent-build.service agent-review.service
```

*Speaker notes: This is the same cloud-init you already use for EC2 user-data.
No Dockerfile. No Helm chart. No kubectl. Just users, directories, and systemd
units. The agent-shell is a custom shell that drops into the agent runtime
instead of bash.*

---

## Slide 5: The Agent as a systemd Service

**Lifecycle management without an orchestrator**

```ini
# /etc/systemd/system/agent-build@.service
[Unit]
Description=Agent %i
After=network-online.target data.mount

[Service]
Type=notify
User=agent-%i
Group=agents
WorkingDirectory=/home/agent-%i
ExecStart=/home/agent-%i/tools/agent-runtime \
  --memory-dir=/home/agent-%i/memory \
  --work-dir=/home/agent-%i/work \
  --event-socket=/run/agents/%i.sock
Restart=always
RestartSec=5

# Resource isolation — the "container" is a cgroup
CPUQuota=200%
MemoryMax=8G
IOWeight=100

# Security — the "sandbox" is systemd
ProtectSystem=strict
ProtectHome=tmpfs
BindPaths=/home/agent-%i
PrivateTmp=true
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
```

*Speaker notes: systemd gives you everything k8s gives you: restart policies,
resource limits, health checks (via sd_notify), dependency ordering, and
sandboxing. The difference is it's been in the kernel for a decade and doesn't
need a control plane.*

---

## Slide 6: Memory Architecture

**Three tiers — just like human cognition**

| Tier | Scope | Backing | Lifetime |
|------|-------|---------|----------|
| Working memory | Current task | tmpfs / RAM | Minutes |
| Short-term memory | Session context | Local file (~/memory/session/) | Hours–days |
| Long-term memory | Learned knowledge | MemoriesDB / AgentCore | Persistent |

```
~/memory/
├── working/          # tmpfs, cleared on restart
│   └── current.json  # active task context
├── session/          # btrfs, snapshotted
│   ├── 2026-03-05/   # daily session logs
│   └── index.json    # session retrieval index
└── long-term/        # mount point for MemoriesDB / AgentCore
    └── .socket       # connection to memory service
```

- Working memory: agent restarts = clean slate (by design)
- Session memory: btrfs snapshots = point-in-time recovery
- Long-term memory: external service = survives agent destruction

*Speaker notes: The agent itself is disposable. Kill it, recreate it from
cloud-init, reconnect to long-term memory, and it picks up where it left off.
This is the key insight: agents are cattle, memory is pets. Invert the
container model.*

---

## Slide 7: Event-Driven Activation

**Agents wake on demand — no idle pods**

```
                    Event arrives
                         │
                         ▼
              ┌─────────────────────┐
              │  systemd .socket    │
              │  ListenStream=...   │
              └──────────┬──────────┘
                         │
              ┌──────────▼──────────┐
              │  Socket activation  │
              │  spawns agent svc   │
              └──────────┬──────────┘
                         │
          ┌──────────────┼──────────────┐
          ▼              ▼              ▼
    ┌──────────┐  ┌──────────┐  ┌──────────┐
    │  On-host │  │  microVM │  │  Cloud    │
    │  process │  │ (firecrk)│  │  (EC2)   │
    └──────────┘  └──────────┘  └──────────┘
```

- Lightweight tasks: run as the agent user process directly
- Isolated/untrusted tasks: spawn a Firecracker microVM
- Heavy compute (training): launch EC2 spot, btrfs-send the model subvolume

*Speaker notes: This is the hybrid model. The agent decides where to run its
workload based on the task requirements. A code review? Local process. Running
untrusted code? microVM with 125ms boot time. Training a model? Spin up a p5
and btrfs-send the data volume. No scheduler needed — the agent IS the scheduler.*

---

## Slide 8: Transparency & Peer Review

**Every agent's work is auditable by default**

```
~/work/
├── 2026-03-05T14:30:00-build-widget/
│   ├── task.json          # what was requested
│   ├── plan.json          # what the agent decided to do
│   ├── actions.log        # what it actually did (append-only)
│   ├── artifacts/         # what it produced
│   └── review-request.json # submitted for peer review
```

- `actions.log` is append-only (chattr +a) — agents can't rewrite history
- Other agents can read ~/work/ of their peers (group=agents)
- Human review: `journalctl --user-unit=agent-build` for full audit trail
- btrfs snapshots of ~/work before and after each task = diff of changes

*Speaker notes: This is the accountability layer. Every agent task produces a
work directory that any other agent or human can inspect. The append-only action
log means the agent can't cover its tracks. Combined with btrfs snapshots, you
get a complete before/after diff of every task. This is better auditability than
you get from most human engineers.*

---

## Slide 9: Connecting to Part 1 — btrfs as the Replication Layer

**Agent memory and models replicate the same way**

```bash
# Snapshot agent's session memory
btrfs subvolume snapshot -r \
  /data/agents/agent-build/memory/session \
  /data/agents/agent-build/memory/session-snap-$(date +%s)

# Replicate to another host (new agent picks up context)
btrfs send --proto 2 --compressed-data \
  -p /data/agents/agent-build/memory/session-snap-prev \
     /data/agents/agent-build/memory/session-snap-curr | \
  ssh target 'sudo btrfs receive /data/agents/agent-build/memory/'

# Same mechanism for model updates (from Part 1)
btrfs send --proto 2 --compressed-data \
  -p /data/model-snap-v1 /data/model-snap-v2 | \
  ssh target 'sudo btrfs receive /data/'
```

- Agent state, model weights, and session memory all use the same primitive
- One replication mechanism for everything
- Incremental: only changed knowledge/weights transfer

*Speaker notes: This is where Part 1 and Part 2 converge. btrfs send/receive
isn't just for model distribution — it's the universal replication primitive for
the entire agent platform. Memory, models, work products, tool configurations —
all are btrfs subvolumes, all replicate incrementally.*

---

## Slide 10: microVM Burst — Off-Cloud Compute

**Firecracker for local isolation, EC2 for scale**

```
Agent receives task requiring isolation
         │
         ▼
┌─────────────────────────┐
│ Agent evaluates:        │
│  - Trust level of task  │
│  - Resource requirements│
│  - Data locality        │
└────────────┬────────────┘
             │
     ┌───────┴───────┐
     ▼               ▼
 Local microVM    Cloud instance
 (Firecracker)    (EC2 spot)
 - 125ms boot     - btrfs send model
 - shared /data   - run training
 - ~30MB overhead - btrfs send results
 - auto-destroy   - terminate
```

- microVMs get a read-only bind mount of the agent's model subvolume
- Results written to a scratch subvolume, snapshotted on completion
- Agent inspects results, merges into its own subvolume if accepted

*Speaker notes: The microVM is the agent's sandbox for untrusted work. It boots
in 125ms, gets read-only access to the model, does its work, and the agent
reviews the output before accepting it. This is defense in depth without
container orchestration.*

---

## Slide 11: Why Not Containers?

| Concern | Container/K8s approach | Agent-as-user approach |
|---------|----------------------|----------------------|
| Isolation | Namespace + cgroup | UID + cgroup + systemd sandbox |
| Packaging | Docker image layers | cloud-init user definition |
| Orchestration | Control plane (etcd, API server) | Agent self-management |
| Scaling | HPA, pod autoscaler | Agent spawns microVM or EC2 |
| State | PVC, StatefulSet | btrfs subvolume per agent |
| Replication | Registry pull | btrfs send/receive (incremental) |
| Observability | Sidecar + log aggregator | journald + append-only work log |
| Recovery | Pod restart + PVC reattach | cloud-init recreate + memory reconnect |
| Overhead | ~50-100MB per container | ~0 (it's a process) |

*Speaker notes: The point isn't that containers are bad. They solved real
problems for stateless web services. But agents are stateful, autonomous, and
self-managing. Wrapping them in containers and then orchestrating them with k8s
is adding two layers of management to something that can manage itself.*

---

## Slide 12: The Evolution of User Data

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

*Speaker notes: We've gone through a full cycle. We started with user-data
configuring Linux users and processes. We added containers because applications
couldn't manage themselves. Now agents CAN manage themselves, so we return to
the original primitive — but with agents as the users and btrfs as the
filesystem that understands replication natively.*

---

## Slide 13: What's Next

- Prototype: cloud-init module for agent provisioning (PR to cloud-init upstream)
- Agent-shell: custom login shell that drops into agent runtime
- Memory service integration: AgentCore adapter for ~/memory/long-term
- btrfs-based agent migration: snapshot entire agent home, send to new host
- Event-driven microVM spawner: systemd + Firecracker integration
- Audit framework: structured logging + btrfs diff for task review

**The agent is the new process. The user account is the new container.
cloud-init is the new orchestrator. btrfs is the new registry.**

---

## Slide 14: Q&A

**Resources:**
- Part 1 (btrfs replication): github.com/davdunc/btrfs-replication-test
- cloud-init: github.com/canonical/cloud-init
- Firecracker: github.com/firecracker-microvm/firecracker
- AgentCore: aws.amazon.com/agentcore
