# Project instructions

## Code exploration: CodeGraph first

If a `.codegraph/` directory exists at the repo root, use `codegraph_explore` first (see the global `~/.claude/CLAUDE.md`) and treat the source it returns as already read.

This also covers `caveman-explore`, the `Explore` agent and `cavecrew-investigator`: try `codegraph_explore` first and only delegate to one of these when it comes back empty or the question is about non-code (docs, config, logs). Subagents cost a fresh context each time, so don't spawn one for something a single `codegraph_explore` call answers.
