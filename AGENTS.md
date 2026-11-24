# 项目入口

Rails 服务端和管理后台在 `backend/`，Rails 命令在该目录执行。微信小程序工程在 `miniapp/`。公开的安装与使用说明放在根目录 `docs/`，入口见 [README](README.md)。

团队开发文档与参考素材统一放在根目录 `dev-docs/`，仅保存在本地。开发前先读 `dev-docs/开发约定.md`，再按任务查对应资料。新克隆的工作区需要从团队本地资料补齐这个目录。

| 开发任务 | 本地入口 |
| --- | --- |
| 阶段安排 | `dev-docs/project/开源版开发计划.md` |
| 数据库与业务范围 | `dev-docs/database/预约挂号开源版_数据库-开发说明.md`，同目录有 Word 字段字典与 Excel 功能清单 |
| 后台页面与基础设施 | `dev-docs/backend/admin-ui.md`、`dev-docs/backend/infrastructure.md` |
| 设置、日志、通知、应用管理与微信提审 | `dev-docs/backend/modules/` 下对应模块的开发说明 |
| 小程序开发与页面参考 | `dev-docs/miniapp/小程序开发规范.md`、`dev-docs/miniapp/外观参考/` |

新文档按读者归入这两个目录。运行时加载的代码、图片和字体留在对应工程。提交标题和正文使用英文，标题沿用 `type: short description`。

每次提交前检查全部暂存改动，每次推送前逐个检查待推送的提交，包括后来又删除的内容。确认其中没有真实密钥或访问凭据后再执行。

## 后台组件与草稿

后台界面优先复用 `backend/app/views/admins/shared/` 的组件和项目已引入的 Tabler 样式。新布局先查 [后台样式规范](dev-docs/backend/admin-ui.md)，可在 Tabler 官网或本地模板找到对应示例。

侧栏按角色权限提供完整功能目录，顶栏只放常用快捷入口。「仅顶栏」模式沿用同一份快捷入口清单；开发和验收均以侧栏核对功能完整性。

待评审的组件集中在 [后台组件草稿](dev-docs/backend/admin-ui/drafts.md)，预览入口为 `/admins/components?tab=drafts`。草稿用示例数据在预览页验证交互，经用户确认后再提炼到 `admins/shared/` 并接入指定正式页面。涉及后台通知、任务监控或 Dashboard 时，先看该草稿和对应的开发约定。

## 后台私密配置

所有部署和角色统一使用只写凭据。管理端通过 `IntegrationSettings.form_field` 取得字段状态，表单复用 `admins/shared/configuration_field`。敏感字段每次渲染为空白输入框并关闭自动填充，编辑时直接显示正在填写的内容。已保存的凭据只显示「已配置」或「未配置」。公开标识显式声明 `public: true`，密文异常使用固定提示。

字段留空保留当前值，填写新值才替换，通过独立确认操作清除覆盖并恢复模块原有的部署回退。保存失败时重新填写凭据。新敏感设置接入加密存储和完整表单参数过滤。响应、导出及日志只使用安全状态、字段名和固定错误提示。用虚构凭据检查原始 HTTP 响应和日志，覆盖部署回退和提交失败。

## 小程序命名

各业务的默认名称用「小艾＋业务名＋小程序」，例如「小艾预约挂号小程序」「小艾电竞护航小程序」。`manifest.json` 的工程名称使用该默认值，首页在 `pages.json` 的 `navigationBarTitleText` 留空。首页自定义标题及其他展示应用名称的位置共用后台配置的小程序名称。后台尚未接入、读取失败或名称为空时，统一显示当前业务的默认名称。
