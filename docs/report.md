# 요구사항 수행 내역

간소화한 `scripts/`와 named volume 환경에서 실행한 검증 결과다. 설정은 README의 build·up·setup 명령으로 적용했다. Bash 문법·Compose 설정·이미지 빌드 검사를 통과했다.

## 환경·보안·권한

| 항목 | 실행 결과 |
| --- | --- |
| 환경 | Ubuntu 22.04.5 LTS, `aarch64`. 설치 앱 `750`, `ldd` 의존성 해결. 제공 바이너리 원본은 변경하지 않음. |
| 저장소 | `codyssey-b4-1_app_data`·`codyssey-b4-1_app_logs`. 스크립트·제공 바이너리만 읽기 전용 마운트. |
| SSH | `sshd -t` 성공, 유효 설정은 아래 출력과 같음. 20022 리슨, admin 비밀번호 로그인 성공, 유효한 임시 비밀번호를 사용한 Root 로그인 거부. |
| UFW | 활성, 기본 inbound deny/outbound allow. TCP 20022·15034만 허용(IPv4·IPv6). |
| 그룹 | `id`에서 admin/dev/test 모두 `agent-common`, admin/dev만 `agent-core` 확인. |

`sshd -T`와 `ufw status` 출력:

```text
port 20022
permitrootlogin no
passwordauthentication yes
Status: active
20022/tcp                  ALLOW IN    Anywhere
15034/tcp                  ALLOW IN    Anywhere
20022/tcp (v6)             ALLOW IN    Anywhere (v6)
15034/tcp (v6)             ALLOW IN    Anywhere (v6)
```

`stat`·`getfacl`로 확인한 디렉토리 정책이다. `$AGENT_HOME=/home/agent-admin/agent-app`이며 디렉토리 소유자는 `agent-admin`이다.

| 경로 | 그룹·권한·ACL |
| --- | --- |
| `/home/agent-admin` | `agent-admin`, 소유자 `rwx`; common에는 traversal `--x` ACL만 허용. ACL mask `--x`. |
| `$AGENT_HOME` | `agent-common`, `710`. |
| `$AGENT_HOME/upload_files` | `agent-common`, `2770`. |
| `$AGENT_HOME/api_keys`, `$AGENT_HOME/bin`, `/var/log/agent-app` | `agent-core`, `2770`. |
| `$AGENT_HOME/bin/monitor.sh` | `agent-dev:agent-core`, `750`. |

`2770` 디렉토리의 기본 ACL은 user/group/mask `rwx`, other `---`다. `runuser`로 파일 생성·읽기·삭제를 검증했다. 세 계정의 업로드 접근, admin/dev의 키·로그 접근은 성공했고 test의 키 링크 읽기·로그 목록·monitor 실행은 거부됐다. 새 공유 파일은 common `660`, 하위 디렉토리는 common `2770`을 상속했다.

## 앱 실행·키 경로 예외

일반 계정에 README의 환경 변수 다섯 개를 지정했다. 명세의 파일형 `AGENT_KEY_PATH=$AGENT_HOME/api_keys/t_secret.key`로 먼저 실행한 결과는 종료 코드 1이었다.

```text
[1/5] Checking User Account               [OK]
[2/5] Verifying Environment Variables     [FAIL]
   >>> Key Path Mismatch. Expected: /home/agent-admin/agent-app/api_keys
System Boot Failed. Process Terminated.
```

승인된 디렉토리형 `AGENT_KEY_PATH=$AGENT_HOME/api_keys`로 별도 실행한 출력:

```text
[1/5] Checking User Account               [OK]
[2/5] Verifying Environment Variables     [OK]
[3/5] Checking Required Files             [OK]
[4/5] Checking Port Availability          [OK]
[5/5] Verifying Log Permission            [OK]
All Boot Checks Passed!
Agent READY
```

`t_secret.key` 내용은 `cmp`로 `agent_api_key_test` 한 줄과 일치함을 확인했고, `readlink secret.key`는 `t_secret.key`였다. 디렉토리형 경로와 상대 링크는 **명세 호환 예외**다.

