# SBOM Monitor Agent 사용 가이드 (USAGE)

이 문서는 대상 서버에서 `collect-sbom.sh` 에이전트 스크립트를 최초 설치하고 실행하며 관리하는 방법을 안내합니다.

## 1. 사전 준비 (Prerequisites)
- 대상 서버에서 아래 명령어를 사용하여 Nexus3로부터 스크립트를 다운로드합니다.
  ```bash
  # Nexus URL 및 저장소 정보에 맞춰 수정하여 실행
  curl -L -o collect-sbom.sh http://your-nexus-server:8081/repository/sbom-monitor-raw/agent/collect-sbom.sh
  chmod +x collect-sbom.sh
  ```
- 대상 서버가 내부망의 Nexus3 및 Black Duck 서버와 통신할 수 있어야 합니다.
- 최초 설정(Setup) 및 크론(Cron) 등록을 위해 **sudo 권한**이 필요합니다.

## 2. 디렉토리 구조
에이전트가 최초 실행되면 스크립트가 위치한 디렉토리 하위에 구동에 필요한 디렉토리가 자동 생성됩니다.

```text
/path/to/sbom-monitor/
├── collect-sbom.sh      # 메인 에이전트 쉘 스크립트 (실행 파일)
├── config.conf          # 에이전트 설정 파일 (최초 실행 시 자동 생성)
├── bin/                 # Syft 바이너리가 다운로드되는 폴더
│   └── syft             
├── log/                 # 스크립트 실행 로그 폴더
│   └── sbom-monitor.log 
└── output/              # 생성된 SBOM JSON 파일이 저장되는 폴더
    └── sbom_*.json      
```

## 3. 실행 모드 및 사용법

스크립트는 목적에 따라 다양한 옵션을 제공합니다. 인자 없이 실행하거나 잘못된 인자 전달 시 도움말이 출력됩니다.

### 3.1. 최초 설치 및 설정 (Setup Mode)
에이전트를 처음 설치하고 주기적 실행 스케줄(crontab)을 등록하려면 **반드시 sudo 권한으로 `--setup` 옵션과 필수 파라미터**를 필수로 전달하여 실행해야 합니다.

```bash
# 사용법
sudo bash collect-sbom.sh --setup --project-name <ProjectName> --target-dirs <dir1> <dir2> ...

# 실행 예시 (프로젝트명: my-backend, 대상: /app /var/www)
sudo bash collect-sbom.sh --setup --project-name my-backend --target-dirs /app /var/www
# 짧은 옵션 지원
sudo bash collect-sbom.sh --setup -p my-backend -t /app /var/www
```

**진행 순서:**
1. Nexus3에서 시스템 아키텍처에 맞는 최신 Syft 바이너리를 `bin/` 디렉토리에 다운로드합니다.
2. 전달받은 `--project-name`과 `--target-dirs` 값을 `config.conf`에 영구 저장합니다.
3. 입력받은 설정으로 첫 번째 SBOM 스캔 및 Black Duck 업로드를 즉시 수행합니다.
4. 서버의 MAC 주소를 해싱한 고유의 요일 및 시간대(비업무 시간)로 `/etc/cron.d/sbom-monitor` 에 스케줄을 자동 등록합니다.

### 3.2. 수동 스캔 실행 (`--run`)
설정이 완료된 기기에서, 스케줄과 무관하게 지금 즉시 스캔 및 결과를 업로드하고 싶을 때 사용합니다. 스크립트 특성상 시스템 권한이 필요할 수 있으므로 sudo 사용을 권장합니다.

```bash
sudo bash collect-sbom.sh --run
```

### 3.3. 크론(Cron) 의존 없는 1회성 스캔 (`--scan-only`)
이 옵션은 `sudo` 권한이 제한되는 환경이거나, `/etc/cron.d` 에 시스템 스케줄이 등록되는 것을 원치 않을 때 유용합니다. (단, 최초 설정 시 생성된 `config.conf` 파일은 존재해야 합니다.)

```bash
bash collect-sbom.sh --scan-only
# 특정 프로젝트 이름으로 오버라이드 하여 스캔할 때:
bash collect-sbom.sh --scan-only --project-name my-temp-project
```
- 내부망의 CI/CD 파이프라인이나 타 스케줄러 도구를 통해 에이전트를 원격 구동할 때 활용할 수 있습니다.
- `sudo` 없이 실행 가능하지만 스캔 대상 디렉토리(`TARGET_DIRS`)에 대한 읽기 권한은 보장되어야 합니다.
- 기본적으로 `config.conf`에 저장된 프로젝트명을 사용하지만, `--project-name` 파라미터를 함께 넘기면 해당 1회성 실행에 대해서만 프로젝트명을 동적으로 변경할 수 있습니다.

### 3.4. 자동 실행 스케줄 모드 (`--cron`)
에이전트가 `/etc/cron.d/sbom-monitor` 에 의해 자동으로 구동될 때 내부적으로 호출되는 옵션입니다. 사용자가 직접 실행할 필요는 없습니다.

```bash
# 크론탭에서 호출하는 구문 예시
15 3 * * 5 root /bin/bash /path/to/sbom-monitor/collect-sbom.sh --cron >> /path/to/sbom-monitor/log/sbom-monitor.log 2>&1
```

## 4. 자가 업데이트 로직 (Self-Update)
에이전트는 실행될 때마다(수동/자동 무관) 상단에서 자체적으로 업데이트 로직을 수행합니다.

1. **스크립트 업데이트**: Nexus3 저장소의 최신 `collect-sbom.sh` 파일을 다운로드하여 현재 파일과 비교합니다. 변경 사항이 있을 경우 자동으로 파일을 덮어쓰고 즉시 재기동합니다.
2. **Syft 바이너리 업데이트**: Nexus3의 **Search API**를 호출하여 현재 아키텍처(amd64/arm64)에 맞는 최신 `syft_*.tar.gz` 파일을 자동으로 검색합니다. 현재 `bin/syft`의 버전과 다를 경우 최신 바이너리를 다운로드하여 교체합니다.

> **참고**:
> - 중앙 Nexus3 저장소의 특정 폴더에 새 버전의 Syft 타르볼만 업로드해 두면, 에이전트가 Search API를 통해 이를 알아서 찾아내어 업데이트합니다.
> - 스크립트 상단의 `NEXUS_SYFT_REPO` 변수를 통해 Syft 바이너리가 보관된 전용 저장소를 지정할 수 있습니다.
