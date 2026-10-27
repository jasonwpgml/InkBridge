# InkBridge 서재 서버 (옛 이름 Pencil Review) — 설계 (2026-10-26)

맥에서 만드는 HTML을 iPad Safari에서 보고 Apple Pencil로 필기한다. 필기는 맥 파일로 저장하고, 맥에서 겹쳐 보고, Claude가 읽어 수정에 반영한다. 화면 영상은 보내지 않는다.

원문 계획은 허브 메모 `inkbridge-html-review-plan-20261026`, 검토 의견은 `inkbridge-claude-handoff`에 있다. 이 문서는 검토에서 지적한 문제를 반영해 바꾼 결정만 적는다. 기존 Sidecar용 InkBridge(AppKit)와 Mac+iPad 네이티브 앱과는 별개이며 파일 형식도 호환되지 않는다.

## 1차 범위

- 단일 사용자, 같은 로컬 네트워크, 자유 필기. 협업·OCR·인터넷 공개·텍스트 선택형 주석은 제외.
- 지원 페이지: 서버 폴더 안의 정적 HTML. 일반 문서 흐름(스크롤되는 본문)만 좌표를 보장한다.
- 미지원으로 명시: fixed/sticky 요소 위 필기, 내부 스크롤 영역, CSS transform으로 움직이는 내용, iframe 내부, SPA·프레임워크 개발 서버, CSP로 외부 스크립트를 막는 페이지, `<base href>`가 다른 출처를 가리키는 페이지. 이런 위치에도 그려지기는 하지만 문서 좌표로 저장되므로 다시 보면 어긋날 수 있다.

## 검토 지적 → 바꾼 결정

