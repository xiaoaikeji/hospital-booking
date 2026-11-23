module Api
  class WechatPaymentNotificationsController < ActionController::API
    MAX_BODY = 2.megabytes

    def create
      route = request.path_parameters
      body = request.body.read(MAX_BODY + 1).to_s
      raise Payments::InvalidResult if body.bytesize > MAX_BODY
      Payments.new.receive(version: route.fetch(:version), config_ref: route.fetch(:config_ref), kind: route.fetch(:kind),
        body: body, headers: request.headers)
      acknowledge(true)
    rescue Payments::InvalidResult, ArgumentError
      acknowledge(false, status: :bad_request)
    rescue StandardError => error
      # Includes a missing receiver/order and a failed business commit. WeChat retries.
      Rails.logger.warn("WeChat Pay notification deferred (#{error.class.name})")
      acknowledge(false, status: :service_unavailable)
    end

    private

    def acknowledge(success, status: :ok)
      if request.path_parameters[:version] == "v2"
        code, message = success ? %w[SUCCESS OK] : %w[FAIL RETRY]
        render xml: "<xml><return_code>#{code}</return_code><return_msg>#{message}</return_msg></xml>", status: status
      elsif success
        head :no_content
      else
        render json: { code: "FAIL", message: "RETRY" }, status: status
      end
    end
  end
end
