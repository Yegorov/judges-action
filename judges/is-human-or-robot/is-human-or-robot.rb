# frozen_string_literal: true

# SPDX-FileCopyrightText: Copyright (c) 2024-2025 Zerocracy
# SPDX-License-Identifier: MIT

# Judge that identifies whether a GitHub user is a human or a bot.
# Examines GitHub users found in the factbase, determines if they are
# humans or bots based on GitHub user type, and special cases for known
# bots like 'rultor' and '0pdd'. Records the result in the factbase.
#
# @see https://github.com/yegor256/fbe/blob/master/lib/fbe/conclude.rb Implementation of Fbe.conclude
# @note Sets is_human=1 for humans and is_human=0 for bots

require 'fbe/octo'
require 'fbe/conclude'

Fbe.conclude do
  quota_aware
  on '(and
    (not (exists is_human))
    (not (exists stale))
    (eq where "github")
    (exists what)
    (exists who)
    )'
  consider do |f|
    begin
      json = Fbe.octo.user(f.who)
    rescue Octokit::NotFound
      $loog.info("GitHub user ##{f.who} is not found")
      next
    end
    type = json[:type]
    if type == 'Bot' || json[:login] == 'rultor' || json[:login] == '0pdd'
      f.is_human = 0
      $loog.info("GitHub user ##{f.who} (@#{json[:login]}) is actually a bot, in #{f.what}")
    else
      f.is_human = 1
      $loog.info("GitHub user ##{f.who} (@#{json[:login]}) is not a bot, in #{f.what}")
    end
  end
end

Fbe.octo.print_trace!
