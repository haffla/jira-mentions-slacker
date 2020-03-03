# frozen_string_literal: true

require "sinatra"
require "redis"
require "cgi"
require_relative "./comment_handler"

class App < Sinatra::Base
  configure do
    redirect_uri = ENV["REDIRECT_URI"]

    set :redis, Redis.new
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
    redis.set "SLACK_TOKEN", data["access_token"]

    if (jira_url = redis.get("JIRA_URL"))
      "Cool. You're all set! #{jira_url}"
    else
      url = "https://auth.atlassian.com/authorize?audience=api.atlassian.com" \
            "&client_id=#{settings.jira_client_id}&scope=read%3Ajira-work%20offline_access" \
            "&redirect_uri=#{CGI.escape(settings.jira_redirect_uri)}&response_type=code&prompt=consent"
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
      redis.set "JIRA_TOKEN", access_token
      redis.set "JIRA_REFRESH_TOKEN", data["refresh_token"]

      resp = HTTParty.get(
        "https://api.atlassian.com/oauth/token/accessible-resources",
        headers: { "Authorization" => "Bearer #{access_token}" }
      )

      data = JSON.parse(resp.body)
      redis.set "JIRA_ID", data[0]["id"]
      redis.set "JIRA_URL", data[0]["url"]
      if redis.get("SLACK_TOKEN")
        "Boom! Way to go."
      else
        url = "https://slack.com/oauth/v2/authorize?" \
              "client_id=#{settings.slack_client_id}" \
              "&scope=im:read,im:write,chat:write,commands"
        "s'all good man! Now just go here: #{url}"
      end
    else
      resp = HTTParty.get(
        "https://api.atlassian.com/me",
        headers: { "Authorization" => "Bearer #{access_token}" }
      )
      data = JSON.parse(resp.body)
      jira_account_id = data["account_id"]
      redis.hset "subs", jira_account_id, { slack_id: slack_id }.to_json
      redis.hset "slack_ids_to_jira_ids", slack_id, jira_account_id
      name = data["name"]
      [200, "You are subcribed now, #{name}!"]
    end
  end

  post "/oauth" do
    redirect "/oauth?success=true"
  end

  post "/:project_id/:issue_id/:comment_id" do
    process(params[:issue_id], params[:comment_id])

    200
  end

  post "/sub" do
    slack_id = params[:user_id]
    url = "https://auth.atlassian.com/authorize" \
          "?audience=api.atlassian.com&client_id=#{settings.jira_client_id}" \
          "&scope=read%3Ame&redirect_uri=#{CGI.escape(settings.jira_redirect_uri)}" \
          "&state=#{slack_id}&response_type=code&prompt=consent"
    [200, url]
  end

  delete "/unsub" do
    slack_id = params[:user_id]
    jira_id = redis.hget "slack_ids_to_jira_ids", slack_id
    if jira_id
      redis.hdel "subs", jira_id
      redis.hdel "slack_ids_to_jira_ids", slack_id
      200
    else
      400
    end
  end

  def redis
    settings.redis
  end

  def process(issue_id, comment_id)
    Thread.new do
      Raven.capture do
        CommentHandler.new(issue_id: issue_id, comment_id: comment_id, settings: settings).process
      end
    end
  end
end
