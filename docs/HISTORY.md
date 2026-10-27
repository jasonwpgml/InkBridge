# InkBridge 개발 기록

날짜별 변경과 그때 확인한 범위입니다. 최신이 위에 있습니다. 로그 파일(`build/…`)은 저장소에 포함하지 않습니다.

## 검증 기록 (맥 화면·서재)

- 2026-10-27 (서재·공개 준비): 문서 필기 모드를 **서재**로 바꾸고 `iPad/LibraryView.swift`에 유리 책장(종류별 책장, 첫 쪽 표지·천 표지, 필기 책갈피, 이어서 쓰기, 변환 중 표시, 검색, iPad 파일 가져오기)을 추가했습니다. 서버에 책 정보(`kind`·`cover`·`pageCount`)와 `POST /__pr/api/import`를 더했고 `pencil-review/`를 `library/`로 옮겼습니다. Sidecar판 소스를 `sidecar/`로 합치고 `-padMode` 실행 인자를 추가했습니다. `scripts/test-all.sh` 전체 통과(30 + 맥 컴파일, 서버 20, Sidecar 391), 시뮬레이터에서 책장·이어서 쓰기·책갈피 화면과 책 주소(303→200)를 확인했습니다. 가로 배치, 책을 눌러 펼치기·가져오기 흐름은 확인하지 않았습니다. 공개 전 보안 점검으로 서재 서버가 다른 사이트에서 보낸 변경 요청을 거부하고(Origin 검사), 페이지 스크립트가 읽는 manifest에는 토큰을 넣지 않으며, 맥이 틀린 연결 코드 3번 뒤 코드를 바꾸고, 서재 웹 뷰가 서버 밖으로 이동하지 않도록 했습니다(서버 검사 21개).
- 2026-10-27 (처음 화면): `iPad/HomeView.swift`에 로고와 세 버전 유리 버튼을 추가하고, 앱이 항상 처음 화면으로 열리게 했습니다. 단독 Pencil Review 앱(`local.inkbridge.pencilreview.pad`)을 실기 iPad와 시뮬레이터에서 제거했습니다(필기는 맥 서버에 저장되므로 iPad에 남은 데이터 없음). 검사 30개·맥 컴파일, 시뮬레이터 세로 화면 확인(로그 `build/home-sim.log`), 서명 빌드(`build/home-device.log`)를 실기 iPad에 설치·실행했습니다. 가로 배치(버튼 세 개 가로 정렬)와 버튼을 눌러 각 모드로 들어가고 돌아오는 흐름은 화면으로 확인하지 않았습니다.
- 2026-10-27 (통합 도구·유리 디자인): 문서 모드에서 웹 도구 막대 대신 앱 도구 막대를 쓰도록 하고(`DocumentSession`이 펜·색·굵기·펜 종류·손가락 필기를 페이지에 전달, 실행 취소·저장·지우기 명령, 상태 수신), 두 모드의 더블탭·스퀴즈를 `PadModel.handlePencil`로 합쳤습니다. 스퀴즈는 이전의 ‘도구 막대 표시/숨김’ 대신 펜 끝 팔레트입니다. 검사 30개·맥 컴파일·웹 검사 19개 통과, 시뮬레이터에서 두 모드의 유리 도구 막대를 확인(로그 `build/unified-tools-sim.log`), 브라우저에서 앱이 보내는 설정(보라 만년필·노랑 형광펜)으로 그린 획의 색·굵기·펜 종류 저장과 실행 취소 명령을 확인했고, 서명 빌드(`build/unified-tools-device.log`)를 실기 iPad에 설치·실행했습니다. 실제 Pencil 더블탭·스퀴즈 팔레트, 유리 재질의 실기 가독성, 문서 모드 펜 종류의 실기 필기감은 확인하지 않았습니다. 서명 만료 2026-10-30 00:33 KST.
- 2026-10-27 (문서 필기 모드): `PadApp.swift`에 화면/문서 모드 전환을 넣고 `project.yml`에 로컬 네트워크 HTTP 허용을 추가했습니다. 같은 날 만든 독립 앱(Pencil Review)은 합친 뒤 `build/pencil-review-ios-standalone-20261027/`로 옮겼고, 이후 iPad·시뮬레이터에서 제거하고 이 폴더도 휴지통으로 옮겼습니다. 변경 전 파일은 `build/merge-documents-before-20261027/`. 검사 30개·맥 컴파일, iPad 시뮬레이터 빌드(로그 `build/merge-documents-sim.log`)에서 두 모드 화면을 확인했고, 서명 빌드(`build/merge-documents-device.log`)를 실기 iPad에 설치·실행했습니다. 이 설치본에는 같은 날 추가된 펜 종류·미리보기 전송 변경도 들어 있습니다. 서명 만료는 2026-10-30 00:33 KST입니다. 실제 Pencil 더블탭·스퀴즈, 펜 종류 선택 화면, 모드 전환 후 재연결은 기기에서 확인하지 않았습니다.
- 2026-10-27: 펜 종류(젤펜·볼펜·만년필)와 필기 중 미리보기만 전송하는 방식을 추가했습니다. 프로토콜·도구 설정 검사 30개, 맥 코드 컴파일, `build-mac.sh` 빌드, iPad 시뮬레이터 및 실기용(서명 제외) 빌드를 통과했습니다. 로그는 `build/pen-kinds-build.log`, `build/pen-kinds-device-build.log`입니다. 펜 종류 선택 창의 화면 확인, 실제 Pencil 필기감, 맥 오버레이 동기화, 메인 스레드 부하 감소 효과는 기기에서 확인하지 않았습니다. 새 맥 앱은 기존과 같은 Apple Development 인증서로 서명해 `/Applications/InkBridge Mac.app`에 설치하고 실행을 확인했습니다. 이전 설치본은 `build/mac-app-before-pen-kinds/`에 있습니다. iPad 앱은 아직 새 버전으로 설치하지 않았습니다.
- 2026-10-26: 도구 선택 UI 개편 후 프로토콜·도구 설정 25개 검사, 맥 코드 컴파일, iPad 시뮬레이터(arm64/x86_64) 및 실기용(arm64, 서명 제외) 빌드 통과. iPad Air 시뮬레이터에서 도구별 설정 복원·재실행 저장·색상 팝오버를 확인하고, iPad mini의 좁은 화면·다크 모드에서 두 줄 배치를 확인했습니다. 실제 iPad는 연결되지 않아 이번 변경의 기기 설치·Pencil 조작은 미검증입니다. 로그는 `build/tool-picker-build.log`, `build/tool-picker-device-build.log`, 변경 전 백업은 `build/tool-picker-before/`입니다.
- 2026-10-22: Homebrew로 `mas` 7.0.0, `xcodegen` 2.46.0 설치. Xcode는 Homebrew 패키지가 없어 App Store 예외 경로로 27.1 설치 완료.
- 패킷 처리·전송 대기·입력 검증 18개 검사 통과. 맥 코드 컴파일, 앱 실행, 연결 코드 UI, 코드 서명 및 plist 검사 통과.
- 2026-10-23: Xcode 첫 실행 설정과 약관 등록 완료. Xcode로 맥 전체 빌드, iOS 27.1 SDK로 iPad 시뮬레이터(arm64/x86_64) 및 실제 기기(arm64) 전체 빌드 성공. 개인 개발 팀으로 서명한 실기 빌드와 설치·실행도 성공했습니다. 로그는 `build/mac-xcode-build.log`, `build/ipad-build.log`, `build/ipad-device-build.log`, `build/ipad-signed-build.log`입니다.
- iOS 27.0 런타임으로 `InkBridge Test iPad` 시뮬레이터를 생성하고 앱 설치·실행을 확인했습니다.
- iPad Air 11-inch (M4), iPadOS 27.0.1에서 개발자 모드·개발자 앱 신뢰·로컬 네트워크 허용을 완료했습니다. 현재 설치본의 프로비저닝 만료 시각은 2026-10-30 00:33 KST이며, 이후에는 Xcode로 다시 서명해 설치해야 합니다.
- 맥 앱을 Apple Development 인증서로 서명해 `/Applications/InkBridge Mac.app`에 설치하고 화면 기록 권한을 갱신했습니다. 맥 디스플레이 검색, 코드 연결, 실제 맥 화면의 iPad 수신을 확인했습니다.
- iPad에서 파란색·빨간색 시험선 표시를 확인했으며, 저장 파일에서도 첫 번째 시험선의 PencilKit 데이터를 읽었습니다. 맥 오버레이의 필기 표시와 실행 취소 동기화는 추가 실기 확인이 필요합니다. Pencil Pro 스퀴즈·필압·체감 지연은 실제 Pencil로 확인해야 합니다.
- 백그라운드 복귀 시 기기 재검색과 전송 중지 뒤 도착하는 프레임 처리를 보완하고, 18개 프로토콜 검사 및 맥 코드 컴파일을 다시 통과했습니다.
- `deslop-review` 자동 검사기는 Swift 프로젝트를 지원하지 않아 위 자체 검사와 소스 검수를 사용했습니다.
- 2026-10-26: 별도 경로의 기존 **Sidecar용 InkBridge**를 0.6.4로 최적화했습니다. 진행 중인 곡선 재사용·부분 화면 갱신·완성 획의 캐시 추가·지우개가 문서를 바꾸지 않은 입력의 갱신 생략을 적용했고, 회귀 검사 387개와 캔버스 입력 격리 검사 10개, 빌드·서명·앱 실행을 확인했습니다. 자세한 측정 결과는 기존 Sidecar 프로젝트의 `README.md`에 있습니다. 이 폴더의 Mac+iPad 네이티브 앱 코드와 JPEG 전송 방식은 이번 작업에서 변경하지 않았으며, 실제 Pencil 체감 비교는 남아 있습니다.

## 도구 선택 UI 참고

별도 Sidecar 버전에도 도구별 색·굵기 저장, 이름이 붙은 큰 도구 버튼, 선 미리보기 설정창을 적용했습니다. Sidecar 버전은 모델·렌더링 391개 검사, 별도 패널 UI 검수와 빌드·서명 검사를 통과했습니다. 이 폴더의 iPad 네이티브 버전과는 별도 앱입니다.

[Goodnotes](https://support.goodnotes.com/hc/en-us/articles/7353756785679-Write-and-customize-ink-with-the-Pen-tool)의 색·굵기 바로 선택과 재탭 설정, [Notability](https://support.gingerlabs.com/en-us/articles/16300108-getting-started-with-notability)의 도구별 프리셋, [Apple Markup](https://support.apple.com/en-ie/guide/ipad/ipad6350b8dc/ipados)의 접을 수 있는 도구 막대를 참고했습니다. InkBridge에서는 화면을 가리지 않도록 하단에 작게 두고, 도구를 바꿔도 필기 화면의 좌표계가 달라지지 않게 적용했습니다.
