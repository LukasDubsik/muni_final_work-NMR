# shellcheck disable=SC2148
# Guard so we don't load twice
[[ ${_UTILITIES_SH_LOADED:-0} -eq 1 ]] && return
_UTILITIES_SH_LOADED=1

# ensure_dir DIR_NAME
# Makes sure the dir exists by creating it
# Globals: none
# Returns: Nothing
ensure_dir() { mkdir -p "$1"; }

clean_process() {
	local last_command=$1
	local num_frames=$2
	local curr_sys=""

	#Delete based on log
	for key in "${!LOG_MAP[@]}"; do
		num=${LOG_MAP[$key]}
		if [[ $num -gt $last_command ]]; then
			if [[ $num -ge 1 && $num -le 5 ]]; then
				curr_sys="preparations"
				rm -rf "process/${curr_sys}/${key}/"
				if [[ $num -eq 3 ]]; then
					rm -rf "process/${curr_sys}/mcpb/"
				fi
			elif [[ $num -ge 6 && $num -le 11 ]]; then
				curr_sys="run_"
				for ((num=0; num < num_frames; num++))
				do
					rm -rf "process/${curr_sys}${num}/${key}/"
				done
			else
				curr_sys="spectrum"
				rm -rf "process/${curr_sys}/${key}/"
			fi
		fi

		if [[ $num -lt 11 ]]; then
			rm -rf "process/spectrum/frames"
		fi
	done
}

# find_sim_num MD_ITER
# Finds what number of job should now be run
# Globals: none
# Returns: 0 if everyting okay, otherwise number that causes error
find_sim_num() {
	local MD_ITER=$1
	local log=$2

	SEARCH_DIR="process/"

	#If we are below the jobs becessary for run, delete all the runs
	if [[ ($log -lt 6) ]]; then
		for file in "$SEARCH_DIR"/run_*; do
			rm -rf "$file"
		done
	fi

	for ((i=1; i <= MD_ITER; i++)); do 
		if [[ -d $SEARCH_DIR/run_$i ]]; then
			continue
		else
			COUNTER=$i
			break
		fi
	done

	if [[ $COUNTER -eq 0 ]]; then
		COUNTER=$MD_ITER
		info "All the md runs have finished"
	elif [[ $COUNTER -eq 1 ]]; then
		info "No md have yet been run"
	else
		info "The md runs have stopped at (wasn't completed): $COUNTER"
	fi
}

# has_heavy_metal MOL2_FILE
# Returns 0 (success) if the mol2 file contains at least one atom that is
# treated as a "heavy metal" (transition metals, Au, etc.), 1 otherwise.
has_heavy_metal() {
	local mol2=$1

	[[ -f "$mol2" ]] || die "Missing mol2 file for heavy-metal detection: $mol2"

	awk '
	BEGIN { in_atoms=0; found=0 }
	/^@<TRIPOS>ATOM/ { in_atoms=1; next }
	/^@<TRIPOS>/     { in_atoms=0 }
	in_atoms {
		# column 2: atom name; strip trailing digits/underscores
		elem = $2
		gsub(/[0-9_]+$/, "", elem)
		u = toupper(elem)
		if (u ~ /^(ZN|CU|FE|CO|NI|MN|CR|V|TI|MO|W|RE|RU|RH|PD|AG|CD|PT|AU|HG|AL|GA|IN|TL|SN|PB|BI|ZR|HF)$/) {
			found = 1
			exit
		}
	}
	END { if (found) exit 0; else exit 1 }
	' "$mol2"
}

# mol2_write_charge_file MOL2_FILE OUT_FILE
# Extracts per-atom partial charges from a mol2 file and writes them as
# one charge per line (format suitable for antechamber -c rc -cf).
# Globals: none
# Returns: Nothing (dies on error)
mol2_write_charge_file() {
	local mol2=$1
	local out=$2

	[[ -f "$mol2" ]] || die "Missing mol2 file for charge extraction: $mol2"

	awk '
	BEGIN { in_atoms=0; n=0 }
	/^@<TRIPOS>ATOM/ { in_atoms=1; next }
	/^@<TRIPOS>/     { in_atoms=0 }
	in_atoms {
		# mol2 ATOM line: ... <subst_id> <subst_name> <charge>
		c = $NF
		# validate numeric charge
		if (c !~ /^[-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$/) {
			exit 3
		}
		print c
		n++
	}
	END {
		if (n == 0) exit 2
	}
	' "$mol2" > "$out" || {
		rc=$?
		if [[ $rc -eq 2 ]]; then
			die "Charge extraction failed (no ATOM records): $mol2"
		elif [[ $rc -eq 3 ]]; then
			die "Charge extraction failed (missing/non-numeric charge column): $mol2"
		else
			die "Charge extraction failed for: $mol2"
		fi
	}

	[[ -s "$out" ]] || die "Charge file was not created or is empty: $out"
}

