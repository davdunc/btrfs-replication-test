# PFR: cloud-init Agent User Provisioning Module (cc_agent_users)

## Summary

Add a cloud-init module for provisioning AI agents as Linux service account users with btrfs subvolume home directories, tiered memory layout, append-only audit logs, and systemd service enablement.

## Business Justification

AI agents are an emerging workload on cloud instances. Provisioning them today requires 60-80 lines of `runcmd` shell scripting to create users, subvolumes, directory structures, file attributes, and services. A native module standardizes this pattern, enforces security best practices, and reduces config to ~15 lines of declarative YAML.

## Feature Description

```yaml
#cloud-config
agent_users:
  - name: agent-build
    groups: [agents]
    shell: /usr/bin/agent-shell
    storage:
      type: btrfs-subvolume
      path: /data/agents/agent-build
      directories: [memory, tools, work]
      bind_home: true
    memory:
      working: {type: tmpfs, size: 512M, path: memory/working}
      session: {type: btrfs, path: memory/session}
      long_term: {type: mount, path: memory/long-term}
    audit:
      append_only: [work/actions.log]
    service:
      template: agent@.service
      enable: true
```

Behaviors:
- Creates system user (no login shell by default)
- Creates btrfs subvolume as home directory when btrfs backing store is detected
- Sets up memory tier directories (working tmpfs / session btrfs / long-term mount point)
- Marks specified audit logs as append-only (`chattr +a`)
- Enables templated systemd service unit

## Security Model

Follows the OpenSSH privilege separation pattern. Agent users run as unprivileged UIDs with systemd hardening: `ProtectSystem=strict`, `ProtectHome=tmpfs`, `BindPaths` for home, `NoNewPrivileges=true`. Agents cannot escalate privileges or modify their own service configuration.

## Reference Implementation

Working PoC using existing cloud-init primitives: https://github.com/davdunc/btrfs-replication-test/blob/main/cloud-init-agents.yaml

## Acceptance Criteria

1. Creates system users with btrfs subvolume homes and memory tier directories
2. Append-only audit log enforcement via file attributes
3. systemd template service enablement
4. Falls back gracefully to ext4/xfs (skip subvolume, use regular directories)
5. Works on Ubuntu 24.04+ and Fedora 43+
6. Documentation and integration tests

## Priority

Medium

## Contact

David Duncan — davdunc@amazon.com