| # | 지적 | 결정 |
|---|---|---|
| 1 | `body { width }`로는 viewport·미디어 쿼리·`vw`·`innerWidth`가 재현되지 않음 | 리뷰를 **viewport(너비×높이)별로 분리**한다. 맥에서는 **그 크기의 iframe 뷰어**로 본다. iframe 안이 별도 viewport이므로 미디어 쿼리·`vw`·`vh`가 같은 값으로 계산된다. 창이 좁으면 iframe을 CSS `transform`으로 축소해 보여 주며 레이아웃은 바뀌지 않는다. `viewportWidth`를 덮어쓰지 않는다. 회전·Split View로 크기가 바뀌면 다른 리뷰로 전환한다. 같은 크기여도 폰트·브라우저 엔진·`hover`/`pointer` 미디어 쿼리·동적 콘텐츠 차이는 남는다. |
| 2 | HTTP LAN 주소는 secure context가 아니라 서비스 워커 불가 | 1차는 **서비스 워커를 쓰지 않는다.** 보장 범위는 "이미 열린 페이지에서 끊긴 동안 쓴 필기를 IndexedDB에 보관했다가 복귀 후 전송"이다. 끊긴 상태의 새로고침·재실행은 보장하지 않는다(iPad가 신뢰하는 인증서로 HTTPS를 준비한 뒤 별도 단계). `--cert/--key` 옵션은 두되 실기 검증 전에는 지원으로 적지 않는다. `getCoalescedEvents`는 기능 탐지 후 사용한다. |
| 2-b | 저장소는 origin 단위 | 서버가 **기본 주소 하나(`<호스트>.local:포트`)**를 권장 주소로 출력하고, IP 주소는 "다른 주소로 열면 미전송 필기가 공유되지 않음" 경고와 함께 출력한다. 툴바에 미전송 개수를 항상 표시하고, 미전송이 있으면 페이지를 떠날 때 경고한다. |
| 3 | 전체 PUT + 실패 시 localStorage는 유실·덮어쓰기 위험 | 전체 덮어쓰기 API를 없앤다. 필기는 **불변 획 + 작업(op) 로그**: `add`(획 추가)와 `erase`(획 ID 삭제)만 있다. 클라이언트는 op를 **IndexedDB에 먼저 기록**한 뒤 순서대로 전송하고, 서버 ACK를 받은 뒤에만 지운다. 서버는 op ID로 중복을 버리고(재시도 안전), 지운 획 ID를 묘비로 남겨 늦게 도착한 같은 획 추가를 무시한다. 리뷰별 직렬 처리, 리비전 번호 증가, 임시 파일 + `fsync` + `rename`으로 원자적 저장. 오래된 전체 데이터가 새 필기를 덮어쓰는 경로 자체가 없다. "전체 지우기"는 클라이언트가 아는 획 ID의 `erase`다. 실행 취소/다시 실행도 `erase`와 새 ID의 `add`로 표현한다. |
| 3-b | reload가 저장 전에 일어날 수 있음 | 파일 변경 신호를 받아도 **펜이 내려가 있거나, IndexedDB 기록이 끝나지 않았거나, 마지막 입력 후 0.8초가 지나지 않았으면 보류**한다. 새로고침 전 스크롤 위치를 sessionStorage에 남기고 복원한다. "1초 안에 새로고침"은 유휴 상태에서만의 목표다. |
| 3-c | SSE 재연결 ≠ 누락 복구 | SSE가 열릴 때마다(재연결 포함) 현재 리뷰를 다시 조회하고 대기열을 다시 보낸다. |
| 4 | 입력 실험이 가장 먼저 | `/__pen-test`를 첫 단계에 둔다. Pointer/Touch 이벤트 순서·취소·중복, `touchType`, 필압, coalesced 개수, 이벤트 빈도, 링크·버튼 위 필기 시 click 발생 여부, 손바닥 스크롤, 확대 후 좌표를 기록하고 결과를 서버에 JSON으로 저장한다. 오버레이 입력 방식은 이 결과로 확정한다. |
| 4-b | `pointer-events:none` 캔버스 밑의 링크가 눌림 | 입력은 window **캡처 단계**에서 받는다. 펜(`pointerType==='pen'`, `touchType==='stylus'`)이면 `touchstart/touchmove`를 non-passive로 `preventDefault`, pointer 이벤트는 `stopPropagation`, 획 직후의 `click`·`mousedown`·`contextmenu`를 캡처 단계에서 삼킨다. 툴바 안의 입력은 제외. 펜이 닿아 있는 동안 손가락 `touchmove`도 막아 손바닥 스크롤을 줄인다. 이 조합이 실제로 충분한지는 `/__pen-test` 실기 결과로 판정한다. |
| 4-c | 좌표 보정 이중 적용 위험 | 좌표는 문서 CSS px인 `clientX + scrollX`(정의상 `pageX`와 같음)를 쓴다. `visualViewport.scale`을 곱하거나 나누지 않는다. 확대 상태 좌표가 맞는지는 `/__pen-test`가 `client/page/visualViewport` 값을 함께 기록해 확인한다. |
| 4-d | Sidecar 더블탭/스퀴즈가 DOM에 온다는 근거 없음 | 맥 브라우저에서는 **그리기 모드 토글**을 기본으로 둔다. 켜면 마우스/펜 드래그가 필기, 끄면 평소 조작. 펜 구분·필압은 `/__pen-test` 결과가 나오면 추가한다. |
| 5 | 레이아웃이 바뀌면 좌표 필기가 다른 문장을 가리킴 | 리뷰 = **(페이지, 콘텐츠 버전, viewport)**. 콘텐츠 버전은 HTML과 HTML·CSS가 참조하는 같은 폴더 자원의 해시다. 서버는 HTML을 내보낼 때 그 버전의 **스냅숏**(HTML+참조 자원)을 저장한다. HTML이 바뀌면 새 버전의 새 리뷰가 되고, 이전 리뷰는 그 버전의 스냅숏 위에서 그대로 열린다. 스키마 버전, 리뷰 ID, 생성/수정 시각, 기기 정보를 남긴다. |
| 5-b | AI용 내보내기가 1차 완료 조건 | 획마다 **그릴 당시의 DOM 정보**(획 아래 요소의 선택자, 텍스트 일부, 문서 좌표 영역, 커서 위치 주변 문장)를 클라이언트가 함께 저장한다. 나중에 최신 페이지를 다시 렌더링해 추정하지 않는다. 내보내기는 `review.json`·`strokes.svg`·`REVIEW.md`(Claude가 읽는 요약)를 쓴다. PNG는 Playwright가 있으면 **해당 리뷰의 스냅숏**을 같은 viewport로 열어 찍는다. Chromium과 iPad Safari의 렌더링 차이가 있으므로 이미지에 그 사실을 기록한다. |

## 동적 페이지 (2026-10-26 추가)

