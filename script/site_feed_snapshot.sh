#!/usr/bin/env bash
# 현재 저장소의 게시 Git 참조에서 피드 blob과 도메인을 확인. 게시 전후 피드 비교용.
# 사용: bash script/site_feed_snapshot.sh [--allow-legacy-domain] <ref>
set -euo pipefail

ALLOW_LEGACY_DOMAIN=0
if [ "${1:-}" = --allow-legacy-domain ]; then
  ALLOW_LEGACY_DOMAIN=1
  shift
fi
REF="${1:?usage: site_feed_snapshot.sh [--allow-legacy-domain] <ref>}"

# 게시 액션이 제거하는 경로가 있으면 쓰기 전에 중단.
if [ -n "$(git ls-tree --name-only "$REF" -- .github)" ]; then
  echo "error: gh-pages must not contain .github" >&2
  exit 1
fi

for file in appcast.xml pricing_supplement.json CNAME; do
  case "$(git ls-tree --format='%(objectmode)' "$REF" -- "$file")" in
    100644|100755) ;;
    *)
      echo "error: published $file is missing or is not a regular file" >&2
      exit 1
      ;;
  esac
  if [ "$file" != CNAME ]; then
    git rev-parse --verify "$REF:$file"
  fi
done

domain="$(git show "$REF:CNAME")"
if [ "$domain" = egasu.chanhyung.kim ]; then exit 0; fi
if [ "$ALLOW_LEGACY_DOMAIN" = 1 ] && [ "$domain" = openusage.chanhyung.kim ]; then exit 0; fi
echo "error: published CNAME does not match the landing page domain" >&2
exit 1
