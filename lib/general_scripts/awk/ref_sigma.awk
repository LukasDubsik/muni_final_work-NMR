# ref_sigma.awk
# Compute average isotropic shielding for a chosen element from a Gaussian .log
# Usage: awk -v ELEM=H -f ref_sigma.awk tms.log
# Output: one number (average isotropic shielding)

BEGIN {
    elem = toupper(ELEM)
    if (elem == "") elem = "H"
}

# Enter NMR block
/Magnetic shielding tensor/ { inblock = 1 }

# Parse "Isotropic" lines robustly
inblock && /Isotropic/ {
    line = $0
    gsub(/Isotropic=/,  "Isotropic =",  line)
    gsub(/Anisotropy=/, "Anisotropy =", line)

    n = split(line, a, /[[:space:]]+/)
    for (i = 1; i <= n - 3; i++) {
        if (a[i] ~ /^[0-9]+$/ && a[i+1] ~ /^[A-Za-z]{1,2}$/ && a[i+2] == "Isotropic") {
            e = toupper(a[i+1])
            iso = (a[i+3] == "=" ? a[i+4] : a[i+3])
            gsub(/[dD]/, "E", iso)

            if (e == elem) {
                sum += (iso + 0.0)
                cnt += 1
            }
        }
    }
}

# End NMR block on blank line
inblock && /^$/ { inblock = 0 }

END {
    if (cnt < 1) {
        print "ERROR: no isotropic shieldings found for element " elem > "/dev/stderr"
        exit 2
    }
    printf("%.6f\n", sum / cnt)
}
