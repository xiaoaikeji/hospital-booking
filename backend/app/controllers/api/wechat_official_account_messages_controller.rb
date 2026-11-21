module Api
  class WechatOfficialAccountMessagesController < ActionController::API
    MAX_BODY = 128.kilobytes
    before_action :load_account
    rescue_from Wechat::MessageCrypto::Invalid, with: -> { head :forbidden }
    rescue_from Nokogiri::XML::SyntaxError, with: -> { head :bad_request }
    rescue_from AppConfiguration::Invalid, Notifications::Error, Wechat::Error, with: -> { head :service_unavailable }

    def verify
      query = request.query_parameters
      echo = query["echostr"]
      return head :bad_request unless echo.is_a?(String) && echo.bytesize.between?(1, 1024)

      if query.key?("msg_signature")
        echo = decrypt(echo)
      else
        @crypto.verify_url!(timestamp: query["timestamp"], nonce: query["nonce"], signature: query["signature"])
      end
      render plain: echo
    end

    def create
      body = request.body.read(MAX_BODY + 1).to_s
      return head :payload_too_large if body.bytesize > MAX_BODY

      envelope = parse_xml(body)
      message = parse_xml(decrypt(envelope["Encrypt"]))
      return head :forbidden unless message["ToUserName"] == @account.wechat_original_id

      reply = Notifications::OfficialAccountEvents.receive!(@account, message)
      reply ? render(xml: @crypto.encrypt(reply)) : render(plain: "success")
    end

    private

    def load_account
      response.headers["Cache-Control"] = "no-store"
      @account = App.wechat_official_accounts.find_by!(appid: request.path_parameters.fetch(:appid))
      return head :forbidden unless @account.accessible?

      @crypto = Wechat::MessageCrypto.new(AppConfiguration.new(@account).callback_credentials!)
    end

    def decrypt(ciphertext)
      query = request.query_parameters
      @crypto.decrypt(ciphertext, timestamp: query["timestamp"], nonce: query["nonce"], signature: query["msg_signature"])
    end

    def parse_xml(body)
      doc = Nokogiri::XML(body) { |options| options.strict.nonet }
      raise Wechat::MessageCrypto::Invalid if doc.internal_subset || doc.external_subset || doc.root&.name != "xml"

      doc.root.element_children.each_with_object({}) do |child, fields|
        raise Wechat::MessageCrypto::Invalid if fields.key?(child.name)
        fields[child.name] = child.text
      end
    end
  end
end
