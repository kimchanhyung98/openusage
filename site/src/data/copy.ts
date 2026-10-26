// 랜딩페이지 카피와 기능 탭 문구.
import { site } from './site';

const brand = site.brand;

export const copy = {
  'nav-github': 'GitHub',
  'nav-cta': 'Download',

  'hero-title': 'AI 사용량을 한눈에 확인하세요.',
  'hero-eyebrow': 'Mac 메뉴 막대 속 AI 사용량',
  'hero-description': '남은 한도부터 비용, 토큰, 초기화 예측까지. 여러 서비스와 계정을 한곳에서 확인하세요.',
  'hero-features': '기능 둘러보기',
  'hero-languages': '한국어 · English · 日本語',
  'hero-preview': '직접 눌러보는 앱 미리보기 · 예시 데이터',

  's00-label': '지원 서비스',

  's02-label': '주요 기능',

  's03-label': '다운로드',
  's03-req': 'macOS 15 이상 · Apple Silicon 및 Intel',
  's03-cta': 'Download',

  'footer-copyright': '© 2026 kimchanhyung98',
  // 푸터 포크 고지는 문장 안에 링크가 들어가 문자열 하나로 담기지 않으므로 Footer.astro가 직접 씀.

  'meta-title': `${brand} — Mac에서 한눈에 보는 AI 사용량`,
  'meta-desc': '12개 AI 서비스의 사용량, 비용, 여러 계정과 Codex 초기화 예측을 Mac 메뉴 막대에서 확인. 한국어·영어·일본어를 지원하는 무료 오픈소스 앱.',

  '404-h': '여기에는 아무것도 없습니다.',
  '404-link': '첫 페이지로',

  // 버전 표시는 런타임에만 필요해 app.ts가 직접 조립. 여기 두면 클라이언트 번들에 copy 전체가 딸려 옴.
} as const;

export interface Tab {
  id: 'menu-bar' | 'dashboard' | 'statistics' | 'reset-watch' | 'soft-limit' | 'accounts' | 'integrations';
  name: string;
  description: [string, string];
  /** 그래픽의 접근성 이름. 내용은 읽히므로 무엇인지만 요약. */
  visualLabel: string;
  note?: string;
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
    note: '오늘·어제·30일 통계와 백만 토큰당 비용 비교. iCloud로 여러 Mac의 사용 이력 합산.',
  },
  {
    id: 'reset-watch',
    name: '초기화 예측',
    description: ['Codex 초기화 예측과', '사용 가능한 리셋을 한눈에.'],
    visualLabel: 'Codex Reset Watch의 예측 확률·커뮤니티 투표율과 남은 초기화권 개수 예시',
    note: 'Reset Watch는 비공식 공개 예측. 개인 한도 초기화를 보장하지 않으며, 새 예측 알림은 설정에서 선택.',
  },
  {
    id: 'soft-limit',
    name: '한도 안내선',
    description: ['내가 정한 사용 한도를', '막대 위 안내선으로 확인하세요.'],
    visualLabel: '주간 사용량 막대의 90% Soft Limit 안내선 예시',
    note: '5시간·주간 중 선택하고 1–100%로 설정. 현재 자동 작업 취소는 지원하지 않음.',
  },
  {
    id: 'accounts',
    name: '계정',
    description: ['여러 계정을 등록하고', '필요한 계정으로 전환하세요.'],
    visualLabel: '설정의 빈 계정 목록에 Account 1을 추가하는 예시',
    note: 'Claude·Codex 계정을 한 카드 또는 개별 카드로 표시. 대시보드의 계정 선택은 조회용이며, 실제 전환은 설정이나 우클릭 메뉴에서 확인 후 실행.',
  },
  {
    id: 'integrations',
    name: '연동',
    description: ['CLI와 로컬 API로', '사용량을 도구와 연결하세요.'],
    visualLabel: 'openusage 명령의 JSON 출력 예시와 curl 명령',
  },
];
