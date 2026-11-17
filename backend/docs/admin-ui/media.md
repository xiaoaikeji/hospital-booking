# 图片与附件

用于封面、多图、列表小图、头像和附件。预览：`/admins/components?tab=media`；[示例代码](../../app/views/admins/components/_media.html.erb)。

- 小图与点击放大：复用 [image_thumbnail](../../app/views/admins/shared/_image_thumbnail.html.erb) 和 [image_modal](../../app/views/admins/shared/_image_modal.html.erb)，两者使用相同且页面内唯一的 `modal_id`。
- 单图提供替换/移除；多图使用 `multiple` 文件框和原生栅格，每张可单独删除。
- 照片用 `object-cover`；二维码、标志用 `object-contain`，保留完整内容。
- 头像用 Avatar；无图时用姓名首字或图标。叠放头像的计数项用不透明底色，避免下面的图片透出。
- 附件显示名称、下载和删除；删除复用通用确认框。
- 文件格式/大小等必要限制，使用 [field_help](../../app/views/admins/shared/_field_help.html.erb) 提示。

当前预览的文件框不上传文件，选文件不会自动替换示例图。
