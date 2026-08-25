#!/bin/bash
# l7_watch.sh — robust L7 monitor (checks the vvp children, not the bash
# wrappers). Logs progress; launches wave 2 when wave 1 completes; exits
# when all 8 seeds are done.
cd /home/smdadmin/PRJ-005/verify/soak/long
WAVE1="1 3 4 6"
WAVE2="7 8 9 12"
while true; do
  W1_ALIVE=0; W2_ALIVE=0
  for s in $WAVE1; do ps aux | grep "[v]vp /tmp/l7_long" | grep -q "+seed=$s " && W1_ALIVE=1; done
  for s in $WAVE2; do ps aux | grep "[v]vp /tmp/l7_long" | grep -q "+seed=$s " && W2_ALIVE=1; done
  echo "$(date -u +%H:%M:%S) wave1_alive=$W1_ALIVE wave2_alive=$W2_ALIVE" >> watch.log
  if [ "$W1_ALIVE" -eq 0 ] && [ "$W2_ALIVE" -eq 0 ]; then
    # wave 1 done and wave 2 not running: launch it (once)
    if [ ! -f .w2 ]; then
      touch .w2
      for s in $WAVE2; do
        setsid nohup bash -c "timeout 10800 stdbuf -oL -eL /tmp/l7_long +seed=$s +target=300000 +maxcyc=35000000 > seed_$s.log 2>&1" >/dev/null 2>&1 &
      done
      echo "$(date -u +%H:%M:%S) wave2 launched" >> watch.log
    else
      echo "$(date -u +%H:%M:%S) ALL DONE" >> watch.log
      exit 0
    fi
  fi
  sleep 600
done
