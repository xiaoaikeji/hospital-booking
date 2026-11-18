# 选择与开关

用于状态、分类、渠道、日期和权限配置。预览：`/admins/components?tab=selection`；[示例代码](../../app/views/admins/components/_selection.html.erb)。

- 后台下拉默认用主题下拉。普通单选、分组和默认项继续使用 `form-select` 的表单结构，分组使用 `optgroup`。
- 互斥选择用 Radio，多项选择用 Checkbox；少量可视选项可用 Selectgroup。
- 启停配置用 Switch；权限组合用复选矩阵。
- 图片选择用 Imagecheck，见 [图片与附件](media.md)。
- 控件保留 label、选中态和原生焦点圈；不另写选中样式。

## 下拉预览

| 样式 | 可用场景 |
| --- | --- |
| 原生单选 | 操作日志类型等普通选项 |
| 原生分组 | 按团队选择服务人员 |
| 原生默认项 | 继承默认通知设置，允许单独启停 |
| 主题单选 | 操作日志类型等需要统一展开面板样式的选项 |
| 可搜索单选 | 按姓名找服务人员，支持分组 |
| 可搜索多选 | 选择已有客户标签，选中项显示为标签 |

主题下拉采用桌面 Tabler `form-elements.html` 的高级单选和 Tags input，复用随模板提供的 Tom Select 2.6.2 与样式。用到主题下拉的页面先渲染 [enhanced_select_assets](../../app/views/admins/shared/_enhanced_select_assets.html.erb)，再给原有 `select` 加 `data-enhanced-select="single"`。选项多时按需用 `search`，业务需要多选时加 `multiple`。继续使用原字段名和值，选择变化由原表单接收。日志操作类型、管理员角色和账号状态、文件存储方式可参考现有正式页面。素材校验和许可证见[材料索引](sources.md)。
