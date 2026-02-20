# 프로젝트 컨벤션 및 개발 가이드 (CONVENTIONS)

이 문서는 `sbom-monitor` 프로젝트의 품질 유지와 일관성 있는 개발을 위한 규칙을 정의합니다.

## 1. 코드 스타일 (Python 기준)
- **Style Guide**: [PEP 8](https://peps.python.org/pep-0008/)을 기본으로 따릅니다.
- **Linting**: `flake8` 또는 `pylint`를 권장합니다.
- **Type Hinting**: 모든 함수의 인자와 반환 타입에 Python Type Hints 사용을 권장합니다.

## 2. Git 커밋 메시지 규칙
커밋 메시지는 다음 형식을 따릅니다:
`type: description`

- **feat**: 새로운 기능 추가
- **fix**: 버그 수정
- **docs**: 문서 수정 (요구사항, 설계 등)
- **refactor**: 코드 리팩토링
- **test**: 테스트 코드 추가 및 수정
- **chore**: 빌드 업무, 패키지 매니저 설정 등

## 3. 에러 핸들링 및 로깅
- **Error Handling**: 폐쇄망 환경에서 네트워크 순단이 발생할 수 있으므로, API 호출 시 리트라이(Retry) 로직을 포함해야 합니다.
- **Logging**: 모든 수집 및 업로드 단계에서 상세 로그를 남기며, 민감 정보(API Token 등)는 마스킹 처리합니다.

## 4. API 인터페이스 규격
- **Black Duck API**: REST API v1/v2를 사용하며, Bearer Token 인증 방식을 사용합니다.
- **Nexus3 API**: API v1 기반의 Component Upload 방식을 사용합니다.
