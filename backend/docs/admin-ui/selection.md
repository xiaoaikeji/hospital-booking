# 选择与开关

用于状态、分类、渠道、日期和权限配置。预览：`/admins/components?tab=selection`；[示例代码](../../app/views/admins/components/_selection.html.erb)。

- 普通/分组下拉：`form-select`，分组使用 `optgroup`。
- 互斥选择用 Radio，多项选择用 Checkbox；少量可视选项可用 Selectgroup。
- 启停配置用 Switch；权限组合用复选矩阵。
- 图片选择用 Imagecheck，见 [图片与附件](media.md)。
- 控件保留 label、选中态和原生焦点圈；不另写选中样式。
