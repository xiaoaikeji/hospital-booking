Rails.application.config.to_prepare do
  Appointments::GroupNotice.register
  Notifications::EventCatalog.register("activity_start", label: "活动开始提醒", fields: {
    activity_name: { label: "活动名称", type: "text", example: "周末活动" },
    starts_at: { label: "开始时间", type: "time", example: "2026-11-28 14:00" }
  })
end
