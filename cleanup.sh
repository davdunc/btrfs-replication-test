#!/bin/bash
# Cleanup: terminate instances and delete security group
set -euo pipefail

SCRIPT_DIR="$(dirname "$0")"
source "${SCRIPT_DIR}/env.sh"

echo "Terminating instances..."
aws ec2 terminate-instances --region "$REGION" --instance-ids "$SRC_ID" "$TGT_ID"
aws ec2 wait instance-terminated --region "$REGION" --instance-ids "$SRC_ID" "$TGT_ID"

echo "Deleting security group..."
aws ec2 delete-security-group --region "$REGION" --group-id "$SG_ID"

echo "Cleanup complete."
