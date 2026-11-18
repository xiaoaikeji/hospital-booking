# 操作与确认

用于按钮、行操作、更多菜单和风险确认。预览：`/admins/components?tab=actions`；[示例代码](../../app/views/admins/components/_actions.html.erb)。

按钮统一带基础类 `btn`，下表列出对应修饰类。

- 参考已设计好的同类页面及样式规范，统一同类操作的图标、交互和文案，按业务灵活调整；拿不准先问用户。
- 新增操作使用“新增＋对象”，例如“新增管理员”“新增预约”；通用操作固定使用“导入”“导出”“查看”“编辑”“删除”，不随页面换同义叫法。

| 操作 | Tabler 样式 |
| --- | --- |
| 新增、保存、当前主动作 | `btn-primary` |
| 编辑 | `btn-outline-primary` |
| 查看 | `btn-info` |
| 导入、导出、下载 | `btn-outline-secondary` |
| 删除确认 / 表格内删除 | `btn-danger` / `btn-sm btn-outline-danger` |
| 停用等风险动作 | `btn-warning` 或对应描边 |
| 取消、关闭、返回 | 中性 `btn` |

- 表格行使用小号按钮；操作组合可参考 [operation_styles](../../app/views/admins/shared/_operation_styles.html.erb)。
- 删除/风险确认复用 [confirmation_modal](../../app/views/admins/shared/_confirmation_modal.html.erb)，传入具体对象与影响；删除用 danger，停用等用 warning。
- 确认框默认仅预览；真实停用表单传入 `form_id`，表单的 `data-disable-confirmation` 指向 Modal ID，由共享 `admins/forms.js` 确认后提交。
- 同一页面的 Modal ID 唯一，触发按钮与目标对应；不为每个页面另造一套确认框。

## 页面操作示例

查看 `/admins/components?tab=page_actions`，按列表、编辑、配置、详情或错误页选用按钮组合。页头、筛选和表格的完整布局查[列表规范](records.md)。[按钮组合示例](../../app/views/admins/components/_page_actions.html.erb)
