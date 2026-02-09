# shellcheck disable=SC2148
# Guard so we don't load twice
[[ ${_LOGGING_SH_LOADED:-0} -eq 1 ]] && return
_LOGGING_SH_LOADED=1

# --------------------------------------------------------------------
# DEPRECATED (2026-02): Central log-based resume has been removed.
# The pipeline now resumes using per-step output validation + .ok stamps
# in each step directory (see utilities.sh: mark_step_ok/step_is_ok).
#
# This file is kept only for backwards compatibility; the functions are
# now no-ops so older scripts don't crash if they still source logging.sh.
# --------------------------------------------------------------------

read_log() { LOG_POSITION=0; }
add_to_log() { :; }
remove_run_log() { :; }