# 小艾预约挂号系统

预约挂号系统的服务端与后台管理项目。

Ruby **3.4.12** / Rails **8.1.3.1** / PostgreSQL。

已接入 Tabler **1.7.5**、Turbo、Stimulus。项目样式使用 Dart Sass，资产由 Propshaft 发布，不使用 Node 打包工具。

## 资源入口

- `vendor/assets/tabler/css/tabler.min.css`：Tabler 官方样式。
- `vendor/assets/tabler/js/tabler.min.js`：Tabler 官方脚本，已包含 Bootstrap 和 Popper。
- `vendor/licenses/tabler/`：Tabler 官方许可证和包元信息。
- `app/assets/stylesheets/application.scss`：项目样式入口。
- `app/javascript/application.js`：项目脚本入口，加载 Turbo 和 Stimulus。
- `app/javascript/controllers/`：Stimulus 控制器。
- `app/views/layouts/application.html.erb`：统一加载 Tabler、项目 CSS 和 Importmap。

官方 Tabler 文件保持原样；自写样式和脚本放在 `app/`。SCSS 编译到 `app/assets/builds/application.css`，源码不发布，编译产物不入库。

## 本地运行

本机需要 PostgreSQL、Redis 和 ImageMagick。先启动 PostgreSQL、Redis，再执行：

```sh
bundle install
bin/rails db:prepare
bin/rails settings:encryption_keys
bin/rails admin:create
bin/rails dartsass:build
bin/dev
```

首次初始化后访问 `/admins/sign_in`，账号 `admin`、密码 `123456`。首个管理员只能通过命令创建；已有管理员时 `admin:create` 会停止，不会重置密码。后续账号由超级管理员在后台创建。

另开终端运行 `bin/jobs` 执行后台任务；开发时可另开终端运行 `bin/rails dartsass:watch` 监听样式变化。本地无需配置 ENV：Sidekiq 默认连接本机 Redis，文件默认存本地。加密主密钥保存在本机 credentials 中，不提交仓库；首次生成后再启动 Web 和任务进程。

## 基础设施

后台任务使用 Sidekiq + sidekiq-cron，生产缓存使用 Redis，不使用 Solid 三件套。Active Storage 标准表、MiniMagick 图片处理、中文与北京时间、后台公共基类及 Pagy 已接入。

管理员、系统配置及日志三张通用表已接入；业务表暂未建立。第三方配置读取遵守「系统配置表 > ENV > Rails credentials」，COS 可在后台配置，敏感字段加密入库，页面不回显。具体配置、生产启动与验证命令见 [基础设施说明](docs/infrastructure.md)。

## 后台管理

登录后访问 `/admins`。所有角色均可修改本人密码；超级管理员可管理账号、维护存储配置和查看操作日志，运营管理员与客服暂只访问现有只读业务预览，具体业务权限待对应功能开发时确定。

- `/admins/administrators`：管理员列表、新建、编辑、停用及密码重置。新建密码留空使用 `123456`，编辑留空保留原密码；不提供邮件找回。
- `/admins/account/edit`：凭当前密码修改本人密码。
- `/admins/system_settings/edit`：本地 / 腾讯云 COS 配置，显示来源，支持保留、替换及清除系统值。其他人修改后，旧表单须刷新再保存。
- `/admins/operation_logs`：管理操作日志，只读查询；日志表结构沿用数据库设计，正式业务日志规则后续确定。

## 后台静态预览

后台使用 Tabler 原生的纵向侧栏、单行顶栏、Dropdown、Collapse、Offcanvas、卡片和表格；首页、预约、客户及组件页仍为静态示例，不连接预约业务。

从侧栏「组件规范」进入 `/admins/components`。单个控件看「组件样式」，按钮组合看「页面操作」，完整列表看「列表规范」。开发时按 [样式规范目录](backend/docs/admin-ui.md) 定位对应规范和公共组件。

组件结构和素材以桌面 Tabler 1.7.1 为依据，运行资源沿用官方 1.7.5。按用户要求，`shared/_typography.scss` 使用大雁同款字体栈，提示图标使用大雁同款 SVG；组件布局与主题继续使用 Tabler。Datepicker 配套文件直接取自桌面示例，页面使用浮层、Modal 使用内嵌，并由共享绑定提供清空。文件控件与保存、删除保持演示。素材路径及校验记录见 `vendor/licenses/tabler/component-assets.json`，按需查阅 [材料索引](docs/admin-ui/sources.md)。

