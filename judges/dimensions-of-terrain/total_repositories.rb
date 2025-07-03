# frozen_string_literal: true

# SPDX-FileCopyrightText: Copyright (c) 2024-2025 Zerocracy
# SPDX-License-Identifier: MIT

require 'fbe/octo'
require 'fbe/unmask_repos'

# Total number of repositories in the project.
#
# This function is called from the "dimensions-of-terrain.rb".
#
# @param [Factbase::Fact] fact The fact just under processing
# @return [Hash] Map with keys as fact attributes and values as integers
def total_repositories(_fact)
  total = 0
  Fbe.unmask_repos.each do |repo|
    total += 1 unless Fbe.octo.repository(repo)[:archived]
  end
  { total_repositories: total }
end
