# PFR: cloud-init MCP Configuration Module (cc_mcp_config)

## Summary

Add a cloud-init module for managing Model Context Protocol (MCP) configuration files that define AI agent capabilities and permission boundaries. Configs are root-owned and agent-readable — agents cannot modify their own capabilities.

## Business Justification

MCP is becoming the standard protocol for defining what tools and resources an AI agent can access. Today, writing these configs requires `write_files` with manual ownership/permission management and no schema validation. A native module enforces the security invariant that MCP config is system policy (like `sshd_config`), not user preference.

## Feature Description

```yaml
#cloud-config
mcp_config:
  base_path: /etc/agent-config
  owner: root
  group: agents
  mode: "0644"
  agents:
    agent-build:
      mcpServers:
        filesystem:
          command: mcp-fs
          args: ["--root", "/home/agent-build"]
        btrfs:
          command: mcp-btrfs
          args: ["--subvolume", "/data/agents/agent-build"]
      permissions:
        allowedPaths: ["/home/agent-build", "/data/model"]
        deniedPaths: ["/etc", "/root", "/home/agent-*"]
        allowedCommands: ["btrfs subvolume snapshot", "btrfs send"]
    agent-review:
      mcpServers:
        filesystem:
          command: mcp-fs
          args: ["--root", "/home/agent-review", "--read-only"]
      permissions:
        allowedPaths: ["/home/agent-review", "/home/agent-build/work"]
        deniedPaths: ["/etc", "/root"]
        allowedCommands: []
```

Behaviors:
- Creates `/etc/agent-config/<agent>/mcp.json` for each defined agent
- Files are root-owned, agent-group-readable (configurable mode, default 0644)
- Agents cannot modify their own capability definitions
- Validates MCP JSON schema before writing
- Integrates with systemd `BindReadOnlyPaths` for runtime enforcement

## Security Model

MCP config is system policy, not user preference — stored in `/etc/agent-config/`, not `~/.config/`. This follows the OpenSSH pattern where `sshd_config` is root-owned and the daemon reads it at startup. A privileged monitor process reads MCP config and validates requests from unprivileged agent runtimes. Agents that compromise their own process still cannot escalate capabilities.

## Reference Implementation

Working PoC: https://github.com/davdunc/btrfs-replication-test/blob/main/cloud-init-agents.yaml

Architecture slides: https://github.com/davdunc/btrfs-replication-test/blob/main/slides.html (slides 14-16)

## Acceptance Criteria

1. Writes per-agent MCP JSON configs with correct ownership and permissions
2. Validates JSON schema before writing
3. Creates directory structure under configurable base path
4. Supports per-agent permission scoping (allowedPaths, deniedPaths, allowedCommands)
5. Works on Ubuntu 24.04+ and Fedora 43+
6. Documentation and integration tests

## Priority

Medium

## Contact

David Duncan — davdunc@amazon.com
