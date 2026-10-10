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
| 호스트 매핑 | `docker compose port` 결과 `127.0.0.1:20022`, `127.0.0.1:15034`. 컨테이너 UFW와 별도로 확인. |

실행: `docker compose build`, `docker compose up -d`, `docker compose exec -T agent bash /workspace/setup.sh`, `docker compose up -d --force-recreate` 후 setup 재실행.

```text
port 20022
permitrootlogin no
passwordauthentication yes
uid=2001(agent-admin) gid=2001(agent-admin) groups=2001(agent-admin),2101(agent-common),2102(agent-core)
[OK] Password-authenticated SSH session.
root@127.0.0.1: Permission denied (publickey,password).
```

컨테이너 내 SSH에서 admin 비밀번호 인증을 검증했다. 사용자 요청에 따라 임시 비밀번호를 런타임 메모리에서 생성해 `passwd` 표준입력으로 전달했고, 파일·환경 변수·명령 인자·증거에 값은 저장하지 않았다. 인증 후 계정을 다시 잠갔다. 일반 사용 시 `passwd agent-admin`으로 직접 설정한다.

디렉토리 확인은 `getfacl`, 권한 검증은 각 계정의 `runuser`로 수행했다.

```text
upload_files: agent-admin:agent-common 2770
api_keys / bin / /var/log/agent-app: agent-admin:agent-core 2770
상위 home·app: group:agent-common:--x, mask::--x, other::---
디렉토리 ACL: group::rwx, mask::rwx, other::---
기본 ACL: default:group::rwx, default:mask::rwx, default:other::---
cat: /home/agent-admin/agent-app/api_keys/secret.key: Permission denied
```

설정 재실행 후 키·monitor.log 내용과 crontab이 유지되고 관리 항목은 한 개였다. 임시 앱 경로로 설정 스크립트를 검사해 다른 키 내용·잘못된 링크·추가 ACL을 거부했으며, 계정·SSH·UFW·cron 파일의 체크섬은 유지되었다.

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

READY 이후 `agent_app.log` 생성·로그 출력과 리슨 안내가 발생했다. `ss`, `/proc/<pid>/exe`, `ps`로 실제 소켓과 부모·자식을 별도 확인했다.

```text
LISTEN 0 1 0.0.0.0:15034 0.0.0.0:* users:(("agent-app-linux",pid=454,fd=4))
PID 453 PPID 452 USER agent-admin EXE /home/agent-admin/agent-app/agent-app-linux-arm64
PID 454 PPID 453 USER agent-admin EXE /home/agent-admin/agent-app/agent-app-linux-arm64
agent-admin:agent-core 660 /var/log/agent-app/agent_app.log
```

TTY 없는 Docker 접속에서 로컬 Ctrl+C가 SSH 클라이언트만 종료해 남은 앱은 admin의 SIGINT로 정리했다. TTY를 할당해 SSH 실행을 다시 검사한 결과 실제 Ctrl+C 정상 종료와 포트 해제를 확인했다. 최종 앱은 종료 상태이고 UFW는 활성 상태다.

## 모니터링·로그·cron

설치본을 admin으로 실행했다. 파일은 `agent-dev:agent-core 750`, 로그는 `agent-admin:agent-core 660`이다.

| 검사 | 실제 결과 |
| --- | --- |
| 프로세스·포트 | 실제 리슨 PID의 설치 경로·admin 소유자 확인. 종료된 앱은 exit 1, 같은 계정의 netcat 리스너도 실행 파일 불일치로 exit 1. |
| 리슨 없는 상태 | 실제 앱 실행 중 `ss`의 빈 출력을 일회성 Bash 함수로 모의 입력해 exit 1 확인. |
| UFW | 실제 비활성화 시 경고 후 기록 성공, 즉시 재활성화. 조회 실패는 모의 입력으로 별도 경고·계속 수행 확인. |
| 자원·임계값 | Linux 전체 CPU·메모리와 `/` 사용률 수집. 실제 MEM 초과 경고 확인. 통제된 입력에서 임계값과 동일하면 경고 없음, 0.01 초과하면 경고. |
| 회전·압축 | 임시 디렉토리에서 정확히 10,000,000바이트일 때 유지, 다음 행으로 초과할 때 회전. 압축 검증·최대 10개·core 권한·앱 로그 보존 확인. |
| 실패·동시 실행 | 압축 실패 시 활성 로그 보존, 기록·보존 파일 목록 조회 실패 시 비정상 종료. 동시 실행 2건 성공, 잠금 시간 초과는 실패. |
| cron | admin crontab 매분 등록. 수동 모니터링 없는 1분 관찰에서 로그 7행 → 8행 증가. |

