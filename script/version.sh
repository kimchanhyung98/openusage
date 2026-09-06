#!/usr/bin/env bash

# release.sh와 build_and_run.sh에서 사용할 번들 버전을 릴리스 태그에서 유도.

openusage_version_from_tag() {
  local tag="$1"

  if [[ ! "$tag" =~ ^v(0\.([7-9]|[1-9][0-9]+)|[1-9][0-9]*\.(0|[1-9][0-9]*))\.(0|[1-9][0-9]*)(-beta\.[1-9][0-9]*)?$ ]]; then
    echo "Release tag must be v0.7.0 or newer, optionally ending in -beta.N, without leading zeroes: $tag" >&2
    return 1
  fi

  printf '%s\n' "${tag#v}"
}

# 릴리스 버전은 실제 HEAD 태그에서만 유도하며 main에 포함된 소스만 허용.
openusage_release_version() {
  local repo_dir="${1:?openusage_release_version requires a repository directory}"
  local tag="$2" version tag_commit head_commit

  version="$(openusage_version_from_tag "$tag")" || return 1
  tag_commit="$(git -C "$repo_dir" rev-parse --verify "refs/tags/$tag^{commit}")" || return 2
  head_commit="$(git -C "$repo_dir" rev-parse --verify HEAD)" || return 2
  if [ "$tag_commit" != "$head_commit" ]; then
    echo "Release tag does not point to HEAD: $tag" >&2
    return 2
  fi
  if ! git -C "$repo_dir" merge-base --is-ancestor "$tag_commit" refs/remotes/origin/main; then
    echo "Release tag must point to a commit reachable from origin/main: $tag" >&2
    return 2
  fi
  printf '%s\n' "$version"
}

# 호출자의 현재 디렉터리와 무관하게 전달받은 worktree의 가장 가까운 릴리스 태그 사용.
# shallow clone처럼 HEAD에서 도달할 수 있는 릴리스 태그가 없을 때만 0.0.0-dev로 fallback.
openusage_development_version() {
  local repo_dir="${1:?openusage_development_version requires a repository directory}"
  local tag version reachable_tags

  git -C "$repo_dir" rev-parse --verify HEAD >/dev/null || return 2
  reachable_tags="$(git -C "$repo_dir" tag --merged HEAD --list 'v[0-9]*')" || return 2

  if [ -z "$reachable_tags" ]; then
    printf '%s\n' "0.0.0-dev"
    return
  fi

  tag="$(git -C "$repo_dir" describe --tags --match 'v[0-9]*' --abbrev=0)" || return 2
  version="$(openusage_version_from_tag "$tag")" || return 1
  printf '%s-dev\n' "$version"
}
