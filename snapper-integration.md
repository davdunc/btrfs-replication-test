# openSUSE-Native Slides for oSC26

---

## Slide: openSUSE Native: btrfs + Snapper

### Agent Task Execution with Snapper Snapshots

Snapper's pre/post snapshot mechanism maps directly to agent task lifecycle:

```
┌─────────────────────────────────────────────────┐
│  Agent Task Lifecycle (Snapper-backed)           │
├─────────────────────────────────────────────────┤
│  1. PRE-SNAPSHOT  → capture state before task   │
│  2. EXECUTE TASK  → agent modifies subvolume    │
│  3. POST-SNAPSHOT → capture state after task    │
│  4. DIFF/AUDIT    → snapper diff for review     │
│  5. ROLLBACK      → undochange if failed        │
└─────────────────────────────────────────────────┘
```

### Code Examples

```bash
# Agent "researcher" starts a task
SNAP_NUM=$(snapper -c agent_researcher create --type pre \
  --description "task: summarize quarterly data" --print-number)

# ... agent executes task, writes to ~/agent_researcher/ ...

# Task complete - create post snapshot
snapper -c agent_researcher create --type post --pre-number $SNAP_NUM \
  --description "task complete: 3 files written"

# Audit what the agent changed
snapper -c agent_researcher diff $SNAP_NUM..$(($SNAP_NUM + 1))

# Rollback if task produced bad output
snapper -c agent_researcher undochange $SNAP_NUM..$(($SNAP_NUM + 1))
```

### Snapper Config per Agent (one config = one subvolume)

```bash
# Create agent subvolume + snapper config
btrfs subvolume create /agents/researcher
snapper -c agent_researcher create-config /agents/researcher

# Set retention policy (keep last 10 task pairs)
snapper -c agent_researcher set-config \
  NUMBER_LIMIT="10" NUMBER_LIMIT_IMPORTANT="20"
```

### Key Insight

> Every agent task becomes an auditable, reversible transaction.
> No custom tooling needed - Snapper is the orchestration layer.

---

## Slide: Edge Deployment: MicroOS + btrfs Agents

### Architecture: Immutable OS + Mutable Agent Layer

```
┌─══════════════════════════════════════════════════════┐
│                SYSTEM DISK (btrfs)                     │
├───────────────────────────────────────────────────────┤
│  OS LAYER (immutable, transactional-update)           │
│  ┌─────────────────────────────────────────────┐     │
│  │  / (read-only snapshot)                      │     │
│  │  transactional-update → atomic OS upgrades   │     │
│  │  rollback via GRUB snapshot boot             │     │
│  └─────────────────────────────────────────────┘     │
├───────────────────────────────────────────────────────┤
│  AGENT LAYER (mutable subvolumes on /agents)          │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐             │
│  │researcher│ │ coder    │ │ reviewer │  ← subvols   │
│  │ snapper  │ │ snapper  │ │ snapper  │  ← per-agent │
│  │ config   │ │ config   │ │ config   │    snapshots  │
│  └──────────┘ └──────────┘ └──────────┘             │
│                                                       │
│  ★ Agent subvolumes SURVIVE OS rollbacks              │
│  ★ Each agent has independent snapshot timeline       │
│  ★ btrfs send/receive replicates agent state to edge  │
└───────────────────────────────────────────────────────┘
```

### Why MicroOS/SL-Micro/Kalpa?

| Property | OS Layer | Agent Layer |
|----------|----------|-------------|
| Mutability | Immutable (read-only root) | Mutable (read-write subvolumes) |
| Updates | `transactional-update` (atomic) | Agent task snapshots (Snapper) |
| Rollback | GRUB boots previous snapshot | `snapper undochange` per agent |
| Lifecycle | OS team controls | Agent orchestrator controls |
| Survives reboot | Yes (persistent) | Yes (separate subvolumes) |

### Deployment Pattern

```bash
# OS updates happen atomically (don't touch agent data)
transactional-update dup
# → creates new root snapshot, stages packages
# → reboot activates new root
# → /agents subvolumes untouched

# Agent deployment via btrfs send/receive from hub
btrfs send /agents/researcher | ssh edge-node btrfs receive /agents/

# Edge agent operates independently, snapshots locally
# Periodic sync back to hub:
btrfs send -p /agents/researcher/.snapshots/1/snapshot \
  /agents/researcher/.snapshots/5/snapshot | \
  ssh hub btrfs receive /archive/edge-01/researcher/
```

### Key Insight

> The OS is cattle (immutable, replaceable, rolled back freely).
> The agents are pets (stateful, snapshotted, replicated).
> btrfs gives both patterns on the same filesystem.
