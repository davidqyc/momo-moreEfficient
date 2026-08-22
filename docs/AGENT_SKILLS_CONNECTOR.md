# momo-moreEfficient ↔ agent-skills Connector

```text
status=CANONICAL_PROJECT_AGENT_SKILLS_CONNECTOR
sourceRepo=davidqyc/agent-skills
projectInstance=instances/momo-moreEfficient.yml
connectorContract=PROJECT_CONNECTOR_CONTRACT.md
```

This file is intentionally a **thin routing entry**. It must not copy Skill bodies, maintain a second model/effort matrix, or store momo's current Issue/PR/WIP/next/dates.

## Read order

Resolve current project truth first:

```text
latest explicit Owner instruction
> current GitHub Issue / latest comments / PR
> docs/decision-log.md
> docs/PROJECT_STATE.md
> AGENTS.md
> davidqyc/agent-skills@main:instances/momo-moreEfficient.yml
> cross-project Skill defaults
> old prompts / chats
```

Cross-project Skills never override current product facts.

## Cross-project routing

Before a new/fresh formal external-Agent Prompt, live-read:

```text
davidqyc/agent-skills@main:README.md
skills/prompt-release-skill-preflight/SKILL.md
instances/momo-moreEfficient.yml
```

Let the live Prompt-release preflight + project instance determine the task-relevant Skill set. Do not keep a manually duplicated Skill inventory in this file.

For every coding-Agent model / reasoning-depth / effort decision, also apply the live JIT route:

```text
skills/reasoning-depth-remote-preflight/SKILL.md
→ skills/coding-reasoning-depth-routing/SKILL.md
→ task/tool-specific additions as required
```

Do not inherit a previous round's depth by inertia.

If an Owner-facing terminal/shell/bootstrap/recovery command is about to be sent, immediately before presentation apply:

```text
skills/owner-terminal-pre-send-enforcement/SKILL.md
```

Session-start reading does not satisfy that JIT gate.

## Project-specific authority

momo-specific product/safety/risk/ROI behavior belongs in:

```text
AGENTS.md
docs/decision-log.md
docs/PROJECT_STATE.md
current Issue / PR / task authority
```

Stable project-specific Agent routing belongs in:

```text
davidqyc/agent-skills@main:instances/momo-moreEfficient.yml
```

Do not put dated architecture-reset conclusions or current release state back into this connector.

## Failure behavior

If `agent-skills` is unreadable:

- do not claim current cross-project Agent routing was verified;
- do not guess reasoning depth/model rules from this thin connector;
- use project-local product/safety authority only for what it actually governs;
- re-verify `agent-skills` before the next formal external-Agent Prompt or Owner-facing terminal command.

Core rule:

> Route, do not mirror.
