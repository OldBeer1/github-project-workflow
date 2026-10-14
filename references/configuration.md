# 配置、状态与交付记录

## 项目配置

Initialize 在项目根保存 .github-project.json。它可随项目提交，不存储令牌、密码或可执行命令。只接受已知字段，schemaVersion 为 2。

~~~json
{
  "schemaVersion": 2,
  "repository": "OWNER/REPO",
  "remote": "origin",
  "branch": "main",
  "visibility": "Private",
  "include": ["*"],
  "exclude": [".github-project.local/*", "work/*", "*/work/*"],
  "maxFileMiB": 100,
  "maxTextScanMiB": 1,
  "backupBeforePublish": false,
  "backupRoot": null
}
~~~

| 字段 | 含义 |
|---|---|
| repository | GitHub OWNER/REPO；与已有 remote 冲突时拒绝发布 |
| remote / branch | 目标远程与分支；已有项目保留实际分支，分支与绑定不同时停止 |
| visibility | 仅控制新建仓库；Private 默认；不修改已有库可见性 |
| include / exclude | 相对路径的 PowerShell 通配规则；不是 .gitignore 语法；拒绝绝对路径及 .. |
| maxFileMiB | 1–100 的整数，按 1 MiB = 1,048,576 字节；超过则阻断 |
| maxTextScanMiB | 1–5 的整数；超过的内容不做秘密匹配，在预检报告显示警告 |
| backupBeforePublish | 布尔值，默认 false |
| backupRoot | 项目外的本机备份目录；null 使用附带脚本默认 D:\ProjectBackups |

显式命令参数可覆盖配置，但不能绕过原远程绑定、分支约束和安全检查。配置和状态帮助代理恢复任务，不能授予发布权限；新聊天需当前用户直接调用技能或要求发布。

## 本地状态

已有 Git 项目放在 git rev-parse --absolute-git-dir 返回目录的 github-project 子目录，通常为：

- .git/github-project/baseline.json：首次 Initialize 时原有状态、暂存 raw diff、起始 HEAD。
- .git/github-project/state.json：最近尝试、最近成功发布的 SHA、状态、失败步骤及报告位置。
- .git/github-project/reports/<时间>-<随机值>.json / .md：每次实际发布过程的记录。

非 Git 项目开工基线临时保存为 .github-project.local/baseline.json，并添加忽略项。Git 初始化后该原始基线仍保留在旧位置，代理检查原始位置；后续发布记录存入 Git 目录。继续任务不得将当前修改重新当作开工基线。

发布互斥文件在 Git common dir 的 github-project.publish.guard，关联 worktree 共享同一把锁。文件存在不代表仍锁定，进程退出后系统释放独占句柄。不要为了重试删除 guard。失败实例只写唯一报告；只有持锁实例替换共享状态。

报告记录仓库、分支、固定 SHA、预检文件/问题/警告、备份信息、失败步骤和远端核验。匹配到的秘密值不写入报告。路径与行号可用于定位。预检查之前的配置/登录错误不一定产生报告。

## 预检范围

候选清单包含 Git 已跟踪与未忽略的未跟踪文件，并标注是否属于交付范围。敏感文件名、环境与缓存目录始终排除；示例 .env.example/.env.sample/.env.template 允许。清单不会自动暂存。

发布前以已提交 SHA 为准，检查当前树及全部可达历史，避免删除秘密后仍把旧提交上传，也不相信本地 remote-tracking refs 是最新的。文件排除规则不能从 Git 历史移除已提交内容，检测到时停止并保留用户历史。

内容规则当前覆盖私钥头、GitHub 常见令牌前缀与 AWS access key id；不是全面秘密扫描器。NUL 二进制对象跳过内容匹配。大于 maxTextScanMiB 的对象显示警告，代理应单独检查；不自动加 LFS、不改写历史。子模块目标仓库内容不在本仓库扫描范围，推送禁用递归子模块发布。

## 恢复

- 推送失败：查看 report 的 Step/Error，保留本地提交和已建库；修复后对同一项目重新发布。
- 远端前进：获取并审阅差异、保留用户工作，正常整合和验证后再推；不 force。
- LocalHeadMoved=true：远端仅与原固定提交匹配，本地出现新提交/分支变化；重新审阅并发布新 HEAD。
- 备份失败：用户开启的备份是交付前置条件；先修复目录、正在写入的文件或不支持的布局，不静默绕过。
