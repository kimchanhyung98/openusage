#!/usr/bin/env bash
# 랜딩 사이트 조립 — Astro 빌드 후 feed 이름 충돌·placeholder·금지 문자열 단언.
# 사용: script/site_assemble.sh [outdir] [stamp]
#   outdir 기본값 .build/site-preview(gitignore). 빈 경로 또는 이전 조립 결과만 교체.
#   WITH_FEED=1 이면 단언이 끝난 뒤 라이브 feed 2개를 outdir에 복사(로컬 미리보기 전용).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/.build/site-preview}"
STAMP="${2:-$(git -C "$ROOT" rev-parse --short=8 HEAD 2>/dev/null || echo local)}"
DATE="$(date -u +%Y-%m-%d)"
FEED_NAMES=(appcast.xml pricing_supplement.json CNAME .nojekyll)
# v0.11.0에서 Reset Watch·Tokscale이 출시되어 금지 목록에서 뺌. 미출시 기능이 생기면 다시 추가.
FORBIDDEN='official|brew|Homebrew|openusage\.ai|robinebers|truly yours|beautiful|no telemetry|never leaves|App Store'

# 0. 경로 별칭을 해소한 뒤 소스·상위 폴더·무관한 기존 작업 보호.
DEST="$(python3 - "$ROOT" "$OUT" <<'PY'
from pathlib import Path
import sys
root, requested = Path(sys.argv[1]).resolve(), Path(sys.argv[2])
out, home = requested.resolve(), Path.home().resolve()
if requested.is_symlink() or out in (root, home) or out in root.parents or out in home.parents:
    sys.exit(f"error: refusing unsafe outdir: {requested}")
if root in out.parents and not (root / ".build") in out.parents:
    sys.exit(f"error: outdir inside the checkout must be below .build/: {out}")
if out.exists():
    if not out.is_dir() or (out / ".git").exists():
        sys.exit(f"error: outdir is not a preview directory: {out}")
    marker = out / ".openusage-site-output"
    owned = marker.is_file() and not marker.is_symlink() and marker.read_text() == "1\n"
    if any(out.iterdir()) and not owned:
        sys.exit(f"error: refusing to replace a nonempty directory not created by site_assemble.sh: {out}")
print(out)
PY
)"

# 1. 입력 단언: site/public에 feed 이름이 있으면 overlay가 feed를 덮어씀.
for f in "${FEED_NAMES[@]}"; do
  if [ -e "$ROOT/site/public/$f" ]; then
    echo "error: site/public/$f must not exist (feed name collision)" >&2
    exit 1
  fi
done

# 2. 기존 미리보기를 유지한 채 같은 파일시스템의 임시 경로에서 조립·검증.
mkdir -p "$(dirname "$DEST")"
OUT="$(mktemp -d "$DEST.staging.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
(cd "$ROOT/site" && npm run build)
cp -R "$ROOT/site/dist/." "$OUT"

# 3. 스탬프 치환(sitemap lastmod 등). 백업 파일 생성 금지, UTF-8 고정.
python3 - "$OUT" "$STAMP" "$DATE" <<'PY'
import pathlib, sys
out, stamp, date = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
for p in list(out.rglob("*.html")) + list(out.rglob("*.xml")):
    s = p.read_text(encoding="utf-8")
    t = s.replace("__BUILD__", stamp).replace("__DATE__", date)
    if t != s:
        p.write_text(t, encoding="utf-8")
PY

# 4. 출력 단언.
for f in "${FEED_NAMES[@]}"; do
  if [ -n "$(find "$OUT" -name "$f" -print -quit)" ]; then
    echo "error: $f must not be produced by the site build" >&2
    exit 1
  fi
done
for f in index.html 404.html robots.txt sitemap.xml js-flag.js; do
  [ -f "$OUT/$f" ] || { echo "error: $OUT/$f missing" >&2; exit 1; }
