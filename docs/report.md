# 요구사항 수행 내역

검증 환경: Ubuntu 22.04.5 LTS · ARM64 · Docker. 로그 날짜·시각은 마스킹했다. Bash 문법 검사, Compose 설정 검사, 이미지 빌드와 setup 실행을 통과했다. 설정은 컨테이너 root로, 앱·monitor·cron은 `agent-admin`으로 확인했다. SSH 접속에는 임시 키 인증을 사용했다.

## 1. SSH 포트 변경 및 Root 원격 접속 차단

```bash
/usr/sbin/sshd -t
/usr/sbin/sshd -T | grep -E '^(port|permitrootlogin|passwordauthentication) '
ss -ltnp 'sport = :20022'
```

`sshd -t` 종료 코드 0. 유효 설정과 리슨 상태:

```text
port 20022
permitrootlogin no
passwordauthentication yes
LISTEN 0 128 0.0.0.0:20022 0.0.0.0:* users:(("sshd",pid=1,fd=3))
LISTEN 0 128 [::]:20022    [::]:*    users:(("sshd",pid=1,fd=4))
```

호스트 공개 주소: `127.0.0.1:20022`, `127.0.0.1:15034`.

## 2. 방화벽 활성화 및 허용 포트

`ufw status verbose` 결과:

```text
Status: active
Default: deny (incoming), allow (outgoing), deny (routed)

20022/tcp                  ALLOW IN    Anywhere
15034/tcp                  ALLOW IN    Anywhere
20022/tcp (v6)             ALLOW IN    Anywhere (v6)
15034/tcp (v6)             ALLOW IN    Anywhere (v6)
```

`agent-admin`의 sudo 허용 명령은 `/usr/sbin/ufw status`뿐이다. 상태 조회는 성공했고 `sudo -n /usr/sbin/ufw disable`은 거부됐다.

## 3. 계정·그룹 생성

`id agent-admin`, `id agent-dev`, `id agent-test` 결과:

```text
uid=2001(agent-admin) gid=2001(agent-admin) groups=2001(agent-admin),2101(agent-common),2102(agent-core)
uid=2002(agent-dev) gid=2002(agent-dev) groups=2002(agent-dev),2101(agent-common),2102(agent-core)
uid=2003(agent-test) gid=2003(agent-test) groups=2003(agent-test),2101(agent-common)
```

`getent group agent-common agent-core` 결과:

```text
agent-common:x:2101:agent-admin,agent-dev,agent-test
agent-core:x:2102:agent-admin,agent-dev
```

## 4. 디렉토리 구조·권한·ACL

`stat -c '%U:%G %a %n'`과 `getfacl`로 확인했다. `$AGENT_HOME=/home/agent-admin/agent-app`이다.

| 경로 | 소유자:그룹 | 권한 |
| --- | --- | --- |
| `$AGENT_HOME` | agent-admin:agent-common | 710 |
| `$AGENT_HOME/upload_files` | agent-admin:agent-common | 2770 |
| `$AGENT_HOME/api_keys` | agent-admin:agent-core | 2770 |
| `$AGENT_HOME/bin` | agent-admin:agent-core | 2770 |
| `/var/log/agent-app` | agent-admin:agent-core | 2770 |
| `$AGENT_HOME/api_keys/t_secret.key` | agent-admin:agent-core | 660 |
| `/var/log/agent-app/monitor.log` | agent-admin:agent-core | 660 |
| `$AGENT_HOME/bin/monitor.sh` | agent-dev:agent-core | 750 |

`/home/agent-admin`의 경로 통과 ACL:

```text
user::rwx
group::---
group:agent-common:--x
mask::--x
other::---
```

`upload_files`, `api_keys`, `bin`, `/var/log/agent-app`의 공통 ACL(setgid 적용):

```text
user::rwx
group::rwx
other::---
default:user::rwx
default:group::rwx
default:mask::rwx
default:other::---
```

`runuser -u <계정> -- ...`으로 일반 계정 권한을 확인했다.

| 작업 | admin | dev | test |
| --- | --- | --- | --- |
| upload_files 파일 생성·읽기·삭제 | 성공 | 성공 | 성공 |
| api_keys·bin·로그 디렉토리 파일 생성·읽기·삭제 | 성공 | 성공 | 거부 |

새 업로드 파일은 `agent-common:660`을 상속했다. test의 monitor 실행도 `Permission denied`로 거부됐다.

## 5. 앱 Boot Sequence 및 Agent READY

SSH 로그인에서 `whoami`는 `agent-admin`, 환경변수는 다음과 같았다.

