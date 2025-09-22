#!/usr/bin/env infinity-env

module add gaussian

psanitaze frame.${num}.gjf

g16 < frame.${num}.gjf > frame.${num}.log