Docker TTY에서 `agent-admin` foreground 실행 후 `agent_app.log` 초기화와 `ss`의 `0.0.0.0:15034`, PID `1504`를 확인했다. 컨테이너 내부 SSH 클라이언트의 비밀번호 로그인에서도 Boot 5단계·READY·리슨 PID `389`를 확인했다. 두 실행 모두 Ctrl+C 후 포트가 해제됐다. 호스트 공개 포트는 `docker compose port`로 localhost 20022·15034를 별도 확인했다.

## 모니터링·로그 회전

실행: `docker compose exec -T -u agent-admin agent /home/agent-admin/agent-app/bin/monitor.sh`.

| 검사 | 결과 |
| --- | --- |
| 정상 앱 | 리슨 PID의 실행 파일·계정 확인, 자원 수집·기록 성공. |
| 앱 중지·다른 리스너 | 포트 미리슨 및 netcat 리스너를 각각 거부, 종료 코드 1. |
| UFW 비활성·조회 실패 | 각각 `[WARNING]` 후 기록 성공. 시험 후 UFW·sudo 조회 권한 복구. |
| 경고 경계 | CPU 20·MEM 10·DISK 80에서 경고 없음, 각 값에 0.01을 더하면 경고. |
| 회전 크기 | 다음 행을 포함해 10,000,000바이트까지 유지, 초과 시 압축·회전. |
| 보존·압축 | 13회 회전 후 활성 1개·gzip 9개, 압축 무결성·core `660` 확인. 앱 로그 유지. |
| 압축 실패 | 오류·비정상 종료, 활성 로그 체크섬 유지. |

CPU는 `vmstat 1 2`의 두 번째 표본에서 `100-idle`, 메모리는 `(MemTotal-MemAvailable)/MemTotal`, 디스크는 `df -P /`다. 컨테이너에서 보이는 Docker Linux 시스템 값이며 CPU는 정수 백분율로 수집한다.

실제 정상 실행·메모리 경고 출력:

```text
[OK] Application PID:1504 PORT:15034
[WARNING] MEM 10.47% > 10%
[2026-10-10 23:54:22] PID:1504 CPU:3.00% MEM:10.47% DISK_USED:2%
```

회전·압축 실패·임계값 경계는 admin의 임시 디렉토리에서 실제 스크립트 함수를 사용해 검증했다. 실제 앱·monitor 로그는 시험에 사용하지 않았고, 실제 CPU·디스크 초과 경고는 발생시키지 않았다.

## Cron·데이터 보존

`crontab -u agent-admin -l` 등록 결과:

```cron
* * * * * umask 0007; PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin /home/agent-admin/agent-app/bin/monitor.sh >> /var/log/agent-app/cron.log 2>&1
```

`cron.log`·`monitor.log`에서 자동 실행을 확인했다. 아래 첫 두 행은 1분 간격 자동 샘플이고 마지막 행은 SSH 실행의 수동 샘플이다. 시각은 컨테이너의 UTC다.

```text
[2026-10-10 23:54:02] PID:1504 CPU:2.00% MEM:9.43% DISK_USED:2%
[2026-10-10 23:55:02] PID:1504 CPU:0.00% MEM:10.99% DISK_USED:2%
[2026-10-10 23:58:45] PID:389 CPU:0.00% MEM:8.80% DISK_USED:2%
```

setup 재실행 전후 키·monitor 로그 체크섬과 crontab이 일치했다. `docker compose up -d --force-recreate` 후 setup을 실행해 키·로그 보존과 monitor 권한·UFW·cron 재설정을 확인했다.

검증 후 앱은 종료했고 UFW는 활성 상태다. SSH 시험용 비밀번호는 저장하지 않았으며 admin·Root 계정을 다시 잠갔다. 사용 시 README에 따라 admin 비밀번호를 설정한다. 원본 로그는 `app_logs` 볼륨에 남아 있고 로컬 증거 사본은 사용자 요청으로 삭제했다.
