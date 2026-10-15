# Linux 보안·모니터링 실습

Ubuntu 22.04 ARM64에서 앱을 일반 계정으로 실행하고 Bash·cron으로 상태를 기록한다.

제출물: [수행 내역서](docs/report.md), [monitor.sh](scripts/monitor.sh).

## 실행 가이드

### 1. 빌드·설정

Docker Desktop 실행 및 `agent-app/agent-app-linux-arm64` 준비 후, 호스트의 프로젝트 디렉토리에서 실행한다.

```bash
docker compose build
docker compose up -d
docker compose exec --user root agent bash /workspace/scripts/setup.sh
docker compose exec --user root agent passwd agent-admin
```

비밀번호는 대화형으로 입력한다. setup은 계정·권한·SSH·UFW를 설정하고 admin의 crontab을 과제용 작업으로 교체한다. 컨테이너 재시작 시 앱 실행 전에 setup을 다시 실행하고, 재생성 시 비밀번호도 다시 설정한다.

### 2. SSH 접속·앱 실행

터미널 A에서 접속한다.

```bash
ssh -p 20022 agent-admin@127.0.0.1
```

SSH 로그인 후 실행한다. 환경변수는 setup이 로그인 환경에 등록한다.

```bash
whoami
env | sort | grep '^AGENT_'
"$AGENT_HOME/agent-app-linux-arm64"
```

| 확인 항목 | 기대 결과 |
| --- | --- |
| 실행 계정 | `agent-admin` |
| `AGENT_HOME` | `/home/agent-admin/agent-app` |
| `AGENT_PORT` | `15034` |
| `AGENT_UPLOAD_DIR` | `$AGENT_HOME/upload_files`의 절대 경로 |
| `AGENT_KEY_PATH` | `$AGENT_HOME/api_keys`의 절대 경로 |
| `AGENT_LOG_DIR` | `/var/log/agent-app` |
| Boot 출력 | 5단계 모두 `[OK]`, `Agent READY` |

**키 경로 호환 예외:** 명세의 파일형 `AGENT_KEY_PATH`는 제공 앱이 `Key Path Mismatch`로 거부한다. 승인된 디렉토리형 경로와 `secret.key -> t_secret.key` 상대 링크를 사용한다. 키 파일 내용은 `agent_api_key_test` 한 줄이다.

앱을 foreground로 유지한 채 터미널 B에서 검증한다.

### 3. 검증

#### 보안·계정·권한

터미널 B의 호스트에서 실행한다. `bash` 진입 후 명령은 컨테이너 root로 실행된다.

```bash
docker compose ps
docker compose exec --user root agent bash
/usr/sbin/sshd -t
cat /etc/ssh/sshd_config.d/00-agent.conf
/usr/sbin/sshd -T | grep -E '^(port|permitrootlogin|passwordauthentication) '
ss -ltnp 'sport = :20022'
ufw status verbose
id agent-admin
id agent-dev
id agent-test
ls -ld "$AGENT_HOME" "$AGENT_HOME"/{upload_files,api_keys,bin} /var/log/agent-app
ls -l "$AGENT_HOME/api_keys/" "$AGENT_HOME/bin/monitor.sh"
stat -c '%U:%G %a %n' "$AGENT_HOME/bin/monitor.sh"
getfacl /home/agent-admin "$AGENT_HOME" \
  "$AGENT_HOME"/{upload_files,api_keys,bin} /var/log/agent-app
exit
```

| 명령·대상 | 기대 결과 |
| --- | --- |
| `docker compose ps` | `127.0.0.1`에 TCP `20022`, `15034`만 공개 |
| 설정 파일 조회 | `Port 20022`, `PermitRootLogin no`, `PasswordAuthentication yes` |
| `sshd -t` / `sshd -T` | 오류 없음 / `port 20022`, `permitrootlogin no`, `passwordauthentication yes` |
| `ss` | sshd가 TCP `20022`에서 LISTEN |
| `id` | 세 계정 모두 `agent-common`, admin·dev만 `agent-core` 포함 |
| `ufw status verbose` | `active`, incoming `deny`·outgoing `allow`, TCP `20022`·`15034`만 허용(IPv4·IPv6) |
| `ls -ld` / `ls -l` | 필수 디렉토리 구조·소유자·그룹·권한, `t_secret.key` 및 `secret.key -> t_secret.key` 확인 |
| `stat` | monitor 소유자·그룹·권한: `agent-dev:agent-core 750` |
| `getfacl`: home / AGENT_HOME | common에 경로 통과 `--x`, other 접근 없음 |
| `getfacl`: upload_files | 그룹 `agent-common`, user/group `rwx`, other `---`, setgid·기본 ACL |
| `getfacl`: api_keys·bin·로그 | 그룹 `agent-core`, user/group `rwx`, other `---`, setgid·기본 ACL |

#### 앱·monitor·cron

터미널 B에서 admin으로 접속한다.

