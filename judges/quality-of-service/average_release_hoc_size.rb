# frozen_string_literal: true

# SPDX-FileCopyrightText: Copyright (c) 2024-2025 Zerocracy
# SPDX-License-Identifier: MIT

require 'fbe/octo'
require 'fbe/unmask_repos'

# Release hoc and commit size
#
# This function is called from the "quality-of-service.rb".
#
# @param [Factbase::Fact] fact The fact just under processing
# @return [Hash] Map with keys as fact attributes and values as integers
def average_release_hoc_size(fact)
  repo_releases = {}
  hocs = []
  commits = []
  Fbe.unmask_repos.each do |repo|
    Fbe.octo.releases(repo).each do |json|
      break if json[:published_at] < fact.since
      (repo_releases[repo] ||= []) << json
    end
  end
  repo_releases.each do |repo, releases|
    releases.reverse.each_cons(2) do |first, last|
      Fbe.octo.compare(repo, first[:tag_name], last[:tag_name]).then do |json|
        hocs << json[:files].sum { |file| file[:changes] }
        commits << json[:total_commits]
      end
    end
  end
  {
    average_release_hoc_size: hocs.empty? ? 0 : hocs.sum.to_f / hocs.size,
    average_release_commits_size: commits.empty? ? 0 : commits.sum.to_f / commits.size
  }
end
