# frozen_string_literal: true

# SPDX-FileCopyrightText: Copyright (c) 2024-2025 Zerocracy
# SPDX-License-Identifier: MIT

require 'tago'
require 'fbe/octo'
require 'fbe/github_graph'
require 'fbe/iterate'
require 'fbe/if_absent'
require 'fbe/who'
require 'fbe/issue'

start = Time.now

Fbe.iterate do
  as 'events-were-scanned'
  by '(plus 0 $before)'
  quota_aware

  def self.skip_event(json)
    t = Time.parse(json[:created_at].iso8601)
    $loog.debug(
      "Event ##{json[:id]} (#{json[:type]}) " \
      "in #{json[:repo][:name]} ignored (#{t.ago} ago)"
    )
    raise Factbase::Rollback
  end

  def self.fetch_tag(fact, repo)
    tag = fact&.all_properties&.include?('tag') ? fact.tag : nil
    if tag.nil? && fact&.all_properties&.include?('release_id')
      tag = Fbe.octo.release(
        "https://api.github.com/repos/#{repo}/releases/#{fact.release_id}"
      ).fetch(:tag_name, nil)
      $loog.debug("The release ##{fact.release_id} has this tag: #{tag.inspect}")
    end
    tag
  end

  def self.fetch_contributors(fact, repo)
    last = Fbe.fb.query("(and (eq repository #{fact.repository}) (eq what \"#{fact.what}\"))").each.to_a.last
    tag = fetch_tag(last, repo)
    contributors = Set.new
    if tag
      Fbe.octo.compare(repo, tag, fact.tag)[:commits].each do |commit|
        author_id = commit.dig(:author, :id)
        contributors << author_id if author_id
      end
    else
      Fbe.octo.contributors(repo).each do |contributor|
        contributors << contributor[:id]
      end
    end
    $loog.debug("The repository ##{fact.repository} has #{contributors.count} contributors")
    contributors.to_a
  end

  def self.fetch_release_info(fact, repo)
    last = Fbe.fb.query("(and (eq repository #{fact.repository}) (eq what \"#{fact.what}\"))").each.to_a.last
    tag = fetch_tag(last, repo)
    tag ||= find_first_commit(repo)[:sha]
    info = {}
    Fbe.octo.compare(repo, tag, fact.tag).then do |json|
      info[:commits] = json[:total_commits]
      info[:hoc] = json[:files].sum { |f| f[:changes] }
      info[:last_commit] = json[:commits].first[:sha]
    end
    $loog.debug("The repository ##{fact.repository} has this: #{info.inspect}")
    info
  end

  def self.find_first_commit(repo)
    commits = Fbe.octo.commits(repo)
    last = commits.last
    while commits.size != 1
      commits = Fbe.octo.commits(repo, sha: last[:sha])
      last = commits.last
    end
    $loog.debug("The repo ##{repo} has this last commit: #{last}")
    last
  end

  def self.comments_info(pr)
    code_comments = Fbe.octo.pull_request_comments(pr[:base][:repo][:full_name], pr[:number])
    issue_comments = Fbe.octo.issue_comments(pr[:base][:repo][:full_name], pr[:number])
    {
      comments: pr[:comments] + pr[:review_comments],
      comments_to_code: code_comments.count,
      comments_by_author: code_comments.count { |comment| comment[:user][:id] == pr[:user][:id] } +
        issue_comments.count { |comment| comment[:user][:id] == pr[:user][:id] },
      comments_by_reviewers: code_comments.count { |comment| comment[:user][:id] != pr[:user][:id] } +
        issue_comments.count { |comment| comment[:user][:id] != pr[:user][:id] },
      comments_appreciated: count_appreciated_comments(pr, issue_comments, code_comments),
      comments_resolved: Fbe.github_graph.resolved_conversations(
        pr[:base][:repo][:full_name].split('/').first, pr[:base][:repo][:name], pr[:number]
      ).count
    }
  end

  def self.issue_seen_already?(fact)
    Fbe.fb.query(
      "(and (eq repository #{fact.repository}) " \
      '(eq where "github") ' \
      "(not (eq event_id #{fact.event_id}))" \
      "(eq what \"#{fact.what}\") " \
      "(eq issue #{fact.issue}))"
    ).each.any?
  end

  def self.count_appreciated_comments(pr, issue_comments, code_comments)
    issue_appreciations =
      issue_comments.sum do |comment|
        Fbe.octo.issue_comment_reactions(pr[:base][:repo][:full_name], comment[:id])
           .count { |reaction| reaction[:user][:id] != comment[:user][:id] }
      end
    code_appreciations =
      code_comments.sum do |comment|
        Fbe.octo.pull_request_review_comment_reactions(pr[:base][:repo][:full_name], comment[:id])
           .count { |reaction| reaction[:user][:id] != comment[:user][:id] }
      end
    issue_appreciations + code_appreciations
  end

  def self.fetch_workflows(pr)
    succeeded_builds = 0
    failed_builds = 0
    Fbe.octo.check_runs_for_ref(pr[:base][:repo][:full_name], pr[:head][:sha])[:check_runs].each do |run|
      next unless run[:app][:slug] == 'github-actions'
      workflow = Fbe.octo.workflow_run(
        pr[:base][:repo][:full_name],
        Fbe.octo.workflow_run_job(pr[:base][:repo][:full_name], run[:id])[:run_id]
      )
      next unless workflow[:event] == 'pull_request'
      case workflow[:conclusion]
      when 'success'
        succeeded_builds += 1
      when 'failure'
        failed_builds += 1
      end
    end
    { succeeded_builds:, failed_builds: }
  end

  def self.fill_fact_by_hash(fact, hash)
    hash.each do |prop, value|
      fact.send(:"#{prop}=", value)
    end
  end

  def self.fill_up_event(fact, json)
    fact.when = Time.parse(json[:created_at].iso8601)
    fact.event_type = json[:type]
    fact.repository = json[:repo][:id].to_i
    fact.who = json[:actor][:id].to_i if json[:actor]
    rname = Fbe.octo.repo_name_by_id(fact.repository)

    case json[:type]
    when 'PushEvent'
      fact.what = 'git-was-pushed'
      fact.push_id = json[:payload][:push_id]
      fact.ref = json[:payload][:ref]
      fact.commit = json[:payload][:head]
      fact.default_branch = Fbe.octo.repository(rname)[:default_branch]
      fact.to_master = fact.default_branch == fact.ref.split('/')[2] ? 1 : 0
      if fact.to_master.zero?
        $loog.debug("Push #{fact.commit} has been made to non-default branch '#{fact.default_branch}', ignoring it")
        skip_event(json)
      end
      pulls = Fbe.octo.commit_pulls(rname, fact.commit)
      unless pulls.empty?
        $loog.debug("Push #{fact.commit} has been made inside #{pulls.size} pull request(s), ignoring it")
        skip_event(json)
      end
      fact.details =
        "A new Git push ##{json[:payload][:push_id]} has arrived to #{rname}, " \
        "made by #{Fbe.who(fact)} (default branch is '#{fact.default_branch}'), " \
        'not associated with any pull request.'
      $loog.debug("New PushEvent ##{json[:payload][:push_id]} recorded")

    when 'PullRequestEvent'
      pl = json[:payload][:pull_request]
      fact.issue = pl[:number]
      case json[:payload][:action]
      when 'opened'
        fact.what = 'pull-was-opened'
        fact.branch = pl[:head][:ref]
        fact.details =
          "The pull request #{Fbe.issue(fact)} has been opened by #{Fbe.who(fact)}."
        $loog.debug("New PR #{Fbe.issue(fact)} opened by #{Fbe.who(fact)}")
      when 'closed'
        fact.what = "pull-was-#{pl[:merged_at].nil? ? 'closed' : 'merged'}"
        fact.hoc = pl[:additions] + pl[:deletions]
        fill_fact_by_hash(fact, comments_info(pl))
        fill_fact_by_hash(fact, fetch_workflows(pl))
        fact.branch = pl[:head][:ref]
        fact.details =
          "The pull request #{Fbe.issue(fact)} " \
          "has been #{json[:payload][:action]} by #{Fbe.who(fact)}, " \
          "with #{fact.hoc} HoC and #{fact.comments} comments."
        $loog.debug("PR #{Fbe.issue(fact)} closed by #{Fbe.who(fact)}")
      else
        skip_event(json)
      end

    when 'PullRequestReviewEvent'
      case json[:payload][:action]
      when 'created'
        skip_event(json) if json[:payload][:pull_request][:user][:id].to_i == fact.who
        if Fbe.fb.query(
          "(and (eq repository #{fact.repository}) " \
          '(eq what "pull-was-reviewed") ' \
          "(eq who #{fact.who}) " \
          "(eq issue #{json[:payload][:pull_request][:number]}))"
        ).each.to_a.last
          skip_event(json)
        end
        skip_event(json) unless json[:payload][:review][:state] == 'approved'

        fact.issue = json[:payload][:pull_request][:number]
        fact.what = 'pull-was-reviewed'
        pull = Fbe.octo.pull_request(rname, fact.issue)
        fact.hoc = pull[:additions] + pull[:deletions]
        fact.comments = pull[:comments] + pull[:review_comments]
        fact.review_comments = pull[:review_comments]
        fact.commits = pull[:commits]
        fact.files = pull[:changed_files]
        fact.details =
          "The pull request #{Fbe.issue(fact)} " \
          "has been reviewed by #{Fbe.who(fact)} " \
          "with #{fact.hoc} HoC and #{fact.comments} comments."
        $loog.debug("PR #{Fbe.issue(fact)} was reviewed by #{Fbe.who(fact)}")
      else
        skip_event(json)
      end

    when 'IssuesEvent'
      fact.issue = json[:payload][:issue][:number]
      case json[:payload][:action]
      when 'closed'
        fact.what = 'issue-was-closed'
        fact.details =
          "The issue #{Fbe.issue(fact)} has been closed by #{Fbe.who(fact)}."
        $loog.debug("Issue #{Fbe.issue(fact)} closed by #{Fbe.who(fact)}")
      when 'opened'
        fact.what = 'issue-was-opened'
        fact.details =
          "The issue #{Fbe.issue(fact)} has been opened by #{Fbe.who(fact)}."
        $loog.debug("Issue #{Fbe.issue(fact)} opened by #{Fbe.who(fact)}")
      else
        skip_event(json)
      end
      skip_event(json) if issue_seen_already?(fact)

    when 'IssueCommentEvent'
      fact.issue = json[:payload][:issue][:number]
      case json[:payload][:action]
      when 'created'
        fact.what = 'comment-was-posted'
        fact.comment_id = json[:payload][:comment][:id]
        fact.comment_body = json[:payload][:comment][:body]
        fact.who = json[:payload][:comment][:user][:id]
        fact.details =
          "A new comment ##{json[:payload][:comment][:id]} has been posted " \
          "to #{Fbe.issue(fact)} by #{Fbe.who(fact)}."
        $loog.debug("Issue comment posted to #{Fbe.issue(fact)} by #{Fbe.who(fact)}")
      end
      skip_event(json)

    when 'ReleaseEvent'
      fact.release = json[:payload][:release][:id]
      fact.tag = json[:payload][:release][:tag_name]
      case json[:payload][:action]
      when 'published'
        fact.what = 'release-published'
        fact.who = json[:payload][:release][:author][:id]
        fetch_contributors(fact, rname).each { |c| fact.contributors = c }
        fill_fact_by_hash(
          fact, fetch_release_info(fact, rname)
        )
        fact.details =
          "A new release '#{json[:payload][:release][:name]}' has been published " \
          "in #{rname} by #{Fbe.who(fact)}."
        $loog.debug("Release published by #{Fbe.who(fact)}")
      else
        skip_event(json)
      end

    when 'CreateEvent'
      case json[:payload][:ref_type]
      when 'tag'
        fact.what = 'tag-was-created'
        fact.tag = json[:payload][:ref]
        fact.details =
          "A new tag '#{fact.tag}' has been created " \
          "in #{rname} by #{Fbe.who(fact)}."
        $loog.debug("Tag #{fact.tag.inspect} created by #{Fbe.who(fact)}")
      else
        skip_event(json)
      end

    else
      skip_event(json)
    end
  rescue Octokit::Forbidden
    raise "@#{Fbe.octo.user[:login]} doesn't have access to the #{rname} repository, maybe it's private"
  end

  over do |repository, latest|
    rname = Fbe.octo.repo_name_by_id(repository)
    $loog.debug("Starting to scan repository #{rname} (##{repository}), the latest event_id was ##{latest}...")
    id = nil
    total = 0
    detected = 0
    first = nil
    rstart = Time.now
    Fbe.octo.repository_events(repository).each_with_index do |json, idx|
      if !$options.max_events.nil? && idx >= $options.max_events
        $loog.debug("Already scanned #{idx} events in #{rname}, stop now")
        break
      end
      if Time.now - start > 5 * 60
        $loog.debug("We are scanning GitHub events for #{start.ago} already, it's time to stop at #{rname}")
        break
      end
      total += 1
      id = json[:id].to_i
      first = id if first.nil?
      if id <= latest
        $loog.debug("The event_id ##{id} (no.#{idx}) is not larger than ##{latest}, good stop in #{json[:repo][:name]}")
        break
      end
      Fbe.fb.txn do |fbt|
        f =
          Fbe.if_absent(fb: fbt) do |n|
            n.where = 'github'
            n.event_id = json[:id].to_i
          end
        if f.nil?
          $loog.debug("The event ##{id} just detected is already in the factbase")
        else
          fill_up_event(f, json)
          $loog.info("Detected new event_id ##{id} (no.#{idx}) in #{json[:repo][:name]}: #{json[:type]}")
          detected += 1
        end
      end
    end
    $loog.info("In #{rname}, detected #{detected} events out of #{total} scanned in #{rstart.ago}")
    if id.nil?
      $loog.debug("No events found in #{rname} in #{rstart.ago}, the latest event_id remains ##{latest}")
      latest
    elsif id <= latest || latest.zero?
      $loog.debug("Finished scanning #{rname} correctly in #{rstart.ago}, next time will scan until ##{first}")
      first
    else
      $loog.debug("Scanning of #{rname} wasn't completed in #{rstart.ago}, next time will try again until ##{latest}")
      latest
    end
  end
end
