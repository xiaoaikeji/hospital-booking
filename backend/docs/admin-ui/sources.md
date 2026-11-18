# 材料索引

实际组件材料目录：`/Users/bithunter/Desktop/tabler-1.7.1/dashboard/`。下面的文件都相对于此目录，按需要查阅。

找不到对应材料时，立即向用户提问。

| 用途 | 原文件 |
| --- | --- |
| 图片、附件、输入、校验、各类选择 | `form-elements.html` |
| 分组表单和设置页 | `form-layout.html`、`settings.html` |
| 管理员登录、密码显示切换 | `sign-in.html` 原生布局、按钮及 `BEGIN INPUT GROUP PASSWORD TOGGLE` 脚本；替换项目品牌、中文和登录功能，去掉注册、找回密码及第三方登录 |
| 头像、尺寸与叠放 | `avatars.html` |
| 表格与行操作 | `tables.html` |
| 日期、范围、多日期及内嵌模式 | `datepicker.html` |
| 按钮和确认框 | `buttons.html`、`modals.html` |
| 页签、折叠、抽屉 | `tabs.html`、`accordion.html`、`offcanvas.html` |
| 信息网格与处理步骤 | `datagrid.html`、`steps.html` |
| 反馈、加载、进度 | `alerts.html`、`toasts.html`、`progress.html`、`placeholder.html` |
| 独立错误页布局、徽章、按钮、图标 | `error-404.html`、`sign-in-cover.html`、`badges.html`、`buttons.html`、`icons.html`；SVG 来自已选 AI 图的矢量描摹及细节修整，见[错误页插画](error-illustrations.md)，静态资源记录见 [素材清单](../../vendor/licenses/tabler/error-assets.json) |
| 原生复制 | `clipboard.html` |
| 官方 API | `dist/js/tabler.js` |
| 完整外观设置、主题切换与重置 | `index.html` 的 `BEGIN THEME SETTINGS` 和页尾 `themeDefaults` 脚本；`dist/js/tabler-theme.js`、`dist/css/tabler-themes.css` |

大雁 `/Users/bithunter/Projects/aitool.web` 主要用于参考后台使用场景。

用户指定沿用大雁的字体栈（`app/assets/stylesheets/shared/_typography.scss`）和提示 SVG（`app/views/backend/shared/_distribution_form.html.erb`）；两者分别在本项目的共享字体文件与 `layouts/admins/_icon.html.erb` 中统一维护。

项目沿用官方 Tabler 1.7.5 运行资源；Datepicker 配套库取自桌面示例，保持原样。日期清空只通过 [共享绑定](../../app/javascript/admins/datepicker.js) 调用官方 API。

图片及配套文件的原始路径和 SHA-256：[component-assets.json](../../vendor/licenses/tabler/component-assets.json)。
