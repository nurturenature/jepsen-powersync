#!/bin/bash
set -o pipefail

# Example: find a Causal Consistency violation
# export SUSPECT_EXIT_CODE=1 
# ./powersync-fuzz-loop.sh ./powersync_fuzz --table mww --clients 10 --rate 10 --time 100 --postgresql --disconnect --no-stop --no-kill --partition --no-pause --interval 5

# set SUSPECT_EXIT_CODE to stop looping in environment, or defaults to 1
SUSPECT_EXIT_CODE=${SUSPECT_EXIT_CODE:-1}

# insure environment is built
./powersync-fuzz-down.sh
./powersync-fuzz-build.sh

echo "looping until exit code >= $SUSPECT_EXIT_CODE"

while true;
do
    # bring up a fresh clean environment
    ./powersync-fuzz-down.sh
    ./powersync-fuzz-up.sh
    
    # fuzz with CLI opts
    echo "fuzzing: $*"
    ./powersync-fuzz-run.sh "$*"
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
