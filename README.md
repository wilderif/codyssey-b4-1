# Linux 보안·모니터링 실습

Ubuntu 22.04 ARM64에서 제공 앱을 일반 계정으로 실행하고 Bash·cron으로 상태와 자원을 기록한다. 제출물은 [수행 내역서](docs/report.md)와 [monitor.sh](scripts/monitor.sh)다.

## 준비

Docker Desktop과 `agent-app/agent-app-linux-arm64`가 필요하다.

```bash
docker compose build
docker compose up -d
docker compose exec agent bash /workspace/scripts/setup.sh
docker compose exec agent passwd agent-admin
ssh -p 20022 agent-admin@127.0.0.1
```

- [start.sh](scripts/start.sh)는 SSH·cron만 시작한다. 재시작·재생성 후에는 [setup.sh](scripts/setup.sh)를 다시 실행한다. 비밀번호는 대화형으로 설정하며 재생성 후 다시 설정한다.
- SSH는 20022이며 Root 로그인을 차단한다. UFW는 TCP 20022·15034만 허용하고, 호스트에는 두 포트를 localhost로만 공개한다. UFW 적용에 `NET_ADMIN`을 사용한다.
- 세 계정 모두 `agent-common`, admin/dev만 `agent-core`에 속한다. 업로드는 common, 키·로그·monitor는 core 접근으로 제한하며 setgid·기본 ACL로 그룹 접근을 유지한다.
- 데이터·로그는 전용 named volume `app_data`·`app_logs`에 저장한다. setup은 기존 키·로그를 보존하며 키 충돌 시 중단한다. `docker compose down`은 볼륨을 보존하고, `down -v`는 삭제한다.

## 앱 실행

환경변수 다섯 개는 [compose.yaml](compose.yaml)의 `environment`에서 관리한다. setup은 이 값을 `/etc/profile.d/agent-app.sh`에 기록해 `agent-admin`의 SSH 로그인 시 적용한다. 값을 변경하면 `docker compose up -d`로 컨테이너를 재생성하고 setup을 다시 실행한 뒤 SSH에 새로 접속한다.

SSH의 `agent-admin` 세션에서 별도 `export` 없이 실행하고 **Ctrl+C**로 종료한다.

```bash
"$AGENT_HOME/agent-app-linux-arm64"
```

명세의 파일형 `AGENT_KEY_PATH=$AGENT_HOME/api_keys/t_secret.key`는 앱이 `Key Path Mismatch`로 거부했다. 디렉토리형 설정과 `secret.key -> t_secret.key` 상대 링크는 **승인된 호환 예외**다. 키 내용은 `agent_api_key_test` 한 줄이다.

Boot 5단계 `[OK]`, `Agent READY`, 로그 초기화와 `0.0.0.0:15034` 리슨을 확인한다.

## 모니터링

앱 실행 중 다른 admin 세션에서 확인한다.

```bash
ss -ltnp 'sport = :15034'
/home/agent-admin/agent-app/bin/monitor.sh
crontab -l
tail -n 5 /var/log/agent-app/monitor.log
```

- monitor는 `agent-dev:agent-core`, 권한 `750`이며 admin의 cron에서 매분 실행된다. 리슨 PID의 실행 파일·계정을 확인하고 앱·포트 이상이면 종료 코드 1을 반환한다.
- CPU는 `vmstat 1 2`의 두 번째 표본에서 `100-idle`, 메모리는 `(MemTotal-MemAvailable)/MemTotal`, 디스크는 `df -P /`로 수집한다. 컨테이너에서 보이는 Docker Linux 시스템 기준이다.
- CPU `>20%`, MEM `>10%`, DISK_USED `>80%`이면 경고한다. 임계값 초과와 UFW 비활성·조회 실패는 수집을 중단하지 않는다.
- 다음 행으로 10,000,000바이트를 초과하면 Bash에서 압축·회전한다. 활성 `monitor.log`와 `.1.gz`~`.9.gz`까지 최대 열 개를 유지하며 앱 로그는 변경하지 않는다.
- cron 오류는 `/var/log/agent-app/cron.log`에서 확인한다. 로그가 늘지 않으면 앱 실행 상태와 admin crontab을 확인한다.

```text
[YYYY-MM-DD HH:MM:SS] PID:... CPU:..% MEM:..% DISK_USED:..%
```

4-2에서는 검증된 Dockerfile만 재사용하고 이미지·계정·모니터링·볼륨을 분리한다.
