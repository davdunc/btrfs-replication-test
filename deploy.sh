#!/bin/bash
set -euo pipefail

REGION="us-east-2"
AMI="ami-01c7a4d75aaf8a437"  # Fedora-Cloud-Base-AmazonEC2.x86_64-43-20260305.0
KEY="davdunc_amazon"
INSTANCE_TYPE="t3.large"
SUBNET="subnet-2a7c5160"
VOL_SIZE=50  # GB for btrfs data volume

TAG_KEY="Project"
TAG_VAL="btrfs-replication-test"

# --- Security Group ---
echo "Creating security group..."
SG_ID=$(aws ec2 create-security-group \
  --region "$REGION" \
  --group-name "btrfs-repl-test-sg" \
  --description "BTRFS replication test - SSH + inter-node" \
  --query 'GroupId' --output text)

aws ec2 authorize-security-group-ingress --region "$REGION" \
  --group-id "$SG_ID" --protocol tcp --port 22 --cidr 0.0.0.0/0

# Allow all traffic between members of this SG (for btrfs send over ssh)
aws ec2 authorize-security-group-ingress --region "$REGION" \
  --group-id "$SG_ID" --protocol -1 --source-group "$SG_ID"

echo "Security group: $SG_ID"

# --- User data: install btrfs-progs, format attached volume ---
# Source: creates writable /data/model subvolume for writing model data
USERDATA_SRC=$(cat <<'CLOUD'
#!/bin/bash
dnf install -y btrfs-progs
while [ ! -b /dev/nvme1n1 ]; do sleep 1; done
mkfs.btrfs -f -L btrfs-data /dev/nvme1n1
mkdir -p /data
mount -o noatime /dev/nvme1n1 /data
echo 'LABEL=btrfs-data /data btrfs defaults,noatime 0 0' >> /etc/fstab
btrfs subvolume create /data/model
CLOUD
)

# Target: only formats and mounts — no subvolume created.
# Subvolumes arrive via btrfs receive; writable snapshots created from those.
USERDATA_TGT=$(cat <<'CLOUD'
#!/bin/bash
dnf install -y btrfs-progs
while [ ! -b /dev/nvme1n1 ]; do sleep 1; done
mkfs.btrfs -f -L btrfs-data /dev/nvme1n1
mkdir -p /data
mount -o noatime /dev/nvme1n1 /data
echo 'LABEL=btrfs-data /data btrfs defaults,noatime 0 0' >> /etc/fstab
CLOUD
)

USERDATA_SRC_B64=$(echo "$USERDATA_SRC" | base64)
USERDATA_TGT_B64=$(echo "$USERDATA_TGT" | base64)

# --- Launch function ---
launch_instance() {
  local name=$1
  local ud_b64=$2
  aws ec2 run-instances \
    --region "$REGION" \
    --image-id "$AMI" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY" \
    --subnet-id "$SUBNET" \
    --security-group-ids "$SG_ID" \
    --associate-public-ip-address \
    --block-device-mappings "[
      {\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":20,\"VolumeType\":\"gp3\"}},
      {\"DeviceName\":\"/dev/sdf\",\"Ebs\":{\"VolumeSize\":${VOL_SIZE},\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}
    ]" \
    --user-data "$ud_b64" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${name}},{Key=${TAG_KEY},Value=${TAG_VAL}}]" \
    --query 'Instances[0].InstanceId' --output text
}

echo "Launching source instance..."
SRC_ID=$(launch_instance "btrfs-source" "$USERDATA_SRC_B64")
echo "Source: $SRC_ID"

echo "Launching target instance..."
TGT_ID=$(launch_instance "btrfs-target" "$USERDATA_TGT_B64")
echo "Target: $TGT_ID"

echo "Waiting for instances to be running..."
aws ec2 wait instance-running --region "$REGION" --instance-ids "$SRC_ID" "$TGT_ID"

# Get IPs
SRC_IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$SRC_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
TGT_IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$TGT_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
SRC_PRIV=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$SRC_ID" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
TGT_PRIV=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$TGT_ID" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)

cat <<EOF

=== BTRFS Replication Test Environment ===
Source:  $SRC_ID  public=$SRC_IP  private=$SRC_PRIV
Target:  $TGT_ID  public=$TGT_IP  private=$TGT_PRIV
SG:      $SG_ID

SSH:
  ssh -i ~/.ssh/davdunc_amazon fedora@$SRC_IP
  ssh -i ~/.ssh/davdunc_amazon fedora@$TGT_IP

Save these for cleanup:
  export SRC_ID=$SRC_ID TGT_ID=$TGT_ID SG_ID=$SG_ID REGION=$REGION
EOF

# Save env for later use
cat > "$(dirname "$0")/env.sh" <<EOF
export SRC_ID=$SRC_ID
export TGT_ID=$TGT_ID
export SG_ID=$SG_ID
export SRC_IP=$SRC_IP
export TGT_IP=$TGT_IP
export SRC_PRIV=$SRC_PRIV
export TGT_PRIV=$TGT_PRIV
export REGION=$REGION
EOF
echo "Environment saved to env.sh"
