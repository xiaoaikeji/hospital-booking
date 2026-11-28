class OperationLogDetails
  Projection = Data.define(:rows, :omitted)
  ID = 1..(2**63 - 1)
  INTEGER = (-2**31)...(2**31)
  COUNT = 0...2**31
  DECIMAL_ID = /\A[0-9]{1,20}\z/
  WECHAT_APPID = /\Awx[0-9a-f]{16}\z/i
  VERSION = /\A[0-9]{1,6}(?:\.[0-9]{1,6}){1,3}\z/

  ADMIN = { "fields" => %w[username name role enabled password], "reason" => %w[账号校验失败 数据库写入失败] }.freeze
  APP = { "fields" => %w[provider app_type appid nickname memo status wechat_original_id appsecret callback_token callback_encoding_aes_key],
    "reason" => :app_reason }.freeze
  APPEARANCE = { "fields" => AppearanceSettings::OPTIONS.keys,
    "reason" => [ "外观已发生变化，请刷新页面后重试", "外观选项无效", "外观未保存，数据库写入失败，请重试" ] }.freeze
  LINK = { "app_id" => ID, "position" => Link::POSITIONS.keys, "reason" => [ "保存失败", "状态未能保存，请重试" ] }.freeze
  LINK_EDIT = LINK.merge("fields" => %w[app app_id position name link_type status sort_order url params image target_appid]).freeze
  LINK_STATUS = LINK.merge("fields" => %w[status], "status_value" => Link::STATUSES.keys).freeze
  DIRECTORY_EDIT = {
    "fields" => %w[name status sort_order image parent_id icon_type icon position main_title good_in introduction fee display_on_homepage department_ids],
    "reason" => [ "资料未保存，请重试" ]
  }.freeze
  DIRECTORY_STATUS = {
    "fields" => %w[status], "status_value" => [ 0, 1 ], "reason" => [ "状态未能保存，请重试" ]
  }.freeze
  DIRECTORY_ORDER = { "fields" => %w[sort_order], "sort_order" => INTEGER }.freeze
  SCHEDULE_EDIT = { "doctor_id" => ID, "schedule_mode" => %w[每周排班 指定日期调整], "schedule_date" => /\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z/,
    "reason" => [ ScheduleEditor::STALE, ScheduleEditor::FAILURE, ScheduleEditor::REVOKE_FAILURE ] }.freeze
  APPOINTMENT_PAYMENT = { "order_no" => DECIMAL_ID, "payment_no" => DECIMAL_ID }.freeze
  PAYMENT_CLOSE_OUTCOMES = { "CLOSED" => "微信已关单", "NOT_CREATED" => "本地关单", "ORDER_NOT_CREATED" => "微信确认无单" }.freeze
  BOOKING_REFUND = { "order_no" => DECIMAL_ID, "refund_no" => DECIMAL_ID, "refund_record_id" => ID,
    "amount_cents" => 0..ID.end, "kind" => %w[cancel admin_refund], "outcome" => %w[approved rejected] }.freeze
  PLUGIN = { "plugin_appid" => WECHAT_APPID }.freeze
  PLUGIN_VERSION = PLUGIN.merge("version" => VERSION).freeze
  MEDIA = { "kind" => %w[image voice video], "code" => INTEGER }.freeze
  OPEN_PLATFORM = { "operation_id" => ID, "open_appid" => WECHAT_APPID, "previous_open_appid" => WECHAT_APPID }.freeze
  LOCATION = { "application_id" => ID, "audit_id" => DECIMAL_ID, "pictures_count" => COUNT }.freeze
  CATEGORIES = { "first" => ID, "second" => ID }.freeze
  RELEASE = { "release_id" => ID, "source_release_id" => ID }.freeze
  ROUND = { "round_id" => ID, "audit_id" => DECIMAL_ID }.freeze

  # Legacy details are presentation input. A known key does not make its value safe.
  RULES = {
    "admin.create" => ADMIN, "admin.update" => ADMIN,
    "admin.password" => ADMIN.merge("fields" => %w[password]),
    "app.create" => APP, "app.update" => APP,
    "app.destroy" => { "reason" => AppConfiguration::DELETE_AUDIT_REASONS },
    "app.user_sharing" => { "fields" => %w[unionid_app_groups] },
    "appointment.phone_policy" => { "fields" => %w[require_mobile_auth] },
    "appointment.night_shift" => { "fields" => [ Schedule::NIGHT_SETTING ], "reason" => [ "晚班设置未保存，请重试" ] },
    "appointment.update" => { "fields" => AppointmentSettings::FIELDS, "reason" => [ AppointmentSettings::STALE,
      AppointmentSettings::INVALID, AppointmentSettings::INVALID_CAPACITY, AppointmentSettings::INVALID_SLOT_CAPACITY,
      AppointmentSettings::INVALID_TIME, AppointmentSettings::INVALID_WINDOW, AppointmentSettings::OVERLAPPING_WINDOWS,
      AppointmentSettings::FAILURE, "请选择是否验证账号手机号和启用晚班" ] },
    "appointment.complete" => { "order_no" => DECIMAL_ID },
    "appointment.refund_request" => BOOKING_REFUND,
    "appointment.payment_close_requested" => { "order_no" => DECIMAL_ID, "reason" => [ "工作人员申请取消" ] },
    "appointment.payment_closed" => APPOINTMENT_PAYMENT.merge("channel_outcome" => PAYMENT_CLOSE_OUTCOMES.keys),
    "appointment.payment_confirmed" => APPOINTMENT_PAYMENT.merge("paid_amount_cents" => 0..ID.end),
    "appointment.hospital_refund" => BOOKING_REFUND.merge("automatic" => :boolean),
    "appointment.refund_review" => BOOKING_REFUND.merge("decision" => %w[approve reject], "reason" => %w[visit_completed]),
    "appointment.refund_sync" => BOOKING_REFUND.merge("reason" => %w[该申请尚未提交微信 微信退款查询失败]),
    "notification.hospital_enable" => { "reason" => ["模板启用失败"] },
    "notification.hospital_disable" => { "reason" => ["模板停用失败"] },
    "appearance.update" => APPEARANCE, "personal_appearance.update" => APPEARANCE,
    "hospital.update" => { "fields" => HospitalProfile::FIELDS + %w[image], "reason" => [ HospitalProfile::FAILURE, HospitalProfile::INVALID_LOCATION ] },
    "department.create" => DIRECTORY_EDIT, "department.update" => DIRECTORY_EDIT,
    "department.enable" => DIRECTORY_STATUS, "department.disable" => DIRECTORY_STATUS, "department.reorder" => DIRECTORY_ORDER,
    "doctor.create" => DIRECTORY_EDIT.merge("display_on_homepage" => :boolean),
    "doctor.update" => DIRECTORY_EDIT.merge("display_on_homepage" => :boolean),
    "doctor.enable" => DIRECTORY_STATUS, "doctor.disable" => DIRECTORY_STATUS, "doctor.reorder" => DIRECTORY_ORDER,
    "doctor.change_fee" => { "fields" => %w[fee], "fee" => /\A[0-9]{1,8}(?:\.[0-9]{1,2})?\z/ },
    "doctor.destroy" => { "fields" => %w[deleted_at], "reason" => [ "医生未移除，请重试" ] },
    "schedule.create" => SCHEDULE_EDIT, "schedule.update" => SCHEDULE_EDIT, "schedule.revoke" => SCHEDULE_EDIT,
    "schedule.export" => {
      "schedule_month" => /\A[0-9]{4}-(?:0[1-9]|1[0-2])\z/, "name_filtered" => :boolean, "department_id" => ID,
      "doctor_status" => DirectoryEntry::STATUSES.values, "display_on_homepage" => :boolean, "row_count" => COUNT,
      "reason" => [ ScheduleExport::INVALID_MONTH, ScheduleExport::FAILURE ]
    },
    "storage_settings.update" => { "fields" => StorageSettings::FIELDS.keys, "reason" => %w[配置版本冲突 配置校验失败 数据库写入失败] },
    "storage_settings.refresh" => { "reason" => [ "配置已保存，存储客户端刷新失败" ] },
    "map_settings.update" => { "fields" => MapSettings::FIELDS.keys },
    "wechat_pay.update" => { "fields" => WechatPaySettings::LABELS.keys },
    "link.create" => LINK_EDIT, "link.update" => LINK_EDIT, "link.destroy" => LINK,
    "link.enable" => LINK_STATUS, "link.disable" => LINK_STATUS,
    "link.reorder" => LINK.merge("fields" => %w[sort_order], "sort_order" => INTEGER),
    "poster.save" => { "fields" => Poster::FIELDS.map(&:to_s) + %w[id image_width image_height] },
    "poster.delete" => { "reason" => %w[海报删除失败] },
    "notification.retry" => { "message_ids" => :count, "reason" => [ "只能补发已明确失败的消息", "该通知正在发送，请稍后查看结果" ] },
    "notification.reply_save" => { "fields" => %w[name messages variables_version send_interval qrcodes] },
    "notification.rules_save" => { "fields" => %w[rules_save] },
    "notification.code_bind" => { "fields" => %w[code_bind] },
    "notification.template_bind" => { "fields" => %w[template_bind] },
    "notification.template_unbind" => { "fields" => %w[template_unbind] },
    "notification.wecom_content" => { "fields" => %w[messages send_interval enabled],
      "event" => %w[passed rejected delayed published failed violation appeal_1 appeal_2 appeal_3 category_2 category_3] + Appointments::GroupNotice::EVENTS.keys },
    "wechat.notification_settings" => {
      "fields" => %w[webhook_key same_robot kinds pull_violations],
      "reason" => [
        "配置已变化，请刷新后再保存", "机器人 Key 格式无效", "请重新填写机器人 Key 或清除系统配置",
        "请填写有效的机器人 Key 或完整 Webhook 地址", "新 Key 已登记在其他通知群",
        "生效的机器人 Key 已轮换，请填写当前 Key 或更新部署配置", "通知类型无效", "通知设置未保存，请核对部署配置"
      ]
    },
    "wechat.fan_sync" => { "sync_id" => ID },
    "wechat.channel_qrcode_create" => { "channel_id" => ID },
    "wechat.menu_publish" => { "count" => COUNT, "code" => INTEGER },
    "wechat.menu_pull" => { "count" => COUNT, "code" => INTEGER, "result" => %w[mismatch] },
    "wechat.menu_media" => MEDIA, "wechat.reply_card_cover_upload" => MEDIA,
    "wechat.plugin_apply" => PLUGIN, "wechat.plugin_unbind" => PLUGIN,
    "wechat.plugin_update" => PLUGIN_VERSION, "wechat.plugin_verify" => PLUGIN_VERSION,
    "wechat.server_domains" => { "fields" => %w[requestdomain uploaddomain downloaddomain wsrequestdomain udpdomain tcpdomain] },
    "wechat.business_domains" => { "fields" => %w[webviewdomain] },
    "wechat.link_create" => { "mini_appid" => WECHAT_APPID, "notify_users" => :boolean, "show_profile" => :boolean },
    "wechat.link_delete" => { "mini_appid" => WECHAT_APPID },
    "wechat.link_verify" => { "mini_appid" => WECHAT_APPID, "outcome" => %w[applied not_applied], "remote_status" => INTEGER },
    "wechat.open_platform_create" => OPEN_PLATFORM, "wechat.open_platform_bind" => OPEN_PLATFORM,
    "wechat.open_platform_unbind" => OPEN_PLATFORM, "wechat.open_platform_sync" => OPEN_PLATFORM,
    "wechat.location_apply" => LOCATION, "wechat.location_verify" => LOCATION,
    "wechat.privacy_update" => { "declaration_count" => COUNT },
    "wechat.category_add" => CATEGORIES, "wechat.category_delete" => CATEGORIES, "wechat.category_verify" => CATEGORIES,
    "wechat.template_add" => { "draft_id" => DECIMAL_ID, "template_type" => %w[normal standard] },
    "wechat.template_delete" => { "template_id" => DECIMAL_ID, "template_type" => %w[normal standard] },
    "wechat.upload" => RELEASE, "wechat.submit" => ROUND.merge(RELEASE).merge("restored_upload_id" => ID),
    "wechat.sync" => ROUND, "wechat.withdraw" => ROUND, "wechat.resume_auto" => ROUND, "wechat.publish" => ROUND,
    "wechat.close" => ROUND.merge(RELEASE), "wechat.delete" => ROUND.merge(RELEASE), "wechat.resolve" => ROUND.merge(RELEASE),
    "wechat.publication_mode" => { "round_id" => ID, "before" => :boolean, "after" => :boolean }
  }.freeze

  LABELS = {
    "fields" => "变更字段", "reason" => "原因", "app_id" => "应用编号", "position" => "展示位置",
    "status_value" => "设置状态", "sort_order" => "排序", "fee" => "挂号费（元）", "message_ids" => "补发条目数", "event" => "通知事件",
    "doctor_id" => "医生编号", "schedule_mode" => "排班方式", "schedule_date" => "调整日期",
    "schedule_month" => "导出月份", "name_filtered" => "按姓名筛选", "department_id" => "科室编号",
    "order_no" => "预约单号", "payment_no" => "支付单号", "channel_outcome" => "关单结果", "paid_amount_cents" => "实付金额",
    "doctor_status" => "医生状态", "display_on_homepage" => "首页推荐", "row_count" => "导出班次数",
    "refund_no" => "退款单号", "refund_record_id" => "退款记录编号", "amount_cents" => "退款金额",
    "automatic" => "直接办理", "decision" => "审核决定",
    "sync_id" => "同步任务编号", "channel_id" => "渠道编号", "count" => "菜单项数量", "code" => "微信错误码",
    "result" => "核对结果", "kind" => "素材类型", "plugin_appid" => "插件 AppID", "version" => "插件版本",
    "mini_appid" => "小程序 AppID", "notify_users" => "通知用户", "show_profile" => "展示在公众号资料页",
    "outcome" => "核实结果", "remote_status" => "微信状态", "operation_id" => "操作编号",
    "open_appid" => "开放平台 AppID", "previous_open_appid" => "原开放平台 AppID",
    "application_id" => "申请编号", "audit_id" => "微信审核单号", "pictures_count" => "截图数量",
    "declaration_count" => "声明项目数", "first" => "一级类目编号", "second" => "二级类目编号",
    "draft_id" => "草稿编号", "template_id" => "模板编号", "template_type" => "模板类型",
    "release_id" => "发布记录编号", "source_release_id" => "原发布记录编号", "restored_upload_id" => "恢复的上传记录编号",
    "round_id" => "审核轮次编号", "before" => "原自动发布状态", "after" => "新自动发布状态"
  }.freeze

  def self.for(log)
    details = log.details
    return Projection.new({}, !details.nil?) unless details.is_a?(Hash)

    allowed = RULES.fetch(log.action, {}).each_with_object({}) do |(key, rule), fields|
      next unless details.key?(key)

      value = safe_value(key, details[key], rule)
      fields[key] = value unless value.nil?
    end
    allowed.delete("refund_no") if allowed["kind"] == "cancel" && allowed["amount_cents"] == 0
    rows = allowed.to_h do |key, value|
      value = DirectoryEntry::STATUSES.fetch(value) if key == "status_value" && value.is_a?(Integer)
      value = PAYMENT_CLOSE_OUTCOMES.fetch(value) if key == "channel_outcome"
      value = "#{Appointment.cents_in_yuan(value)} 元" if key.in?(%w[paid_amount_cents amount_cents])
      if log.action.in?(%w[appointment.hospital_refund appointment.refund_request appointment.refund_review appointment.refund_sync])
        value = { "cancel" => "退号", "admin_refund" => "退差价" }.fetch(value) if key == "kind"
        value = Appointment::REFUND_ITEM_LABELS.fetch(value) if key == "outcome"
        value = { "approve" => "同意", "reject" => "拒绝" }.fetch(value) if key == "decision"
      end
      [ (key == "kind" && log.category == "booking" ? "退款类型" : LABELS.fetch(key)), display_value(value) ]
    end
    Projection.new(rows, allowed != details)
  end

  def self.safe_value(key, value, rule)
    if key == "fields"
      return unless value.is_a?(Array)

      names = value & rule
      return names if value.empty? || names.any?
      return
    end
    case rule
    when Array then value if rule.include?(value)
    when Range then value if value.is_a?(Integer) && rule.cover?(value)
    when Regexp then value if value.is_a?(String) && rule.match?(value)
    when :boolean then value if value == true || value == false
    when :count then value.size if value.is_a?(Array)
    when :app_reason then AppConfiguration.audit_reason(value)
    end
  end

  def self.display_value(value)
    case value
    when Array then value.presence&.join("、") || "无"
    when TrueClass then "是"
    when FalseClass then "否"
    else value
    end
  end

  private_class_method :safe_value, :display_value
end
