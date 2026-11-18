# 反馈与加载

用于操作结果、表单失败和等待状态。预览：`/admins/components?tab=feedback`；[示例代码](../../app/views/admins/components/_feedback.html.erb)。

- 页面反馈用 Alert：成功 success、信息 info、风险 warning、失败 danger。
- 轻量消息用 Toast；字段错误放在字段旁，需要汇总时用 Danger Alert。
- 页面操作反馈复用 [flash](../../app/views/admins/shared/_flash.html.erb)，表单级错误复用 [form_errors](../../app/views/admins/shared/_form_errors.html.erb)；字段级错误继续按输入规范显示。
- 登录提示放在登录按钮下方、卡片内部，继续复用 `flash`。
- 真实表单加 `data-admin-form`，复用 [submit_button](../../app/views/admins/shared/_submit_button.html.erb)，按操作规范传入 `icon`。提交中禁用按钮，以 Spinner 替换图标，并设置 `aria-busy`。预览不放入可写表单。
- 有真实进度用 Progress；内容未加载时用 Placeholder。
- 普通配置说明按 [输入与校验](forms.md) 处理，不做成警告条。
- 独立错误页复用 [公共模板](../../app/views/admins/shared/_error_page.html.erb) 与已验证的主题 SVG，统一生成静态文件；[错误页目录与用法](error-pages.md)、[素材说明](error-illustrations.md) 按需查阅。
