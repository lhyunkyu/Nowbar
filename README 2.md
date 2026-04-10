# NotchInteraction

마우스 포인터가 노치에 가까워질수록 노치가 부풀어 오르며 시계/배터리 정보를 보여주는 macOS 앱.

## 동작 방식

| proximity | 반응 |
|-----------|------|
| 0.0 ~ 0.05 | 변화 없음 (일반 노치) |
| 0.05 ~ 0.4 | 노치가 서서히 커지고 glow 효과 |
| 0.4 ~ 1.0 | 시계, 배터리 아이콘 fade-in |

## 빌드 & 실행

```bash
cd ~/Desktop/NotchInteraction
swift run
```

## Xcode 프로젝트로 열기

```bash
cd ~/Desktop/NotchInteraction
swift package generate-xcodeproj
open NotchInteraction.xcodeproj
```

## 주의사항

- **노치가 있는 MacBook** (14", 16" Pro / Max)에서 동작 확인
- 노치 없는 모델에서는 오버레이가 메뉴바 위에 표시됨
- 시스템 환경설정 → 개인 정보 보호 → 손쉬운 사용에서 앱 권한 허용 필요
  (전역 마우스 이벤트 감시를 위해)
