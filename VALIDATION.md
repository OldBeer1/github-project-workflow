# 验证记录

日期：2026-10-14（Asia/Shanghai）。本记录区分本地隔离验证与真实 GitHub 发布。

## v2 本地回归

| 测试 | Windows PowerShell 5.1.26100.9444 | PowerShell 7.6.5 |
|---|---:|---:|
| 发布流程隔离回归 | 35/35 | 35/35 |
| 可选 CI 生成器 | 19/19 | 19/19 |
| 合计 | 52/52 | 52/52 |

108 项全部通过。逐项结果见 validation-results.json。发布回归使用模拟 GitHub 元数据与真实本地 bare Git 传输，不创建真实测试库。

覆盖：新建默认私有库、更新/幂等、目标冲突与 URL 重写、已有非快进/无关历史、用户暂存及未跟踪内容保留、初始化基线、只读自检/预览、非法配置、敏感文件名/令牌内容/已删除历史、旧远程引用、大小阈值、互斥锁、无锁失败状态保护、推送期间并发 HEAD 前进、禁用附带标签、备份与 SHA-256、最近成功提交保留。

CI 验证覆盖 Python compile-only / unittest / 已声明 pytest 路由、npm ci 与现有 test/lint/build、混合项目、PowerShell 双版本、已有工作流不覆盖、非 npm 拒绝、版本输入验证及官方 Actions 固定 SHA。Python 编译/unittest 和 npm 命令已实际运行，故意错误会正确失败；pytest 路由未联网安装第三方 pytest 执行。四类生成 YAML 已用现有 PyYAML 解析触发器/权限/jobs 结构。

技能格式 quick_validate.py 通过；全部运行脚本语法通过；git diff --check 通过；真实绑定 OldBeer1/github-project-workflow 的 Doctor 返回 Healthy=true。

## 独立复核

skill-creator 要求的独立前向检查发现并修正：

1. 不再用可能过期的本地 remote refs 排除敏感历史，改扫全部可达历史。
2. 推送固定 SHA 并关闭 followTags 与子模块递归发布。
3. 只有持锁实例更新共享 state，其他失败仅保存唯一报告。

对应问题均增加实际隔离回归。独立只读复核通过，不等同于 GitHub 端到端验证。

## 已有真实交付证据

v1 已创建私有仓库 [OldBeer1/github-project-workflow](https://github.com/OldBeer1/github-project-workflow)，main。首次 dfa150bd305874eaa7a1c8f5f01e6585a2ace07f、后续 79633cfed03dcc87baba41828720735e3a2c5f72 已真实推送并核对远端；GitHub API 已确认 private=true。

v2 的真实发布、安装包及托管 CI 结果另记于本机交付报告；本地通过不能代替托管 runner 的结果。

## 能力边界

本机安装、当前聊天发现、跨新聊天调用与云端 Work 是不同验证层次。当前环境已列出本技能；未声称所有新聊天或云端工作区已加载并授权。云端需实际技能、项目与认证。

内容扫描仅有限规则及大小阈值，不保证发现所有秘密；备份不是加密/VSS 快照；共享 Git worktree 的备份有布局限制。SSH 凭据推送、GitHub Enterprise、云端非 Windows 等价执行、真实多人竞争 GitHub 分支未实测。本机并发测试使用真实本地 Git 且在推送期间实际创建新提交。

## 首次托管 CI 与修正

提交 abf1cc376513e91d6678fd282af2f59b935eb04e 已实际推送并核对远端。首次托管运行中 PowerShell 7 全通过，Windows PowerShell 5.1 的两项已删除历史敏感内容测试失败：[首次运行](https://github.com/OldBeer1/github-project-workflow/actions/runs/38586052772)。

历史对象元数据查询已改为无需 stdin 的 Git 批量枚举，再严格筛选固定提交可达的命名对象；任何对象元数据缺失都阻断。增加 exit 0 但元数据为空的阻断测试，以及无关不可达秘密 blob 不扩大扫描范围的测试。两代 PowerShell 本地发布回归均为 35/35，CI 生成器各 19/19，共 108/108。

最终托管复跑结果见 [Project checks](https://github.com/OldBeer1/github-project-workflow/actions/workflows/project-checks.yml) 及本机升级交付报告。初次失败保留，不把它称为通过。