// @ts-check
import { defineConfig } from 'astro/config';

// 정적 출력 전용. 배포 시 gh-pages의 feed 파일을 보존하는 별도 조립 필요.
export default defineConfig({
  site: 'https://openusage.chanhyung.kim',
  trailingSlash: 'ignore',
  // 기존 인라인 요소 사이 공백 유지.
  compressHTML: true,
  build: {
    // meta CSP가 인라인 style을 막으므로 모든 CSS를 외부 파일로 출력.
    inlineStylesheets: 'never',
  },
  vite: {
    // 작은 script도 인라인하지 않고 _astro/ 해시 파일로 출력(CSP script-src 'self').
    build: { assetsInlineLimit: 0 },
  },
  // 코드 블록은 <pre><code> 직접 작성. Shiki 인라인 style 경고 제거.
  markdown: { syntaxHighlight: false },
  security: {
    // Astro가 번들 자산 해시를 넣은 meta CSP를 생성. 외부 출처 없음.
    csp: {
      directives: [
        "default-src 'self'",
        "img-src 'self'",
        "font-src 'self'",
        "connect-src 'self'",
        "object-src 'none'",
        "base-uri 'self'",
        "form-action 'none'",
      ],
    },
  },
});
