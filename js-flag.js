// 첫 페인트 전에 html.js를 켜 리빌 초기 상태를 적용. 인라인 금지(meta CSP)라 외부 파일.
// app.ts가 끝내 실행되지 않으면(_astro 자산 차단·네트워크 실패) 리빌이 opacity 0에 갇히므로
// 짧은 안전장치를 두어 .js를 되돌림. app.ts는 초기화 성공 시 data-ready를 세움.
document.documentElement.classList.add('js');
setTimeout(function () {
  if (document.documentElement.dataset.ready !== '1') {
    document.documentElement.classList.remove('js');
  }
}, 3000);
