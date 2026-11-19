# 项目入口

Rails 服务端和管理后台在 `backend/`，Rails 命令在该目录执行。微信小程序工程在 `miniapp/`。公开的安装与使用说明放在根目录 `docs/`，入口见 [README](README.md)。

团队开发文档与参考素材统一放在根目录 `dev-docs/`，仅保存在本地。开发前先读 `dev-docs/开发约定.md`，再按任务查对应资料。新克隆的工作区需要从团队本地资料补齐这个目录。

| 开发任务 | 本地入口 |
| --- | --- |
| 阶段安排 | `dev-docs/project/开源版开发计划.md` |
| 数据库与业务范围 | `dev-docs/database/预约挂号开源版_数据库-开发说明.md`，同目录有 Word 字段字典与 Excel 功能清单 |
| 后台页面与基础设施 | `dev-docs/backend/admin-ui.md`、`dev-docs/backend/infrastructure.md` |
| 设置、日志、应用管理与微信提审 | `dev-docs/backend/modules/` 下对应模块的开发说明 |
| 小程序开发与页面参考 | `dev-docs/miniapp/小程序开发规范.md`、`dev-docs/miniapp/外观参考/` |

新文档按读者归入这两个目录。运行时加载的代码、图片和字体留在对应工程。提交标题和正文使用英文，标题沿用 `type: short description`。
