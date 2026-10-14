# GitHub 项目交付工作流

这是供 Codex / ChatGPT Work 调用的 **github-project** 技能。项目开工时启用，完成并验证后由代理提交、自动创建缺失的私有仓库或更新已有仓库。用户不需要手动运行 PowerShell。

## 如何调用

在 Codex 新聊天中这样说：

~~~text
$github-project
帮我做一个图片批量处理工具，完成验证后自动交付到 GitHub。
没有仓库就创建私有仓库，已有绑定仓库就更新。
~~~

已有项目：

~~~text
使用 github-project 工作流继续这个项目，结束后同步到已有 GitHub 仓库。
~~~

ChatGPT Work 在实际可用的技能选择器中选择“GitHub 项目交付”。本机安装不会自动给其他云端工作区安装或授权；云端须加载技能、项目和认证。官方说明：[Build skills](https://learn.chatgpt.com/docs/build-skills)。

## 新增能力

| 能力 | 实际行为 | 默认 |
|---|---|---|
| 项目绑定 | .github-project.json 保存仓库、分支、交付范围和备份设置；保存开工前改动及暂存基线 | 启用 |
| 发布预检 | 候选文件清单；扫描固定提交及全部可达历史中的敏感路径、已知密钥格式、文件大小 | 启用 |
| 并发保护 | 仓库文件锁；推送固定 SHA；检测推送期间本地 HEAD 前进；不附带推送标签/子模块仓库 | 启用 |
| 自检与报告 | Doctor/Plan 只读检查；发布 JSON/Markdown 报告、最近尝试及最近成功提交 | 启用 |
| 发布前备份 | ZIP、文件清单和 SHA-256；用户启用后失败会停止发布 | 关闭，可选 |
| GitHub Actions | 按已有 Python/npm/PowerShell 检查生成，保留已有工作流和依赖方式 | 可选 |

配置文件不含密码或令牌，也不作为另一个聊天的发布授权。本技能在激活的项目任务中执行，不是后台监听器。

## 文件与维护

- SKILL.md：代理执行流程和授权边界。
- scripts/project-workflow.ps1：Initialize / Doctor / Plan。
- scripts/publish-github.ps1：预检、固定提交、锁、建库、推送、远端核验。
- scripts/workflow-common.ps1：配置、候选清单、历史扫描及本地报告。
- scripts/backup-project.ps1：可选的独立 Git 项目备份。
- scripts/add-project-ci.ps1：可选 CI 生成器。
- references/configuration.md：配置字段、状态路径、扫描限制。
- references/portable.md：非 Windows / 云端 Work。
- tests/test-workflow.ps1、tests/test-ci.ps1：隔离本地回归；不修改真实 GitHub 项目。
- VALIDATION.md / validation-results.json：本版本验证证据。

## 本机安装与环境

用户级安装目录为 %USERPROFILE%\.agents\skills\github-project，跨项目可用。技能选择器未刷新时新建聊天或重启应用。Windows 脚本兼容 Windows PowerShell 5.1 和 PowerShell 7，需要 Git 与已登录的 GitHub CLI。当前机器 gh 回退为 D:\DevTools\bin\gh.exe，优先使用 PATH 里的实际工具。不修改全局 Git 认证配置。

## 测试方法

用户可以在一个新的 Codex 聊天中调用：

~~~text
$github-project
做一个最小 Python 示例项目，创建私有测试仓库 github-project-smoke-test。
先运行测试，再自动发布；最后修改 README 再同步一次，核对复用同一个仓库。
~~~

该示例会创建真实仓库，只有实际发出这个请求时才执行。开发者回归使用 PowerShell：

~~~powershell
pwsh -NoProfile -File .\tests\test-workflow.ps1
powershell.exe -NoProfile -File .\tests\test-workflow.ps1
pwsh -NoProfile -File .\tests\test-ci.ps1
powershell.exe -NoProfile -File .\tests\test-ci.ps1
~~~

发布回归使用临时目录、模拟 GitHub 元数据和真实本地 bare Git 传输；不接触真实远端。测试覆盖敏感文件/历史、并发提交、原有暂存区、非快进保护和可选备份。CI 测试验证生成内容与实际 Python/npm 检查命令。临时发布回归目录保留 results.json 便于定位失败。

## 实际边界

敏感内容扫描是有限规则检查，不保证发现所有秘密：默认仅扫描不超过 1 MiB 的文本对象（可设 1–5 MiB），更大的对象会列出警告，二进制不做内容规则匹配。普通 Git 文件大小默认上限 100 MiB，可降低；大文件/LFS 需按项目单独处理。[GitHub 文件限制](https://docs.github.com/en/repositories/working-with-files/managing-large-files/about-large-files-on-github)。

备份不是加密或 VSS 快照，不备份可重建环境，独立 Git 历史可能含早期敏感内容；工作树共享 Git 目录等不支持的布局会明确停止。CI 自动适配覆盖常见入口，自定义构建流程需要按项目现有规则调整。远端领先时不会强推覆盖。
