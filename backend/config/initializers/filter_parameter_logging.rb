# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  :mobile, :phone, :authorization, :private_key, :auth_code, :pre_auth_code, :state, :signature, :ticket, :xml, :database_url, :redis_url, :storage_settings,
  :webhook_key, :wechatid, :userstr, /\Aprivacy\z/i, :buttons, :media_id, :qualification, :head_image, :location_application,
  :rejection_reason, :rejection_screenshots, /\Aq\z/i, /\Afiles?\z/i
]
