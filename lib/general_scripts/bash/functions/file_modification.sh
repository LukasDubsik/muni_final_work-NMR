# shellcheck disable=SC2148
# Guard so we don't load twice
[[ ${_FILE_NMODIFICATION_SH_LOADED:-0} -eq 1 ]] && return
_FILE_NMODIFICATION_SH_LOADED=1

