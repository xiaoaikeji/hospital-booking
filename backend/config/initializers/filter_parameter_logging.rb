# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  # Filter the entire form payload, including newly added fields and query-string variants.
  /\A(?:app|map|notification_settings|storage_settings|wechat_pay|credentials)(?:\z|\[|%5b)/i,
  /\A(?:appointment|patient|refund|payment_cancellation)(?:\z|\[|%5b)/i,
  # SQL bind logging sees these JSON columns as a whole, including legacy values.
  /\A(?:settings|details|response_data|error_message|hospital_snapshot|payment_data|refund_data)\z/i,
  # SQL bind logging uses unqualified column names, including patients.name.
  /\A(?:name|remark|gender|age)\z/i, :patient_name, :patient_gender, :patient_age, :symptom,
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  :mobile, :phone, :authorization, :private_key, :auth_code, :pre_auth_code, :state, :signature, :echostr, :ticket, :xml, :database_url, :redis_url,
  :ciphertext, :req_info, :webhook, :verification_pem, :wechatid, :userstr, /\Aprivacy\z/i, :buttons, :media_id, :qualification, :head_image, :location_application,
  :background, :page_query, :notification_content, :reply_content, :reply_rules, :template_binding, :reply_binding,
  :rejection_reason, :rejection_screenshots, :openid, :unionid, :sessions, :login_profile, :first_ip, /\A(?:ak|key|endpoint|notify_origin)\z/i,
  /\A(?:js_)?code\z/i, /\Aq\z/i, /\Afiles?\z/i
]

# Rails logs malformed JSON bodies before parameter filters can run.
module RedactedParameterParseLogging
  private

  def log_parse_error_once
    @parse_error_logged ||= (logger || Rails.logger).debug("Error occurred while parsing request parameters.")
  end
end

ActionDispatch::Request.prepend(RedactedParameterParseLogging)
