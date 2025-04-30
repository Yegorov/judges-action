# frozen_string_literal: true

# SPDX-FileCopyrightText: Copyright (c) 2024-2025 Zerocracy
# SPDX-License-Identifier: MIT

require 'fbe/octo'
require 'fbe/overwrite'
require 'tago'
require 'time'
require_relative 'jp'

# Incrementally accumulates data into a fact, using Ruby scripts
# found in the directory provided, by the prefix.
#
# @param [Factbase::Fact] fact The fact to put data into (some data already there)
# @param [String] dir Where to find Ruby scripts
# @param [String] prefix The prefix to use for scripts (e.g. "total")
# @param [Integer] timeout How many seconds to spend, after which we give up
# @return nil
def Jp.incremate(fact, dir, prefix, timeout: 30, avoid_duplicate: false)
  start = Time.now
  Dir[File.join(dir, "#{prefix}_*.rb")].shuffle.each do |rb|
    n = File.basename(rb).gsub(/\.rb$/, '')
    unless fact[n].nil?
      $loog.info("#{n} is here: #{fact[n].first}")
      next
    end
    if Fbe.octo.off_quota
      $loog.info('No GitHub quota left, it is time to stop')
      break
    end
    if Time.now - start > timeout
      $loog.info("We are doing this for too long (#{start.ago} > #{timeout}s), time to stop")
      break
    end
    require_relative rb
    before = Time.now
    next if avoid_duplicate && (send("#{n}_props") - fact.all_properties).empty?
    h = send(n, fact)
    h.each do |k, v|
      next if avoid_duplicate && fact.all_properties.include?(k.to_s)
      fact = Fbe.overwrite(fact, k.to_s, v)
    end
    $loog.info("Collected #{n} in #{before.ago} (#{start.ago} total): [#{h.map { |k, v| "#{k}: #{v}" }.join(', ')}]")
  end
end
