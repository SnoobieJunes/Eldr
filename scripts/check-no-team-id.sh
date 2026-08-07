#!/bin/sh
# Fail the commit if an Apple DEVELOPMENT_TEAM id is staged into a project file.
#
# This repository is PUBLIC and the team id is deliberately absent from every
# pbxproj — signing is supplied on the command line instead:
#
#   xcodebuild ... DEVELOPMENT_TEAM="$(cat private/dev-team.txt)"
#
# It has nevertheless leaked three times, always the same way: Xcode rewrites
# the pbxproj when the project is opened with a team selected, and the change
# rides along in the next `git commit -a`. dbe72b7 scrubbed it, 53b465a (AC146)
# put it back into Huginn, and Xcode later wrote it into EldrChat as well.
#
# Install as a pre-commit hook:
#   ln -sf ../../scripts/check-no-team-id.sh .git/hooks/pre-commit
#
# Bypass, if you genuinely mean to commit one:
#   git commit --no-verify

set -eu

hits=$(git diff --cached -U0 -- '*.pbxproj' \
       | grep -n '^+.*DEVELOPMENT_TEAM = [A-Z0-9]' || true)

if [ -n "$hits" ]; then
	printf '%s\n' "pre-commit: refusing to stage an Apple team id into a public pbxproj." >&2
	printf '%s\n' "" >&2
	printf '%s\n' "$hits" >&2
	printf '%s\n' "" >&2
	printf '%s\n' "Xcode almost certainly wrote this. Drop the hunk:" >&2
	printf '%s\n' "  git restore --staged --worktree -- '*.pbxproj'" >&2
	printf '%s\n' "" >&2
	printf '%s\n' "Signing comes from the command line, not the project file:" >&2
	printf '%s\n' '  xcodebuild ... DEVELOPMENT_TEAM="$(cat private/dev-team.txt)"' >&2
	printf '%s\n' "" >&2
	printf '%s\n' "Intentional? git commit --no-verify" >&2
	exit 1
fi

exit 0
