# 导航与布局

用于页面框架、内容分组和展开交互。预览：`/admins/components?tab=containers`；[示例代码](../../app/views/admins/components/_containers.html.erb)。

- 页面框架复用 [admins 布局](../../app/views/layouts/admins.html.erb)；侧栏、顶栏、图标和主题入口在 [layouts/admins](../../app/views/layouts/admins/)。
- 登录页复用 [admin_auth 布局](../../app/views/layouts/admin_auth.html.erb)，沿用原版 `sign-in.html` 的居中卡片和间距，并复用同一外观面板及切换绑定。
- 内容用 `container-xl`，公共布局默认 `data-bs-layout="fluid"` 铺满宽度，也支持外观设置切换标准/盒式；页头用 `page-header mt-0 mb-3`，标题 `fs-1`，图标 `w-5 h-5`，间距 `gap-3`。
- 分组用 Card、`row g-3`；等高用 `row-deck`/`h-100`，填余高用 `flex-fill`，小屏自然换行。
- 配置页复用 [configuration_card](../../app/views/admins/shared/_configuration_card.html.erb)，作为 `card` 表单内的布局片段，统一标题、错误及保存区；字段使用 [configuration_field](../../app/views/admins/shared/_configuration_field.html.erb)，常规栅格为 `col-md-6 col-xl-4`，按字段宽度调整。桌面能容纳时尽量一屏展示，小屏或内容较多时正常滚动，不用固定高度或隐藏溢出来掩盖内容；示例见输入规范预览。
- “清除系统配置”放在保存按钮旁，复用现有风险确认框；只清除本页的数据库配置并按来源回退，不逐字段放清除勾选，无系统值时禁用。清除继续使用事务和配置版本校验。
- 独立详情分类用 GET 页签；同页局部切换用 Tab。
- 分组互斥展开用 Accordion；额外设置用 Collapse，展开/收起文案跟随 `aria-expanded`；侧边详情用 Offcanvas。
- 使用现有 Tabler 主题颜色、边框和圆角；官方资源与初始化已在公共布局中加载。
- 外观面板复用 [theme_settings](../../app/views/layouts/admins/_theme_settings.html.erb)，包括配色、13 种主题色、4 类字体、6 组灰阶、5 档圆角，以及导航、宽度、吸顶、悬浮和侧栏折叠；[切换绑定](../../app/javascript/admins/theme_settings.js) 来自桌面原版示例，即时应用并记住选择，重置恢复本项目默认布局。
- 全项目字体由 [shared/typography](../../app/assets/stylesheets/shared/_typography.scss) 统一配置，沿用大雁字体栈，不逐个控件设置。
