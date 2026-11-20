module Notifications
  module ReplyVariables
    WEEKDAYS = %w[星期日 星期一 星期二 星期三 星期四 星期五 星期六].freeze
    FIELDS = {
      "name" => { "label" => "粉丝昵称", "example" => "小艾", "hint" => "没有昵称时显示「朋友」" },
      "user_id" => { "label" => "用户编号", "example" => "12345678", "hint" => "本公众号身份尚未同步时显示「未同步」" },
      "app_name" => { "label" => "公众号名称", "example" => "活动服务号" },
      "appid" => { "label" => "公众号 AppID", "example" => "wxExampleAccount" },
      "qrcode_name" => { "label" => "渠道码名称", "example" => "场馆门口", "optional" => true, "hint" => "仅扫码有值；其他入口省略包含它的整行" },
      "date_new" => { "label" => "今天日期", "example" => "2026年11月20日" },
      "week" => { "label" => "星期", "example" => "星期五" },
      "time" => { "label" => "本次互动时间", "example" => "2026-11-20 14:00:00" }
    }.freeze

    def self.values(app, message)
      identity = UserApp.for_app(app).includes(:user).find_by(openid: message["FromUserName"])
      at = Time.zone.at(message.fetch("CreateTime").to_i)
      scene = message["EventKey"].to_s.delete_prefix("qrscene_")
      code = OfficialAccountQrcode.find_by(app: app, scene: scene) if message["Event"].in?(%w[SCAN subscribe])
      { "name" => identity&.user&.nickname.presence || "朋友", "user_id" => identity&.user&.user_no || "未同步",
        "app_name" => app.display_name, "appid" => app.appid, "qrcode_name" => code&.name,
        "date_new" => at.strftime("%Y年%m月%d日"), "week" => WEEKDAYS[at.wday], "time" => at.strftime("%F %T") }
    end

    def self.examples(app)
      FIELDS.transform_values { |field| field["example"] }.merge("app_name" => app.display_name, "appid" => app.appid)
    end
  end
end
