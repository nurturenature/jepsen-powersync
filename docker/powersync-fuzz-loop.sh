#!/bin/bash
set -o pipefail

# ./powersync-fuzz-loop.sh ./powersync_fuzz --table mww --clients 10 --rate 10 --time 100 --postgresql --disconnect --no-stop --no-kill --partition --no-pause --interval 5

# insure environment is built
./powersync-fuzz-down.sh
./powersync-fuzz-build.sh

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

    # desired exit code?
    if [ $ec -gt 1 ]; then
        echo "found suspect, exit code $ec > 1, non-monotonic read!"
        echo "leaving docker PowerSync custer up"
        echo "copying powersync_fuzz.log from powersync-fuzz-node container to this host"
        docker cp powersync-fuzz-node:/jepsen/jepsen-powersync/powersync_endpoint/powersync_fuzz.log .

        # leave environment up
        break
    fi

    # try again
done
