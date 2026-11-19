module Wechat
  class ComponentClient < BaseClient
    def component_token(config, ticket)
      result = json(:post, "/cgi-bin/component/api_component_token", body: {
        component_appid: config[:appid], component_appsecret: config[:appsecret], component_verify_ticket: ticket })
      [ required(result, "component_access_token"), result["expires_in"] ]
    end

    def pre_auth(token, appid)
      result = component_post("api_create_preauthcode", token, component_appid: appid)
      required(result, "pre_auth_code")
    end

    def authorization(token, appid, code)
      result = component_post("api_query_auth", token, component_appid: appid, authorization_code: code)
      required(result, "authorization_info")
    end

    def original_id(token, appid, target)
      result = component_post("api_get_authorizer_info", token, component_appid: appid, authorizer_appid: target)
      required(required(result, "authorizer_info"), "user_name")
    end

    def refresh(token, appid, target, refresh_token)
      component_post("api_authorizer_token", token, component_appid: appid, authorizer_appid: target, authorizer_refresh_token: refresh_token)
    end

    private

    def component_post(path, token, body)
      json(:post, "/cgi-bin/component/#{path}", query: { component_access_token: token }, body: body)
    end
  end
end
