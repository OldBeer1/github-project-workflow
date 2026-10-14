---
name: github-project
description: "GitHub 项目交付工作流。用户要求项目完成后自动上传 GitHub、没有仓库自动创建或继续更新已有仓库时使用；可在 Codex/Work 开工前调用，并在同一项目交付时完成配置、预检、备份和发布。"
---

# GitHub 项目交付

把 GitHub 交付作为当前项目的完成条件。开工时绑定项目，完成内容与验证后自动提交、建库或推送，核对远端并返回仓库和提交链接。代理执行脚本，用户无需记终端命令。

## 激活与授权

用户在当前任务调用本技能，或明确要求“做完自动上传 GitHub”，即授权为**该项目**创建默认私有仓库、提交任务文件并推送到已确认目标。该授权延续到项目完成及上下文压缩后，不在每次提交前重复询问。用户指定公开仓库、组织、分支或限制时优先遵循。

技能发现、读取配置/状态、远程地址或另一个项目的授权，都不授权发布新项目。只要求计划/预览时只做预览。本技能不是后台监听器或所有聊天的完成钩子。云端 Work 需要该环境实际可访问的技能、项目与 GitHub 凭据。

## 开工：绑定目标与保留基线

1. 找到真正的项目根目录，读取项目约定、依赖和验证入口。检查原有 Git 状态、暂存区、分支、远程及交付范围。文档/设计任务选择成果、必要可编辑源和导出；生成目录名不代表项目名。
2. 优先用户指定目标，否则沿用当前 GitHub 上游、origin 或唯一明确的 GitHub 远程。无绑定时按真实项目名称选择有意义的仓库名，归属已登录账号，默认 private。多个不同目标或与原绑定冲突时澄清目标。
3. 用 publish-github.ps1 -Inspect 核实账号、GitHub 目标、权限与分支。Windows 优先 PATH 的 Git/gh，此电脑 gh 回退路径为 D:\DevTools\bin\gh.exe。简短告知目标及已有/将创建。
4. **同名已有仓库先使用其历史。** 未建立项目时先克隆再开发；本地非空目录遇到非空远程时，用独立克隆检查冲突，只导入审阅过的交付文件，保留原件。不要用独立首次提交覆盖已有历史。
5. 用 project-workflow.ps1 -Action Initialize 保存 .github-project.json 与开工基线；使用项目实际目录，别顺手配置整个父目录。记录原有暂存内容，继续任务不覆盖首次基线。配置可提交，只保存仓库/分支/范围/阈值/备份设置，禁止凭据与执行命令。保存配置不能代替当前用户授权。
6. 授权、目标和原有改动保留到任务上下文/压缩摘要。配置跨聊天帮助定位；新聊天仍需用户调用或明确要求发布。需要 CI 时在项目已有验证方式明确后生成，不能凭技术栈猜测试命令。

## 交付：完成、审阅、发布

1. 完成项目及相称的测试/检查；失败继续修复。缺少必要检查要说明，不能把未验证说成通过。用户接受未完成状态时才发布标明的 WIP。
2. 按项目约定维护 .gitignore，运行 -Action Plan 查看候选文件范围及已提交内容预检。排除环境、缓存、本机状态和凭据，保留配置模板、锁文件、源文件与交付导出。候选清单不是对未提交文本的完整秘密扫描，暂存前仍须审阅差异。
3. 新项目初始化 main；已有仓库保留当前分支。只暂存本次任务文件并检查 git diff --cached。普通 commit 会一并提交原有暂存内容，必须先隔离任务范围并保留用户原暂存状态。只有整个新项目已核实可发布时才 git add -- .。无变化跳过空提交。
4. 运行发布辅助脚本。它不会暂存或提交，会扫描当前提交及全部可达历史，检查敏感文件名、部分已知密钥格式和大小，固定审阅后的 SHA，再普通推送。排除规则不能从已有 Git 历史中移除文件；遇到阻断先定位，不自动改写历史或删除用户数据。
5. 开启可选备份时先执行随技能附带的 backup-project.ps1，核对 ZIP/清单/哈希。备份包括独立 Git 历史，环境和敏感文件名默认排除；不是加密或原子快照。工作树布局/正在写入导致备份失败时停止发布，不能静默跳过用户启用的备份。
6. 发布锁串行处理同一仓库的交付。只推选定 SHA 到选定分支，禁用附带标签与子模块仓库推送，不 force。推送后核对远端 SHA，写本地 JSON/Markdown 报告与状态。
7. 只有远端等于固定 SHA 且本地 HEAD/分支仍相同，才报告“已同步最新提交”。LocalHeadMoved=true 表示仅原固定提交发布成功；重新审阅、验证新提交后再发布，不把并发产生的提交当已上传。
8. 返回仓库、分支、提交、验证结果、报告及可选备份位置；列明未交付文件或用户改动。PR 仅在用户另要求时创建，并使用宿主的 PR 附加工具。

