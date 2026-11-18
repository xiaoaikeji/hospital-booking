# 输入与校验

用于新建、编辑、配置表单。预览：`/admins/components?tab=forms`；[示例代码](../../app/views/admins/components/_forms.html.erb)。

- 普通输入用 `form-control`，多行文本用 `textarea.form-control`，字段用原生栅格分组。下拉见[主题下拉](selection.md#下拉预览)。
- 金额/单位用 Input Group；只读用 `readonly`，不可操作用 `disabled`；必填字段配套 label 与 required。
- label 和 placeholder 能说明白就不加提示。只有不说明就难以配置时才补充：短说明放 placeholder（如 `默认：0`），放不下或控件不支持时用 [field_help](../../app/views/admins/shared/_field_help.html.erb)。
- 日期复用 [date_field](../../app/views/admins/shared/_date_field.html.erb)：含清空，仅显示当月日期；页面用浮层，Modal 内传 `inline: true`。时刻使用 `HH:mm` 文本输入。
- 密码显示切换复用 [password_toggle](../../app/views/admins/shared/_password_toggle.html.erb)，放在 `input-group-flat` 的 `input-group-text` 中，传入密码框 `input_id`；样式和交互沿用原版登录模板，配套脚本为 `admins/password_toggle.js`。
- 配置字段复用 [configuration_field](../../app/views/admins/shared/_configuration_field.html.erb)：来源 Badge 紧跟 label；未配置用 `danger`，已配置用 `success` 并显示“系统配置 / ENV / credentials”，默认值用 `secondary`，解密失败用 `danger`。外部来源的非敏感文本值放在 placeholder，输入框留空，填写后才保存为系统配置。密钥只显示配置状态。预览中的来源为静态示例。
- 存储设置使用现有下拉和字段组件，由 `admins/storage_settings.js` 联动：本地模式隐藏并停用 COS 字段，选择 COS 后再显示；切换不清除已有配置。对应只读预览为“存储方式联动”。
- 字段错误用 `is-invalid` 和 `invalid-feedback`；输入组的错误放在组外，加 `d-block`。错误只在实际出错时显示。
- Rails 表单复用 `admin_field_class`、`admin_field_errors`（`app/helpers/admins_helper.rb`），不依赖自动错误包裹。
- label 关联控件 ID；错误通过 `aria-describedby` 关联，不用 placeholder 代替 label。

日期、图片等片段的参数直接查看对应 shared 文件；无需重新实现其交互。
