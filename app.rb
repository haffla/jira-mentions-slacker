# frozen_string_literal: true

require "sinatra"
require "redis"
require "cgi"
require_relative "./comment_handler"
require_relative "./jira_service"
require_relative "./store"

class App < Sinatra::Base
  configure do
    redirect_uri = ENV["REDIRECT_URI"]

    set :server, :puma
    set :store, Store.new(redis: Redis.new)
    set :slack_redirect_uri, "#{redirect_uri}/oauth"
    set :slack_client_id, ENV["SLACK_CLIENT_ID"]
    set :slack_client_secret, ENV["SLACK_CLIENT_SECRET"]
    set :jira_redirect_uri, "#{redirect_uri}/jira/oauth"
    set :jira_client_id, ENV["JIRA_CLIENT_ID"]
    set :jira_client_secret, ENV["JIRA_CLIENT_SECRET"]
  end

  get "/oauth" do
    query = {
      client_id: settings.slack_client_id,
      client_secret: settings.slack_client_secret,
      code: params[:code],
      redirect_uri: settings.slack_redirect_uri
    }
    resp = HTTParty.post("https://slack.com/api/oauth.v2.access", query: query)
    data = JSON.parse(resp.body)
    # slack_id = data["authed_user"]["id"]
    settings.store.save_slack_token data["access_token"]

    if (jira_url = settings.store.jira_url)
      "Cool. You're all set! #{jira_url}"
    else
      url = JiraService.oauth_setup_url(client_id: settings.jira_client_id, redirect_uri: settings.jira_redirect_uri)
      "Cool. Please authorize the Jira app now: #{url}"
    end
  end

  get "/jira/oauth" do
    code = params[:code]
    slack_id = params[:state]

    resp = HTTParty.post(
      "https://auth.atlassian.com/oauth/token",
      body: {
        grant_type: "authorization_code",
        client_id: settings.jira_client_id,
        client_secret: settings.jira_client_secret,
        code: code,
        redirect_uri: settings.jira_redirect_uri
      }
    )
    data = JSON.parse(resp.body)
    access_token = data["access_token"]

    if slack_id.nil?
      settings.store.save_jira_token access_token
      settings.store.save_jira_refresh_token data["refresh_token"]

      resp = HTTParty.get(
        "https://api.atlassian.com/oauth/token/accessible-resources",
        headers: { "Authorization" => "Bearer #{access_token}" }
      )

      data = JSON.parse(resp.body)
      settings.store.save_jira_id data[0]["id"]
      settings.store.save_jira_url data[0]["url"]
      if settings.store.slack_token
        "Boom! Way to go."
      else
        url = "https://slack.com/oauth/v2/authorize?" \
              "client_id=#{settings.slack_client_id}" \
              "&scope=im:read,im:write,chat:write,commands"
        button = <<~HTML
          <a href="#{url}"><img alt="Add to Slack"\
          height="40" width="139" src="https://platform.slack-edge.com/img/add_to_slack.png"\
          srcset="https://platform.slack-edge.com/img/add_to_slack.png 1x,\
          https://platform.slack-edge.com/img/add_to_slack@2x.png 2x"></a>
        HTML
        erb "<p>'s all good man! And now please...</p><br><br>#{button}"
      end
    else
      resp = HTTParty.get(
        "https://api.atlassian.com/me",
        headers: { "Authorization" => "Bearer #{access_token}" }
      )
      data = JSON.parse(resp.body)
      jira_account_id = data["account_id"]
      settings.store.save_sub jira_account_id, { slack_id: slack_id }
      settings.store.save_slack_jira_mapping slack_id, jira_account_id
      name = data["name"]
      [200, "You are subcribed now, #{name}!"]
    end
  end

  post "/:project_id/:issue_id/:comment_id" do
    process(params[:issue_id], params[:comment_id])

    200
  end

  post "/sub" do
    slack_id = params[:user_id]
    url = JiraService.oauth_subscribe_url(
      client_id: settings.jira_client_id,
      redirect_uri: settings.jira_redirect_uri,
      slack_id: slack_id
    )
    "Cool! Just click <#{url}|*here*> and allow me to read your Jira profile."
  end

  post "/unsub" do
    slack_id = params[:user_id]
    if settings.store.remove_sub(slack_id)
      "I hate to see you go :("
    else
      "I am sorry, but you haven't subsribed yet."
    end
  end

  def process(issue_id, comment_id)
    Thread.new do
      Raven.capture do
        jira_service = JiraService.new(
          project_id: settings.store.jira_id,
          token: settings.store.jira_token,
          refresh_token: settings.store.jira_refresh_token,
          client_id: settings.jira_client_id,
          client_secret: settings.jira_client_secret,
          store: settings.store
        )

        CommentHandler.new(
          issue_id: issue_id,
          comment_id: comment_id,
          jira_service: jira_service,
          store: settings.store
        ).process
      end
    end
  end
end
