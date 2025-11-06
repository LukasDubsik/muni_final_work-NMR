#Start the block for NMR
/Magnetic shielding tensor/ { inblock=1; next }
#If the block contains Isotropic it contains our data
inblock && /Isotropic/ {
    atom=$1; elem=$2; iso=$5                    #Split the line
    if (elem=="H" && atom<=LIMIT) {             #If it is a hydrogen (1H) belonging to cysteine (atoms 1-14 in the input)
        delta = SIGMA_TMS - iso                 #Apply the shift
        printf("%.6f\t1.0\t%d\n", delta, atom)  #Print to the result along with the number label
    }
}
#Ending the NMR block
inblock && /^$/ { inblock=0 }