#!/usr/bin/env bash
# Static watcher program for a validated PR/MR poll sidecar.
# It emits exactly one merged line for a merged PR or MR, one declined line for
# a GitHub pull request the captain closed without merging after commenting on
# it, and stays silent otherwise, including on every error, so a failed lookup
# can never be read as a merge or a decline. The provider-tagged identity is
# data in the sidecar and is never interpolated into this source: these bytes
# are identical for every task.
# Each provider is read through its own standard CLI, gh for GitHub and glab
# for GitLab, so an upstream checkout needs no extra tooling to follow either.
#
# Decline detection is GitHub-only. It needs a comment author identity, and the
# merge request path already reads state through glab's plain field output
# rather than a JSON processor firstmate does not require, so a GitLab merge
# request keeps watching only for its merge. That matches bin/fm-pr-merge.sh,
# which also serves GitHub alone.
#
# This program never writes. It reports the newest captain comment it can see
# on every cycle, and the watcher's durable seen record decides whether that is
# a fresh instruction, so a killed or timed-out poll can never lose or
# half-record a delivery.
set -u
LC_ALL=C
export LC_ALL

if [ "$#" -eq 6 ] && [ "$1" = --validated ]; then
  provider=$2
  url=$3
  host=$4
  path=$5
  number=$6
elif [ "$#" -eq 0 ]; then
  case "$0" in
    *.check.sh) data=${0%.check.sh}.pr-poll ;;
    *) exit 0 ;;
  esac

  [ -f "$data" ] && [ ! -L "$data" ] || exit 0
  { exec 3< "$data"; } 2>/dev/null || exit 0
  IFS= read -r provider <&3 || exit 0
  IFS= read -r url <&3 || exit 0
  IFS= read -r host <&3 || exit 0
  IFS= read -r path <&3 || exit 0
  IFS= read -r number <&3 || exit 0
  if IFS= read -r _extra <&3; then
    exit 0
  fi
  exec 3<&-
else
  exit 0
fi

case "$number" in
  [1-9]*) ;;
  *) exit 0 ;;
esac
case "$number" in
  *[!0-9]*) exit 0 ;;
esac

# Every component is revalidated here rather than trusted from the sidecar, and
# the stored URL must then be exactly reconstructible from those components, so
# a doctored sidecar cannot redirect this poll at another host or project.
case "$provider" in
  github)
    [ "$host" = github.com ] || exit 0
    owner=${path%%/*}
    repo=${path#*/}
    [ "${#owner}" -ge 1 ] && [ "${#owner}" -le 39 ] || exit 0
    case "$owner" in
      *[!A-Za-z0-9-]*|-*|*-|*--*) exit 0 ;;
    esac
    [ "${#repo}" -ge 1 ] && [ "${#repo}" -le 100 ] || exit 0
    case "$repo" in
      .|..|*[!A-Za-z0-9._-]*) exit 0 ;;
    esac
    [ "$url" = "https://github.com/$owner/$repo/pull/$number" ] || exit 0
    state=$(gh pr view "$url" --json state -q .state 2>/dev/null) || exit 0
    if [ "$state" = MERGED ]; then
      printf '%s\n' merged
      exit 0
    fi
    # Closing a pull request without merging it, after leaving a comment on it,
    # is how the captain declines work and says what to change. Only a comment
    # authored by the account this home is authenticated to the forge as counts
    # as the captain speaking, so a review bot, a CI bot, or a pipeline comment
    # can never be read as his instruction. Every lookup below stays silent on
    # failure for the same reason the merge branch does.
    [ "$state" = CLOSED ] || exit 0
    captain=$(gh api user -q .login 2>/dev/null) || exit 0
    [ "${#captain}" -ge 1 ] && [ "${#captain}" -le 39 ] || exit 0
    case "$captain" in
      *[!A-Za-z0-9-]*|-*|*-) exit 0 ;;
    esac
    # Only the author login and the comment identifier are read. A comment body
    # is arbitrary captain prose that would have to survive a wake line intact,
    # so firstmate fetches it from the forge when it handles the wake instead.
    comments=$(gh pr view "$url" --json comments -q '.comments[] | [.author.login, .id] | @tsv' 2>/dev/null) || exit 0
    [ -n "$comments" ] || exit 0
    latest=
    while IFS=$'\t' read -r author comment_id _rest; do
      [ "$author" = "$captain" ] || continue
      latest=$comment_id
    done <<EOF
$comments
EOF
    [ -n "$latest" ] || exit 0
    # The identifier reaches a wake reason line, so it is accepted only as the
    # opaque token shape a forge issues for a comment and never as a path, an
    # option, or more than one word.
    [ "${#latest}" -le 200 ] || exit 0
    case "$latest" in
      *[!A-Za-z0-9_-]*) exit 0 ;;
    esac
    printf 'declined %s %s\n' "$number" "$latest"
    ;;
  gitlab)
    [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || exit 0
    [ "$host" != github.com ] || exit 0
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
    [ "${#path}" -ge 3 ] && [ "${#path}" -le 1024 ] || exit 0
    case "$path" in
      /*|*/|*//*) exit 0 ;;
    esac
    # A GitLab project sits under at least one group at no fixed depth, and
    # GitLab reserves the "-" segment as its route separator.
    rest=$path
    segments=0
    while [ -n "$rest" ]; do
      case "$rest" in
        */*) segment=${rest%%/*}; rest=${rest#*/} ;;
        *) segment=$rest; rest= ;;
      esac
      segments=$((segments + 1))
      [ "$segments" -le 20 ] || exit 0
      [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 255 ] || exit 0
      case "$segment" in
        .|..|-*|*.git|*.atom|*[!A-Za-z0-9._-]*) exit 0 ;;
      esac
    done
    [ "$segments" -ge 2 ] || exit 0
    [ "$url" = "https://$host/$path/-/merge_requests/$number" ] || exit 0
    # glab resolves the instance from the project URL passed to -R, so the host
    # comes from the validated record rather than glab's configured default.
    # It cannot take a merge request URL the way gh does: that form shells out
    # to git for the current repository, and the watcher runs in no repository.
    # The state is read from glab's own field output rather than its JSON,
    # because plain glab has no field selector and firstmate does not require a
    # JSON processor; only an exact "merged" wakes, so a changed format or an
    # unreadable merge request stays silent instead of reporting a merge.
    raw=$(glab mr view "$number" -R "https://$host/$path" 2>/dev/null) || exit 0
    state=$(printf '%s\n' "$raw" | sed -n 's/^state:[[:space:]]*//p' | head -1) || exit 0
    [ "$state" = merged ] && printf '%s\n' merged
    ;;
  *) exit 0 ;;
esac
exit 0
