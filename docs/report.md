# 요구사항 수행 내역

## 환경·보안·권한

| 항목 | 실행 결과 |
| --- | --- |
| Docker·런타임 | Ubuntu 22.04 / ARM64, 앱 실행에 필요한 라이브러리 확인. 원본 644 유지, 설치본 750. |
| SSH | 유효 설정 `port 20022`, `permitrootlogin no`, `passwordauthentication yes`; 비밀번호 인증 admin 접속 성공, Root 시도 거부. |
| UFW | IPv4·IPv6 활성, inbound deny / outbound allow, TCP 20022·15034만 허용. |
| 계정 | admin/dev/test UID 2001/2002/2003, common GID 2101, core GID 2102. admin/dev는 두 그룹, test는 common만 포함. |
| ACL | 세 계정 shared 읽기·쓰기 성공. admin/dev core 접근 성공; test 키·로그·bin 목록/쓰기/키 링크 읽기 거부. 새 파일의 group·ACL 상속 확인. |
| 재실행·보존 | setup 재실행 및 컨테이너 재생성 전후 키·업로드·로그·증거 SHA-256 모두 일치. |

실행: `docker compose build`, `docker compose up -d`, `docker compose exec -T agent bash /workspace/setup.sh`, `docker compose up -d --force-recreate` 후 setup 재실행.

```text
port 20022
permitrootlogin no
passwordauthentication yes
uid=2001(agent-admin) gid=2001(agent-admin) groups=2001(agent-admin),2101(agent-common),2102(agent-core)
[OK] Password-authenticated SSH session.
root@127.0.0.1: Permission denied (publickey,password).
```

사용자 요청에 따라 검증용 임시 비밀번호를 런타임 메모리에서 생성해 `passwd` 표준입력으로 전달했다. 파일·환경 변수·명령 인자·증거에 값은 저장하지 않았다. SSH 비밀번호 인증 후 계정을 다시 잠갔다. 일반 사용 시 `passwd agent-admin`으로 직접 설정한다.

## 앱·키 경로 호환 예외

`AGENT_HOME=/home/agent-admin/agent-app`, `AGENT_PORT=15034`, `AGENT_UPLOAD_DIR=$AGENT_HOME/upload_files`, `AGENT_LOG_DIR=/var/log/agent-app`으로 일반 계정에서 실행했다.

| 구분 | 설정 | 실제 결과 |
| --- | --- | --- |
| 명세 | `AGENT_KEY_PATH=$AGENT_HOME/api_keys/t_secret.key` | 콘솔 admin 실행에서 2단계 실패, 종료 코드 1. 이후 단계 건너뜀. |
| 선택 설정 | `AGENT_KEY_PATH=$AGENT_HOME/api_keys` | 비밀번호 인증 SSH 세션에서 foreground 실행, Boot 5단계와 READY 성공. |

fixture는 `t_secret.key`에 `agent_api_key_test` 한 줄이며, `secret.key -> t_secret.key` 상대 링크로 내용 중복을 피했다. 앱이 요구하는 디렉토리 경로에 맞춘 **승인된 명세 예외**다. 앱 바이너리·검사는 변경하지 않았다.

```text
[2/5] Verifying Environment Variables     [FAIL]
   >>> Key Path Mismatch. Expected: /home/agent-admin/agent-app/api_keys
System Boot Failed. Process Terminated.

[1/5] Checking User Account               [OK]
[2/5] Verifying Environment Variables     [OK]
[3/5] Checking Required Files             [OK]
[4/5] Checking Port Availability          [OK]
[5/5] Verifying Log Permission            [OK]
All Boot Checks Passed!
Agent READY
```

READY 이후 로그 출력과 리슨 안내가 발생했다. 실제 소켓·실행 파일 확인은 별도 `ss`, `/proc/<pid>/exe`, `ps` 검사로 수행했다.

## 모니터링·잔여 검증

모니터링·회전·cron은 구현 및 검증 중이다. 현재 과제 전체 완료로 선언하지 않는다.

원본 증거는 전용 볼륨의 `/var/lib/agent-evidence/`에 보존한다: `security.log`, `setup-first.log`, `setup-rerun.log`, `setup-recreate.log`, `ssh-login.log`, `root-ssh.log`, `app-file-path.log`, `app-directory-path.log`, `app-listener.log`. ignored 원시 로그는 Git에 추가하지 않는다.