```bash
ssh -p 20022 agent-admin@127.0.0.1
```

SSH 로그인 후 monitor를 직접 실행하고 cron 등록 내용을 조회한다. 이후 70초 동안 수동 실행 없이 자동 로그 증가를 확인한다.

```bash
ss -ltnp 'sport = :15034'
"$AGENT_HOME/bin/monitor.sh"
crontab -l
wc -l /var/log/agent-app/monitor.log
sleep 70
wc -l /var/log/agent-app/monitor.log
tail -n 3 /var/log/agent-app/monitor.log
tail -n 3 /var/log/agent-app/cron.log
stat -c '%s %n' /var/log/agent-app/monitor.log
ls -lh /var/log/agent-app/monitor.log*
```

| 명령·대상 | 기대 결과 |
| --- | --- |
| `ss` / cron.log | `0.0.0.0:15034` LISTEN, 리슨 PID와 `[OK] Application PID:... PORT:15034`의 PID 일치 |
| monitor 직접 실행 | 프로세스·포트 `[OK]`, 자원 로그 출력 |
| 자원·경고 | Linux 시스템 CPU·MEM·root DISK_USED 기록. CPU `>20%`, MEM `>10%`, DISK_USED `>80%`일 때 `[WARNING]` 후 기록 지속 |
| UFW 점검 | 비활성·조회 실패 시 경고 후 수집 지속 |
| `crontab -l` | 명시적 PATH와 `* * * * * .../bin/monitor.sh` 작업 1개 |
| `wc -l` / `tail` | 70초 후 행 수 증가, 최신 시각 갱신, cron.log에 자동 실행 결과 기록 |
| `stat` / `ls -lh` | monitor.log 용량 관리: 최대 10MB/10개 파일 유지 |

로그 형식과 보관 기준:

```text
[YYYY-MM-DD HH:MM:SS] PID:... CPU:..% MEM:..% DISK_USED:..%
```

다음 행 포함 10,000,000바이트 초과 전에 회전하며 활성 로그 1개·gzip 최대 9개를 유지한다. 회전이 발생한 경우 행 수 대신 최신 기록 시각으로 자동 실행을 확인한다.

### 4. 종료

터미널 A에서 **Ctrl+C**로 앱을 종료한 후 확인한다.

```bash
ss -ltnp 'sport = :15034'
exit
```

15034 LISTEN 행이 없어야 한다. 터미널 B도 `exit`로 SSH를 종료한다.

호스트에서 컨테이너를 제거한다. 키·데이터·로그 볼륨은 보존된다.

```bash
docker compose down
docker compose ps -a
```

`docker compose ps -a`에 컨테이너 행이 없으면 종료 완료다.

## 계정·그룹·권한

### 계정별 소속 그룹

| 계정 | 기본 그룹 | 추가 그룹 | 역할 |
| --- | --- | --- | --- |
| `agent-admin` | `agent-admin` | `agent-common`, `agent-core` | 앱·monitor·cron 실행 |
| `agent-dev` | `agent-dev` | `agent-common`, `agent-core` | monitor 소유자, 키·로그 관리 |
| `agent-test` | `agent-test` | `agent-common` | 업로드 파일 테스트 |

### 그룹별 접근 권한

`$AGENT_HOME=/home/agent-admin/agent-app` 기준이다. 아래는 그룹 권한이며, 소유자인 계정에는 소유자 권한이 적용된다.

| 그룹 | 경로 | 권한·허용 작업 |
| --- | --- | --- |
| `agent-common` | `/home/agent-admin`, `$AGENT_HOME` | 경로 통과(`--x`), 디렉토리 목록 조회 불가 |
| `agent-common` | `$AGENT_HOME/upload_files` | `2770`: 목록 조회·파일 생성·읽기·쓰기·삭제 |
| `agent-core` | `$AGENT_HOME/api_keys`, `$AGENT_HOME/bin`, `/var/log/agent-app` | `2770`: 목록 조회·파일 생성·삭제·경로 통과 |
| `agent-core` | `api_keys/t_secret.key`, `/var/log/agent-app/monitor.log` | `660`: 읽기·쓰기 |
| `agent-core` | `bin/monitor.sh`, `agent-app-linux-arm64` | `750`: 그룹은 읽기·실행 |

공유 디렉토리의 setgid는 그룹을 상속하고, 기본 ACL은 생성 모드 범위에서 그룹 접근을 유지한다. `agent-test`는 core 전용 경로에 접근할 수 없다.

`monitor.sh`의 소유자는 `agent-dev`로 읽기·쓰기·실행 권한을 가진다. 스크립트 내부 검사는 실행 계정을 `agent-admin`으로 제한한다. admin은 bin 디렉토리에 쓰기 권한이 있어 monitor 파일을 삭제·교체할 수 있다.

sudo 권한은 `agent-admin`의 `/usr/sbin/ufw status` 조회만 허용한다.