右下角画笔打开完整外观设置：配色、主题色、字体、灰阶、圆角，以及导航、页面宽度、吸顶、悬浮和侧栏折叠。控件及即时切换绑定来自桌面 Tabler 1.7.1 的 `index.html`，官方主题资源保持原样；偏好保存在当前浏览器，重置恢复默认的 `combined` 与 `fluid`。入口和用法见 `docs/admin-ui/containers.md`，资源记录见 `vendor/licenses/tabler/preview-assets.json`。

后台模板位于 `app/views/layouts/admins.html.erb`、`app/views/layouts/admins/` 和 `app/views/admins/dashboard/index.html.erb`。顶栏快捷入口在窄屏保持显示并横向滚动，右侧工具区不参与滚动；侧栏单独折叠，底部管理员区域仅在桌面显示。

`app/assets/stylesheets/admins/_header.scss` 由 `application.scss` 引入，只在 `.app-admins` 内隐藏导航滚动条、限制横向滚动手势。布局、颜色、圆角及组件继续使用 Tabler 原生实现；日期清空另有调用官方 API 的共享绑定，不自行绘制组件，不编写界面用的 Rails 测试。

预约列表预览位于 `/admins/reservations`，可从顶栏「预约」或侧栏「预约管理 → 预约列表」进入。使用 24 条内存示例数据，支持按预约状态、服务项目、预约日期筛选，以及关键词搜索、Pagy 每页 20 条分页和独立预约详情、编辑页面。新增、编辑、导入、导出和删除均为界面演示，不执行数据库写入、文件上传或文件导出。切换主题保留当前页面与筛选条件。该页面复用共享组件，未单独编写 CSS/JS 或 Rails 测试。

当前预览手机号均为示例数据。列表布局、列顺序和手机号展示见[列表规范](backend/docs/admin-ui/records.md)，按钮语义见[操作与确认](backend/docs/admin-ui/actions.md)，字段提示见[输入与校验](backend/docs/admin-ui/forms.md)。

提示样式材料：桌面 `dashboard/form-elements.html` 的原生表单及 Tooltip 属性、`dashboard/alerts.html` 的 info-circle 图标、`dashboard/dist/js/tabler.js` 的 Tooltip 自动初始化；参考 `/Users/bithunter/Projects/aitool.web/app/views/backend/shared/_group_qrcode_form.html.erb` 的字段旁提示位置，未复制其自定义样式。

通用删除/风险确认弹窗位于 `app/views/admins/shared/_confirmation_modal.html.erb`，复用原生 Danger modal 的状态条、警示图标和双按钮结构，支持 `danger` 和 `warning` 两种语义。使用原生 `modal-lg`（宽屏 720px、窄屏自适应）、24px 标题、16px 正文及大号按钮；正文短句用 `d-inline-block` 整体换行，按钮文案用 `text-nowrap` 保持一行，不额外编写 CSS/JS。

### 预约详情

`/admins/reservations/:id` 展示对应示例预约的概要、进度、预约信息、客户信息、费用支付、备注和操作记录，例如 `/admins/reservations/2`。列表预约编号与「查看」均进入独立详情页，「返回列表」保留原来的搜索、筛选与页码。不存在的示例编号返回 404。

详情页采用原生 Card、Datagrid、Steps、透明费用表格和响应式栅格。确认预约、开始/完成服务、编辑、取消和删除均为界面演示，不改变记录。页面复用共享组件，未单独编写 CSS/JS 或 Rails 测试。

详情卡片按行配对，使用原生 `h-100`、`flex-fill` 让上排卡片等高、下排备注/操作记录与费用卡片底边对齐；小屏自然改为单列。概要只展示服务、编号、状态和进度；安排、联系方式、来源与支付详情分别集中展示，创建及更新时间通过操作记录查看，去掉重复字段。

所有通用确认框采用纵向 flex、块级图标及同轴文字居中；确认标题去掉末尾全角问号，避免中文标点占位造成视觉偏移。

详情页材料：

- `/Users/bithunter/Desktop/tabler-1.7.1/dashboard/datagrid.html`：信息卡片与字段网格。
- `/Users/bithunter/Desktop/tabler-1.7.1/dashboard/steps.html`：预约进度和纵向操作记录。
- `/Users/bithunter/Desktop/tabler-1.7.1/dashboard/invoice.html`：透明费用明细表。
- `/Users/bithunter/Desktop/tabler-1.7.1/dashboard/modals.html`：编辑与确认弹窗的已有原生结构。

### 编辑预约

`/admins/reservations/:id/edit` 为独立编辑页面，例如 `/admins/reservations/1/edit`。列表和详情中的编辑入口均可进入；列表的搜索、筛选和页码在编辑、返回详情、返回列表之间保留。

