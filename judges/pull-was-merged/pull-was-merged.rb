# frozen_string_literal: true

# SPDX-FileCopyrightText: Copyright (c) 2024-2025 Zerocracy
# SPDX-License-Identifier: MIT

# Judge that monitors pulls which were closed or merged.

require 'fbe/conclude'
require 'fbe/octo'
require 'fbe/github_graph'
require 'fbe/who'
require 'fbe/issue'
require 'fbe/delete'
require 'fbe/overwrite'
require_relative '../../lib/fill_fact'
require_relative '../../lib/pull_request'

Fbe.iterate do
  as 'merges-were-scanned'
  by "(agg
    (and
      (eq where 'github')
      (or
        (eq what 'pull-was-opened')
        (eq what 'code-was-contributed')
        (eq what 'code-was-reviewed')
        (eq what 'code-contribution-was-rewarded')
        (eq what 'code-review-was-rewarded'))
      (eq repository $repository)
      (gt issue $before)
      (empty
        (and
          (eq where $where)
          (eq repository $repository)
          (eq issue $issue)
          (eq what 'pull-was-closed')))
      (empty
        (and
          (eq where $where)
          (eq repository $repository)
          (eq issue $issue)
          (eq what 'pull-was-merged'))))
    (min issue))"
  quota_aware
  repeats 100
  over(timeout: 5 * 60) do |repository, issue|
    repo = Fbe.octo.repo_name_by_id(repository)
    json = Fbe.octo.pull_request(repo, issue)
    unless json[:state] == 'closed'
      $loog.debug("Pull #{repo}##{issue} is not closed: #{json[:state].inspect}")
      next issue
    end
    nn =
      Fbe.if_absent do |n|
        n.where = 'github'
        n.repository = repository
        n.issue = issue
        n.when = json[:closed_at] ? Time.parse(json[:closed_at].iso8601) : Time.now
        actor = Fbe.octo.issue(repo, issue)[:closed_by]
        if actor
          n.who = actor[:id].to_i
        else
          n.stale = 'who'
        end
        action = json[:merged_at].nil? ? 'closed' : 'merged'
        n.what = "pull-was-#{action}"
        n.hoc = json[:additions] + json[:deletions]
        Jp.fill_fact_by_hash(n, Jp.comments_info(json))
        Jp.fill_fact_by_hash(n, Jp.fetch_workflows(json))
        n.branch = json[:head][:ref]
      end
    next issue if nn.nil?
    nn.details = "Apparently, #{Fbe.issue(nn)} has been '#{nn.what}'."
    issue
  end
end

Fbe.octo.print_trace!
