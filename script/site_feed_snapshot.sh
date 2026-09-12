#!/usr/bin/env bash
# 현재 저장소의 게시 Git 참조에서 피드·도메인 blob을 기록. 게시 전후 동일성 비교용.
# 사용: bash script/site_feed_snapshot.sh <ref>
set -euo pipefail

REF="${1:?usage: site_feed_snapshot.sh <ref>}"

# 게시 액션이 제거하는 경로가 있으면 쓰기 전에 중단.
if [ -n "$(git ls-tree --name-only "$REF" -- .github)" ]; then
  echo "error: gh-pages must not contain .github" >&2
  exit 1
fi

for file in appcast.xml pricing_supplement.json CNAME; do
  if [ "$(git cat-file -t "$REF:$file")" != blob ]; then
    echo "error: published $file is missing or is not a file" >&2
    exit 1
  fi
  git rev-parse --verify "$REF:$file"
done

if [ "$(git show "$REF:CNAME")" != openusage.chanhyung.kim ]; then
  echo "error: published CNAME does not match the landing page domain" >&2
  exit 1
fi