表单铺满内容区，按客户信息、预约安排、费用与备注分组；原生栅格随屏幕宽度切换为三列、两列或一列。保存按钮使用 `btn-primary`，取消为中性按钮。点击保存仅打开静态预览说明，不提交表单、不修改记录；关闭说明会保留本页已填内容。日期复用带清空的官方 Datepicker 片段，未为该页面单独编写 CSS/JS 或 Rails 测试。

编辑页材料：

- `/Users/bithunter/Desktop/tabler-1.7.1/dashboard/settings.html`：分组表单、卡片与底部操作区。
- `/Users/bithunter/Desktop/tabler-1.7.1/dashboard/form-layout.html`：原生表单布局及响应式栅格。
- `/Users/bithunter/Desktop/tabler-1.7.1/dashboard/form-elements.html`：输入框、选择器、必填标记、文本域和金额/时长输入组。

### 客户空列表

`/admins/customers` 始终展示零条客户数据，不连接客户业务或数据库。顶栏「客户」和侧栏「客户管理 → 客户列表」均可进入。筛选开合使用原生 Collapse，展开后文案为「收起筛选」，收起后为「更多筛选」；`admins/_collapse.scss` 仅根据原生 `aria-expanded` 状态显示其中一段文案，不新增 JS。分组接缝用原生 `border-bottom-0` 去掉叠加边框，展开与收起都保持单线。

页面通过 `content_for :fill_content` 为布局容器启用 `d-flex flex-column flex-fill`，列表卡片继续使用 `flex-fill`，筛选区与工具栏自然占用各自高度；空状态使用 `empty flex-fill h-auto` 填充剩余空间并居中。对齐 aitool 的空列表逻辑：无数据时不渲染表头和分页，只保留筛选、搜索与居中提示。高度分配完全使用原生类，没有固定高度、没有 `calc(100vh - ...)`、没有测高 JS；空间不足时页面正常向下滚动。

分页是否显示由页面数据决定：零条数据或总页数为 1 时不渲染分页栏，超过 1 页才显示。客户空列表不显示底部分页占位，预约列表也使用同一规则。

公共后台布局不显示底部品牌页脚，右下角主题画笔独立保留。

客户页材料：

- `/Users/bithunter/Desktop/tabler-1.7.1/dashboard/blank.html`：原生 flex 容器及 Empty 标题、说明结构。
- `/Users/bithunter/Desktop/tabler-1.7.1/dashboard/accordion.html`：原生 Collapse 与 `aria-expanded` 状态。
- `/Users/bithunter/Desktop/tabler-1.7.1/dashboard/tables.html`：列表卡片及搜索工具栏。
- `/Users/bithunter/Projects/aitool.web/app/views/admins/users/index.html.erb`：客户类列表的筛选与空状态组织。
- `/Users/bithunter/Projects/aitool.web/app/assets/stylesheets/backend/_content.scss`：参考空列表贯通 flex 布局的思路，未复制其自定义 CSS。

### 预约列表所用材料

优先使用桌面下载包中的原生组件结构，运行时继续加载项目已有的 Tabler 1.7.5 资源：

- `/Users/bithunter/Desktop/tabler-1.7.1/dashboard/tables.html`：Invoices 示例的卡片表格、横向滚动容器、工具栏与分页。
- `/Users/bithunter/Desktop/tabler-1.7.1/dashboard/modals.html`：居中详情弹窗、标题、关闭按钮和页脚结构。
- `/Users/bithunter/Desktop/tabler-1.7.1/dashboard/datagrid.html`：详情弹窗中的字段网格。
- `/Users/bithunter/Desktop/tabler-1.7.1/dashboard/buttons.html`：主要、信息、次要、描边和风险操作按钮。
- `/Users/bithunter/Desktop/tabler-1.7.1/dashboard/icons.html`：导入、导出、查看、编辑、删除、保存和警示图标。
- `/Users/bithunter/Projects/aitool.web/app/views/admins/orders/index.html.erb`：列表页的组织方式及双行单元格。
- `/Users/bithunter/Projects/aitool.web/app/views/backend/shared/_list_filters.html.erb`：分行选项筛选卡。
- `/Users/bithunter/Projects/aitool.web/app/views/backend/shared/_list_toolbar.html.erb`：搜索、添加占位和记录数排列。
- `/Users/bithunter/Projects/aitool.web/app/views/backend/shared/_list_pagination.html.erb`：分页与记录数页脚。
- `/Users/bithunter/Projects/aitool.web/app/assets/stylesheets/backend/_content.scss`：仅参考标题与图标的尺寸，不复制其自定义样式。
