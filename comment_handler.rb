# frozen_string_literal: true

class CommentHandler
  RULE = "-" * 35
  ACCEPTED_TYPES = %w[
    heading
    paragraph
    blockquote
    panel
    rule
    text
    emoji
    mention
    table
    inline_card
  ].freeze

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
    content = comment["body"]["content"].filter_map do |c|
      c["content"]
    end

    mentions = content.flat_map do |cc|
      cc.filter_map { |c| c["attrs"]["id"] if c["type"] == "mention" }
    end

    return nil if mentions.empty?

    [mentions.uniq, handle(comment["body"]["content"])]
  end

  def handle(d)
    d.flat_map do |c|
      type = c["type"].gsub(/(.)([A-Z])/, '\1_\2').downcase
      send "handle_#{type}", c if ACCEPTED_TYPES.include? type
    end.join.strip
  end

  def handle_heading(d)
    "*" + handle(d["content"]) + "*\r\n"
  end

  def handle_text(d)
    d["text"]
  end

  def handle_paragraph(d)
    handle(d["content"]) + "\r\n"
  end

  def handle_mention(d)
    "@" + d["attrs"]["text"]
  end

  def handle_emoji(d)
    d["attrs"]["text"]
  end

  def handle_blockquote(d)
    handle(d["content"]) + "\r\n"
  end

  def handle_panel(d)
    handle(d["content"]) + "\r\n"
  end

  def handle_rule(_d)
    RULE + "\r\n"
  end

  def handle_table(_)
    "~ :question: ~\r\n"
  end

  def handle_inline_card(d)
    d["attrs"]["url"]
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
end
