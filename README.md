# BTRFS Send/Receive Replication Test — Fedora Cloud Base 43

## Architecture

```
┌─────────────────────┐         btrfs send          ┌─────────────────────┐
│   SOURCE (t3.large) │ ──────────────────────────▶  │   TARGET (t3.large) │
│                     │    incremental deltas        │                     │
│  /data (btrfs 50G)  │    over SSH (private IP)     │  /data (btrfs 50G)  │
│   └─ model/         │                              │   └─ model-snap-v1/ │
│   └─ model-snap-v1/ │                              │   └─ model-snap-v2/ │
│   └─ model-snap-v2/ │                              │   └─ model/ (rw)    │
└─────────────────────┘                              └─────────────────────┘
```

## Quick Start

```bash
chmod +x deploy.sh btrfs-send-test.sh cleanup.sh

# 1. Deploy infrastructure
./deploy.sh

# 2. Source the environment
source env.sh

# 3. Copy SSH key to source so it can reach target over private network
scp -i ~/.ssh/davdunc_amazon ~/.ssh/davdunc_amazon fedora@$SRC_IP:~/.ssh/id_rsa
ssh -i ~/.ssh/davdunc_amazon fedora@$SRC_IP 'chmod 600 ~/.ssh/id_rsa'

# 4. Copy and run the btrfs test on source
scp -i ~/.ssh/davdunc_amazon btrfs-send-test.sh fedora@$SRC_IP:~
ssh -i ~/.ssh/davdunc_amazon fedora@$SRC_IP "sudo bash btrfs-send-test.sh $TGT_PRIV"

# 5. Verify on target
ssh -i ~/.ssh/davdunc_amazon fedora@$TGT_IP 'sudo btrfs subvolume list /data'

# 6. Cleanup
./cleanup.sh
```

## How btrfs send/receive works for LLM replication

The key insight: `btrfs send -p <parent> <child>` computes a **binary delta** between
two snapshots and streams only the changed blocks. For LLM model files this means:

1. **Initial deployment**: Full snapshot send (~size of model weights)
2. **Fine-tuning updates**: Only changed weight tensors are transmitted
3. **One-to-many**: Pipe the same send stream to multiple targets simultaneously:

```bash
btrfs send -p /data/model-snap-v1 /data/model-snap-v2 | \
  tee >(ssh fedora@target2 'sudo btrfs receive /data/') | \
  ssh fedora@target3 'sudo btrfs receive /data/'
```

## Scaling to production LLM replication

For real model distribution, consider:

- **Instance type**: Use storage-optimized (i4i, im4gn) or memory-optimized (r7i) for
  large models. For training, p5/p4d with EFA.
- **Volume size**: Match to model size. A 70B parameter model at fp16 ≈ 140GB.
- **Compression**: `mount -o compress=zstd` on the btrfs volume — model weights
  compress ~15-30% with zstd.
- **Parallel send**: For many targets, use a fan-out tree (source → 2 relays → N targets)
  rather than source → N directly.
- **Automation**: Wrap the snapshot/send cycle in a systemd timer or triggered by
  training job completion via EventBridge → SSM Run Command.

## Files

| File | Purpose |
|------|---------|
| `deploy.sh` | Creates SG, launches 2 Fedora 43 instances with btrfs volumes |
| `btrfs-send-test.sh` | Runs on source: writes data, snapshots, sends full + incremental |
| `cleanup.sh` | Terminates instances, deletes SG |
| `env.sh` | (generated) Instance IDs and IPs for scripting |
