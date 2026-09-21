#!/bin/sh
# A rock-paper-scissors match between the submission and the staged opponent
# (docs/class-activities.md, "Authoring an activity"). The worker test runs it
# end to end; instructors may copy it as a starting point.
#
# Both players are `strategy.py` files taking the round history as argv and
# printing one of rock / paper / scissors. The submission's copy is in the
# working directory; the bot's is in $CHICKADEE_OPPONENT_DIR. Rounds are
# decided by the players alone; the seed only breaks ties in a stable way, so
# a re-test replays the same result.
set -u
if [ -z "${CHICKADEE_OPPONENT_DIR:-}" ]; then
    echo "no opponent staged: CHICKADEE_OPPONENT_DIR is unset" >&2
    exit 2
fi
if [ -z "${CHICKADEE_MATCH_SEED:-}" ]; then
    echo "no match seed: CHICKADEE_MATCH_SEED is unset" >&2
    exit 2
fi
opponent="$CHICKADEE_OPPONENT_DIR/strategy.py"
if [ ! -f "$opponent" ]; then
    echo "opponent file missing at $opponent" >&2
    exit 2
fi
rounds=5
wins=0
history=""
i=0
while [ "$i" -lt "$rounds" ]; do
    mine=$(python3 strategy.py $history)
    theirs=$(python3 "$opponent" $history)
    case "$mine$theirs" in
        rockscissors|paperrock|scissorspaper) wins=$((wins + 1)) ;;
    esac
    history="$history $mine:$theirs"
    i=$((i + 1))
done
echo "seed=$CHICKADEE_MATCH_SEED rounds=$rounds wins=$wins history=$history" >&2
score=$(python3 -c "print($wins / $rounds)")
echo "{\"score\": $score, \"metric\": $wins, \"shortResult\": \"$wins/$rounds rounds won\"}"
if [ "$wins" -gt 0 ]; then exit 0; else exit 1; fi
