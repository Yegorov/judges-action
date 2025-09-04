# frozen_string_literal: true

# SPDX-FileCopyrightText: Copyright (c) 2024-2025 Zerocracy
# SPDX-License-Identifier: MIT

# Judge that finds and records all issues in GitHub repositories.
# Iterates through repositories, identifies existing issues by searching GitHub,
# and records them in the factbase with metadata about when they were opened
# and by whom. Used to ensure a complete record of issues in the monitored repos.
#
# We have this script because "github-events.rb" is unreliable - it may miss.
# some issues, due to GitHub limitations. GitHub doesn't allow us to scan the
# entire history of all events, only the last 1000. Moreover, there could be
# connectivity problems.
#
# @see https://github.com/yegor256/fbe/blob/master/lib/fbe/iterate.rb Implementation of Fbe.iterate
# @see https://github.com/yegor256/fbe/blob/master/lib/fbe/if_absent.rb Implementation of Fbe.if_absent

require 'time'
require 'fbe/fb'
require 'fbe/octo'
require 'fbe/if_absent'
require 'fbe/who'
require 'fbe/issue'
require_relative '../../lib/issue_was_lost'

Fbe.fb.query('(and (eq where "github") (exists repository) (unique repository))').each do |r|
  next if Fbe.octo.off_quota?
  repo = Fbe.octo.repo_name_by_id(r.repository)
  issues = Fbe.fb.query(
    "(and (eq repository #{r.repository}) (exists issue) (eq where 'github') (unique issue))"
  ).each.to_a.map(&:issue).uniq.sort
  next if issues.empty?
  must = (issues.min..issues.max).to_a
  missing = must - issues
  added = 0
  checked = 0
  missing.take(200).each do |i|
    json = Fbe.octo.issue(repo, i)
    checked += 1
    if json[:number].nil?
      $loog.warn("Apparently, the JSON for the issue ##{i} doesn't have 'number' field")
      Jp.issue_was_lost('github', r.repository, i)
      next
    end
    type = json[:pull_request] ? 'pull' : 'issue'
    f =
      Fbe.if_absent do |n|
        n.where = 'github'
        n.what = "#{type}-was-opened"
        n.repository = r.repository
        n.issue = json[:number]
      end
    next if f.nil?
    f.when = json[:created_at]
    f.who = json.dig(:user, :id)
    if type == 'pull'
      ref = Fbe.octo.pull_request(repo, f.issue).dig(:head, :ref)
      if ref
        f.branch = ref
      else
        f.stale = 'branch'
      end
    end
    f.details = "The #{type} #{Fbe.issue(f)} has been opened by #{Fbe.who(f)}."
    $loog.info("Lost #{type} #{Fbe.issue(f)} was found")
    added += 1
  rescue Octokit::NotFound => e
    Jp.issue_was_lost('github', r.repository, i)
    $loog.info("The issue ##{i} doesn't exist in #{repo}: #{e.message}")
  end
  if missing.empty?
    $loog.info("No missing issues in #{repo}")
  else
    $loog.info("Checked #{checked} out of #{missing.count} missing issues in #{repo}, #{added} facts added")
  end
end

Fbe.octo.print_trace!
