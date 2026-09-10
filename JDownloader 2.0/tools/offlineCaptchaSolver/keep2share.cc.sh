#!/bin/sh
cd "$(dirname "$0")" || exit 1

./checkdeps.sh || exit 1

file="${2:-result.txt}"
[ -e "$file" ] && rm -f "$file"

# Run solver in background and track PID
node ./ocr.js keep2share.cc "$@" > solver.log 2>&1 &
node_pid=$!

# Wait up to 30s with subsecond polling (0.1s)
timeout_tenths=300
elapsed_tenths=0

while [ ! -e "$file" ] && [ "$elapsed_tenths" -lt "$timeout_tenths" ]; do
    if ! kill -0 "$node_pid" 2>/dev/null; then
        # Node process exited
        break
    fi
    sleep 0.1
    elapsed_tenths=$((elapsed_tenths + 1))
done

if kill -0 "$node_pid" 2>/dev/null; then
    kill -9 "$node_pid" 2>/dev/null
    node_exit_code=124
else
    wait "$node_pid" 2>/dev/null
    node_exit_code=$?
fi

if [ "$node_exit_code" -ne 0 ] || [ ! -e "$file" ] || [ ! -s "$file" ]; then
    [ -e "$file" ] && rm -f "$file"
    echo "ERROR: Captcha solver failed (exit code: $node_exit_code) or solving impossible" >> solver.log
    exit 1
fi

exit 0
