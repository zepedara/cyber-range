#!/bin/bash
# Continuous protocol noise from inside the range segments. Randomised - a metronome is
# itself an unrealistic signature.
DB=10.30.10.12
SYSLOG_COLLECTORS="10.30.5.10 10.30.10.11"
while true; do
  for c in wk01 wk02 wk03 app01 web01; do
    incus info $c >/dev/null 2>&1 || continue
    [ $((RANDOM % 100)) -lt 70 ] && incus exec $c -- timeout 10 mysql -h $DB -u appsvc -pAppSvc2026 corpdb \
        -e "select count(*) from customers;" </dev/null >/dev/null 2>&1
    [ $((RANDOM % 100)) -lt 80 ] && incus exec $c -- bash -c "
        logger -n $(echo $SYSLOG_COLLECTORS | tr ' ' '\n' | shuf -n1) -P 514 -d -t sshd \
          'Accepted publickey for svcuser from 10.30.20.$((RANDOM%254+1)) port $((RANDOM%60000+1024)) ssh2'
        logger -n $(echo $SYSLOG_COLLECTORS | tr ' ' '\n' | shuf -n1) -P 514 -d -t CRON \
          'pam_unix(cron:session): session opened for user root'" </dev/null >/dev/null 2>&1
    [ $((RANDOM % 100)) -lt 50 ] && incus exec $c -- timeout 10 bash -c \
        "echo | openssl s_client -connect 10.30.30.10:443 -no_ticket >/dev/null 2>&1" </dev/null >/dev/null 2>&1
  done
  sleep $((RANDOM % 90 + 45))
done
