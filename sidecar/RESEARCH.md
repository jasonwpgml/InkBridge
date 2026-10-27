# MacBook + iPad 조사와 InkBridge 구현 근거

조사일: 2026-10-22. 아래 앱의 기능은 공식 문서 확인 결과이며, 서로의 지연·화질을 동일 조건에서 비교 측정한 결과는 아닙니다. 실제 기기 검증은 문서 마지막에 따로 구분했습니다.

## 사용 목적별 후보

| 구성 | 어떤 때 유용한가 | 비용·중요한 차이 |
|---|---|---|
| [Sidecar](https://support.apple.com/en-us/102597) | 아이패드를 맥의 확장/미러링 화면으로 쓰고 Pencil 입력 전달 | macOS/iPadOS 기본 기능. 지금 선택한 InkBridge 구성의 연결 수단 |
| [Universal Control](https://support.apple.com/en-au/102459) | iPad의 Goodnotes·Safari를 그대로 쓰면서 맥 키보드·트랙패드로 조작 | 기본 기능. 각 기기가 자기 앱을 실행하며, 화면 미러링과 용도가 다름 |
| [Presentify](https://presentifyapp.com/faq) | 웹페이지·앱 화면 위 강의 필기, 강조, 도형 | 유료 Mac 앱. Sidecar를 통한 iPad 필기를 공식 안내. Fn으로 아래 앱 조작, 전체 화면 공유 필요 |
| [ScreenBrush](https://apps.apple.com/kr/app/screenbrush/id1233965871?mt=12) | 무료로 화면 필기를 시험하고 그림을 저장 | 기본 무료, 일부 기능 앱 내 구입. 스냅샷과 PNG/PDF/PSD 내보내기. 도형·실행 취소 등은 Plus |
| [Astropad Studio](https://astropad.com/product/studio/) | 펜 작업의 압력 곡선·제스처·앱별 단축키를 세밀하게 조정 | Mac+iPad 앱 구성. 유료. 단순 강의 필기보다 정교한 그리기 환경을 원하는 경우 후보 |
| [Stream Deck Mobile](https://www.elgato.com/es/en/explorer/products/stream-deck/how-you-can-use-stream-deck-for-free/) | iPad를 앱 실행·음소거·녹화·장면 전환용 버튼판으로 사용 | Mac 프로그램+iPad 앱. 6개 키 무료, 확장은 유료. 기능은 해당 앱/플러그인 지원에 따름 |
| [Touch Portal](https://www.touch-portal.com/) | 버튼 하나에 여러 동작·조건·단축키를 묶는 개인 제어판 | Mac 호스트+iPad 앱. 기본 무료, Pro 확장. 직접 꾸미는 매크로 구성에 적합 |
| [Duet](https://www.duetdisplay.com/) | Mac 외 Windows·Android까지 화면 확장·원격 작업을 연결 | 유료 플랜에 따라 기능 차이. 같은 Apple 계정의 Mac+iPad만 쓰는 현재 환경에서는 Sidecar부터 확인할 만함 |
| [LocalSend](https://localsend.org/) | 여러 운영체제 사이 로컬 파일·텍스트 전송 | 무료 공개소스. Mac+iPad만 쓰면 AirDrop과 역할이 겹치며, 다른 OS가 추가될 때 유용 |

**추천 구성:** 평소에는 Sidecar 확장 또는 Universal Control 중 작업에 맞는 쪽을 쓰고, 강의는 Sidecar 미러링+InkBridge로 전환합니다. iPad에서 다른 iPad 앱으로 전환하면 Sidecar는 일시정지하므로, 같은 iPad에서 Sidecar 필기와 Stream Deck Mobile 버튼판을 항상 동시에 사용할 수 있다고 가정하지 않습니다. 이 동작은 [Apple 문서](https://support.apple.com/en-us/102597)에 명시되어 있습니다.

## 아이패드는 반드시 App Store 앱이어야 하는가?

아닙니다. ‘아이패드에서 실행’과 ‘네이티브 앱 설치’는 다른 선택입니다.

| 방식 | 설치·운영 | 개인 제작에 대한 판단 |
|---|---|---|
| Safari 웹앱/PWA | 웹페이지를 열고 ‘홈 화면에 추가 → 웹 앱으로 열기’ | 개발자 서명 없이 앱처럼 실행 가능. 개인 제어판·자료 뷰어의 빠른 시작에 적합 |
| 무료 Xcode Personal Team | Mac의 Xcode에서 본인 기기로 빌드·설치 | 프로비저닝이 발급 후 7일 만료. 다시 빌드·설치 필요. 기기당 앱 3개 제한 |
| 유료 개발자 계정 + TestFlight | 서명한 빌드를 업로드하고 TestFlight 앱으로 설치 | 개발자 프로그램은 미국 기준 연 $99. 빌드마다 최대 90일이어서 주기적 갱신 필요 |
| 등록 기기용 개발/Ad Hoc 배포 | 기기와 맞는 인증서·프로비저닝 프로필로 서명한 `.ipa`를 Xcode/Configurator 등으로 설치 | App Store 공개 없이 배포할 수 있지만, `.ipa` 파일을 보내기만 하면 설치되는 방식은 아님 |
| Mac 앱 + Sidecar | Mac에만 직접 만든 프로그램을 실행 | 이번에 사용자가 선택한 방식. iPad 자작 앱·개발자 계정 없이 Pencil을 사용할 수 있음 |

근거: [iPad 웹앱](https://support.apple.com/en-mide/guide/ipad/ipad8f1f7a29/ipados), [무료 개발자 계정 제한](https://developer.apple.com/help/account/basics/about-your-developer-account), [개발자 프로그램](https://developer.apple.com/programs), [TestFlight 기간](https://testflight.apple.com/), [등록 기기 배포](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices).

네이티브 앱은 PencilKit, 영상 디코딩, 기기 연동을 깊이 다룰 때 유리합니다. 웹앱을 단순 패키징해도 네이티브 Pencil 기능이나 iPadOS의 백그라운드 제약이 저절로 해결되지는 않습니다. 이번 목표는 Sidecar가 화면 전송과 입력을 맡으므로 이 배포 절차 자체를 생략할 수 있었습니다.

## 직접 화면 전송도 만든다면

[OpenDisplay 공식 저장소](https://github.com/peetzweg/opendisplay)와 [공식 사이트](https://opendisplay.app/)에는 Mac 송신기+iPad 수신기 형태의 공개 구현이 있습니다. USB/Wi-Fi로 확장 화면을 전달하는 구조를 연구할 후보입니다. 이번 구현에는 해당 코드를 가져오지 않았고, 최신 Pencil 기능·앱 배포 상태·비공개 API 의존성은 실제 도입 버전에서 다시 점검해야 합니다.

현재 필요에는 Mac 투명 필기판부터 만드는 편이 범위가 작습니다. 자체 전송으로 확장한다면 화면 캡처, 영상 압축, 전달, iPad 표시, 좌표 변환, 펜 입력 회신, 연결 복구를 추가해야 합니다. 별도로 측정한 지연이나 구현 완료 예상 시간을 제시하지 않았습니다.

## Presentify REA 조사

### 분석 대상

- Homebrew cask가 제공한 Presentify 8.1.4, 빌드 70.
- 설치하지 않고 `brew fetch --cask presentify`로 배포 DMG를 확보.
- DMG SHA-256: `58ebb945db724ada06160723b6a94ba4cec9f736c61061a91bf27a8ff181d878`.
- 실행 파일 SHA-256: `c2acae59c9fd6c1ac3d3beca73ba240a776ecaf47632632df9ab33588ec59344`.
- Mach-O universal, 분석한 슬라이스 arm64. 번들 ID `com.rampatra.presentify`.

### 관찰한 사실

1. REA 패키지 검사에서 256개 그래프 노드와 267개 항목 위치를 관찰했습니다. 이 수치는 앱 기능 개수가 아닙니다.
2. Info.plist에 `LSUIElement=true`, 메인 storyboard, 화면 확대를 위한 화면 캡처 권한 설명이 들어 있습니다.
3. Objective-C/Swift 메타데이터에 `AnnotatePanel`의 상위 클래스가 `NSPanel`로 기록되어 있습니다.
4. `AnnotateViewController`에서 `mouseDown:`, `mouseDragged:`, `mouseUp:`, `flagsChanged:` 메서드를 관찰했습니다.
5. 같은 클래스에서 `currentPath`, `currentShape`, `lineWeight`, `strokeColor`, `highlighter`, `drawMode` 같은 상태 필드를 관찰했습니다.
6. `ShortcutManager`, `AnnotateScreenListeners`, 커서 강조·확대·스포트라이트용 클래스가 각각 존재합니다.

Evidence:

- 패키지 원본 검사: `ev_7414f5185b17c7cc61d769be371dc2d92d41e2890b4a428c0b75b04e29d8619c`
- Mach-O 검사: `ev_22c56b6b2487f347ef9fb68c44e2f800b789ab675d5b355f59c4b64195090fd4`
- 네이티브 dispatch 메타데이터: `ev_9d2bc796669464a68e6339d371f97d0acd2286d510ea4b6874a9fa5ece3aa2d7`
- Info.plist: `ev_c350063ed5e400cdab619bc895994a4d38509a7196eb7057162050efa72c5192`

전체 증거 묶음은 작업 폴더 `work/rea-presentify/evidence/presentify-8.1.4.json`에 보존했습니다.

### 해석과 한계

위 메타데이터와 공식 사용법은 ‘별도 창에 필기를 표시하고 입력 모드를 전환한다’는 설계를 뒷받침합니다. 내부 알고리즘 전체를 증명하지는 않습니다. 이 환경에는 Ghidra/Hopper 등 깊은 디컴파일 엔진이 없어 함수 본문을 디컴파일하지 않았습니다. Swift generic/resilient metadata 일부도 REA에서 지원되지 않습니다. Presentify를 실행한 동적 분석이나 속도 비교를 했다고 주장하지 않습니다.

REA의 DMG 목록 조회는 성공했으나 `extract_artifact`는 이 서버 버전에서 DMG 추출을 지원하지 않았습니다. 읽기 전용으로 마운트한 뒤 작업 폴더에 복사하고 마운트를 해제했습니다. 이는 일반 파일 도구로 수행한 단계이며 별도의 REA 동적 증거는 아닙니다.

### InkBridge에서 직접 구현한 선택

Presentify의 소스 코드·아이콘·UI 리소스를 복사하지 않았습니다. 별도의 Swift/AppKit 코드로 다음을 작성했습니다.

- 투명 NSPanel과 화면별 필기 데이터.
- 펜/형광펜/화살표 렌더링, 획 단위 지우개.
- 조작 모드의 클릭 통과, Fn 임시 조작, Carbon 전역 단축키.
- 최대 100개 편집 기록, JSON 파일 저장/불러오기, 투명 PNG 내보내기.
- 기본 선택 화면은 실제 내장 디스플레이 우선. 사용자가 앱에서 다른 필기 화면 선택 가능.
- 디스플레이 연결 변경 시 화면 목록 갱신. 디스플레이 설정 자체는 변경하지 않음.
- 앱 사용법과 별도 연습장.

앱에는 원격 서버, 계정, 자동 업데이트, 시스템 설정 변경 코드가 없습니다. 화면 캡처·확대 기능은 첫 버전 범위에서 제외했고, 화면+필기 캡처는 macOS 기본 단축키를 사용합니다.

## 0.1 완료 확인

- 빌드·모델 검증: Swift 빌드 성공, 33개 모델 검증 통과.
- UI 관찰: 도구 막대, 내장 연습장, 필기/조작 모드 전환 화면 확인.
- 사용자 실기 확인: 아이패드에서 선이 정상 출력됨.
- 사용자 실기 확인: 같은 선이 맥북 화면에도 동일한 위치에 보임.
- 미측정: Pencil 지연 수치, 필압, 모든 전체 화면 앱, 모든 외부 모니터/Spaces 조합, 강의 송출 앱별 결과.


## 0.2 — 글래스 UI와 Pencil 입력 조사 (2026-10-22)

- macOS 26의 공식 [NSGlassEffectView](https://developer.apple.com/documentation/appkit/nsglasseffectview)를 사용했습니다. 13~25에서는 NSVisualEffectView로 대체합니다. 시스템 외관 설정을 따르며 OS 설정을 변경하지 않습니다.
- [Apple Sidecar 안내](https://support.apple.com/en-us/102597)는 Apple Pencil 2세대 이후의 더블탭을 지원한다고 명시합니다. 앱에서 [NSResponder.changeMode(with:)](https://developer.apple.com/documentation/appkit/nsresponder/changemode(with:))를 받아 현재 필기 도구와 획 지우개를 전환하도록 구현했습니다. 실제 Pencil Pro 전달은 별도 실기 확인이 필요합니다.
- [Apple Pencil Pro API 설명](https://developer.apple.com/videos/play/wwdc2024/10214/)은 iPad의 UIPencilInteraction과 PencilKit 도구 선택기의 스퀴즈 지원을 설명합니다. macOS AppKit/Sidecar에서 스퀴즈를 받는 공개 API는 이번 조사에서 확인하지 못했습니다. iPad 지원을 Sidecar 지원으로 간주하지 않습니다.
- 기존 InkBridge는 고정 굵기의 직선 연결과 모든 획의 반복 렌더링을 사용했습니다. 0.2에서는 곡선 보간, 같은 경로를 사용하는 지우개 판정, 완료된 획의 Retina 이미지 캐시를 추가했습니다. 실제 지연을 계측하거나 다른 앱과 비교한 결과는 아닙니다.
- 검증: 모델 36개 + 렌더링 9개 통과, 빌드·코드 서명·plist 정상. UI에서 접기·펼치기, 재실행 후 상태 복원, 모드 전환 확인. 실기 필기감과 더블탭 확인 대기.

## 후속 설계 — 문서 연동 모드 (미구현)

두 용도는 같은 앱 안에서 별도 모드로 제공할 수 있습니다.

| 모드 | 입력·화면 경로 | 적합한 자료 |
|---|---|---|
| 화면 위 필기 | Pencil → Sidecar → Mac 렌더링 → iPad 화면 | 현재 실행 중인 Mac 앱·웹페이지 |
| 문서 필기 | iPad PencilKit에서 즉시 렌더링 → 문서 저장 및 Mac에 반영 | PDF·이미지·웹페이지를 PDF로 저장한 자료·화면 캡처 |

문서 모드는 Apple의 PencilKit/PKCanvasView와 PDFKit을 사용하는 iPad 앱이 담당합니다. PencilKit의 도구 선택기를 활용하면 Apple Pencil Pro 스퀴즈와 더블탭을 지원하는 기본 경험을 이용할 수 있습니다. Goodnotes의 엔진을 사용하는 것은 아니므로 같은 필기감을 보장하지는 않지만, 선이 보이기까지 Mac 왕복을 기다리지 않아도 됩니다.

첫 구현 범위는 다음처럼 잡을 수 있습니다.

1. PDF/이미지를 가져와 페이지별로 필기. 원본, 편집 가능한 PKDrawing, Mac에서 볼 미리보기 이미지를 문서 패키지로 저장.
2. 사용자가 선택한 iCloud Drive 폴더를 통해 문서 연동. 첫 버전은 iPad가 필기를 편집하고 Mac은 보기·발표를 담당해 동시 편집 충돌을 줄임. 파일 충돌이 발생하면 별도 사본을 보존.
3. 강의 중 즉시 반영이 필요하면 문서 저장과 별도로 기기 간 미리보기 전송을 추가. iCloud 파일 동기화만으로 매 획의 즉시 반영을 보장하지 않음.

Mac 웹페이지의 스크롤·영상·앱 버튼이 문서 모드에서 그대로 작동하는 것은 아닙니다. 이런 사용에는 기존 Sidecar 모드를 유지하거나, 별도로 화면 전송 및 좌표 동기화 기능을 설계해야 합니다.

현재 이 Mac에는 Command Line Tools만 있고 Xcode/iPadOS SDK가 없습니다. 실제 iPad 앱을 빌드·설치하려면 Xcode, Apple 계정 개발 서명, 기기의 개발자 모드가 필요합니다. 이 변경들은 이번 업데이트에서 실행하지 않았습니다. 무료 Personal Team 배포의 서명 만료 제약도 기존 배포 조사 내용을 따릅니다.


## 0.3.1 — 더블탭 수신 경로 및 유리 표면 수정

사용자는 0.2에서 더블탭에 반응이 없다고 보고했습니다. 시스템 설정 → 디스플레이 → 아이패드에서 ‘Apple Pencil의 두 번 탭 활성화’가 켜져 있는 것을 UI로 확인했으며 변경하지 않았습니다.

[Apple의 changeMode 이벤트 문서](https://developer.apple.com/documentation/appkit/nsevent/eventtype/changemode)는 이 이벤트가 맨 앞 프로세스의 키 윈도우에 전달되며, 필요한 경우 앱 로컬 이벤트 모니터로 받도록 설명합니다. 기존 비활성 패널은 다른 앱을 맨 앞에 둔 채 필기할 수 있어 이벤트 누락 원인이 될 수 있습니다. 0.3.1은 필기할 때 InkBridge를 활성화하고 로컬 changeMode 모니터에서 이벤트를 한 번 처리합니다. 이는 문서와 코드에 근거한 수정이며, 실제 Pencil Pro 성공 여부는 사용자의 추후 테스트가 필요합니다.

유리 바탕을 제거한 중간 시안은 사용자 피드백에 따라 폐기했습니다. 최종 디자인은 macOS의 NSGlassEffectView regular 재질과 밝은 외관을 사용해 유리 표면을 유지하고, 별도 테두리선·창 그림자를 추가하지 않습니다. 도구 막대 접기·펼치기는 크기와 내용의 불투명도를 애니메이션으로 전환합니다.


## 0.5 재조사 — 이전 스퀴즈 조사 정정

사용자 확인: 무선 Sidecar 연결이며 iPad 기본 앱에서 Pencil Pro 제스처는 정상입니다. 0.4.1의 활성 필기판 수정 후 더블탭이 작동한다고 확인했습니다. 기존 앱에는 스퀴즈 핸들러가 없었으므로, 그때의 무반응을 Sidecar 미지원의 증거로 볼 수 없습니다.

- 공식 [onPencilSqueeze](https://developer.apple.com/documentation/swiftui/view/onpencilsqueeze(perform:))는 **macOS 14.5 이상**에서 사용할 수 있습니다. Apple 문서 JSON의 platforms 항목과 이 Mac의 SwiftUI.swiftinterface 양쪽에서 확인했습니다. [preferredPencilSqueezeAction](https://developer.apple.com/documentation/swiftui/environmentvalues/preferredpencilsqueezeaction)은 Mac에서 contextual palette가 기본 동작이라고 명시합니다. 앞서 AppKit NSEvent만 조사한 범위가 부족했습니다.
- [Inkquation의 Sidecar 안내](https://inkquation.app/en/sidecar/)도 Pencil Pro 스퀴즈 도구 선택기를 안내합니다. 타사 앱을 설치하거나 직접 비교 시험하지는 않았습니다.
- 구현: 기존 InkCanvas를 NSViewRepresentable/NSHostingView로 감싸고 onPencilSqueeze의 ended에서 원형 도구를 엽니다. hover 위치가 없으면 현재 포인터 위치를 사용합니다. 더블탭은 이미 실기 확인한 AppKit changeMode를 유지해 이중 전환을 피합니다.
- [Apple Sidecar 안내](https://support.apple.com/en-us/102597)에 따르면 OS 27 전에는 손가락으로 일반 클릭·창 드래그를 하는 대신 제한된 다중 터치 제스처를 지원합니다. 현재 Mac은 macOS 26.6. 일반 터치 지원 확대에는 Mac·iPad 양쪽 OS 27 이상이 필요합니다. 시스템 업데이트나 설정 변경은 하지 않았습니다.
- 무선 지연과 앱 렌더링 지연은 분리 측정하지 않았습니다. USB와 동일 조건 비교는 무선 구간의 영향을 좁힐 방법이며 완전한 해결을 보장하지 않습니다. 현재 고정 굵기 AppKit 렌더러에는 iPad PencilKit의 예측 입력을 구현하지 않았습니다.

### 유리의 외관 변화

[WholeWindowLiquidGlass](https://github.com/vientooscuro/WholeWindowLiquidGlass)는 native clear glass의 progressive blur 입력을 조정하는 구현과 한계를 공개합니다. 이를 참고해 toolbar의 바깥 재질에만 inputBlurOpacity 계열과 inputBlurRadius를 조정했습니다. 중앙 착색을 낮추려는 목적으로 inputFaceOpacity도 0으로 설정합니다. 광학 가장자리의 굴절 입력과 버튼 내부 필터는 변경하지 않습니다. 참조 코드의 라이선스는 THIRD_PARTY_NOTICES.txt와 앱 Resources에 포함합니다.

별도의 활성 상태 보정(subduedState)을 시도했으나 사용자가 더 불투명하다고 피드백해 제거했습니다. 자동 캡처는 다른 창 배경의 실시간 굴절을 정확하게 보여주지 못하므로, 캡처만으로 외관 성공을 선언하지 않습니다. 최신 표면의 실기 확인은 별도입니다. 필터 조정은 비공개 API여서 macOS 26만 적용하며 키를 검사하고, 향후 버전에는 기본 유리로 돌아갑니다. 시스템의 투명도 줄이기는 존중합니다.

## 0.5.1 — 재시작과 Sidecar 기본 선택

사용자는 0.5에서도 유리가 대부분 불투명하거나 색이 달라지고, 가끔 원하는 투명함을 보인다고 보고했습니다. 따라서 이전 필터 보정을 외관 유지의 해결책으로 간주하지 않습니다. 이번 버전에서는 GlassSurface.swift를 변경하지 않았습니다. 창 활성 상태 또는 AppKit 내부 필터 갱신과의 관련성은 아직 가설입니다.

재시작 전 0.5의 도구 막대에서 ‘스퀴즈 수신됨’을 확인했습니다. 이는 필기 중 SwiftUI 완료 콜백이 앱까지 도착했다는 증거이며, 원형 도구가 사용자에게 보였다는 증거는 아닙니다. 0.5.1은 이미 열린 도구를 후속 호출로 닫지 않도록 하고, 화면 교체 시 이전 NSHostingView를 제거하며 현재 캔버스의 콜백만 처리합니다. 중복 호출이 실제 무표시 현상의 원인이었는지는 아직 확인하지 못했습니다.

시작 시 Sidecar 이름의 화면을 우선 선택하고, 없으면 내장 화면을 선택합니다. 앱에서 사용자가 화면을 직접 선택하면 해당 실행 동안 자동 전환을 멈추고, 선택한 화면이 연결 해제되면 기본 선택으로 돌아갑니다. macOS의 미러링·디스플레이 설정은 변경하지 않습니다. 재실행한 0.5.1의 UI에서 Sidecar Display (AirPlay) 선택과 기존 2획 복원을 확인했습니다. 빌드와 기존 45개 검증, 서명·plist 검사를 통과했습니다.

## 0.5.2 — 필터 내부 값과 실제 표시의 불일치 재현

동일한 창과 줄무늬 배경에 세 개의 NSGlassEffectView를 배치해 비교했습니다. 왼쪽은 0.5.1의 조건부 갱신, 가운데는 명명된 레이어 필터 경로로 매 프레임 반영, 오른쪽은 macOS 기본 clear 재질입니다. 블러 반경 1.5, 블러 불투명도 0, 중앙 착색 불투명도 0은 왼쪽과 가운데에서 같습니다.

실행 로그에서 왼쪽과 가운데 필터의 내부 값은 동일했습니다. 그러나 UI 캡처에서 왼쪽은 불투명하게 흐렸고 가운데는 배경 줄무늬가 선명하며 가장자리 굴절이 보였습니다. 다른 검증 창을 활성화한 뒤에도 가운데의 선명함을 확인했습니다. 사용자는 이 캡처의 가운데가 원하는 디자인이라고 확인했습니다.

0.5.1은 CAFilter 객체를 수정한 후 내부 값이 같으면 이후 갱신을 생략했습니다. 이 상태는 화면에 표시되는 재질까지 갱신됐음을 보장하지 않았습니다. 0.5.2는 참조 구현처럼 `filters.<name>.<input>` 경로를 통해 CALayer에 값을 전달하고 필터 배열을 매 프레임 재설정합니다. 이는 내부 값과 화면 표시의 차이를 해소한 실험 결과이며, AppKit 내부에서 어떤 프레임에 기존 재질을 다시 제출하는지까지 추적한 결과는 아닙니다.

수정에는 기존 맑은 재질의 수치를 그대로 사용했습니다. 굴절 입력, 가장자리 홈, 버튼 내부 재질, 시스템 설정은 바꾸지 않았습니다. 실제 앱에 같은 방법을 적용한 0.5.2를 실행했습니다. 당시 Sidecar는 화면 목록에 없어 내장 화면이 선택됐습니다. 검증용 소스와 상태 로그는 작업 폴더 `work/glass-probe`에 보존하며 배포 앱에는 포함하지 않습니다. 스크린샷·키보드 입력·사용자 문서는 이 로그에 저장하지 않았습니다.

사용자 실기 확인(2026-10-22): 0.5.2에서 ‘필기 시작’ 또는 다른 창으로 이동한 뒤에도 원하는 투명함이 유지되는지 질문했고, 사용자가 ‘원하는 투명함이 계속 유지됨’이라고 답했습니다. 이 외관을 기준 디자인으로 확정했습니다. 이 답변은 해당 사용 환경의 실기 확인이며 모든 OS 버전·디스플레이 조합의 검증을 뜻하지는 않습니다.

## 0.6–0.6.2 — 지우개와 도구 사용성

부분 지우기는 원래 획에 지우개 경로 마스크를 저장하고, 획 지우기는 닿은 획을 제거합니다. 지우개 이벤트 사이도 이어 처리하며 한 번의 드래그가 실행 취소 단위입니다. 마스크가 있는 파일은 형식 2를 사용하고 기존 형식 1도 읽습니다. 모델 48개·렌더링 15개 검증을 통과했습니다. 사용자는 실제 지우기가 작동한다고 확인했습니다.

검은 배경에서 유리 전체에 흰 바탕을 더하지 않고 글자와 아이콘 바로 뒤에만 작은 반투명 받침을 추가했습니다. 승인된 0.5.2의 GlassSurface.swift는 변경하지 않았습니다. 도구 모양과 최소한의 가림을 함께 원한다는 답변을 반영해, 0.6.2는 대기 중 작은 도구 아이콘을 표시하고 입력 중에는 점/범위 원만 남깁니다. 포인터 이미지의 밝은/검은 배경 대비는 시각 검수했고 실제 iPad 입력 중 전환은 아직 실기 확인 전입니다.

[Presentify 공식 기능 안내](https://presentifyapp.com/)와 비교하면 InkBridge는 개인용 화면 필기와 Sidecar 기본 배치, 취향에 맞춘 유리 표면에 집중한 시제품입니다. Presentify의 텍스트·도형, 자동 지우기, 스포트라이트/확대, 클릭 강조 등은 아직 구현하지 않았습니다. 두 앱의 종단 간 지연이나 장시간 안정성을 동일 조건에서 비교하지 않았으므로 성능 동급이라고 평가하지 않습니다.

[Apple Sidecar 안내](https://support.apple.com/ko-kr/102597)에 따른 손가락 입력 제약은 시스템 기능입니다. 현재 macOS 26.6에서는 제한된 멀티터치 제스처와 Sidecar 제어를 사용할 수 있으며 일반 Mac 창/메뉴의 터치 확대에는 양쪽 OS 27 이상이 필요합니다. 이 작업에서 OS·디스플레이 설정은 변경하지 않았습니다.

## 2026-10-22 — 맥 화면 수신 + iPad 즉시 필기

요구사항은 빈 공책 동기화가 아니라 맥 화면을 iPad에서 보면서 그 위에 쓰는 방식이다. Sidecar 위에 다른 iPad 앱을 투명 오버레이로 얹는 공개 API를 전제로 하지 않는다. iPad 앱 안에서 맥 영상 수신과 투명 PencilKit 캔버스를 함께 구성한다.

- 맥은 ScreenCaptureKit으로 선택한 화면을 캡처하고 영상으로 iPad에 전송한다. 자체 필기 창과 도구 창은 캡처에서 제외해 iPad에 잉크가 중복되어 돌아오는 것을 막는다.
- iPad는 수신한 영상 위에 PencilKit으로 즉시 그린다. 로컬 렌더링은 맥 응답을 기다리지 않는다. 진행 중 획 전송과 획 완료 후 확정 데이터 전송을 구분하고, 지우기·실행 취소·재접속 시에도 상태를 맞춘다.
- 맥은 받은 필기를 자신의 오버레이에 표시한다. 영상과 필기의 좌표 변환은 같은 캡처 영역·종횡비를 기준으로 하고, 해상도·화면 방향 변경에는 새 좌표 기준을 적용한다.
- 배경 영상 지연과 필기 데이터 전달 지연은 남는다. 현재 Sidecar 지연의 원인이나 새 방식의 성능 수치를 측정한 것은 아니다. 로컬 필기 렌더링을 네트워크 왕복에서 분리하는 것이 이 설계의 목적이다.
- 향후 구현 범위이며 0.6.3에는 포함하지 않았다. 현재 Mac에는 Command Line Tools만 있고 Xcode/iPadOS SDK가 없다. 실기 빌드·설치에는 Xcode, Apple 계정 서명과 iPad 개발자 모드 준비가 필요하다.

공식 근거: [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit/), [PencilKit](https://developer.apple.com/documentation/pencilkit/), [iPadOS 앱 격리](https://support.apple.com/en-au/guide/security/sec15bfe098e/web), [실기 실행](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices).