```text
AGENT_HOME=/home/agent-admin/agent-app
AGENT_PORT=15034
AGENT_UPLOAD_DIR=/home/agent-admin/agent-app/upload_files
AGENT_KEY_PATH=/home/agent-admin/agent-app/api_keys
AGENT_LOG_DIR=/var/log/agent-app
```

명세의 파일형 `AGENT_KEY_PATH=$AGENT_HOME/api_keys/t_secret.key`는 `Key Path Mismatch`로 종료 코드 1이었다. 승인된 호환 예외로 디렉토리형 경로와 상대 링크 `secret.key -> t_secret.key`를 사용했다. 키 내용은 `agent_api_key_test` 한 줄이다.

`"$AGENT_HOME/agent-app-linux-arm64"` foreground 실행 결과:

```text
[1/5] Checking User Account               [OK]
[2/5] Verifying Environment Variables     [OK]
[3/5] Checking Required Files             [OK]
[4/5] Checking Port Availability          [OK]
[5/5] Verifying Log Permission            [OK]
All Boot Checks Passed!
Agent READY
```

`ss -ltnp 'sport = :15034'` 결과:

```text
LISTEN 0 1 0.0.0.0:15034 0.0.0.0:* users:(("agent-app-linux",pid=407,fd=4))
```

`/var/log/agent-app/agent_app.log` 생성·기록과 제공 원본·설치 파일의 SHA-256 일치를 확인했다.

## 6. monitor.sh 실행 결과

`agent-admin`으로 `"$AGENT_HOME/bin/monitor.sh"` 실행, 종료 코드 0:

```text
[OK] Application PID:407 PORT:15034
[WARNING] MEM 10.07% > 10%
[YYYY-MM-DD HH:MM:SS] PID:407 CPU:2.00% MEM:10.07% DISK_USED:2%
```

CPU는 `vmstat 1 2`의 두 번째 표본, MEM은 `/proc/meminfo`의 MemTotal·MemAvailable, DISK는 `df -P /`로 수집한다. 측정 범위는 컨테이너에서 보이는 Linux 시스템이다.

| 검증 | 결과 |
| --- | --- |
| 정상 앱 | 리슨 PID·실행 파일·계정 확인, 자원 기록, 종료 코드 0 |
| UFW 비활성 | `[WARNING] UFW is inactive.`, 기록 지속, 종료 코드 0 |
| UFW 조회 권한 임시 제거 | `[WARNING] Cannot query UFW: sudo: a password is required`, 기록 지속, 종료 코드 0 |
| Ctrl+C로 앱 종료 | 15034 리슨 해제, `[ERROR] Application port 15034 is not listening.`, 종료 코드 1 |
| 경고 경계 | CPU 20·MEM 10·DISK 80에서 경고 없음, 각각 +0.01에서 경고 |
| 로그 회전 경계 | 다음 행 포함 10,000,000바이트까지 유지, 초과 시 gzip 회전 |
| 로그 보관 개수 | 13회 회전 후 활성 1개·gzip 9개, gzip 무결성 검사 통과 |

UFW와 조회 권한은 시험 후 복구했다. 경고 경계·로그 회전은 현재 monitor 함수를 임시 파일에서 검증했으며, 실제 monitor·앱 로그는 회전 시험에 사용하지 않았다.

## 7. monitor.log 누적 기록

`tail -n 3 /var/log/agent-app/monitor.log` 결과:

```text
[YYYY-MM-DD HH:MM:SS] PID:407 CPU:2.00% MEM:11.35% DISK_USED:2%
[YYYY-MM-DD HH:MM:SS] PID:407 CPU:2.00% MEM:11.42% DISK_USED:2%
[YYYY-MM-DD HH:MM:SS] PID:407 CPU:3.00% MEM:10.44% DISK_USED:2%
```

## 8. crontab 매분 등록 및 자동 실행

`agent-admin`의 `crontab -l` 결과:

```cron
PATH=/usr/sbin:/usr/bin:/sbin:/bin
* * * * * /home/agent-admin/agent-app/bin/monitor.sh >> /var/log/agent-app/cron.log 2>&1
```

앱 실행 중 수동 monitor 실행 없이 60초 대기했다.

| 확인 시점 | monitor.log 행 수 |
| --- | --- |
| 대기 전 | 1 |
| 60초 후 | 2 |

자동으로 추가된 monitor.log와 동일 시각의 cron.log 기록:

```text
[OK] Application PID:407 PORT:15034
[WARNING] MEM 12.63% > 10%
[YYYY-MM-DD HH:MM:SS] PID:407 CPU:2.00% MEM:12.63% DISK_USED:2%
```
