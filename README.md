# 한글 자소 정리 (HangulJaso)

macOS에서 한글 파일명의 자소 분리(NFD) 문제를 자동으로 감지하고 NFC로 변환하는 메뉴 바 앱입니다.

## 문제

macOS는 파일명을 NFD(Normalization Form Decomposition) 방식으로 저장하여, 한글 파일명이 자소 단위로 분리되는 현상이 발생합니다. 예를 들어 `한글.txt`가 `ㅎㅏㄴㄱㅡㄹ.txt`처럼 보이는 문제입니다. 이 앱은 이런 파일명을 NFC(Normalization Form Composition)로 자동 변환합니다.

## 주요 기능

- **메뉴 바 상주**: Dock 아이콘 없이 메뉴 바에서 동작
- **폴더 감시**: 지정한 폴더(Downloads, Desktop, Documents 등)를 FSEvents로 실시간 모니터링
- **자동 NFC 변환**: 감시 폴더의 NFD 파일을 자동 변환하고 알림 표시 (앱 시작 시 전체 스캔, FSEvents 실시간 감지, 1시간 주기 전체 스캔, 폴더 추가 시 즉시 스캔)
- **NFD 태그 표시**: NFD 파일에 주황색 `NFD` 태그를 자동 부여, 변환 후 자동 정리
- **Finder 컨텍스트 메뉴**: 파일 우클릭 시 "한글 파일명 NFC 변환" 메뉴 (Finder Sync Extension)
- **Finder 도구막대**: 🇰🇷 버튼 클릭으로 즉시 변환 (도구막대 사용자화에서 추가)
- **Finder 빠른 동작**: Quick Action(.workflow)을 통한 NFC 변환
- **자동 재시작**: LaunchAgent KeepAlive로 앱 비정상 종료 시 자동 복구
- **알림**: 자동 변환/수동 변환 완료 시 macOS 알림 표시

## 빌드 및 실행

[XcodeGen](https://github.com/yonaskolb/XcodeGen)이 필요합니다.

```bash
brew install xcodegen
```

### 명령어

| 명령어 | 설명 |
|---|---|
| `make build` | xcodegen + Debug 빌드 |
| `make install` | 빌드 + /Applications에 설치 |
| `make run` | 빌드 + 설치 + 앱 실행 |
| `make rerun` | 앱 재실행 (빌드 없이) |
| `make kill` | 실행 중인 앱 종료 |
| `make clean` | 빌드 아티팩트 정리 |
| `make release` | Release 빌드 |

> `make run`을 사용하면 xcodegen, 빌드, 설치, 실행이 한 번에 처리됩니다.

## 구조

```
HangulJaso/              # 메인 앱
├── App/                 # AppDelegate, HangulJasoApp, Constants
├── Models/              # ConversionRecord, FileItem, WatchedFolder
├── Services/            # NFCService, FileMonitorService, WorkflowInstaller, LaunchAgentService
├── ViewModels/          # HangulJasoViewModel
├── Views/               # SwiftUI 설정 화면
└── Resources/           # Info.plist, Assets

HangulJasoFinder/        # Finder Sync Extension
├── FinderSync.swift     # 컨텍스트 메뉴 + 도구막대 (🇰🇷)
└── Resources/           # Info.plist, Entitlements

Workflows/               # Finder Quick Action (.workflow)
```

## Finder Sync Extension

Finder에서 파일/폴더를 우클릭하면 빠른 동작에 "한글 파일명 NFC 변환" 항목이 표시됩니다. Finder 도구막대에 🇰🇷 버튼을 추가하면 클릭 한 번으로 변환할 수 있습니다.

### Finder 도구막대에 추가

1. Finder 메뉴 > **보기** > **도구막대 사용자화...**
2. "한글 NFC 변환" 아이콘을 도구막대로 드래그
3. **완료** 클릭

### 로컬 개발 및 실행

Finder Sync Extension은 로컬 개발 및 실행이 가능합니다. 별도의 App Store 배포나 공증(Notarization) 없이도 `make run`으로 빌드하면 Extension이 앱 번들 내 `PlugIns/` 디렉토리에 자동으로 포함되어 동작합니다.

단, Finder Sync Extension이 활성화되려면 다음 조건이 필요합니다:

1. 앱이 `/Applications`에 설치되어 실행 중이어야 합니다 (`make run` 사용)
2. **시스템 설정 > 개인 정보 보호 및 보안 > 확장 프로그램 > 추가된 확장 프로그램**에서 HangulJaso의 Finder 확장이 활성화되어야 합니다
3. 최초 설치 후 Finder를 재시작해야 할 수 있습니다 (`killall Finder`)

### 동작 방식

Extension은 `DistributedNotificationCenter`를 통해 메인 앱에 변환을 요청하고, 메인 앱이 실제 NFC 변환과 알림 표시를 처리합니다.

## 자동 NFC 변환 동작

자동 변환이 활성화된 감시 폴더에서는 4가지 트리거로 NFD 파일을 감지·변환합니다:

1. **앱 시작 시**: 모든 자동 변환 폴더를 재귀적으로 전체 스캔
2. **FSEvents 실시간 감지**: 파일 생성/이동/이름 변경 시 해당 디렉토리 즉시 스캔
3. **주기적 전체 스캔**: 1시간 간격으로 자동 변환 폴더 전체를 재귀 스캔
4. **폴더 추가 시**: 설정에서 감시 폴더를 추가하면 즉시 전체 스캔 실행

스캔 시 `readdir()`로 원본 파일명을 직접 읽어 NFD를 감지합니다 (Swift URL은 자동으로 NFC 정규화하므로 사용 불가). 변환 완료 시 macOS 알림으로 결과를 표시합니다.

## 자동 재시작

설정에서 "로그인 시 자동 시작"을 활성화하면 LaunchAgent가 설치됩니다. `KeepAlive` 옵션이 포함되어 있어 앱이 어떤 이유로든 종료되면 macOS가 자동으로 재시작합니다.

## 요구 사항

- macOS 14.0 (Sonoma) 이상
- Xcode 15 이상
- XcodeGen

## 라이선스

MIT
