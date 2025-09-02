# frozen_string_literal: true

# SPDX-FileCopyrightText: Copyright (c) 2024-2025 Zerocracy
# SPDX-License-Identifier: MIT

# Judge that verifies GitHub users still exist and are active.
# Checks GitHub users in the factbase that haven't been updated in the last 2 days,
# attempts to retrieve their nickname, and if the user no longer exists in GitHub,
# mark the entire fact as "stale".
#
# @see ../../lib/nick_of.rb Implementation of the nick retrieval logic
# @see https://github.com/yegor256/fbe/blob/master/lib/fbe/delete.rb Implementation of Fbe.delete

require 'elapsed'
require 'fbe/conclude'
require 'fbe/fb'
require 'fbe/octo'
require_relative '../../lib/nick_of'

seen = []

Fbe.conclude do
  on "(and
    (eq what 'who-has-name')
    (lt when (minus (to_time (env 'TODAY' '#{Time.now.utc.iso8601}')) '2 days'))
    (absent stale)
    (exists who)
    (eq where 'github'))"
  consider do |f|
    next if seen.include?(f.who)
    seen << f.who
    elapsed($loog) do
      nick = Jp.nick_of(f.who)
      unless nick.nil?
        $loog.debug("GitHub user @#{nick} (##{f.who}) is alive")
        next
      end
      Fbe.fb.query("(and (eq where 'github') (eq what 'who-has-name') (eq who #{f.who}))").delete!
      done =
        Fbe.fb.query("(and (eq where 'github') (eq who #{f.who}))").each do |n|
          n.stale = 'who'
        end
      throw :"GitHub user ##{f.who} is gone, marked #{done} facts as stale"
    end
  end
end

Fbe.octo.print_trace!
