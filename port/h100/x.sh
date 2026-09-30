#!/bin/bash
# x.sh <command...>: run a command in the port's container, in the current
# directory (the x function of common.sh as a standalone command, e.g. for
# TC="bash port/h100/x.sh" in port/tests/run_ref_tests.sh).
source "$(dirname "$0")/common.sh"
x "$@"
