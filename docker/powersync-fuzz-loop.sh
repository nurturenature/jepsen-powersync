#!/bin/bash
set -o pipefail

# Example: find a Causal Consistency violation
# export SUSPECT_EXIT_CODE=2
# ./powersync-fuzz-loop.sh ./powersync_fuzz --clients 10 --rate 10 --time 100 --postgresql --disconnect --no-stop --no-kill --partition --no-pause --interval 5

# set SUSPECT_EXIT_CODE to exit code to stop looping, or defaults to 1
SUSPECT_EXIT_CODE=${SUSPECT_EXIT_CODE:-1}

# set TIME_LIMIT, maximum runtime of test, or defaults to 600s
TIME_LIMIT=${TIME_LIMIT:-600s}

# insure environment is built
./powersync-fuzz-down.sh
./powersync-fuzz-build.sh

echo "looping until exit code >= $SUSPECT_EXIT_CODE"
echo "with a test time limit of $TIME_LIMIT"

while true;
do
    # bring up a fresh clean environment
    ./powersync-fuzz-down.sh
    ./powersync-fuzz-up.sh
    
    # fuzz with CLI opts
    echo "fuzzing: $*"
    timeout --verbose "$TIME_LIMIT" ./powersync-fuzz-run.sh "$*"
    ec=$?

    echo "exit code from powersync-fuzz-run.sh: $ec"

    # suspect exit code?
    if [ $ec -ge "$SUSPECT_EXIT_CODE" ]; then
        echo "found suspect, exit code $ec >= $SUSPECT_EXIT_CODE, database state!"
        echo "leaving docker PowerSync custer up"
        echo "copying powersync_fuzz.log from powersync-fuzz-node container to this host"
        docker cp powersync-fuzz-node:/jepsen/jepsen-powersync/powersync_endpoint/powersync_fuzz.log .

        # leave environment up
        break
    fi

# try again
done

exit "$ec"
