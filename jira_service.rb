# frozen_string_literal: true

require "cgi"

class JiraService
  attr_reader :project_id, :token, :refresh_token, :client_id, :client_secret, :store

  def initialize(client_id:, client_secret:, store:)
    @project_id = store.project_id
    @token = store.jira_token
    @refresh_token = store.jira_refresh_token
    @client_id = client_id
    @client_secret = client_secret
    @store = store
  end

  def fetch_comment(issue_id:, comment_id:)
    url = "https://api.atlassian.com/ex/jira/#{project_id}/rest/api/3/issue/#{issue_id}/comment/#{comment_id}"
    resp = HTTParty.get(url, headers: { "Authorization" => "Bearer #{token}" })
    data = JSON.parse(resp.body)

    if data["code"] == 401
      refresh_resp = HTTParty.post(
        "https://auth.atlassian.com/oauth/token",
        body: {
          grant_type: "refresh_token",
          client_id: client_id,
          client_secret: client_secret,
          refresh_token: refresh_token
        }
      )
      data = JSON.parse(refresh_resp.body)
      token, refresh_token = data.values_at "access_token", "refresh_token"
      store.save_jira_token token
      store.save_jira_refresh_token refresh_token if refresh_token
      # now try again
      resp = HTTParty.get(url, headers: { "Authorization" => "Bearer #{token}" })
    end

    raise StandardError, resp.body if resp.code >= 300

    JSON.parse(resp.body)
  end

  class << self
    def oauth_setup_url(client_id:, redirect_uri:)
      "https://auth.atlassian.com/authorize?audience=api.atlassian.com" \
      "&client_id=#{client_id}&scope=read%3Ajira-work%20offline_access" \
      "&redirect_uri=#{CGI.escape(redirect_uri)}&response_type=code&prompt=consent"
    end

    def oauth_subscribe_url(client_id:, redirect_uri:, slack_id:)
      "https://auth.atlassian.com/authorize" \
      "?audience=api.atlassian.com&client_id=#{client_id}" \
      "&scope=read%3Ame&redirect_uri=#{CGI.escape(redirect_uri)}" \
      "&state=#{slack_id}&response_type=code&prompt=consent"
    end

    def request_access(client_id:, client_secret:, redirect_uri:, code:)
      resp = HTTParty.post(
        "https://auth.atlassian.com/oauth/token",
        body: {
          grant_type: "authorization_code",
          client_id: client_id,
          client_secret: client_secret,
          code: code,
          redirect_uri: redirect_uri
        }
      )
      data = JSON.parse(resp.body)
      data.values_at("access_token", "refresh_token")
    end

    def instance_details(access_token:)
      resp = HTTParty.get(
        "https://api.atlassian.com/oauth/token/accessible-resources",
        headers: { "Authorization" => "Bearer #{access_token}" }
      )
      JSON.parse(resp.body).then do |data|
        [data[0]["id"], data[0]["url"]]
      end
    end

    def user_details(access_token:)
      resp = HTTParty.get(
        "https://api.atlassian.com/me",
        headers: { "Authorization" => "Bearer #{access_token}" }
      )
      data = JSON.parse(resp.body)
      data.values_at("account_id", "name")
    end
  end
end