- 획마다 그릴 때의 `location.hash`를 `state`로 저장하고, 현재 hash와 같은 획만 그린다. 단계·탭 상태를 hash에 두는 페이지에서 다른 단계 화면에 필기가 겹치지 않는다. hash 밖의 상태(슬라이더 값, 애니메이션 진행)는 구분하지 않는다.
- 펜이 버튼·링크·summary·label·입력 위에서 350ms 안에 6px 이내로 떼어지면 필기 대신 누름으로 처리한다(터치 기본 동작을 막았으므로 `click()`/`focus()`를 대신 호출). `input[type=range]`는 펜 입력을 가로채지 않는다.

## 실시간 전송 (2026-10-26 추가)

- 그리는 중인 점: 펜이 닿아 있는 동안 새 점을 최대 33ms마다 `POST /__pr/api/reviews/<id>/live`로 보낸다(한 번에 요청 하나, 응답이 오면 다음 묶음). 서버는 저장하지 않고 SSE `live`로 중계한다. 받는 쪽은 `from` 위치가 이어지는 점만 덧그리고, 펜을 떼면 `done`, 필기가 아닌 탭이면 `cancel`을 보낸다. 5초 동안 갱신이 없으면 미리보기를 버린다. 미리보기 전송 실패는 무시한다. 획 자체는 기존 IndexedDB 대기열로 저장된다.
- 변경분: 서버의 `review` 이벤트가 그 리비전에서 추가된 획 전체와 지워진 획 ID를 함께 보낸다. 받는 쪽은 리비전이 정확히 1 늘어날 때만 적용하고, 건너뛰었거나 연결이 다시 열리면 전체를 다시 받는다. 클라이언트의 리비전은 POST 응답이 아니라 이 이벤트로만 올린다(서버 획 목록과 리비전이 따로 놀지 않게).
- 같은 페이지·버전·viewport를 연 다른 기기는 아직 리뷰가 없어도 처음 받은 `live`·`review` 이벤트로 그 리뷰를 따라간다.

## 변환 문서는 쪽 좌표 (2026-10-27 추가)

- PDF·PowerPoint·Word를 변환한 쪽 문서(`converted/…/index.html`, 1600px 쪽 이미지)는 화면 좌표 대신 **쪽 이미지 픽셀 좌표**로 필기를 저장한다. 글자 배치가 화면 크기에 따라 바뀌지 않으므로, 1번 결정(viewport별 리뷰)이 필요 없다.
- 그런 리뷰의 viewport는 `1600×1600`(`PAGE_SPACE`)으로 고정한다. 그래서 iPad 가로·세로, 맥 브라우저, Sidecar가 모두 **같은 리뷰**를 열고 같은 필기를 실시간으로 보고 고친다. 회전해도 리뷰를 바꾸지 않는다.
- 굵기도 쪽 픽셀로 저장해 쪽과 함께 커지고 작아진다(종이처럼). 지우개 반경·탭 판정은 화면 px 기준으로 환산한다. 쪽 이미지 위에는 요소·글자가 없으므로 DOM 앵커는 남기지 않는다.
- 이전에 화면 좌표로 쓴 리뷰는 그대로 둔다. 맥 뷰어와 PDF 내보내기는 두 형식을 모두 읽지만, 문서를 열었을 때 이어 쓰는 리뷰는 쪽 좌표 리뷰다.
- 획 굵기 상한은 60 → 200(쪽 픽셀에서는 작은 화면의 굵은 형광펜이 60을 넘는다).

## 추가 보완

- **캔버스 메모리**: 문서 전체 크기 캔버스를 만들지 않는다. 화면 높이의 2배(위·아래 0.5배 여유) 캔버스를 문서 좌표 위치에 놓고, 스크롤로 범위를 벗어나면 옮겨서 그 범위에 걸치는 획만 다시 그린다. 1180×820 viewport, DPR 2 기준 약 2360×3280×4B ≈ 31MB.
- **인증**: 서버 시작 시 토큰(`.pencil-review/token`, 재시작해도 유지, `--new-token`으로 교체). 첫 URL의 `?t=`를 확인하면 HttpOnly·SameSite=Lax 쿠키를 주고(Strict면 QR·북마크 앱에서 처음 열 때 쿠키가 빠짐) 토큰 없는 주소로 리다이렉트한다. 이후 HTML·정적 자원·SSE·API·내보내기 모두 쿠키를 검사한다. 쿠키도 origin(호스트명) 단위라 주소를 바꾸면 토큰 URL로 다시 들어가야 한다. HTML·오버레이는 `no-store`.
- **경로 검사**: URL 디코딩 실패·NUL 거부, 정규화 후 루트 밖 거부, `realpath`로 symlink 이탈 거부, 점(`.`)으로 시작하는 경로 조각(`.git`, `.env`, `.pencil-review`)은 정적 제공하지 않는다. 필기 데이터는 API로만 제공한다.
- **감시**: `fs.watch` 재귀 + 100ms 디바운스. 점 경로, `node_modules`, 서버 데이터 폴더는 제외. 웹 자원 확장자만 reload 대상.
- **주입**: `</body>` 마지막 위치 앞(없으면 끝)에 `<script src="/__pr/overlay.js" data-...>`. CSP meta·`<base>`가 있으면 서버 로그에 경고.
- **QR**: 의존성을 늘리지 않고 1차는 URL 출력만. Playwright는 PNG 내보내기에만 쓰는 선택 의존성.
- **수치 주장**: Sidecar 대비 배수, "맥 부담 거의 0", "무선 지연 없음", "네이티브 수준 필기감"은 측정 전에는 쓰지 않는다. 측정 시 브라우저·OS 버전을 기록한다. 원문의 네트워크 출처 [1]~[7]은 URL이 없어 확인하지 못했으므로 오프라인 연결 방법은 실험 항목으로만 둔다.

