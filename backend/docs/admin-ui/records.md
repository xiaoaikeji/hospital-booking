# 列表与状态

用于记录表格、筛选结果和空列表。完整布局见 `/admins/components?tab=list_examples` 的「列表规范」页签，[示例代码](../../app/views/admins/components/_list_examples.html.erb)。状态、表格及分页组件见 `/admins/components?tab=records`。

- 零条记录时保留筛选和搜索，列表卡片填满屏幕剩余高度。用原生 flex 将图标、标题和说明整体居中，图标按业务选择，尺寸沿用 [客户空列表](../../app/views/admins/customers/index.html.erb)。首次空列表和筛选无结果使用对应提示。
- 有记录时，列表卡片随表格内容自然收高。零条记录不显示表头和分页，只有一页也不显示分页。
- 选项少的筛选条件用 [list_filter_row](../../app/views/admins/shared/_list_filter_row.html.erb) 横排，每项点击即筛选，当前项高亮。同页额外条件用原生 Collapse 展开，由「更多筛选／收起筛选」切换。操作日志等选项多的页面用下拉等表单控件组合筛选。

- 第一列为记录 ID，显示 `#1`；翻页和筛选不重新编号。费用明细、权限矩阵不属于记录列表。
- 后台手机号在所有页面完整显示。
- 长表格用 `table-responsive`；短字段和行操作保持一行，避免一字一行或撑宽页面。
- 状态用 `badge bg-*-lt`，运行状态可用 Status Dot；行按钮按 [操作与确认](actions.md) 选择。
- 真实列表分页复用 [pagination](../../app/views/admins/shared/_pagination.html.erb)，传入 Pagy 对象与分页 URL 方法；只计算必要页码，不由前端分页。

完整列表结构参考 [预约列表](../../app/views/admins/reservations/index.html.erb)。
