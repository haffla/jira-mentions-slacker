# frozen_string_literal: true

require "sinatra"
require "redis"
require_relative "./comment_handler"
require_relative "./jira_service"
require_relative "./slack_service"
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
    SlackService.new(
      client_id: settings.slack_client_id,
      client_secret: settings.slack_client_secret,
      redirect_uri: settings.slack_redirect_uri,
      store: store
    ).request_access(code: params[:code])

    if (jira_url = store.jira_url)
      "Cool. You're all set! #{jira_url}"
    else
      url = JiraService.oauth_setup_url(client_id: settings.jira_client_id, redirect_uri: settings.jira_redirect_uri)
      here = <<~HTML
        <a href="#{url}">here</a>
      HTML
      "Cool. Just click #{here} in order to authorize the Jira app."
    end
  end

  get "/jira/oauth" do
    code = params[:code]
    slack_id = params[:state]

    access_token, refresh_token = JiraService.request_access(
      client_id: settings.jira_client_id,
      client_secret: settings.jira_client_secret,
      code: code,
      redirect_uri: settings.jira_redirect_uri
    )

    if slack_id.nil?
      store.save_jira_token access_token
      store.save_jira_refresh_token refresh_token
      id, url = JiraService.instance_details(access_token: access_token)
      store.save_jira_id id
      store.save_jira_url url

      if store.slack_token
        "Boom! Way to go."
      else
        button = SlackService.oauth_button(settings.slack_client_id)
        erb "<p>'s all good man! And now please...</p><br><br>#{button}"
      end
    else
      jira_account_id, name = JiraService.user_details(access_token: access_token)
      store.save_sub jira_account_id, { slack_id: slack_id }
      store.save_slack_jira_mapping slack_id, jira_account_id
      [200, "You are subcribed now, #{name}!"]
    end
  end

  post "/:project_id/:issue_id/:comment_id" do
    process(params[:issue_id], params[:comment_id])

    200
  end

  post "/sub" do
    slack_id = params[:user_id]
    jira_id = store.jira_id_by_slack_id slack_id
    if jira_id
      # We got the user's Slack ID and Jira ID
      "You already subscribed mate!"
    else
      url = JiraService.oauth_subscribe_url(
        client_id: settings.jira_client_id,
        redirect_uri: settings.jira_redirect_uri,
        slack_id: slack_id
      )
      "Cool! Just click <#{url}|*here*> and allow me to read your Jira profile."
    end
  end

  post "/unsub" do
    slack_id = params[:user_id]
    if store.remove_sub(slack_id)
      "I hate to see you go :("
    else
      "I am sorry, but you haven't subsribed yet."
    end
  end

  def store
    settings.store
  end

  def process(issue_id, comment_id)
    Thread.new do
      Raven.capture do
        comment = JiraService.new(
          client_id: settings.jira_client_id,
          client_secret: settings.jira_client_secret,
          store: store
        ).fetch_comment(issue_id: issue_id, comment_id: comment_id)

        mentions, text, author = CommentHandler.process(comment)

        SlackService.send_message(
          author: author,
          mentions: mentions,
          text: text,
          issue_id: issue_id,
          store: store
        )
      end
    end
  end
end
