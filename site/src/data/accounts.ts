export interface DemoAccount {
  id: string;
  name: string;
  status: 'Ready' | 'Sign-In Needed';
}

export interface DemoAccountFamily {
  id: string;
  name: string;
  activeAccount: string;
  profiles: DemoAccount[];
}

// 공개 문서와 같은 예시 이름 사용. 실제 로컬 계정 정보는 읽지 않음.
export const accountFamilies: DemoAccountFamily[] = [
  {
    id: 'claude', name: 'Claude', activeAccount: 'account-1',
    profiles: [
      { id: 'account-1', name: 'Account 1', status: 'Ready' },
      { id: 'account-2', name: 'Account 2', status: 'Ready' },
    ],
  },
  {
    id: 'codex', name: 'Codex', activeAccount: 'account-1',
    profiles: [
      { id: 'account-1', name: 'Account 1', status: 'Ready' },
      { id: 'account-2', name: 'Account 2', status: 'Ready' },
    ],
  },
];
