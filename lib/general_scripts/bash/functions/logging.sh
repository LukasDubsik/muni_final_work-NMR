# shellcheck disable=SC2148
# Guard so we don't load twice
[[ ${_LOGGING_SH_LOADED:-0} -eq 1 ]] && return
_LOGGING_SH_LOADED=1

