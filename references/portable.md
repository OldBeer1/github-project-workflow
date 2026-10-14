# 非 Windows 与云端 Work

先核实宿主和实际工具。本机 D 盘、已安装技能与 gh 凭据不会自动出现在云端工作区。

## 有 PowerShell 7、Git 和 gh

Windows 辅助脚本使用 Windows 本地路径规则；不要直接在 Linux 容器调用。按以下等价流程实现并保留 SKILL.md 的授权、原有改动和验证要求。

## 原生 Git / gh 流程

使用宿主实际 shell；下面是命令要点，不是可直接粘贴的跨平台脚本：

1. gh api user --jq .login 检查账号，gh api repos/OWNER/REPO 检查存在、权限和默认分支。仅明确 HTTP 404 可视为缺库。
2. 读取已有项目配置、真实根目录、Git 状态、原有暂存区、当前分支和有效读写 URL。保存当前项目绑定及基线，不存储凭据或命令，不把配置当授权。
3. 已有远程历史先克隆/沿用。非空本地目录保留原件，在独立克隆检查并导入审阅过的任务文件。新 Git 项目使用 main；已有仓库保留分支。
4. 维护忽略规则、按任务范围暂存、检查 diff 并提交，保留用户原暂存/未提交文件。记录 git rev-parse HEAD 得到固定 SHA，使用 git ls-tree、git rev-list --objects SHA 和 git cat-file 检查当前树及全部可达历史的敏感路径、内容与大小。不能直接拿本地远程引用排除历史。
5. 如用户开启备份，使用该环境可信工具备份并核对清单/哈希；不要尝试执行 Windows 路径。取得该仓库互斥锁后重新核对分支和 HEAD，远程 URL 的 insteadOf/pushInsteadOf 最终解析必须仍是同一 GitHub 库。
6. 仓库缺失才 gh repo create OWNER/REPO --private。公开仅在用户要求时用 --public。缺少 origin 才添加 canonical GitHub URL，不静默重绑。
7. 使用现有认证，或仅对单次 Git 命令设置 !gh auth git-credential，不把令牌写入命令/文件/日志。普通推送 git push --no-follow-tags --recurse-submodules=no origin SHA:refs/heads/BRANCH，禁止 force。推送前再次核对 HEAD。
8. git ls-remote origin refs/heads/BRANCH 核对固定 SHA，配置分支上游。核对本地 HEAD/分支是否仍相同；并发前进时只报告原 SHA 发布成功，重新审阅新提交后再交付。
9. 记录本地报告、失败步骤、最近成功提交和链接。共享状态只在持锁期间更新。按平台实现同等互斥/报告能力；缺少实现时明确未验证限制，不声称 Windows 新能力已在云端实测。

可选 CI 应复用项目已存在的测试、lint、build 和包管理器，不覆盖现有工作流，不把无测试的编译检查称为测试通过。

## 只有连接器

检查连接器是否支持建库、完整文件/二进制提交和分支更新。缺少能力时不能用文本接口冒充完整 Git 推送，不让用户把令牌贴进聊天。完成可审阅成果并说明缺少能力，在已授权且具备完整 Git 工具的环境继续。

## 调用和安装

Codex 使用 $github-project；Work 使用实际技能选择器。用户级本机目录为 ~/.agents/skills/github-project。不同客户端/云端须确认实际技能列表；未加载时使用宿主安装/上传入口，或附上 SKILL.md 明确要求遵循。

官方说明：[Build skills](https://learn.chatgpt.com/docs/build-skills)、[Skill controls](https://learn.chatgpt.com/docs/enterprise/skills)。
