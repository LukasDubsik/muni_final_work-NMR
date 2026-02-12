# Start the block for NMR (do NOT `next` — some logs put the first record on the same line)
/Magnetic shielding tensor/ { inblock=1 }
BEGIN {
    if (A == "") A = 1.0
    if (B == "") B = 0.0
}
# Parse shielding records robustly (Gaussian formatting varies: "Isotropic=" vs "Isotropic =")
inblock && /Isotropic/ {
    line = $0
    gsub(/Isotropic=/,  "Isotropic =",  line)
    gsub(/Anisotropy=/, "Anisotropy =", line)

    n = split(line, a, /[[:space:]]+/)
    for (i = 1; i <= n - 3; i++) {
        # Match: <idx> <elem> Isotropic [=] <value>
        if (a[i] ~ /^[0-9]+$/ && a[i+1] ~ /^[A-Za-z]{1,2}$/ && a[i+2] == "Isotropic") {
            atom = a[i] + 0
            elem = toupper(a[i+1])
            iso  = (a[i+3] == "=" ? a[i+4] : a[i+3])
            gsub(/[dD]/, "E", iso)  # tolerate Fortran exponents

            if (elem == "H" && atom <= LIMIT) {
                delta = SIGMA_TMS - (iso + 0)
                delta = A * delta + B
                printf("%.6f\t1.0\t%d\n", delta, atom)
            }
        }
    }
}

# End NMR block
inblock && /^$/ { inblock=0 }