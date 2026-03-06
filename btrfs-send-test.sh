#!/bin/bash
# Run on SOURCE instance after user-data completes
# Demonstrates: sharded model → snapshot → btrfs send → incremental update
#
# KEY INSIGHT: btrfs send -p transmits blocks that differ between snapshots.
# CoW means ANY write allocates new blocks — even if content is identical.
# So overwriting a single weights file rewrites ALL its blocks, and the
# incremental send transmits the FULL file, not a content-level delta.
#
# Where incremental send wins:
#   - Sharded models: unchanged shards = zero bytes sent
#   - LoRA/adapters: base weights untouched, only adapter files are new
#   - Config/tokenizer: small files rarely change
#
# This demo simulates a sharded model where fine-tuning changes 1 of 4 shards.
set -euo pipefail

TARGET_PRIV="${1:?Usage: $0 <target-private-ip>}"

echo "=== Step 1: Create sharded model in /data/model ==="
# Simulate a sharded model: 4 weight shards + config + tokenizer
for i in 1 2 3 4; do
  dd if=/dev/urandom of=/data/model/shard-${i}.bin bs=1M count=25 status=progress
done
echo '{"model":"test-llm","version":"1.0","layers":32,"shards":4}' > /data/model/config.json
dd if=/dev/urandom of=/data/model/tokenizer.bin bs=1M count=5 status=progress
echo "Total model size:"
du -sh /data/model/

echo ""
echo "=== Step 2: Create read-only snapshot (v1 baseline) ==="
btrfs subvolume snapshot -r /data/model /data/model-snap-v1
echo "Snapshot created: /data/model-snap-v1"

echo ""
echo "=== Step 3: Full send to target ==="
btrfs send --proto 2 --compressed-data /data/model-snap-v1 | \
  pv | \
  ssh -o StrictHostKeyChecking=no "fedora@${TARGET_PRIV}" \
  'sudo btrfs receive /data/'
echo "Full snapshot sent."

echo ""
echo "=== Step 4: Simulate fine-tuning — update 1 of 4 shards ==="
# Only shard-2 changes. Shards 1, 3, 4, tokenizer, config are untouched.
dd if=/dev/urandom of=/data/model/shard-2.bin bs=1M count=25 status=progress
echo '{"model":"test-llm","version":"2.0","layers":32,"shards":4}' > /data/model/config.json
echo ""
echo "Changed files: shard-2.bin (25MB), config.json (<1KB)"
echo "Unchanged:     shard-{1,3,4}.bin (75MB), tokenizer.bin (5MB)"

echo ""
echo "=== Step 5: Create second snapshot ==="
btrfs subvolume snapshot -r /data/model /data/model-snap-v2

echo ""
echo "=== Step 6: Incremental send (v1 → v2) ==="
echo "Only changed blocks are transmitted — unchanged shards cost zero bytes."
btrfs send --proto 2 --compressed-data -p /data/model-snap-v1 /data/model-snap-v2 | \
  pv | \
  ssh -o StrictHostKeyChecking=no "fedora@${TARGET_PRIV}" \
  'sudo btrfs receive /data/'

echo ""
echo "=== Done ==="
echo "On the target you now have:"
echo "  /data/model-snap-v1  (full baseline, read-only)"
echo "  /data/model-snap-v2  (incremental — only shard-2 + config transferred)"
echo ""
echo "To make v2 writable on the target for serving:"
echo "  sudo btrfs subvolume snapshot /data/model-snap-v2 /data/model"
echo ""
echo "IMPORTANT: Do NOT change received read-only snapshots to read-write."
echo "  This breaks received_uuid and future incremental sends."
echo "  Always create a new writable snapshot instead."
echo ""
echo "=== When incremental send does NOT help ==="
echo "If your framework rewrites ALL shards (full checkpoint), every block is"
echo "new due to CoW, and the incremental send transmits the full model."
echo "btrfs send compares block ownership in the btree, not file content."
