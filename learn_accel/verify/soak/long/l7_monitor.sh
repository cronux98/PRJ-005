#!/bin/bash
# l7_monitor.sh — L7 soak monitor: watches wave-1 seeds; when all finish,
# launches wave-2; logs a heartbeat status. Run setsid-backgrounded.
cd /home/smdadmin/PRJ-005/verify/soak/long
WAVE1="1 3 4 6"
WAVE2="7 8 9 12"
BIG=21
while true; do
  alive=0
  for s in $WAVE1 $BIG; do
    if pgrep -f "l7_long +seed=$s " >/dev/null 2>&1 || pgrep -f "l7_big +seed=$s " >/dev/null 2>&1; then
      alive=$((alive+1))
    fi
  done
  echo "$(date -u +%H:%M:%S) wave1+big alive=$alive" >> monitor.log
  if [ "$alive" -eq 0 ]; then
    # wave 1 + big done: launch wave 2 if not already launched
    if [ ! -f .wave2_launched ]; then
      touch .wave2_launched
      for s in $WAVE2; do
        setsid nohup bash -c "timeout 10800 stdbuf -oL -eL /tmp/l7_long +seed=$s +target=600000 +maxcyc=70000000 > seed_$s.log 2>&1" >/dev/null 2>&1 &
      done
      echo "$(date -u +%H:%M:%S) wave2 launched" >> monitor.log
    else
      # wave 2 done too: exit
      a2=0
      for s in $WAVE2; do pgrep -f "l7_long +seed=$s " >/dev/null 2>&1 && a2=1; done
      if [ "$a2" -eq 0 ]; then
        echo "$(date -u +%H:%M:%S) ALL WAVES DONE" >> monitor.log
        exit 0
      fi
    fi
  fi
  sleep 300
done
