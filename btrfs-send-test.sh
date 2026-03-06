#!/bin/bash
# Run on SOURCE instance after user-data completes
# Demonstrates: write data → snapshot → btrfs send → receive on target
set -euo pipefail

TARGET_PRIV="${1:?Usage: $0 <target-private-ip>}"

echo "=== Step 1: Write test data to /data/model ==="
# Simulate model weights / artifacts
dd if=/dev/urandom of=/data/model/weights.bin bs=1M count=100
echo '{"model":"test-llm","version":"1.0","layers":32}' > /data/model/config.json
echo "Data written to /data/model"
btrfs filesystem usage /data

echo "=== Step 2: Create read-only snapshot ==="
btrfs subvolume snapshot -r /data/model /data/model-snap-v1
echo "Snapshot created: /data/model-snap-v1"

echo "=== Step 3: Send snapshot to target ==="
# btrfs send streams the snapshot over SSH to btrfs receive on the target
btrfs send /data/model-snap-v1 | \
  ssh -o StrictHostKeyChecking=no "fedora@${TARGET_PRIV}" \
  'sudo btrfs receive /data/'

echo "=== Full snapshot sent to target ==="

echo "=== Step 4: Write incremental changes (simulating model update) ==="
dd if=/dev/urandom of=/data/model/weights.bin bs=1M count=100
echo '{"model":"test-llm","version":"2.0","layers":32}' > /data/model/config.json

echo "=== Step 5: Create second snapshot ==="
btrfs subvolume snapshot -r /data/model /data/model-snap-v2

echo "=== Step 6: Send INCREMENTAL delta (v1 → v2) ==="
btrfs send -p /data/model-snap-v1 /data/model-snap-v2 | \
  ssh -o StrictHostKeyChecking=no "fedora@${TARGET_PRIV}" \
  'sudo btrfs receive /data/'

echo "=== Incremental send complete ==="
echo ""
echo "On the target, you now have:"
echo "  /data/model-snap-v1  (full baseline)"
echo "  /data/model-snap-v2  (incremental update)"
echo ""
echo "To make v2 writable on the target:"
echo "  sudo btrfs subvolume snapshot /data/model-snap-v2 /data/model"
