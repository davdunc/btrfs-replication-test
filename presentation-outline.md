# BTRFS Send/Receive for LLM Model Replication on AWS
## Presentation Outline & Speaker Notes

---

## Slide 1: Title

**BTRFS Send/Receive: Efficient LLM Model Distribution on AWS**

- Incremental replication of large model artifacts using filesystem-level deltas
- Fedora Cloud Base 43 on Amazon EC2
- github.com/davdunc/btrfs-replication-test

---

## Slide 2: The Problem

**Distributing LLM models at scale is expensive**

- A 70B parameter model at fp16 ≈ 140 GB
- Fine-tuning changes a fraction of the weights
- Redeploying the full model to N inference servers = N × 140 GB transferred
- Traditional approaches: S3 sync, rsync, container image layers — all file-level granularity

*Speaker notes: Frame this as a bandwidth and time problem. Every training iteration that produces updated weights triggers a full redistribution cycle. At scale with dozens of inference nodes, this becomes the bottleneck.*

---

## Slide 3: The Insight — Filesystem-Level Deltas

**BTRFS send computes binary deltas between snapshots**

```
btrfs send -p <parent-snapshot> <child-snapshot>
```

- Copy-on-write filesystem tracks which blocks actually changed
- Send stream contains only modified extents — not file-level diffs
- Receive applies the delta atomically on the target
- No application-level diffing, no rsync checksumming

*Speaker notes: The key differentiator vs rsync or S3 sync is that btrfs knows at the block level what changed because of CoW. rsync has to checksum every file. For a 140GB model where 2GB of weights changed, btrfs send transmits ~2GB. rsync has to read all 140GB to figure that out.*

---

## Slide 4: Architecture

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

*Speaker notes: One-to-many via tee. For large fan-out, use a relay tree: source → 2-3 relays → N targets. Each relay receives and re-sends.*

---

## Slide 5: Demo Environment Setup

**Fedora Cloud Base 43 on EC2 — two instances, btrfs data volumes**

```bash
# User data: runs at boot on each instance
dnf install -y btrfs-progs

mkfs.btrfs -f -L btrfs-data /dev/nvme1n1
mkdir -p /data
mount /dev/nvme1n1 /data

# Create the model subvolume
btrfs subvolume create /data/model
```

*Speaker notes: Fedora 43 ships kernel 6.x with full btrfs support. We attach a dedicated gp3 EBS volume and format it as btrfs. The subvolume is the unit of replication.*

---

## Slide 6: Step 1 — Write Model Data

**Populate the subvolume with model artifacts**

```bash
# Simulate model weights and config
dd if=/dev/urandom of=/data/model/weights.bin bs=1M count=100
echo '{"model":"test-llm","version":"1.0","layers":32}' \
  > /data/model/config.json
```

*Speaker notes: In production this is your training output — safetensors files, tokenizer, config. The subvolume holds the complete model checkpoint.*

---

## Slide 7: Step 2 — Snapshot & Full Send

**Create a read-only snapshot and send the full baseline**

```bash
# Read-only snapshot (required for send)
btrfs subvolume snapshot -r /data/model /data/model-snap-v1

# Full send to target over SSH
btrfs send /data/model-snap-v1 | \
  ssh fedora@target 'sudo btrfs receive /data/'
```

- Snapshot is instantaneous (CoW metadata operation)
- Send streams the entire subvolume contents
- Receive creates an identical read-only snapshot on the target

*Speaker notes: This is the baseline. First deployment is always a full send. The snapshot is instant regardless of data size — it's just a metadata pointer.*

---

## Slide 8: Step 3 — Update & Incremental Send

**After fine-tuning, send only what changed**

```bash
# Model updated by training
dd if=/dev/urandom of=/data/model/weights.bin bs=1M count=100
echo '{"model":"test-llm","version":"2.0","layers":32}' \
  > /data/model/config.json

# New snapshot
btrfs subvolume snapshot -r /data/model /data/model-snap-v2

# Incremental: only the delta between v1 and v2
btrfs send -p /data/model-snap-v1 /data/model-snap-v2 | \
  ssh fedora@target 'sudo btrfs receive /data/'
```