CPU는 `/proc/stat`의 1초 변화량에서 idle·iowait를 제외하고 guest 중복을 피했다. 메모리는 `(MemTotal-MemAvailable)/MemTotal`, 디스크는 `df -P /`를 사용했다. 측정값은 컨테이너에서 보이는 Docker Linux 시스템 기준이며 macOS·컨테이너 quota 기준이 아니다.

```text
[OK] PID:454 PPID:453 EXE:/home/agent-admin/agent-app/agent-app-linux-arm64 USER:agent-admin PORT:0.0.0.0:15034
[WARNING] UFW inactive
[WARNING] MEM 12.16% > 10%
[OK] Monitoring sample appended
[ERROR] PID 7034 is not the installed application.
Before lines: 7
After lines: 8
```

cron 등록 내용을 축약하면 다음과 같다. 전체 PATH·필수 환경 변수는 원본의 같은 행에 명시했다.

```text
* * * * * PATH=... AGENT_HOME=... AGENT_PORT=15034 AGENT_UPLOAD_DIR=... AGENT_KEY_PATH=... AGENT_LOG_DIR=/var/log/agent-app /home/agent-admin/agent-app/bin/monitor.sh >> /var/lib/agent-evidence/cron.log 2>&1
```

최근 실제 로그는 날짜를 제외하고 표시한다. 원본은 지정된 `[YYYY-MM-DD HH:MM:SS]` 형식으로 보존한다.

```text
[timestamp] PID:454 CPU:2.25% MEM:11.13% DISK_USED:2%
[timestamp] PID:454 CPU:0.25% MEM:9.67% DISK_USED:2%
[timestamp] PID:7100 CPU:1.41% MEM:10.26% DISK_USED:2%
```

## 증거와 검증 범위

원본 증거는 전용 볼륨의 `/var/lib/agent-evidence/`에 보존하며 ignored 로그는 Git에 추가하지 않는다.

| 증거 파일 | 확인 내용 |
| --- | --- |
| `security.log`, `ssh-login.log`, `root-ssh.log` | SSH·UFW·그룹·ACL·일반 계정 접근과 인증 |
| `setup-first.log`, `setup-rerun.log`, `setup-recreate.log`, `setup-conflicts.log` | 설정·재실행·볼륨 보존·충돌 거부 |
| `app-file-path.log`, `app-directory-path.log`, `app-listener.log`, `app-tty-stop.log` | 두 키 경로·Boot·로그·리슨·Ctrl+C 종료 |
| `monitor-functions.log`, `monitor-operational.log`, `monitor-stopped.log`, `unrelated-listener.log` | 경고·계산·회전·잠금·상태 검사 실패 |
| `cron-before.txt`, `cron-after.txt`, `cron-observation.log`, `cron.log` | 중복 없는 매분 등록·자동 실행·최근 로그 |

예: `docker compose exec agent cat /var/lib/agent-evidence/cron-observation.log`.

필수 운영 검증은 수행했다. 리슨 없는 상태·UFW 조회 실패·임계값 경계·일부 기록 실패는 모의 입력이고, 대용량 회전은 임시 디렉토리에서 검증했다. 운영 로그를 실제로 10MB까지 누적한 결과로 주장하지 않는다. `bash -n`과 `git diff --check`로 소스도 확인했다. 키 경로 예외와 위 검증 조건을 전제로 제출하며 4-2 실행 검증은 포함하지 않는다.
