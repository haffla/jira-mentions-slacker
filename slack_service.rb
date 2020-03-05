# frozen_string_literal: true

class SlackService
  attr_reader :client_id, :client_secret, :store, :redirect_uri

  def initialize(client_id:, client_secret:, store:, redirect_uri:)
    @client_id = client_id
    @client_secret = client_secret
    @store = store
    @redirect_uri = redirect_uri
  end

  def request_access(code:, redirect_uri:)
    query = {
      client_id: client_id,
      client_secret: client_secret,
      code: code,
      redirect_uri: redirect_uri
    }
    resp = HTTParty.post("https://slack.com/api/oauth.v2.access", query: query)
    data = JSON.parse(resp.body)
    # slack_id = data["authed_user"]["id"]
    store.save_slack_token data["access_token"]
  end

  class << self
    def send_message(author:, mentions:, text:, issue_id:, store:)
      return if mentions.nil?

      slack_token = store.slack_token
      base_url = store.jira_url
      header = "#{author} mentioned you in " \
               "<#{base_url}/browse/#{issue_id}|*#{issue_id}*>."
      mentions.each do |id|
        sub = store.sub id
        next if sub.nil?

        slack_id = sub["slack_id"]
        resp = HTTParty.post(
          "https://slack.com/api/chat.postMessage",
          headers: { "Authorization" => "Bearer #{slack_token}" },
          body: {
            channel: slack_id,
            text: header,
            attachments: [{ text: text }].to_json
          }
        )

        raise StandardError, resp.body if resp.code >= 300
      end
    end

    def oauth_button(client_id)
      url = "https://slack.com/oauth/v2/authorize?" \
            "client_id=#{client_id}" \
            "&scope=im:read,im:write,chat:write,commands"
      <<~HTML
        <a href="#{url}"><img alt="Add to Slack"\
        height="40" width="139" src="https://platform.slack-edge.com/img/add_to_slack.png"\
        srcset="https://platform.slack-edge.com/img/add_to_slack.png 1x,\
        https://platform.slack-edge.com/img/add_to_slack@2x.png 2x"></a>
      HTML
    end
  end
end
