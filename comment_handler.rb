# frozen_string_literal: true

class CommentHandler
  attr_reader :issue_id, :comment_id, :store, :jira_service

  def initialize(store:, issue_id:, comment_id:, jira_service:)
    @store = store
    @jira_service = jira_service
    @issue_id = issue_id
    @comment_id = comment_id
  end

  def process
    comment = jira_service.fetch_comment(
      issue_id: issue_id,
      comment_id: comment_id
    )
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
      cc.filter_map { |c| c["attrs"]["id"] if c["type"] == "mention" }
    end

    return nil if mentions.empty?

    [mentions.uniq, text_from_content(content)]
  end

  def send_message_to_slack(author:, mentions:, text:)
    base_url = store.jira_url
    header = "#{author} mentioned you in " \
             "<#{base_url}/browse/#{issue_id}|*#{issue_id}*>."
    slack_token = store.slack_token
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
