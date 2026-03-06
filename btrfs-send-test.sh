#!/bin/bash
# Run on SOURCE instance after user-data completes
# Demonstrates: btrfs send/receive with block-level CoW delta efficiency
#
# KEY CONCEPT: btrfs CoW + send -p gives true block-level deltas when
# files are modified in-place (mmap, partial write, append) rather than
# fully rewritten. Only the touched 4K blocks get new extents.
#
# This matters for:
#   - mmap-based weight formats (safetensors, GGUF) — fine-tuning touches
#     a subset of blocks within large files
#   - Agent session memory — append-only or partially updated state files
#   - Logs, indexes, databases — append/update patterns
#
# The WORST case is full-file rewrite (dd, cp, torch.save to same path)
# which allocates all-new blocks and sends the entire file.
set -euo pipefail

TARGET_PRIV="${1:?Usage: $0 <target-private-ip>}"

echo "=== Step 1: Create model weights in /data/model ==="
# 100MB file simulating a large weights file (safetensors/GGUF)
dd if=/dev/urandom of=/data/model/weights.bin bs=1M count=100 status=progress
echo '{"model":"test-llm","version":"1.0","layers":32}' > /data/model/config.json
echo "Model size: $(du -sh /data/model/weights.bin | cut -f1)"

echo ""
echo "=== Step 2: Snapshot v1 (baseline) ==="
btrfs subvolume snapshot -r /data/model /data/model-snap-v1

echo ""
echo "=== Step 3: Full send to target ==="
btrfs send --proto 2 --compressed-data /data/model-snap-v1 | \
  pv | \
  ssh -o StrictHostKeyChecking=no "fedora@${TARGET_PRIV}" \
  'sudo btrfs receive /data/'
echo "Full send complete."

echo ""
echo "=== Step 4: In-place partial update (simulating mmap fine-tuning) ==="
# Write 2MB at offset 10MB — like an mmap'd framework updating a weight tensor.
# Only ~512 btrfs blocks (4K each) get CoW'd. The other 24,576 blocks are unchanged.
dd if=/dev/urandom of=/data/model/weights.bin bs=1M count=2 seek=10 conv=notrunc status=progress
echo '{"model":"test-llm","version":"2.0","layers":32}' > /data/model/config.json
echo ""
echo "Modified: 2MB of 100MB weights file in-place (2% of blocks)"

echo ""
echo "=== Step 5: Snapshot v2 ==="
btrfs subvolume snapshot -r /data/model /data/model-snap-v2

echo ""
echo "=== Step 6: Incremental send (v1 → v2) ==="
echo "Only CoW'd blocks are transmitted — expect ~2MB, not 100MB."
btrfs send --proto 2 --compressed-data -p /data/model-snap-v1 /data/model-snap-v2 | \
  pv | \
  ssh -o StrictHostKeyChecking=no "fedora@${TARGET_PRIV}" \
  'sudo btrfs receive /data/'

echo ""
echo "=== Done ==="
echo "On the target:"
echo "  /data/model-snap-v1  (baseline, read-only)"
echo "  /data/model-snap-v2  (incremental ~2MB delta, read-only)"
echo ""
echo "To serve v2:  sudo btrfs subvolume snapshot /data/model-snap-v2 /data/model"
echo ""
echo "IMPORTANT: Never flip received snapshots to read-write (breaks received_uuid)."
echo ""
echo "=== Where this works ==="
echo "  ✓ mmap/partial write (safetensors, GGUF)  — block-level delta"
echo "  ✓ Agent session memory (append/update)     — block-level delta"
echo "  ✓ Sharded models (unchanged shards)        — zero bytes"
echo "  ✗ Full file rewrite (torch.save, dd)       — sends entire file"
