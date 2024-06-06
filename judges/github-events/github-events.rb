# frozen_string_literal: true

# MIT License
#
# Copyright (c) 2024 Zerocracy
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

def put_new_event(fact, json)
  fact.when = Time.parse(json[:created_at].iso8601)
  fact.event_type = json[:type]
  fact.event_id = json[:id].to_i
  fact.repository = json[:repo][:id].to_i
  fact.who = json[:actor][:id].to_i if json[:actor]

  case json[:type]
  when 'PushEvent'
    fact.what = 'git-was-pushed'
    fact.push_id = json[:payload][:push_id]
    raise Factbase::Rollback

  when 'IssuesEvent'
    fact.issue = json[:payload][:issue][:number]
    if json[:payload][:action] == 'closed'
      fact.what = 'issue-was-closed'
    elsif json[:payload][:action] == 'opened'
      fact.what = 'issue-was-opened'
    end

  when 'IssueCommentEvent'
    fact.issue = json[:payload][:issue][:number]
    if json[:payload][:action] == 'created'
      fact.what = 'comment-was-posted'
      fact.comment_id = json[:payload][:comment][:id]
      fact.comment_body = json[:payload][:comment][:body]
      fact.who = json[:payload][:comment][:user][:id]
    end
    raise Factbase::Rollback

  when 'ReleaseEvent'
    fact.release_id = json[:payload][:release][:id]
    if json[:payload][:action] == 'published'
      fact.what = 'release-published'
      fact.who = json[:payload][:release][:author][:id]
    end

  when 'CreateEvent'
    if json[:payload][:ref_type] == 'tag'
      fact.what = 'tag-was-created'
      fact.tag = json[:payload][:ref]
    end

  else
    raise Factbase::Rollback
  end

  fact.details =
    "A new event ##{json[:id]} happened in GitHub repository #{json[:repo][:name]} " \
    "(##{json[:repo][:id]}) of type '#{json[:type]}', " \
    "with the creation time #{json[:created_at].iso8601}; " \
    'this fact must be interpreted later by other judges.'
end

def one_repo(repo, limit)
  seen = 0
  catch :stop do
    octo.repository_events(repo).each do |json|
      unless fb.query("(eq event_id #{json[:id]})").each.to_a.empty?
        $loog.debug("The event ##{json[:id]} (#{json[:type]}) has already been seen, skipping")
        next
      end
      $loog.info("Detected new event ##{json[:id]} in #{json[:repo][:name]}: #{json[:type]}")
      fb.txn do |fbt|
        if_absent(fbt) do |n|
          put_new_event(n, json)
        end
      end
      seen += 1
      if seen >= limit
        $loog.debug("Already scanned #{seen} events, that's enough (>=#{limit})")
        throw :stop
      end
      throw :alarm if octo.off_quota
    end
  end
  seen
end

limit = $options.max_events
limit = 1000 if limit.nil?
raise "It is impossible to scan deeper than 10,000 GitHub events, you asked for #{limit}" if limit > 10_000

catch :alarm do
  repos = each_repo.each.to_a
  repos.each do |repo|
    one_repo(repo, limit / repos.size)
  end
end
