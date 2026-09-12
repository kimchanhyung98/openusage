// 사이트 전역 상수. 브랜드 이름은 여기 한 곳에서만 관리.
const repo = 'https://github.com/kimchanhyung98/openusage';

export const site = {
  brand: 'OpenUsage',
  url: 'https://openusage.chanhyung.kim',
  repo,
  githubProfile: 'https://git.chanhyung.kim',
  linkedin: 'https://linkedin.chanhyung.kim/',
  upstream: 'https://github.com/robinebers/openusage',
  releasesLatest: `${repo}/releases/latest`,
} as const;