## 저장 형식

`<작업 폴더>/.pencil-review/`

```
token                       접속 토큰
reviews/<reviewId>.json     리뷰 (아래)
snapshots/<version>/...     콘텐츠 버전별 HTML·자원 사본 + manifest.json
exports/<reviewId>/         review.json, strokes.svg, REVIEW.md, page.png(선택)
pen-tests/<시각>.json        /__pen-test 결과
```

```json
{
  "schema": 1,
  "id": "r_…",
  "page": "index.html",
  "contentVersion": "3f2a…",
  "viewport": { "width": 1180, "height": 820 },
  "createdAt": "…", "updatedAt": "…",
  "revision": 12,
  "device": "iPad Safari …",
  "strokes": [
    { "id": "s_…", "tool": "pen", "color": "#e5484d", "width": 2.5,
      "points": [[x, y, pressure], …], "createdAt": "…",
      "anchors": [{ "selector": "main > p:nth-of-type(3)", "text": "…", "rect": [x, y, w, h] }],
      "context": "커서 위치 주변 문장" }
  ],
  "erased": ["s_…"]
}
```

viewport 높이는 Safari 주소창 접힘에 따라 바뀌는 `innerHeight` 대신 `100lvh` 측정값(미지원이면 `100vh`)을 쓴다. iPad Safari의 `vh`는 큰 viewport 기준이라 이 값이 미디어 쿼리·`vh` 계산과 일치한다.

## API

| 경로 | 메서드 | 역할 |
|---|---|---|
| `/<파일>` | GET | 정적 파일. HTML이면 스냅숏 저장 + 오버레이 주입 |
| `/__pr/events` | GET | SSE. `reload {path}`, `review {id, revision}` |
| `/__pr/api/reviews?page=&version=&w=&h=` | GET | 조건에 맞는 리뷰 목록 |
| `/__pr/api/reviews/<id>` | GET | 리뷰 전체(묘비 제외 획) |
| `/__pr/api/reviews/<id>/ops` | POST | `{meta, ops:[…]}` 적용. 리뷰가 없으면 meta로 생성. `{revision, applied}` 반환 |
| `/__pr/api/reviews/<id>/export` | POST | 내보내기 파일 생성 |
| `/__pr/api/pen-tests` | POST | 입력 실험 결과 저장 |
| `/__pr/view?review=<id>` | GET | 맥용 고정 viewport iframe 뷰어 |
| `/__pr/snap/<version>/<경로>` | GET | 스냅숏 제공(없는 자원은 현재 파일로 대체) |
| `/__pr/pen-test`, `/__pen-test` | GET | 입력 실험 페이지 |

## 단계

1. 서버(인증·경로·주입·SSE·스냅숏·op 저장) + `/__pen-test` + 오버레이 기본 필기 + 고정 viewport 뷰어 + 내보내기(JSON·SVG·MD). ← 이번 구현
2. iPad 실기: `/__pen-test` 결과로 입력 방식 확정, 빠른 필기 중 저장·연결 끊김·서버 재시작 유실 검사.
3. Playwright PNG를 실제 iPad 화면 캡처와 비교, 미디어 쿼리 예제로 위치 검증.
4. Sidecar 브라우저 입력, 신뢰 인증서 HTTPS와 오프라인 재실행.