## Windows 脚本入口

路径相对于本 SKILL.md：

~~~powershell
# 开工：只读检查，然后保存绑定与原始基线
& '<skill-dir>\scripts\publish-github.ps1' -ProjectPath '<project-root>' -Repository 'OWNER/REPO' -Inspect
& '<skill-dir>\scripts\project-workflow.ps1' -ProjectPath '<project-root>' -Repository 'OWNER/REPO' -Action Initialize

# 自检 / 发布清单；两者不会建库、提交或推送
& '<skill-dir>\scripts\project-workflow.ps1' -ProjectPath '<project-root>' -Action Doctor
& '<skill-dir>\scripts\project-workflow.ps1' -ProjectPath '<project-root>' -Action Plan

# 已完成内容、选文件并提交后，复用配置或 origin
& '<skill-dir>\scripts\publish-github.ps1' -ProjectPath '<project-root>'

# 可选：先备份；备份目录必须在项目之外
& '<skill-dir>\scripts\publish-github.ps1' -ProjectPath '<project-root>' -BackupBeforePublish -BackupRoot '<backup-directory>'

# 可选：先预览，再生成适合已有检查方式的 CI
& '<skill-dir>\scripts\add-project-ci.ps1' -ProjectPath '<project-root>' -WhatIf
~~~

-Initialize/-Doctor/-Plan 也可通过 publish-github.ps1 转发；-WhatIf 不写配置、报告、远程或仓库。只有新建公开库才加 -Visibility Public，不改变已有库可见性。默认备份关闭；本机备份脚本默认 D:\ProjectBackups，其他机器应显式配置可用目录。

配置、状态、报告及扫描限制见 [references/configuration.md](references/configuration.md)。非 Windows/云端 Work 见 [references/portable.md](references/portable.md)。

## 可选 CI

add-project-ci.ps1 使用现有 Python、npm 或本工作流的 PowerShell 检查，固定官方 Actions 提交，使用 contents: read。已有 project-checks.yml 不覆盖，其他工作流保留；不更换包管理器、不修改依赖/锁文件。不能识别的项目测试入口先读取并理解项目，再手工适配。Python 无测试时只声明编译检查；npm 无 test/lint/build 时不生成空任务。

本地生成与测试通过不代表 GitHub runner 已通过。上传 .github/workflows 时 GitHub OAuth 可能要求额外 workflow 权限；通过官方登录流程取得，不索要聊天中的令牌。CI 失败继续定位由本次修改引入的问题。

## 失败与恢复

保留 Git 非快进保护。远端前进时读取差异并在保留用户工作前提下整合、验证；不要强推、删库、自动 stash 或改写历史。网络/权限错误只重试有依据的操作，两次同样失败后报告本地提交、失败步骤与恢复入口。建库后推送失败重用原库。

权限或宿主限制阻止交付时保存成果并明确“本地完成，GitHub 未同步”。初始路径、配置、认证等检查失败可能发生在报告建立之前；不能承诺所有失败都有报告。发布过程的失败保存唯一报告，只有持锁实例更新共享状态。
