# frozen_string_literal: true

class Store
  attr_reader :r

  def initialize(redis:)
    @r = redis
  end

  def jira_token
    r.get "JIRA_TOKEN"
  end

  def save_jira_token(token)
    r.set "JIRA_TOKEN", token
  end

  def jira_refresh_token
    r.get "JIRA_REFRESH_TOKEN"
  end

  def save_jira_refresh_token(token)
    r.set "JIRA_REFRESH_TOKEN", token
  end

  def jira_url
    r.get "JIRA_URL"
  end

  def save_jira_url(url)
    r.set "JIRA_URL", url
  end

  def slack_token
    r.get "SLACK_TOKEN"
  end

  def jira_id
    r.get "JIRA_ID"
  end

  def save_jira_id(id)
    r.set "JIRA_ID", id
  end

  def save_slack_token(token)
    r.set "SLACK_TOKEN", token
  end

  def sub(id)
    sub = r.hget "subs", id
    JSON.parse(sub) if sub
  end

  def save_sub(id, payload)
    r.hset "subs", id, payload.to_json
  end

  def save_slack_jira_mapping(slack_id, jira_id)
    r.hset "slack_ids_to_jira_ids", slack_id, jira_id
  end

  def jira_id_by_slack_id(slack_id)
    r.hget "slack_ids_to_jira_ids", slack_id
  end

  def remove_sub(slack_id, jira_id)
    r.hdel "slack_ids_to_jira_ids", slack_id
    r.hdel "subs", jira_id
  end
end
