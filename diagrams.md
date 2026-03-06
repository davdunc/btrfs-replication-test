# Presentation Diagrams

All diagrams use [Mermaid](https://mermaid.js.org/). GitHub renders them inline.
To export as PNG/SVG for slides, paste into [mermaid.live](https://mermaid.live)
or run `npx @mermaid-js/mermaid-cli -i diagrams.md -o output/`.

Individual `.mmd` files are in `diagrams/` for standalone rendering.

---

## Slide 4: Replication Architecture

```mermaid
flowchart LR
    subgraph Source["TRAINING NODE (p5.48xlarge)"]
        direction TB
        M["/data/model"] --> S1["/data/model-snap-v1<br/>🔒 read-only"]
        M --> S2["/data/model-snap-v2<br/>🔒 read-only"]
    end

    S2 -- "btrfs send --proto 2<br/>incremental delta" --> TEE((tee))

    TEE -- "SSH pipe" --> T1
    TEE -- "SSH pipe" --> T2
    TEE -- "SSH pipe" --> T3

    subgraph Targets["INFERENCE FLEET"]
        T1["Inference Node 1<br/>/data/model-snap-v2"]
        T2["Inference Node 2<br/>/data/model-snap-v2"]
        T3["Inference Node N<br/>/data/model-snap-v2"]
    end

    style Source fill:#2d3748,stroke:#4299e1,color:#fff
    style Targets fill:#2d3748,stroke:#48bb78,color:#fff
    style TEE fill:#ed8936,stroke:#dd6b20,color:#fff
```

---

## Slide 6–7: Demo Flow — Full & Incremental Send

```mermaid
sequenceDiagram
    participant S as Source /data
    participant Snap as Snapshots
    participant Net as Network (SSH)
    participant T as Target /data

    Note over S: Step 1: Write model data
    S->>S: dd → /data/model/weights.bin (100MB)
    S->>S: echo → /data/model/config.json

    Note over S,Snap: Step 2: Read-only snapshot
    S->>Snap: btrfs subvolume snapshot -r<br/>model → model-snap-v1

    Note over Snap,T: Step 3: Full send
    Snap->>Net: btrfs send --proto 2 --compressed-data<br/>model-snap-v1
    Net->>T: btrfs receive /data/
    Note over T: ✅ model-snap-v1 (read-only)

    Note over S: Step 4: Update model (fine-tuning)
    S->>S: dd → /data/model/weights.bin (changed)
    S->>S: echo → config.json v2.0

    Note over S,Snap: Step 5: Second snapshot
    S->>Snap: btrfs subvolume snapshot -r<br/>model → model-snap-v2

    Note over Snap,T: Step 6: Incremental send (delta only)
    Snap->>Net: btrfs send -p snap-v1 snap-v2<br/>⚡ only changed blocks
    Net->>T: btrfs receive /data/
    Note over T: ✅ model-snap-v2 (read-only)

    Note over T: Create writable copy for serving
    T->>T: btrfs subvolume snapshot<br/>model-snap-v2 → model (rw)
```

---

## Slide 9: Comparison with Alternatives

```mermaid
quadrantChart
    title Incremental Efficiency vs Rollback Speed
    x-axis "Slow Rollback" --> "Instant Rollback"
    y-axis "File-Level Sync" --> "Block-Level Sync"
    quadrant-1 "Best: fast sync + instant rollback"
    quadrant-2 "Good sync, slow rollback"
    quadrant-3 "Worst: slow everything"
    quadrant-4 "Fast rollback, slow sync"
    "btrfs send/receive": [0.9, 0.95]
    "rsync": [0.2, 0.7]
    "S3 sync": [0.15, 0.2]
    "Container layers": [0.7, 0.4]
```

---

## Slide 11: Agent-as-User Architecture

```mermaid
flowchart TB
    subgraph Host["Linux Host"]
        direction TB

        subgraph Agents["Agent Users (UIDs)"]
            direction LR
            subgraph A1["agent-build"]
                A1M["~/memory"]
                A1T["~/tools"]
                A1W["~/work"]
            end
            subgraph A2["agent-review"]
                A2M["~/memory"]
                A2T["~/tools"]
                A2W["~/work"]
            end
            subgraph A3["agent-deploy"]
                A3M["~/memory"]
                A3T["~/tools"]
                A3W["~/work"]
            end
        end

        EB["Event Bus<br/>systemd socket activation"]

        A1 --- EB
        A2 --- EB
        A3 --- EB

        subgraph Services["Backing Services"]
            direction LR
            MEM["Extended Memory<br/>AgentCore / MemoriesDB"]
            MOD["Model Store<br/>btrfs subvolumes"]
            AUD["Audit Log<br/>journald + actions.log"]
        end

        EB --- Services
    end

    style Host fill:#1a202c,stroke:#4a5568,color:#fff
    style Agents fill:#2d3748,stroke:#4299e1,color:#fff
    style A1 fill:#2c5282,stroke:#63b3ed,color:#fff
    style A2 fill:#276749,stroke:#68d391,color:#fff
    style A3 fill:#744210,stroke:#ed8936,color:#fff
    style Services fill:#2d3748,stroke:#9f7aea,color:#fff
    style EB fill:#553c9a,stroke:#b794f4,color:#fff
```

---

## Slide 12: cloud-init Provisioning Flow

```mermaid
flowchart LR
    CI["cloud-init<br/>#cloud-config"] --> U["Create system users<br/>agent-build, agent-review"]
    U --> BV["Create btrfs subvolumes<br/>/data/agents/agent-*"]
    BV --> BD["Bind-mount as<br/>home directories"]
    BD --> DIR["Create ~/memory<br/>~/tools ~/work"]
    DIR --> TMP["Mount tmpfs<br/>~/memory/working"]
    TMP --> LOG["Set append-only<br/>~/work/actions.log"]
    LOG --> SD["Enable systemd<br/>agent@.service"]
    SD --> RUN["✅ Agents running"]

    style CI fill:#ed8936,stroke:#dd6b20,color:#fff
    style RUN fill:#48bb78,stroke:#38a169,color:#fff
```

---

## Slide 13: systemd Sandboxing Layers

```mermaid
flowchart TB
    subgraph Systemd["systemd agent@.service"]
        direction TB
        CG["CPUQuota=200%<br/>MemoryMax=8G<br/>IOWeight=100"]
        NS["ProtectSystem=strict<br/>ProtectHome=tmpfs<br/>PrivateTmp=true"]
        SEC["NoNewPrivileges=true<br/>User=agent-%i<br/>Group=agents"]
        BIND["BindPaths=/home/agent-%i"]
        LIFE["Restart=always<br/>RestartSec=5<br/>Type=notify"]
    end

    CG --> |"Resource Limits"| PROC["Agent Process"]
    NS --> |"Filesystem Sandbox"| PROC
    SEC --> |"Privilege Restriction"| PROC
    BIND --> |"Home Access"| PROC
    LIFE --> |"Lifecycle"| PROC

    style Systemd fill:#2d3748,stroke:#4299e1,color:#fff
    style PROC fill:#48bb78,stroke:#38a169,color:#fff
```

---

## Slide 14: Memory Architecture — Three Tiers

```mermaid
flowchart TB
    subgraph Agent["Agent Process"]
        RT["Agent Runtime"]
    end

    RT <--> W
    RT <--> S
    RT <--> LT

    subgraph Working["Working Memory"]
        W["tmpfs (RAM)<br/>512MB<br/>⏱️ Minutes"]
    end

    subgraph Session["Session Memory"]
        S["btrfs subvolume<br/>~/memory/session/<br/>⏱️ Hours–Days"]
        SS["📸 Snapshots<br/>→ btrfs send/receive"]
    end
    S --- SS

    subgraph LongTerm["Long-Term Memory"]
        LT["AgentCore / MemoriesDB<br/>~/memory/long-term/<br/>⏱️ Persistent"]
    end

    RESTART["Agent killed /<br/>recreated"] -.->|"cleared"| W
    RESTART -.->|"preserved"| S
    RESTART -.->|"preserved"| LT

    style Working fill:#fc8181,stroke:#e53e3e,color:#fff
    style Session fill:#f6e05e,stroke:#d69e2e,color:#000
    style LongTerm fill:#68d391,stroke:#38a169,color:#000
    style Agent fill:#2d3748,stroke:#4299e1,color:#fff
    style RESTART fill:#e53e3e,stroke:#c53030,color:#fff
```

---

## Slide 15: Event-Driven Activation & microVM Decision

```mermaid
flowchart TB
    EVT["Event arrives<br/>(systemd .socket)"] --> WAKE["Socket activation<br/>spawns agent service"]

    WAKE --> EVAL{"Agent evaluates task"}

    EVAL -->|"Trusted + lightweight"| LOCAL["On-host process<br/>⚡ 0ms overhead"]
    EVAL -->|"Untrusted / isolated"| MVM["Firecracker microVM<br/>⚡ 125ms boot<br/>~30MB overhead"]
    EVAL -->|"Heavy compute<br/>(training)"| CLOUD["EC2 Spot instance<br/>btrfs send model →<br/>run training →<br/>btrfs send results ←"]

    LOCAL --> RESULT["Results → ~/work/"]
    MVM --> RESULT
    CLOUD --> RESULT

    RESULT --> REVIEW{"Agent reviews<br/>output"}
    REVIEW -->|"Accept"| MERGE["Merge into<br/>agent subvolume"]
    REVIEW -->|"Reject"| DISCARD["Discard scratch<br/>subvolume"]

    style EVT fill:#553c9a,stroke:#b794f4,color:#fff
    style EVAL fill:#2d3748,stroke:#4299e1,color:#fff
    style LOCAL fill:#48bb78,stroke:#38a169,color:#fff
    style MVM fill:#ed8936,stroke:#dd6b20,color:#fff
    style CLOUD fill:#4299e1,stroke:#2b6cb0,color:#fff
    style REVIEW fill:#2d3748,stroke:#4299e1,color:#fff
```

---

## Slide 16: Transparency & Audit Trail

```mermaid
flowchart LR
    subgraph Task["Task Execution"]
        direction TB
        REQ["task.json<br/>📋 what was requested"]
        PLAN["plan.json<br/>🗺️ what agent decided"]
        LOG["actions.log<br/>📝 what it did<br/>(append-only)"]
        ART["artifacts/<br/>📦 what it produced"]
        RR["review-request.json<br/>👀 submitted for review"]
        REQ --> PLAN --> LOG --> ART --> RR
    end

    subgraph Audit["Audit Mechanisms"]
        direction TB
        SNAP["btrfs snapshot<br/>before/after diff"]
        JRNL["journalctl<br/>--user-unit=agent-*"]
        PEER["Peer agents<br/>read ~/work/<br/>(group=agents)"]
    end

    Task --> Audit

    style Task fill:#2d3748,stroke:#4299e1,color:#fff
    style Audit fill:#276749,stroke:#68d391,color:#fff
```

---

## Slide 17: btrfs as Universal Replication

```mermaid
flowchart TB
    subgraph Source["Source Host"]
        MW["Model Weights<br/>/data/model"]
        AM["Agent Memory<br/>/data/agents/*/memory"]
        WP["Work Products<br/>/data/agents/*/work"]
        AH["Full Agent Home<br/>/data/agents/*"]
    end

    MW -->|"btrfs send -p"| DELTA["Incremental<br/>Delta Stream"]
    AM -->|"btrfs send -p"| DELTA
    WP -->|"btrfs send"| DELTA
    AH -->|"btrfs send"| DELTA

    DELTA -->|"SSH / netcat"| RCV["btrfs receive"]

    subgraph Target["Target Host(s)"]
        MW2["Model Weights ✅"]
        AM2["Agent Memory ✅"]
        WP2["Work Products ✅"]
        AH2["Full Agent ✅"]
    end

    RCV --> MW2
    RCV --> AM2
    RCV --> WP2
    RCV --> AH2

    style Source fill:#2d3748,stroke:#4299e1,color:#fff
    style Target fill:#2d3748,stroke:#48bb78,color:#fff
    style DELTA fill:#ed8936,stroke:#dd6b20,color:#fff
    style RCV fill:#48bb78,stroke:#38a169,color:#fff
```

---

## Slide 18: Why Not Containers? — Visual Comparison

```mermaid
flowchart LR
    subgraph Container["Container Model"]
        direction TB
        DF["Dockerfile"] --> IMG["Image Build"]
        IMG --> REG["Registry Push"]
        REG --> PULL["Registry Pull"]
        PULL --> CRT["Container Runtime"]
        CRT --> K8S["K8s Orchestrator"]
        K8S --> POD["Pod"]
    end

    subgraph AgentModel["Agent-as-User Model"]
        direction TB
        CC["cloud-config"] --> CINIT["cloud-init"]
        CINIT --> USR["Linux User + btrfs subvol"]
        USR --> SYS["systemd service"]
        SYS --> PROC["Process"]
    end

    style Container fill:#e53e3e,stroke:#c53030,color:#fff
    style AgentModel fill:#48bb78,stroke:#38a169,color:#fff
```

---

## Slide 19: Gaps — Where Containers Still Win

```mermaid
mindmap
  root((What This<br/>Doesn't Solve))
    Multi-Host
      Service discovery
      Cross-host DNS
      Agent gossip protocol needed
    Scaling
      replicas: 50 is trivial in k8s
      UID templating gets awkward
    Identity
      UIDs are local
      Need SPIFFE/SPIRE
    State Conflicts
      btrfs send is eventually consistent
      No merge strategy
      Last snapshot wins
    Observability
      journald is per-host
      Need centralized aggregation
    Fine-Grained Control
      No admission control
      No resource negotiation
      Rollback is all-or-nothing
```
