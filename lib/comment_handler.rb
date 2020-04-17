# frozen_string_literal: true

class CommentHandler
  RULE = "-" * 35
  ACCEPTED_TYPES = %w[
    inline_card
    bullet_list
    ordered_list
    blockquote
    paragraph
    mention
    heading
    emoji
    panel
    table
    rule
    text
  ].freeze

  class << self
    def process(comment)
      content = comment["body"]["content"].filter_map do |c|
        c["content"]
      end

      mentions = content.flat_map do |cc|
        cc.filter_map { |c| c["attrs"]["id"] if c["type"] == "mention" }
      end

      return nil if mentions.empty?

      [
        mentions.uniq,
        handle(comment["body"]["content"]),
        comment["author"]["displayName"]
      ]
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
      link = (d["marks"] || []).find { |m| m["type"] == "link" }
      href = link&.dig("attrs", "href")
      return "<#{link['attrs']['href']}|#{d['text']}>" if href

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

    def handle_bullet_list(d)
      d["content"].map { |l| handle_list_item(l, "•") }.join("\r\n") + "\r\n"
    end

    def handle_ordered_list(d)
      d["content"].map.with_index(1) do |l, i|
        handle_list_item(l, "#{i}.")
      end.join("\r\n") + "\r\n"
    end

    def handle_list_item(d, char)
      "#{char} #{handle(d['content'])}"
    end
  end
end
