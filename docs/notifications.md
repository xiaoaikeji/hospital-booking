# 通知与公众号运营

超级管理员可使用侧栏的「回复内容」「微信模板消息」「渠道二维码」「发送记录」。其他角色沿用原有权限，无新增配置或补发权限。

## 配置回复

选择公众号，新增一组回复内容，在一页添加文字和小程序卡片、排序、预览并保存。卡片封面上传到当前公众号。菜单、渠道码、首次关注、再次关注和文字关键词均可引用同一组内容。

菜单或渠道码的「新增回复内容」会打开编辑窗口；保存后返回正在编辑的入口并自动选中，父页面草稿保留。渠道码的「编辑回复」默认「仅改这个码」，保存时复制内容并自动绑定，原二维码保持不变。「更新全部」会列出已绑定的线上菜单、待核实菜单、渠道码、关注与关键词入口。菜单改绑在「保存并发布」确认成功后生效。

渠道码只填名称即可使用，默认仅统计来源；也可选择欢迎语、专属回复或两者。已关注粉丝再扫码按该码的配置处理，不改变原关注来源。欢迎语依首次／再次关注规则选择。扫码、菜单点击、关键词回调按公众号及微信事件标识持久去重。

首条文字可在微信回调中以加密 XML 应答，其余文字和卡片按顺序通过客服接口发送。记录中的「应答已生成」表示系统已生成回调应答，接收尚未确认；「渠道已接受」表示微信接口已确认接受，不表示已读。超时显示「待核实」，没有补发入口。

## 微信模板消息

在当前公众号的「微信模板消息」选择微信已有模板，核对字段建议和示例预览，确认保存一次。相同事件以后直接使用已确认的模板和字段绑定，不在每次发送时重新猜测。业务决定收件人、真实数据、计划时间及跳转地址。

接入项目在 `config/initializers/notification_events.rb` 登记事件及业务字段；当前以「活动开始提醒」验证。同一个机构的其他公众号需分别配置，其模板、粉丝身份、素材和回复内容不会回退到另一账号。

```ruby
Notifications::TemplateMessages.new(account).deliver(
  event: "activity_start", subject: activity,
  recipients: [user_app], # 必须是当前公众号的已关注身份
  data: { activity_name: activity.name, starts_at: activity.starts_at },
  idempotency_key: "activity:#{activity.id}:start",
  scheduled_at: activity.remind_at,
  jump: { url: activity.public_url }
)
```

业务模型与收件人选择留在接入项目。模块不查询医院科室、电竞比赛或业务页面路径。缺字段、未绑定模板、跨账号收件人会拒绝登记；未到计划时间不发送。

## 通用发送入口

业务提供事件、业务对象、已选目标和实际消息。`dispatch` 返回 `Notification`；相同事件、业务对象、目标身份和去重标识返回原任务。无目标不建任务。消息 ID 在同一任务内唯一，补发不重新解析目标或生成内容。

```ruby
target = Notifications::Channels::WecomGroup.target(robot_key, name: "运营通知群")
task = Notifications.dispatch(
  event: "activity.reminder", subject: activity, target: target,
  messages: [{ id: "notice", type: "text", content: { text: "活动即将开始" } }],
  idempotency_key: "activity:#{activity.id}:reminder"
)
```

Sidekiq 只传任务 ID。`Notifications::Delivery` 负责锁定执行、持久保存每条请求的发起状态及回执、汇总任务结果。渠道实现 `send_message(message, notification:)`，返回 `status: sent/failed/unknown`、安全的 `response` 与 `error_message`；第三方请求在各平台 Client。新增渠道只需增加渠道实现及模块内的选择，不改业务调用、控制器或 Worker。

企业微信按登记时选定的稳定渠道保存加密凭据。默认群由 A 改为 B 后，旧任务仍使用 A；渠道项缺失或身份不匹配时失败，不转发 B。正常发送与人工补发均保留原内容，机器人 Key 不进入任务快照或回执。

## 发送记录与补发

一次发送多条消息时，每条分别显示实际内容、处理步骤、次数及失败原因。文字成功、卡片被明确拒绝时，只补发卡片；已成功及待核实条目不会再次发送。人工补发在操作日志中关联通知任务，并保留之前的尝试摘要。请求发出前先保存 `sending`，进程中断也不能把它当成未发送。

`notifications` 保持已定的 16 个字段，消息与逐条结果在 JSONB 中，不新增消息子表或状态枚举。「待核实」使用逐条 `sending` 加渠道状态表达。配置统一在 `settings.notification`；既有微信审核通知设置和历史记录入口继续使用。

## 安装与升级

执行 `cd backend && bin/rails db:migrate`，然后重启 Web 和 Sidekiq。通用通知派发由 `config/schedule.yml` 每分钟补排到期任务。生产 Web 和任务进程使用相同的加密主密钥。

升级前产生的微信历史记录继续保留；它们没有目标快照，不伪造为新的通用任务。本次开发库没有这类记录。若其他部署已有旧的待发任务，升级前应核对目标并另行决定处理方式，不能推断其排队时的群。

本地测试使用模拟微信响应。上线仍需用真实授权公众号验证菜单发布、永久二维码、回调加密应答、客服窗口与卡片权限、真实模板字段限制及送达情况。
