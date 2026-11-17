# 列表与状态

用于记录表格、筛选结果和空列表。预览：`/admins/components?tab=records`；[示例代码](../../app/views/admins/components/_records.html.erb)。

- 第一列为记录 ID，显示 `#1`；翻页和筛选不重新编号。费用明细、权限矩阵不属于记录列表。
- 后台手机号在所有页面完整显示。
- 长表格用 `table-responsive`；短字段和行操作保持一行，避免一字一行或撑宽页面。
- 状态用 `badge bg-*-lt`，运行状态可用 Status Dot；行按钮按 [操作与确认](actions.md) 选择。
- 无数据时不显示表头与分页；只有一页也不显示分页。
- 真实列表分页复用 [pagination](../../app/views/admins/shared/_pagination.html.erb)，传入 Pagy 对象与分页 URL 方法；只计算必要页码，不由前端分页。
- 首次空列表与筛选无结果分别提供对应提示。需要填满剩余屏幕高度时，照 [客户空列表](../../app/views/admins/customers/index.html.erb) 使用原生 flex，不写固定高度或测高 JS。

完整列表结构参考 [预约列表](../../app/views/admins/reservations/index.html.erb)。
