# frozen_string_literal: true

class CommentHandler
  attr_reader :redis, :issue_id, :comment_id

  def initialize(redis:, issue_id:, comment_id:)
    @redis = redis
    @issue_id = issue_id
    @comment_id = comment_id
  end

  def process
    jira_id = redis.get "JIRA_ID"
    token = redis.get "JIRA_TOKEN"

    url = "https://api.atlassian.com/ex/jira/#{jira_id}/rest/api/3/issue/#{issue_id}/comment/#{comment_id}"
    resp = HTTParty.get(url, headers: { "Authorization" => "Bearer #{token}" })
    raise StandardError, resp.body unless resp.code.to_s.start_with? "2"

    comment = JSON.parse(resp.body)
    mentions, text = data_from_comment(comment)
    return if mentions.nil?

    send_message_to_slack(
      author: comment["author"]["displayName"],
      mentions: mentions,
      text: text
    )
  end

  private

  def data_from_comment(comment)
    content = comment["body"]["content"].map do |c|
      c["content"]
    end

    mentions = content.flat_map do |cc|
      cc.map { |c| c["attrs"]["id"] if c["type"] == "mention" }.compact
    end

    return nil if mentions.empty?

    [mentions.uniq, text_from_content(content)]
  end

  def send_message_to_slack(author:, mentions:, text:)
    slack_token = redis.get "SLACK_TOKEN"
    header = "#{author} mentioned you in " \
             "<https://nerdgeschoss.atlassian.net/browse/#{issue_id}|*#{issue_id}*>."

    mentions.each do |id|
      sub = redis.hget "subs", id
      next if sub.nil?

      slack_id = JSON.parse(sub)["slack_id"]
      resp = HTTParty.post(
        "https://slack.com/api/chat.postMessage",
        headers: { "Authorization" => "Bearer #{slack_token}" },
        body: {
          channel: slack_id,
          text: header,
          attachments: [{ text: text }].to_json
        }
      )

      raise StandardError, resp.body unless resp.code.to_s.start_with? "2"
    end
  end

  def text_from_content(content)
    content.flat_map do |cc|
      cc.map do |c|
        case c["type"]
        when "text" then c["text"]
        when "mention" then "@#{c['attrs']['text']}"
        when "inlineCard" then c["attrs"]["url"]
        when "hardBreak" then "\r\n"
        else raise StandardError, "Unknown element #{c['type']}"
        end
      end
    end.join.strip
  end
end
