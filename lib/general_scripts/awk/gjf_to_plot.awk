BEGIN {
  if (SCALE_M == "") SCALE_M = 1
  if (SCALE_B == "") SCALE_B = 0
}

# Start the block for NMR
/Magnetic shielding tensor/ { inblock=1 }

# Parse shielding records robustly
inblock && /Isotropic/ {
    line = $0
    gsub(/Isotropic=/,  "Isotropic =",  line)
    gsub(/Anisotropy=/, "Anisotropy =", line)

    n = split(line, a, /[[:space:]]+/)
    for (i = 1; i <= n - 3; i++) {
        if (a[i] ~ /^[0-9]+$/ && a[i+1] ~ /^[A-Za-z]{1,2}$/ && a[i+2] == "Isotropic") {
            atom = a[i] + 0
            elem = toupper(a[i+1])
            iso  = (a[i+3] == "=" ? a[i+4] : a[i+3])
            gsub(/[dD]/, "E", iso)

            if (elem == "H" && atom <= LIMIT) {
                delta_calc = SIGMA_REF - (iso + 0)
                delta      = SCALE_M * delta_calc + SCALE_B
                printf("%.6f\t1.0\t%d\n", delta, atom)
            }
        }
    }
}

# End NMR block
inblock && /^$/ { inblock=0 }
