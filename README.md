# Linux 보안·모니터링 실습

Ubuntu 22.04 ARM64 컨테이너에서 제공 앱을 일반 계정으로 실행하고 Bash·cron으로 상태와 시스템 자원을 기록한다.

## 준비와 설정

Docker Desktop을 실행하고 `agent-app/agent-app-linux-arm64`를 준비한다. 바이너리는 별도 제공 파일이며 Git에 포함하지 않는다.

```bash
docker info
docker compose build
docker compose up -d
docker compose exec agent bash /workspace/setup.sh
docker compose exec agent passwd agent-admin
ssh -p 20022 agent-admin@127.0.0.1
```

- 호스트 포트는 `127.0.0.1:20022`, `127.0.0.1:15034`만 공개한다. 컨테이너 UFW는 `NET_ADMIN`으로 관리한다.
- `start.sh`는 SSH·cron만 시작한다. setup과 앱 실행은 명시적으로 수행한다.
- admin/dev/test는 common에, admin/dev는 core에도 포함된다. 업로드는 common, 키·로그·monitor는 core 접근으로 제한한다.
- setup 재실행은 기존 데이터·로그를 보존한다. 키·계정·규칙 충돌은 덮어쓰지 않고 중단한다.
- 비밀번호는 런타임에서 직접 입력한다. 검증을 마친 현재 admin 계정은 잠겨 있으므로 사용 전에 위 `passwd` 명령을 실행한다.

## 앱 실행

SSH의 admin 세션에서 환경을 지정한다.

```bash
export AGENT_HOME=/home/agent-admin/agent-app
export AGENT_PORT=15034
export AGENT_UPLOAD_DIR="$AGENT_HOME/upload_files"
export AGENT_KEY_PATH="$AGENT_HOME/api_keys"
export AGENT_LOG_DIR=/var/log/agent-app
```

최초 검증에서는 명세 경로로 먼저 실행하고, 종료·포트 해제 후 선택 설정을 검사한다.

```bash
AGENT_KEY_PATH="$AGENT_HOME/api_keys/t_secret.key" "$AGENT_HOME/agent-app-linux-arm64"
ss -ltn 'sport = :15034'
"$AGENT_HOME/agent-app-linux-arm64"
```

명세의 파일형 키 경로는 실제 앱에서 거부되었다. 선택한 디렉토리형 경로와 `secret.key -> t_secret.key` 상대 링크는 **승인된 호환 예외**다. fixture 내용은 `agent_api_key_test` 한 줄이며 setup에서 생성한다.

Boot 5단계 `[OK]`, `Agent READY`, 로그 초기화와 실제 `0.0.0.0:15034` 리슨을 확인한다. 앱은 foreground에서 실행하고 **Ctrl+C로 종료**한다. 다른 admin 터미널에서 `ss -ltnp 'sport = :15034'`로 확인할 수 있다.

## 모니터링

앱 실행 중 다른 admin 세션에서 확인한다.

```bash
/home/agent-admin/agent-app/bin/monitor.sh
crontab -l
tail -n 5 /var/log/agent-app/monitor.log
```

- 설치된 `monitor.sh`는 `agent-dev:agent-core`, 권한 `750`이며 admin의 cron에서 매분 실행된다. 앱이 종료된 상태에서는 상태 검사 오류가 발생하고 샘플을 추가하지 않는다.
- CPU는 `/proc/stat`의 1초 변화량, 메모리는 `MemTotal`·`MemAvailable`, 디스크는 `df /`로 계산한다. Docker Linux에서 보이는 시스템 전체 값이며 macOS 또는 컨테이너 할당량 기준 사용률이 아니다.
- 경고 기준은 CPU `>20%`, MEM `>10%`, DISK_USED `>80%`다. UFW 비활성·조회 실패와 임계값 경고는 수집을 중단하지 않는다.
- 다음 행으로 10,000,000바이트를 초과하면 압축 회전한다. 활성 로그 1개·압축 로그 최대 9개를 유지하며 앱의 `agent_app.log`는 건드리지 않는다.

```text
[YYYY-MM-DD HH:MM:SS] PID:... CPU:..% MEM:..% DISK_USED:..%
```

## 데이터 보존과 문제 확인

앱 데이터·로그·증거는 전용 named volume에 저장한다. 컨테이너 시작·재시작 후에는 setup을 명시적으로 실행해 방화벽을 적용한다. 재생성 후에는 비밀번호도 다시 설정한다. `docker compose down`은 볼륨을 보존하며, 데이터가 필요하면 `down -v`를 사용하지 않는다.

| 증상 | 확인과 조치 |
| --- | --- |
| Docker 연결 실패 | Docker Desktop 실행 후 `docker context ls`, `docker info` 확인. |
| SSH 연결·인증 실패 | setup 수행 여부, `sshd -t`, `sshd -T`, admin 비밀번호, `docker compose port agent 20022` 확인. |
| 재생성 후 SSH 호스트 키 변경 | 컨테이너의 `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`로 지문을 확인한 뒤 해당 localhost 기록 갱신. |
| UFW 설정 실패 | `NET_ADMIN`, `iptables -L -n`, `ufw status verbose` 확인. privileged 모드로 우회하지 않음. |
| 권한·키 충돌 | `id`, `getfacl`, `readlink`로 확인하고 기존 데이터를 검토한 뒤 충돌 해결. |
| 앱 실행 실패 | 실제 Boot 출력과 `ldd` 결과 확인. 앱을 Root로 실행하거나 검사를 변경하지 않음. |
| cron 기록 없음 | 앱 실행 상태, admin의 `crontab -l`, cron 프로세스와 `/var/lib/agent-evidence/cron.log` 확인. |

4-2를 시작할 때 검증된 Dockerfile을 복사하고 원본 커밋 또는 체크섬을 기록한다. 이미지·컨테이너·볼륨은 별도로 만들고 계정·ACL·cron 전체를 복사하지 않는다.

제출물: [수행 내역서](docs/report.md), [모니터링 소스](monitor.sh).