done
if [ -n "$(find "$OUT" -name '*.bak' -print -quit)" ]; then
  echo "error: backup files in output" >&2
  exit 1
fi
if grep -rl '__[A-Z]*__' "$OUT" --include='*.html' --include='*.xml' >/dev/null; then
  echo "error: unreplaced placeholder in output" >&2
  exit 1
fi
# 앱 아이콘 글리프는 상표 결정 전까지 페이지에 싣지 않음. 하위 경로의 페이지까지 검사.
if grep -rq 'id="pi-openusage"' "$OUT" --include='*.html'; then
  echo "error: openusage icon symbol must not ship before the trademark decision" >&2
  exit 1
fi

# 5. 금지 문자열(대소문자 무시, 모든 html): data-notice 요소(포크 고지)를 뺀 본문에서 0건.
#    고지 안에서는 업스트림 링크(repo, 선택적으로 TRADEMARK)만 허용하고 그 밖의 'robinebers' 언급 금지.
python3 - "$OUT" "$FORBIDDEN" <<'PY'
import pathlib, re, sys
out, pattern = pathlib.Path(sys.argv[1]), re.compile(sys.argv[2], re.I)
notice_re = re.compile(r"<p[^>]*\bdata-notice\b[^>]*>.*?</p>", re.S)
anchor_re = re.compile(r'<a[^>]+href="https://github\.com/robinebers/openusage(?:/blob/main/TRADEMARK\.md)?"[^>]*>.*?</a>', re.S)
# provider 로그인 안내는 앱 원문이며 사이트의 공식성 주장과 구분.
provider_sign_in_re = re.compile(r"\bofficial (?:Claude|Codex) sign-in\b")
# rglob — 하위 디렉터리에 페이지가 늘어도 검사에서 빠지지 않게.
for page in sorted(out.rglob("*.html")):
    html = page.read_text(encoding="utf-8")
    notices = notice_re.findall(html)
    body = provider_sign_in_re.sub("provider sign-in", notice_re.sub("", html))
    hits = sorted({m.group(0) for m in pattern.finditer(body)})
    if hits:
        sys.exit(f"error: {page.relative_to(out)}: forbidden strings outside the fork notice: {hits}")
    for n in notices:
        anchors = anchor_re.findall(n)
        if not 1 <= len(anchors) <= 2:
            sys.exit(f"error: {page.relative_to(out)}: fork notice must link the upstream repo once (optionally TRADEMARK too), got {len(anchors)}")
        if "robinebers" in anchor_re.sub("", n):
            sys.exit(f"error: {page.relative_to(out)}: 'robinebers' appears outside the two upstream links in the fork notice")
    print(f"ok   {page.relative_to(out)}: forbidden-string check ({len(notices)} notice)")
PY

# 6. 로컬 미리보기 전용: 라이브 feed 사본. 단언 뒤에 복사하므로 위 검사 대상이 아님.
if [ "${WITH_FEED:-0}" = "1" ]; then
  for f in appcast.xml pricing_supplement.json; do
    curl -sSf --max-time 20 "https://openusage.chanhyung.kim/$f" -o "$OUT/$f"
  done
  echo "copied live appcast.xml and pricing_supplement.json into $OUT (preview only)"
fi

# 7. 검증을 모두 통과한 결과만 교체. 교체 실패 시 이전 결과 복원.
python3 - "$OUT" "$DEST" <<'PY'
from pathlib import Path
import shutil, sys, tempfile
out, dest = Path(sys.argv[1]), Path(sys.argv[2])
(out / ".openusage-site-output").write_text("1\n")
previous = None
if dest.exists():
    previous = Path(tempfile.mkdtemp(prefix=f".{dest.name}.previous-", dir=dest.parent))
    previous.rmdir()
    dest.rename(previous)
try:
    out.rename(dest)
except BaseException:
    if previous is not None:
        previous.rename(dest)
    raise
if previous is not None:
    shutil.rmtree(previous)
PY

echo "assembled $DEST (build $STAMP, $DATE)"
