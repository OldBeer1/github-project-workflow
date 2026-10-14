# GitHub 项目交付工作流

这是供 Codex / ChatGPT Work 调用的技能，名字为 **github-project**。项目开工时启用，项目完成并验证后由代理提交、创建缺失仓库或推送已有仓库。用户不需要手动运行 PowerShell。

## 开始一个项目

Codex 新聊天可这样说：

```text
$github-project
帮我做一个图片批量处理工具，完成验证后自动交付到 GitHub。
没有仓库就创建私有仓库，已有绑定仓库就更新。
```

ChatGPT Work 在技能选择器中 @ 选择 **GitHub 项目交付**，然后描述项目。也可以明确说：

```text
使用 github-project 工作流完成这个项目，结束后自动同步到 GitHub。
```

指定已有仓库：

```text
$github-project
继续完善当前项目，完成后推送到它已有的 GitHub 仓库，保留当前分支。
```

也可给出 OWNER/REPO。省略时代理优先沿用项目已有 GitHub 上游或 origin，无绑定时根据真实项目名称选择仓库名，使用当前 gh 登录账号，默认私有。

## 代理会完成什么

1. 开工前检查项目范围、现有改动、Git 分支、GitHub 身份和仓库绑定。
2. 已有远程历史先克隆/沿用，再开发。无库时在交付阶段创建私有仓库。
3. 完成项目、验证成果，选择本次任务文件提交，保留用户原有无关修改和暂存内容。
4. 推送当前分支，核对远端提交与本地 HEAD 一致，再返回仓库和提交链接。

只激活本次项目的发布；新聊天需用户明确调用或要求自动交付。不运行后台监听器，不给所有聊天安装全局完成钩子。沙箱/账号批准要求仍然有效。选择已有公开仓库会沿用其可见性，新建默认私有。

## 文件

- SKILL.md：代理工作流。
- agents/openai.yaml：技能选择器名称和提示。
- scripts/publish-github.ps1：Windows 辅助脚本，只发布已经审阅的本地提交。
- references/portable.md：非 Windows 和云端 Work 的执行说明。
- VALIDATION.md / validation-results.json：实际验证证据。

## 本机安装

用户级目录为 %USERPROFILE%\.agents\skills\github-project，跨项目可用。技能选择器未刷新时新建聊天或重启应用。

Windows 环境需要 Git 和已登录的 gh。此电脑的 gh 回退路径为 D:\DevTools\bin\gh.exe；辅助脚本优先用实际 PATH 中可用的工具，不存储令牌。

不同云端 Work 环境需要单独加载技能、项目文件和认证，本机安装不会自动替云端授权。可用技能上传/安装入口导入本技能包；能否直接发现取决于客户端和工作区。

官方加载路径与调用说明：[Build skills](https://learn.chatgpt.com/docs/build-skills)。

## 发布行为

辅助脚本默认复用 origin，支持指定 Remote。检查配置地址以及 Git 最终解析的读写地址，防止 insteadOf/pushInsteadOf 导向另一个仓库。缺少仓库才创建；已有同名库不会再次创建。非快进推送保留 Git 原有保护，推送失败保留本地提交，不 force push。

权限、冲突或无法安全区分的用户改动会明确报告，代理不会把这些失败冒充为已同步。大文件、私密素材和密码应在交付文件选择阶段处理。
