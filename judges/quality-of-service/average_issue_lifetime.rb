# frozen_string_literal: true

# SPDX-FileCopyrightText: Copyright (c) 2024-2025 Zerocracy
# SPDX-License-Identifier: MIT

require 'fbe/octo'
require 'fbe/unmask_repos'

# Calculates the average lifetime of issues and pull requests in monitored GitHub repositories.
# This function determines how long issues and PRs remain open before being closed by
# measuring the time difference between creation and closure dates. Only includes
# issues/PRs that were closed after the 'since' date specified in the fact object.
#
# This function is called from the "quality-of-service.rb" using the incremate
# helper to collect these specific metrics as part of repository quality assessment.
#
# @param [Factbase::Fact] fact The fact object containing the 'since' timestamp
# @return [Hash] Map with average_issue_lifetime and average_pull_lifetime in seconds
# @see ../quality-of-service.rb Main judge that calls this function
def average_issue_lifetime(fact)
  ret = {}
  { issue: 'average_issue_lifetime', pr: 'average_pull_lifetime' }.each do |type, prop|
    ages = []
    Fbe.unmask_repos do |repo|
      q = "repo:#{repo} type:#{type} closed:>#{fact.since.utc.iso8601[0..9]}"
      ages +=
        Fbe.octo.search_issues(q)[:items].map do |json|
          next if json[:closed_at].nil?
          next if json[:created_at].nil?
          json[:closed_at] - json[:created_at]
        end
    end
    ages.compact!
    ret[prop] = ages.empty? ? 0 : ages.sum.to_f / ages.size
    ret[prop.sub(/\Aaverage_/, 'some_')] = ages
  end
  ret
end
