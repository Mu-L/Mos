# Agent Skills

本目录存放仓库内可复用的 agent skill。新增、移动或删除 skill 后，要同步更新本文件和 `.agents/INDEX.md`。

## release-preparation

路径：`.agents/skills/release-preparation/SKILL.md`

触发场景：

- 准备 stable、beta 或 alpha release。
- bump version / build number。
- 创建 release build、archive、notarization、zip。
- 更新 Sparkle appcast。
- 创建 GitHub release draft。

约束：

- 不要跳过 skill 自带验证步骤。
- 不要在用户确认前发布 GitHub release。
- 不要在用户确认前推送发布分支。
