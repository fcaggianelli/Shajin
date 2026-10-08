#!/bin/sh
# Esegue tutti i test headless del deathmatch 3D. Exit code != 0 se uno fallisce.
cd "$(dirname "$0")/.." || exit 1
status=0
for t in movement phase1 phase2 phase3 phase4; do
	godot --headless --path . "res://tests/test_$t.tscn" > "/tmp/test_$t.log" 2>&1
	code=$?
	echo "test_$t: $(grep RISULTATO "/tmp/test_$t.log" || echo "nessun risultato") (exit $code, log in /tmp/test_$t.log)"
	[ $code -ne 0 ] && status=1
done
exit $status