*Speaker notes: This is where the magic happens. The `-p` flag tells btrfs send to compute the difference between snap-v1 and snap-v2. Only changed blocks are transmitted. For a real model where fine-tuning touches 1-5% of weights, this is a massive reduction.*

---

## Slide 9: One-to-Many Replication

**Fan out to multiple inference servers simultaneously**

```bash
btrfs send -p /data/model-snap-v1 /data/model-snap-v2 | \
  tee >(ssh fedora@target2 'sudo btrfs receive /data/') \
      >(ssh fedora@target3 'sudo btrfs receive /data/') | \
  ssh fedora@target4 'sudo btrfs receive /data/'
```

- Single read of the delta from source
- Streamed in parallel to all targets
- For large fan-out (50+ nodes): use a relay tree

*Speaker notes: tee duplicates the stream without re-reading the source. The bottleneck becomes the source's network bandwidth. For very large clusters, have 3-4 relay nodes that each re-fan to 10-15 targets.*

---

## Slide 10: Making It Writable on the Target

**Received snapshots are read-only — create a writable clone for serving**

```bash
# On the target: create writable snapshot from received data
btrfs subvolume snapshot /data/model-snap-v2 /data/model

# Point your inference server at /data/model
# Atomic swap: stop service, delete old, snapshot new, start service
```

- Writable snapshot is instant (CoW)
- Old snapshots can be retained for rollback
- Rollback = snapshot the previous version, no re-transfer needed

*Speaker notes: This gives you instant rollback for free. Keep the last 3-5 snapshots. If v2 has a regression, just re-snapshot v1 and restart the inference server. Zero network traffic for rollback.*

---

## Slide 11: Performance Characteristics

| Operation | Time complexity | Network cost |
|-----------|----------------|-------------|
| Snapshot creation | O(1) — metadata only | None |
| Full send (100 GB model) | O(data size) | ~100 GB |
| Incremental send (2% changed) | O(delta size) | ~2 GB |
| Writable snapshot on target | O(1) — metadata only | None |
| Rollback to previous version | O(1) — metadata only | None |

**With zstd compression:**
```bash
mount -o compress=zstd /dev/nvme1n1 /data
```
15-30% reduction on model weights, applied transparently.

*Speaker notes: The incremental send scales with the size of the change, not the size of the model. This is fundamentally different from rsync which scales with total data size for the checksumming phase.*

---

## Slide 12: Production Considerations

- **Instance types**: i4i / im4gn for storage-dense inference, p5 for training
- **EBS volumes**: gp3 for cost efficiency, io2 for high-throughput sends
- **Automation**: SSM Run Command triggered by EventBridge on training completion
- **Monitoring**: `btrfs filesystem usage` for space, CloudWatch custom metrics for send duration
- **Security**: SSH keys managed via Secrets Manager, or use SSM Session Manager port forwarding
- **Compression**: `compress=zstd` mount option — free 15-30% savings

---

## Slide 13: Comparison with Alternatives

| Approach | Full deploy | Incremental | Rollback | Complexity |
|----------|-----------|-------------|----------|------------|
| S3 sync + download | O(model) | File-level | Re-download | Low |
| rsync | O(model) checksum | Block-level | Re-sync | Medium |
| Container image layers | O(layer) | Layer-level | Tag swap | High |
| **btrfs send/receive** | **O(model)** | **Block-level, no checksum** | **Instant (local)** | **Medium** |

*Speaker notes: btrfs send wins on incremental because it doesn't need to checksum — it already knows what changed. It wins on rollback because snapshots are local and instant. The tradeoff is you need btrfs on both ends.*

---

## Slide 14: What's Next

- Extend to real model weights (Llama, Mistral) with actual fine-tuning deltas
- Benchmark send/receive throughput vs rsync on 70B+ models
- Automate with EventBridge → Step Functions → SSM Run Command pipeline
- Evaluate btrfs deduplication for multi-model serving on the same volume
- Test with Graviton4 (aarch64 Fedora 43 AMI available)

**Try it yourself:** github.com/davdunc/btrfs-replication-test

---

## Slide 15: Q&A

**Resources:**
- Repository: github.com/davdunc/btrfs-replication-test
- btrfs docs: btrfs.readthedocs.io
- Fedora Cloud: fedoraproject.org/cloud
