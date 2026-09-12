// 랜딩페이지 카피와 기능 탭 문구.
import { site } from './site';

const brand = site.brand;

export const copy = {
  'nav-github': 'GitHub',
  'nav-cta': 'Download',

  'hero-title': 'AI 사용량을 한눈에 확인하세요.',

  's00-label': '지원 서비스',

  's02-label': '주요 기능',

  's03-label': '다운로드',
  's03-req': 'macOS 15 이상 · Apple Silicon 및 Intel',
  's03-cta': 'Download',

  'footer-copyright': '© 2026 kimchanhyung98',
  // 푸터 포크 고지는 문장 안에 링크가 들어가 문자열 하나로 담기지 않으므로 Footer.astro가 직접 씀.

  'meta-title': `${brand} — Mac에서 한눈에 보는 AI 사용량`,
  'meta-desc': 'AI 서비스 사용량과 남은 한도, 리셋 시간을 한곳에서 확인하는 무료 오픈소스 Mac 앱.',

  '404-h': '여기에는 아무것도 없습니다.',
  '404-link': '첫 페이지로',

  // 버전 표시는 런타임에만 필요해 app.ts가 직접 조립. 여기 두면 클라이언트 번들에 copy 전체가 딸려 옴.
} as const;

export interface Tab {
  id: 'menu-bar' | 'dashboard' | 'statistics' | 'accounts' | 'integrations';
  name: string;
  description: [string, string];
  /** 그래픽의 접근성 이름. 내용은 읽히므로 무엇인지만 요약. */
  visualLabel: string;
}

export const tabs: Tab[] = [
  {
    id: 'menu-bar',
    name: '메뉴 막대',
    description: ['작업 중에도 AI 사용량을', '바로 확인하세요.'],
    visualLabel: '맥북의 메뉴 막대로 확대해 AI 사용량을 확인하는 예시',
  },
  {
    id: 'dashboard',
    name: '대시보드',
    description: ['사용량과 초기화 시간을', '서비스별로 확인하세요.'],
    visualLabel: '메뉴 막대를 클릭해 사용량 대시보드를 여는 예시',
  },
  {
    id: 'statistics',
    name: '사용량 통계',
    description: ['비용과 토큰 사용량을', '기간별로 확인하세요.'],
    visualLabel: '같은 대시보드 상단의 비용·토큰 사용량 통계 강조',
  },
  {
    id: 'accounts',
    name: '계정',
    description: ['여러 계정을 등록하고', '필요한 계정으로 전환하세요.'],
    visualLabel: '설정의 빈 계정 목록에 Account 1을 추가하는 예시',
  },
  {
    id: 'integrations',
    name: '연동',
    description: ['CLI와 로컬 API로', '사용량을 도구와 연결하세요.'],
    visualLabel: 'openusage 명령의 JSON 출력 예시와 curl 명령',
  },
];
