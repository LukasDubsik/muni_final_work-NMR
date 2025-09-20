#!/usr/bin/env infinity-env

module add gaussian

for file in gauss/frame.*.gjf; do
    
    name=$(basename "$file" .gjf)
    g16 < "$file" > nmr/${name}.log

done