# mol2_first_metal MOL2FILE
# Prints: "<atom_id> <elem> <charge> <x> <y> <z>"
mol2_first_metal() {
	local mol2="$1"

	awk '
	BEGIN {
		inatom=0
		# Extend as needed
		metals["AU"]=1; metals["AG"]=1; metals["PT"]=1; metals["PD"]=1; metals["HG"]=1;
		metals["ZN"]=1; metals["FE"]=1; metals["CU"]=1; metals["NI"]=1; metals["CO"]=1;
	}
	/^@<TRIPOS>ATOM/ { inatom=1; next }
	/^@<TRIPOS>/ && $0 !~ /^@<TRIPOS>ATOM/ { inatom=0 }
	inatom {
		id=$1; name=$2; x=$3; y=$4; z=$5; type=$6; charge=$9

		elem=name
		gsub(/[0-9]/,"",elem)
		elem=toupper(elem)

		# also try from type (before any dot)
		elem2=type
		sub(/\..*/,"",elem2)
		gsub(/[0-9]/,"",elem2)
		elem2=toupper(elem2)

		if (metals[elem])  { print id, elem, charge, x, y, z; exit }
		if (metals[elem2]) { print id, elem2, charge, x, y, z; exit }
	}
	' "$mol2"
}

# mol2_has_metal MOL2FILE
mol2_has_metal() {
	local mol2="$1"
	[[ -n "$(mol2_first_metal "$mol2")" ]]
}

# mol2_to_mcpb_pdb MOL2FILE OUTPDB METAL_ID
# Writes a minimal PDB with residue 1=LIG and residue 2=<METAL> (metal is separate residue)
mol2_to_mcpb_pdb() {
	local mol2="$1"
	local outpdb="$2"
	local metal_id="$3"

	awk -v mid="$metal_id" '
	BEGIN { inatom=0 }
	/^@<TRIPOS>ATOM/ { inatom=1; next }
	/^@<TRIPOS>/ && $0 !~ /^@<TRIPOS>ATOM/ { inatom=0 }
	inatom {
		id=$1; name=$2; x=$3; y=$4; z=$5

		# residue assignment
		if (id == mid) { res="AU"; resid=2 }
		else          { res="LIG"; resid=1 }

		# PDB atom naming: keep up to 4 chars
		aname=name
		if (length(aname) > 4) aname=substr(aname,1,4)

		printf "HETATM%5d %-4s %-3s A%4d    %8.3f%8.3f%8.3f  1.00  0.00\n",
			id, aname, res, resid, x, y, z
	}
	END { print "END" }
	' "$mol2" > "$outpdb"
}

