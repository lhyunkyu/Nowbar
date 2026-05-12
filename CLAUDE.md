# NowBar — CLAUDE.md

## 프로젝트 개요
macOS 노치 영역에 음악 재생 정보를 표시하는 오버레이 앱.
SwiftUI + AppKit 혼합 구조. NSWindow를 직접 제어하며, 노치 위에 투명 윈도우를 레이어링.

## 아키텍처

### 윈도우 구성 (AppDelegate)
| 윈도우 | 역할 |
|---|---|
| `notchBarWindow` | 노치 영역 자체 (호버 감지용) |
| `nowBarWindow` | 노치 아래 드롭다운 알약 (NowBarOverlayView) |
| `sideBarWindow` | 노치 오른쪽 사이드바 알약 (SideBarNowPlayingView) |

### 주요 싱글턴
- `NowPlayingManager.shared` — 재생 정보 관리 (Spotify / Apple Music / Browser)
- `NotchState.shared` — 노치 호버/확장 상태
- `PowerManager.shared` — 배터리 상태
- `NotificationManager.shared` — 시스템 알림

### MusicSource enum
```swift
enum MusicSource { case none, spotify, music, browser }
```
- `.spotify` — Distributed Notification 기반
- `.music` — Distributed Notification + AppleScript 폴링
- `.browser` — AppleScript 탭 순회 + MediaRemote position 보완

## 코드 규칙

### 파일 크기
- **300줄 초과** → 분리 고민
- **500줄 초과** → 반드시 분리

### 파일 분리 원칙
- View는 View끼리, 로직은 Manager/Helper로 분리
- 재사용 컴포넌트는 `SideBarComponents.swift` 같은 별도 파일로

### 새 파일 생성 시
Xcode에서 수동으로 "Add Files to NotchInteraction..." 필요. Claude가 파일을 만들어도 Xcode 프로젝트에 자동 추가되지 않음.

### 네이밍
- View: `~View`, `~Content`
- Manager: `~Manager`
- 상수: camelCase (Swift 관례)

## 브라우저 미디어 감지 구조
1. `NSWorkspace.didActivateApplicationNotification` → 브라우저 전환 시 즉시 체크
2. 2초 폴링 타이머 → 백업
3. AppleScript로 전체 탭 순회 → `▶` 접두사 탭 우선, 없으면 음악 URL 탭 fallback
4. MediaRemote `getNowPlayingInfo` → position / duration / isPlaying 보정
5. `nativeAppIsActive` 플래그 → Spotify/Music 재생 중이면 브라우저 감지 차단

### 지원 브라우저
Chrome, Safari, Brave, Edge, Arc

### 지원 사이트
YouTube, YouTube Music, Spotify Web, SoundCloud

## 애니메이션 스타일
- 알약 등장/퇴장: `.spring(response: 0.38, dampingFraction: 0.65)`
- 앨범아트 트랙 전환: Y축 3D 플립 (easeIn 0.16s → easeOut 0.16s)
- 사이드바 확장: `.spring(response: 0.42, dampingFraction: 0.78)`

## 주요 수치
```swift
notchWidth:              190pt
notchHeight:             37pt
notchHalfWidth:          120pt
nowBarWidth:             520pt
nowBarHeight:            160pt
sideBarCollapsedWidth:   220pt
sideBarExpandedWidth:    340pt
sideBarExpandedHeight:   180pt
expandedPillHeight:      116pt
```

## macOS 앱 개발 공통 규칙

### 메인 스레드
- UI 업데이트는 반드시 `DispatchQueue.main.async` 또는 `@MainActor`
- `@Published` 프로퍼티 변경은 항상 메인 스레드에서

### 메모리 관리
- 클로저 캡처 시 `[weak self]` 필수 (특히 Timer, NotificationCenter, URLSession)
- `Timer` 결과는 반드시 프로퍼티에 저장 (저장 안 하면 즉시 해제됨)
- `isReleasedWhenClosed = false` — 닫혀도 윈도우 메모리 유지해야 할 때

### NSWindow 오버레이 패턴
- `windowLevel = .maximumWindow + 1` — 항상 최상단
- `collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]` — 모든 Space에 고정
- `ignoresMouseEvents` — 클릭 통과 여부를 상황에 맞게 설정
- `backgroundColor = .clear`, `isOpaque = false`, `hasShadow = false`

### AppleScript
- 앱 자동 실행 방지: 스크립트 실행 전 `NSWorkspace.runningApplications` 에서 실행 중인지 확인
- 백그라운드 실행: `DispatchQueue.global(qos: .userInitiated).async`
- 긴 문자열에 `(160) ` 같은 길이 접두사가 붙는 경우가 있음 — 파싱 시 제거 처리

### 권한 처리
- 접근성 권한 (`AXIsProcessTrustedWithOptions`) — 글로벌 마우스 이벤트 감지에 필요
- `NSAppleEventsUsageDescription` — Info.plist에 AppleScript 사용 설명 필수
- Sandbox 비활성화 상태 (PrivateFramework 접근, 글로벌 이벤트 모니터링 등)

### Private Framework 사용 (MediaRemote 등)
- `dlopen` / `dlsym` 으로 동적 로드
- 함수 포인터를 `unsafeBitCast`로 캐스팅
- App Store 배포 불가 — TestFlight/직접 배포만 가능

### 이벤트 모니터링
- `NSEvent.addGlobalMonitorForEvents` — 다른 앱 위에서도 이벤트 감지 (접근성 권한 필요)
- `NSEvent.addLocalMonitorForEvents` — 앱 내부 이벤트 (권한 불필요)
- `applicationWillTerminate`에서 반드시 `NSEvent.removeMonitor()` 호출

### 앱 이름 / 배포
- `LSUIElement = true` — 메뉴바 아이콘만 있는 에이전트 앱 (Dock 아이콘 숨김)
- `applicationShouldTerminateAfterLastWindowClosed` → `false` 반환 (창 닫아도 앱 유지)
- Spotlight 캐시 갱신: `lsregister -kill -r -domain local -domain system -domain user`

## 하지 말 것
- `AlertWindowManager.shared.isVisible` 조건으로 나우바 숨기지 말 것 (항상 표시)
- `MusicSource`를 `NowPlayingManager.MusicSource`로 쓰지 말 것 (top-level enum)
- 브라우저 재생 시 `seek()` 미지원 — 조용히 return
- `NSLog` 디버그 로그는 기능 완성 후 제거
