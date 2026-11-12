#!/usr/bin/env bash
# Generic stub: log the call, exit with $STUB_EXIT_<name> (default 0).
# STUB_PKG_MISSING lists packages the repositories lack: a package manager's
# "info" or "install" of one of them fails.
name="$(basename "$0")"
printf '%s %s\n' "${name}" "$*" >> "${STUB_LOG:-/dev/null}"
case " $* " in
  *" info "*|*" install "*)
    last="${*: -1}"
    [[ " ${STUB_PKG_MISSING:-} " == *" $last "* ]] && { echo "No match for argument: $last" >&2; exit 1; } ;;
esac
var="STUB_EXIT_${name//[^A-Za-z0-9]/_}"
exit "${!var:-0}"
