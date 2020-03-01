# frozen_string_literal: true

require 'sinatra'
require 'redis'

class App < Sinatra::Base
  configure do
    set :redis, Redis.new
  end

  post '/:project_id/:issue_id/:comment_id' do
    process(params[:issue_id], params[:comment_id])

    200
  end

  post '/sub' do
    payload = JSON.parse(request.body.read, symbolize_names: true)
    slack_id = payload[:slack_id]
    user = user_by_email(payload[:email])

    if user && slack_id
      val = { slack_id: slack_id }.to_json
      settings.redis.hset 'subs', user['accountId'], val

      201
    else
      400
    end
  end

  delete '/sub/:email' do
    user = user_by_email(params[:email])
    if user
      settings.redis.hdel 'subs', user['accountId']

      204
    else
      400
    end
  end

  def user_by_email(email)
    JSON.parse(
      HTTParty.get(
        "https://nerdgeschoss.atlassian.net/rest/api/3/user/search?query=#{email}",
        basic_auth: { username: ENV['JIRA_USER'], password: ENV['JIRA_TOKEN'] }
      ).body
    ).first
  end

  def process(issue_id, comment_id)
    Thread.new do
      comment = JSON.parse(
        HTTParty.get(
          "https://nerdgeschoss.atlassian.net/rest/api/3/issue/#{issue_id}/comment/#{comment_id}",
          basic_auth: { username: ENV['JIRA_USER'], password: ENV['JIRA_TOKEN'] }
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
          slack_token = ENV['SLACK_TOKEN']
          HTTParty.post(
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
