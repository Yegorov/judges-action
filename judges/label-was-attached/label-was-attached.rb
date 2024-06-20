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

iterate do
  as 'labels-were-scanned'
  by "(agg (and (eq repository $repository) (eq what 'issue-was-opened') (gt issue $before)) (min issue))"
  limit $options.max_labels
  quota_aware
  over do |repository, issue|
    octo.issue_timeline(repository, issue).each do |te|
      next unless te[:event] == 'labeled'
      badge = te[:label][:name]
      next unless %w[bug enhancement question].include?(badge)
      nn = if_absent(fb) do |n|
        n.repository = repository
        n.issue = issue
        n.label = te[:label][:name]
        n.what = $judge
      end
      next if nn.nil?
      nn.who = te[:actor][:id]
      nn.when = te[:created_at]
      nn.details =
        "The '##{nn.label}' label was attached by @#{te[:actor][:login]} " \
        "to the issue #{octo.repo_name_by_id(nn.repository)}##{nn.issue} " \
        "at #{nn.when.utc.iso8601}; this may trigger future judges."
    end
    issue
  end
end