# mol2_strip_atom MOL2FILE OUTMOL2 ATOM_ID
# Removes one atom and all bonds to it; renumbers atoms and bonds.
mol2_strip_atom() {
	local mol2="$1"
	local outmol2="$2"
	local strip_id="$3"

	awk -v sid="$strip_id" '
	function flush_counts() {
		# rewrite molecule counts line later; handled by storing and printing after parse
	}
	BEGIN { state=0; nat=0; nb=0 }
	{
		lines[NR]=$0
	}
	/^@<TRIPOS>ATOM/ { state=1 }
	/^@<TRIPOS>BOND/ { state=2 }
	END {
		# First pass: map atoms
		inatom=0
		for (i=1;i<=NR;i++) {
			if (lines[i] ~ /^@<TRIPOS>ATOM/) { inatom=1; continue }
			if (lines[i] ~ /^@<TRIPOS>/ && lines[i] !~ /^@<TRIPOS>ATOM/) { if (inatom) inatom=0 }
			if (inatom) {
				split(lines[i], f, /[ \t]+/)
				old=f[1]
				if (old == sid) continue
				nat++
				map[old]=nat
				atomline[nat]=lines[i]
			}
		}

		# Second pass: bonds
		inbond=0
		for (i=1;i<=NR;i++) {
			if (lines[i] ~ /^@<TRIPOS>BOND/) { inbond=1; continue }
			if (lines[i] ~ /^@<TRIPOS>/ && lines[i] !~ /^@<TRIPOS>BOND/) { if (inbond) inbond=0 }
			if (inbond) {
				split(lines[i], f, /[ \t]+/)
				a=f[2]; b=f[3]
				if (a == sid || b == sid) continue
				nb++
				bondline[nb]=lines[i]
				bonda[nb]=a; bondb[nb]=b
			}
		}

		# Output
		# Copy header through molecule section, but fix counts line (2nd line after @<TRIPOS>MOLECULE)
		out=""
		inmol=0; mol_line=0
		for (i=1;i<=NR;i++) {
			if (lines[i] ~ /^@<TRIPOS>MOLECULE/) { inmol=1; mol_line=0; print lines[i]; continue }
			if (inmol) {
				mol_line++
				if (mol_line == 2) {
					printf "%d %d 0 0 0\n", nat, nb
					inmol=0
					continue
				}
				print lines[i]
				continue
			}
			if (lines[i] ~ /^@<TRIPOS>ATOM/) {
				print lines[i]
				for (k=1;k<=nat;k++) {
					# rewrite atom index
					split(atomline[k], f, /[ \t]+/)
					old=f[1]
					sub("^" old "[ \t]+", k " ", atomline[k])
					print atomline[k]
				}
				# skip original atom block
				for (j=i+1;j<=NR;j++) {
					if (lines[j] ~ /^@<TRIPOS>/ && lines[j] !~ /^@<TRIPOS>ATOM/) { i=j-1; break }
				}
				continue
			}
			if (lines[i] ~ /^@<TRIPOS>BOND/) {
				print lines[i]
				for (k=1;k<=nb;k++) {
					split(bondline[k], f, /[ \t]+/)
					old=f[1]; a=f[2]; b=f[3]
					newa=map[a]; newb=map[b]
					printf "%d %d %d %s\n", k, newa, newb, f[4]
				}
				# skip original bond block
				for (j=i+1;j<=NR;j++) {
					if (lines[j] ~ /^@<TRIPOS>/ && lines[j] !~ /^@<TRIPOS>BOND/) { i=j-1; break }
				}
				continue
			}
			print lines[i]
		}
	}
	' "$mol2" > "$outmol2"
}

# write_single_ion_mol2 OUTMOL2 ELEM CHARGE X Y Z
write_single_ion_mol2() {
	local outmol2="$1"
	local elem="$2"
	local charge="$3"
	local x="$4"
	local y="$5"
	local z="$6"

	cat > "$outmol2" <<EOF
@<TRIPOS>MOLECULE
${elem}
 1 0 0 0 0
SMALL
USER_CHARGES

@<TRIPOS>ATOM
      1 ${elem}        ${x} ${y} ${z} ${elem} 1 ${elem} ${charge}
@<TRIPOS>BOND
EOF
}


# mol2_sanitize_atom_coords_inplace MOL2FILE
# Fixes non-standard MOL2 where ATOM lines contain an extra "element" column:
#   id name element x y z ...
# Converts to standard Tripos:
#   id name x y z ...
# This is required for MCPB.py (pymsmt) which expects x,y,z in fields 3-5.
mol2_sanitize_atom_coords_inplace() {
	local mol2="$1"
	local tmp="${mol2}.tmp"

	awk '
	function isnum(v) { return (v ~ /^[-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$/) }
	BEGIN { inatom=0 }
	/^@<TRIPOS>ATOM/ { inatom=1; print; next }
	/^@<TRIPOS>/ && $0 !~ /^@<TRIPOS>ATOM/ { inatom=0; print; next }
	{
		if (!inatom) { print; next }

		n=split($0, f, /[ \t]+/)
		# If f[3] is not numeric but f[4..6] are, drop f[3] (the extra element token)
		if (n >= 7 && !isnum(f[3]) && isnum(f[4]) && isnum(f[5]) && isnum(f[6])) {
			printf "%s %s %s %s %s", f[1], f[2], f[4], f[5], f[6]
			for (i=7;i<=n;i++) printf " %s", f[i]
			printf "\n"
		} else {
			print
		}
	}
	' "$mol2" > "$tmp" || die "Failed to sanitize MOL2: $mol2"

	mv "$tmp" "$mol2" || die "Failed to replace MOL2: $mol2"
}