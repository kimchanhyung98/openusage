#!/usr/bin/env bash

# release.sh와 build_and_run.sh에서 사용할 번들 버전을 릴리스 태그에서 유도.

openusage_version_from_tag() {
  local tag="$1"

  if [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]]; then
    echo "Release tag must use vMAJOR.MINOR.PATCH with an optional pre-release suffix: $tag" >&2
    return 1
  fi

  printf '%s\n' "${tag#v}"
}

# 호출자의 현재 디렉터리와 무관하게 전달받은 worktree의 가장 가까운 릴리스 태그 사용.
# shallow clone처럼 worktree에 태그가 하나도 없을 때만 0.0.0-dev로 fallback.
openusage_development_version() {
  local repo_dir="${1:?openusage_development_version requires a repository directory}"
  local tag version

  tag="$(git -C "$repo_dir" describe --tags --match 'v[0-9]*' --abbrev=0 2>/dev/null || true)"

  if [ -z "$tag" ]; then
    printf '%s\n' "0.0.0-dev"
    return
  fi

  version="$(openusage_version_from_tag "$tag")" || return 1
  printf '%s-dev\n' "$version"
}
