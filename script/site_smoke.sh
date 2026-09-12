#!/usr/bin/env bash
# 배포 후 smoke — 랜딩 페이지가 appcast/pricing 제공을 깨지 않았는지 확인.
# 사용: script/site_smoke.sh [base_url] <feed_baseline_dir>
# 기준 폴더는 검증할 배포에 포함된 appcast.xml과 pricing_supplement.json 사본.
set -euo pipefail
BASE="${1:-https://openusage.chanhyung.kim}"
BASELINE_DIR="${2:-}"
CURL=(curl -sS --max-time 20)
fail=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

mkdir "$tmpdir/expected"
for f in appcast.xml pricing_supplement.json; do
  if [ -z "$BASELINE_DIR" ] || [ ! -s "$BASELINE_DIR/$f" ]; then
    echo "FAIL deployment baseline: supply a directory containing both deployed feeds as the second argument"
    exit 1
  fi
  cp "$BASELINE_DIR/$f" "$tmpdir/expected/$f"
done

check() {  # $1 label, $2 path, $3 expected status, $4 content-type substring, $5 body regex(optional)
  local url="$BASE$2" out="${6:-$tmpdir/body}" resp code ctype
  # curl -w 출력은 개행이 없으므로 read 대신 변수 분리(read는 EOF에서 1을 반환해 set -e에 걸림).
  resp="$("${CURL[@]}" -o "$out" -w '%{http_code} %{content_type}' "$url")" || resp="000 -"
  code="${resp%% *}"
  ctype="${resp#* }"
  if [ "$code" != "$3" ]; then echo "FAIL $1: $url -> HTTP $code (want $3)"; fail=1; return; fi
  if [[ "$ctype" != *"$4"* ]]; then echo "FAIL $1: content-type '$ctype' (want *$4*)"; fail=1; return; fi
  if [ -n "${5:-}" ] && ! grep -Eq "$5" "$out"; then echo "FAIL $1: body lacks /$5/"; fail=1; return; fi
  echo "ok   $1: HTTP $code $ctype"
}

check "landing"  "/"                           200 "text/html"        "<title>"
check "404 file" "/404.html"                   200 "text/html"        'data-page="404"'
check "404 page" "/definitely-missing-$RANDOM" 404 "text/html"        'data-page="404"'
check "robots"   "/robots.txt"                 200 "text/plain"       "Sitemap:"
check "sitemap"  "/sitemap.xml"                200 "xml"              "<urlset"
check "appcast"  "/appcast.xml"                200 "xml"              "sparkle:edSignature" "$tmpdir/appcast.xml"
check "pricing"  "/pricing_supplement.json"    200 "application/json" '"pricing"' "$tmpdir/pricing_supplement.json"

"${CURL[@]}" "$BASE/" -o "$tmpdir/index.html"

# og:image가 실제로 서빙되는지(절대 URL의 경로만 BASE에 붙여 확인).
ogpath="$(python3 -c 'import re,sys,urllib.parse as u; m=re.search(r"property=\"og:image\" content=\"([^\"]+)\"", open(sys.argv[1], encoding="utf-8").read()); print(u.urlparse(m.group(1)).path if m else "")' "$tmpdir/index.html")"
if [ -n "$ogpath" ]; then check "og:image" "$ogpath" 200 "image/"; else echo "FAIL og:image meta missing"; fail=1; fi

# 검사 도중 바뀔 수 있는 원격 브랜치 대신 해당 배포의 사본과 바이트 단위 대조.
for f in appcast.xml pricing_supplement.json; do
  if cmp -s "$tmpdir/$f" "$tmpdir/expected/$f"; then
    echo "ok   $f matches deployment baseline"
  else
    echo "FAIL $f differs from deployment baseline (retry after deployment and cache propagation)"
    fail=1
  fi
done

# appcast item 수와 app.ts와 같은 규칙으로 고른 latest.
python3 - "$tmpdir/appcast.xml" "$tmpdir/expected/appcast.xml" <<'PY' || fail=1
# 입력은 이 사이트의 자체 feed(외부 entity 없음)라 stdlib parser로 충분.
import posixpath, re, sys, xml.etree.ElementTree as ET
from email.utils import parsedate_to_datetime
from urllib.parse import urlsplit, urlunsplit
NS = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
PREFIX = "https://github.com/kimchanhyung98/openusage/releases/download/"
root = ET.parse(sys.argv[1]).getroot()
items = root.findall(".//item")
want = len(ET.parse(sys.argv[2]).getroot().findall(".//item"))
source = "deployment baseline"
if len(items) < want:
    sys.exit(f"FAIL appcast has {len(items)} items, fewer than {source} ({want})")
stable = []
for it in items:
    ch = (it.findtext(NS + "channel") or "").strip()
    short = (it.findtext(NS + "shortVersionString") or "").strip()
    enc = it.find("enclosure")
    url = enc.get("url", "") if enc is not None else ""
    try:
        build = int(it.findtext(NS + "version") or "")
    except ValueError:
        continue
    try:
        pub = parsedate_to_datetime(it.findtext("pubDate") or "").timestamp()
    except Exception:
        pub = 0
    parts = urlsplit(url.replace("\\", "/"))
    normalized_path = posixpath.normpath(re.sub(r"%2e", ".", parts.path, flags=re.I))
    normalized = urlunsplit(parts._replace(path=normalized_path))
    if ch == "" and re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", short) and 0 < build <= 9007199254740991 and url.startswith(PREFIX) and normalized.startswith(PREFIX):
        stable.append((build, pub, short, url))
if not stable:
    sys.exit("FAIL appcast has no stable item")
build, _, short, url = max(stable, key=lambda item: item[:2])
print(f"ok   appcast items: {len(items)} (>= {want} from {source}), stable {len(stable)}")
print(f"ok   latest by sparkle:version: {short} (build {build}) -> {url}")
PY

# index.html의 로컬 자산과 외부 GitHub 링크가 모두 응답하는지.
while IFS= read -r asset; do
  code="$("${CURL[@]}" -o /dev/null -w '%{http_code}' "$BASE$asset" || echo 000)"
  if [ "$code" = "200" ]; then echo "ok   asset $asset"; else echo "FAIL asset $asset -> $code"; fail=1; fi
done < <(grep -oE '(src|href)="/[^"]+"' "$tmpdir/index.html" | sed -E 's/^[a-z]+="//; s/"$//' | sort -u)
while IFS= read -r link; do
  code="$("${CURL[@]}" -L -o /dev/null -w '%{http_code}' "$link" || echo 000)"
  if [ "$code" = "200" ]; then echo "ok   link $link"; else echo "FAIL link $link -> $code"; fail=1; fi
done < <(grep -oE 'href="https://github\.com/[^"]+"' "$tmpdir/index.html" | sed -E 's/^href="//; s/"$//' | sort -u)

# http → https 301(라이브에서만).
if [[ "$BASE" == https://* ]]; then
  code="$("${CURL[@]}" -o /dev/null -w '%{http_code}' "${BASE/https:/http:}/" || echo 000)"
  if [ "$code" = "301" ]; then echo "ok   http redirect 301"; else echo "FAIL http redirect -> $code"; fail=1; fi
fi

exit "$fail"
