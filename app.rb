# frozen_string_literal: true

require 'sinatra'
require 'redis'
require 'cgi'

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
    slack_id = data["authed_user"]["id"]
    settings.redis.set "SLACK_TOKEN", data["access_token"]

    if jira_url = settings.redis.get("JIRA_URL")
      "Cool. You're all set! #{jira_url}"
    else
      url = "https://auth.atlassian.com/authorize?audience=api.atlassian.com&client_id=#{settings.jira_client_id}&scope=read%3Ajira-work&redirect_uri=#{CGI.escape(settings.jira_redirect_uri)}&response_type=code&prompt=consent"
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
      settings.redis.set "JIRA_TOKEN", access_token
      resp = HTTParty.get(
        "https://api.atlassian.com/oauth/token/accessible-resources",
        headers: {
          "Authorization" => "Bearer #{access_token}"
        }
      )
      data = JSON.parse(resp.body)
      settings.redis.set "JIRA_ID", data[0]["id"]
      settings.redis.set "JIRA_URL", data[0]["url"]
      if slack_token = settings.redis.get("SLACK_TOKEN")
        "Alles gut jetzt!"
      else
        url = "https://slack.com/oauth/v2/authorize?client_id=#{settings.slack_client_id}&scope=im:read,im:write,chat:write,commands"
        "Alles gut! Now just go here: #{url}"
      end
    else
      resp = HTTParty.get(
        "https://api.atlassian.com/me",
        headers: { "Authorization" => "Bearer #{access_token}" }
      )
      data = JSON.parse(resp.body)
      jira_account_id = data["account_id"]
      settings.redis.hset "subs", jira_account_id, { slack_id: slack_id }.to_json
      settings.redis.hset "slack_ids_to_jira_ids", slack_id, jira_account_id
      name = data["name"]
      [200, "You are signed up #{name}!"]
    end
  end

  post "/oauth" do
    redirect "/oauth?success=true"
  end

  post '/:project_id/:issue_id/:comment_id' do
    process(params[:issue_id], params[:comment_id])

    200
  end

  post '/sub' do
    slack_id = params[:user_id]
    url = "https://auth.atlassian.com/authorize?audience=api.atlassian.com&client_id=#{settings.jira_client_id}&scope=read%3Ame&redirect_uri=#{CGI.escape(settings.jira_redirect_uri)}&state=#{slack_id}&response_type=code&prompt=consent"
    [200, url]
  end

  delete '/unsub' do
    slack_id = params[:user_id]
    jira_id = settings.redis.hget "slack_ids_to_jira_ids", slack_id
    if jira_id
      settings.redis.hdel "subs", jira_id
      settings.redis.hdel "slack_ids_to_jira_ids", slack_id
      200
    else
      400
    end
  end

  def process(issue_id, comment_id)
    Thread.new do
      jira_id = settings.redis.get "JIRA_ID"
      token = settings.redis.get "JIRA_TOKEN"
      url = "https://api.atlassian.com/ex/jira/#{jira_id}/rest/api/3/issue/#{issue_id}/comment/#{comment_id}"
      comment = JSON.parse(
        HTTParty.get(
          url,
          headers: { "Authorization" => "Bearer #{token}" }
        ).body
      )

      content = comment['body']['content'].map do |c|
        c['content']
      end

      mentions = content.flat_map do |cc|
        cc.map { |c| c['attrs']['id'] if c['type'] == 'mention' }.compact
      end

      if mentions.any?
        text = content.flat_map do |cc|
          cc.map do |c|
            case c['type']
            when 'text' then c['text']
            when 'mention' then "@#{c['attrs']['text']}"
            when 'inlineCard' then c['attrs']['url']
            when 'hardBreak' then "\r\n"
            else "OOPS_UNKNOWN_ELEMENT_IN: #{comment_id}"
            end
          end
        end.join.strip

        header = "#{comment['author']['displayName']} mentioned you in <https://nerdgeschoss.atlassian.net/browse/#{issue_id}|*#{issue_id}*>."
        mentions.uniq.each do |id|
          sub = settings.redis.hget 'subs', id
          next if sub.nil?

          slack_id = JSON.parse(sub)['slack_id']
          slack_token = settings.redis.get 'SLACK_TOKEN'
          resp = HTTParty.post(
            'https://slack.com/api/chat.postMessage',
            headers: {
              'Authorization' => "Bearer #{slack_token}"
            },
            body: {
              channel: slack_id,
              text: header,
              attachments: [
                { text: text }
              ].to_json
            }
          )
        end
      end
    end
  end
end
