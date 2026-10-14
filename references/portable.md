# 非 Windows 与云端 Work

先识别当前宿主与实际工具，不把本机 D 盘路径带到云容器。技能文件和已登录的本机 gh 不会因此自动同步到云端。

## 可用 Git 和 gh

使用宿主实际 shell 执行命令。按 SKILL.md 确定项目根、仓库、分支与提交范围，先完成内容与验证。

- gh api user --jq .login：确认当前账号。
- gh api repos/OWNER/REPO：确认存在、写权限和默认分支。只有明确 HTTP 404 可当作不存在；网络与其他权限错误不能当作缺库。
- 远程存在且本地新建项目时，先克隆并使用已有历史。非空本地目录不要覆盖；晚调用时用独立克隆与逐文件导入。
- 新项目先维护忽略规则，git init -b main，选择交付文件并提交。已有项目保留当前分支与用户原有改动。
- 仓库缺失才 gh repo create OWNER/REPO --private。公开仅在用户要求时使用 --public；不改变已有仓库可见性。
- origin 尚不存在时添加 https://github.com/OWNER/REPO.git。存在时先检查读取与推送地址属于同一目标，避免静默重绑。
- 使用现有认证机制，或仅对该 Git 命令配置 credential.https://github.com.helper 为 !gh auth git-credential；不把令牌写入命令、文件或日志。
- 推送明确的当前分支，普通 git push --set-upstream origin BRANCH，不 force。用 git ls-remote origin refs/heads/BRANCH 对比 git rev-parse HEAD。

推送失败后保留本地提交与远程已创建仓库，按 SKILL.md 的重试/冲突条件处理。

## 只有连接器

先检查当前连接器是否真的支持创建仓库、提交完整文件/二进制和目标分支更新。工具缺少这些能力时不要用文本文件接口冒充完整 Git 推送，也不要擅自让用户把令牌贴进聊天。

可以完成可审阅成果，明确缺少的能力；在具备 Git/gh 或完整 GitHub 工具的已授权环境继续交付。仅发现或安装技能不会自动建立 GitHub 账号授权。

## 调用与安装

Codex 使用 $github-project。ChatGPT Work 在技能选择器中 @ 选择“GitHub 项目交付”；自然语言“使用 github-project，完成后自动同步 GitHub”也能明确任务意图。

本地用户级安装放在 ~/.agents/skills/github-project。云端或不同客户端是否已加载要查看实际技能列表；未加载时通过宿主技能上传/安装入口导入技能包，或直接附上 SKILL.md 并明确要求遵循。不要把本机安装宣称为所有云端工作区已安装。

官方依据：
- [Build skills](https://learn.chatgpt.com/docs/build-skills)
- [Skill controls](https://learn.chatgpt.com/docs/enterprise/skills)
