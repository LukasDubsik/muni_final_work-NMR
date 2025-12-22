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
mol2_first_metal()
{
    local mol2="$1"
    awk '
function cap(sym,   a,b) {
    gsub(/[^A-Za-z]/, "", sym);
    if (length(sym) == 1) return toupper(sym);
    a = toupper(substr(sym,1,1));
    b = tolower(substr(sym,2,1));
    return a b;
}
BEGIN{ in_atoms=0 }
/^@<TRIPOS>ATOM/ { in_atoms=1; next }
/^@<TRIPOS>/ { in_atoms=0 }
in_atoms {
    # mol2: id name x y z type resid resname charge
    id=$1; type=$6; x=$3; y=$4; z=$5; charge=$9;

    # Metals we want MCPB to recognize
    if (type ~ /^(Au|AU|Ag|AG|Zn|ZN|Fe|FE|Cu|CU|Ni|NI|Co|CO|Mn|MN|Hg|HG|Cd|CD|Pt|PT|Ir|IR|Os|OS|Pb|PB|Sn|SN)$/) {
        print id " " cap(type) " " charge " " x " " y " " z;
        exit;
    }
}
END {
	print "-1";
}
' "$mol2"
}


# mol2_has_metal MOL2FILE
mol2_has_metal() {
	local mol2="$1"
	local line
	line="$(mol2_first_metal "$mol2" | head -n1)"
	[[ -n "$line" ]]
}


# mol2_to_mcpb_pdb MOL2FILE OUTPDB METAL_ID
# Writes a MCPB-friendly PDB:
#   residue 1 = LIG, residue 2 = metal (separate residue)
# IMPORTANT: include element symbol in columns 77-78 (MCPB/pymsmt uses it). 
mol2_to_mcpb_pdb()
{
    local mol2="$1"
    local out="$2"
    local mid="$3"

    awk -v mid="$mid" '
    function cap(sym,   a,b) {
        gsub(/[^A-Za-z]/, "", sym);
        if (length(sym) == 0) return "X";
        if (length(sym) == 1) return toupper(sym);
        a = toupper(substr(sym,1,1));
        b = tolower(substr(sym,2,1));
        return a b;
    }
    function guess_elem(name,   s) {
        s = name;
        gsub(/[0-9]/, "", s);

        # Two-letter elements if atom name starts with known pattern (e.g., Cl, Br, Au)
        if (length(s) >= 2 && substr(s,2,1) ~ /[a-z]/) return cap(substr(s,1,2));
        if (length(s) >= 2 && substr(s,1,2) ~ /^(CL|BR|NA|MG|ZN|FE|AU|AG|SI|AL|CA|MN|CU|NI|CO|SE|HG|CD|PB|SN|PT|IR|OS)$/)
            return cap(substr(s,1,2));

        return cap(substr(s,1,1));
    }

    BEGIN { in_atoms=0; }
    /^@<TRIPOS>ATOM/ { in_atoms=1; next }
    /^@<TRIPOS>/ { in_atoms=0 }

   in_atoms {
		id=$1; name=$2; x=$3; y=$4; z=$5; type=$6; resi=$7; resid=$8;

		if (id == mid) {
			# Metal: residue name uppercase (AU), element as proper case (Au)
			elem = cap(type);
			resn = toupper(substr(elem,1,2));
			atn  = toupper(elem);     # make atom name robust ("AU")
			resi_out = 2;            # IMPORTANT: separate residue number from ligand
		} else {
			# Ligand: force residue name to LIG for MCPB consistency
			elem = guess_elem(name);
			resn = "LIG";
			atn  = name;
			resi_out = 1;
		}

		# PDB fixed-width, element in cols 77-78 (right-justified)
		printf("HETATM%5d %-4s %3s A%4d    %8.3f%8.3f%8.3f%6.2f%6.2f          %2s\n",
			id, atn, resn, resi_out, x, y, z, 1.00, 0.00, elem);
	}


    END { print "END" }
    ' "$mol2" > "$out"
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
				line = lines[i]
				sub(/^[ \t]+/, "", line)
				split(line, f, /[ \t]+/)
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
				line = lines[i]
				sub(/^[ \t]+/, "", line)
				split(line, f, /[ \t]+/)
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
					aline = atomline[k]
					sub(/^[ \t]+/, "", aline)
					split(aline, f, /[ \t]+/)
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
					bline = bondline[k]
					sub(/^[ \t]+/, "", bline)
					split(bline, f, /[ \t]+/)
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
	local elem_in="$2"
	local charge="$3"
	local x="$4"
	local y="$5"
	local z="$6"

	# Residue/substructure label: keep uppercase (e.g., AU, ZN)
	local elem_u
	elem_u="$(echo "$elem_in" | tr '[:lower:]' '[:upper:]')"

	# Atom name: match PDB atom name (uppercase, e.g., AU) so MCPB key is AU-AU.
	# Atom type: canonical element symbol (Au, Zn, Fe, ...) for correct element inference.
	local elem_sym
	elem_sym="$(echo "$elem_u" | awk '{ printf("%s%s", substr($0,1,1), tolower(substr($0,2))) }')"

	cat > "$outmol2" <<EOF
@<TRIPOS>MOLECULE
${elem_u}
1 0 0 0 0
SMALL
USER_CHARGES

@<TRIPOS>ATOM
	1 ${elem_u}        ${x} ${y} ${z} ${elem_sym} 1 ${elem_u} ${charge}
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

		n=NF
		for (i=1;i<=n;i++) f[i]=$i

		# If the atom name is missing (id x y z type ...), synthesize one (A<id>)
		if (n >= 8 && isnum(f[2]) && isnum(f[3]) && isnum(f[4]) && !isnum(f[5])) {
			printf "%s A%s %s %s %s", f[1], f[1], f[2], f[3], f[4]
			for (i=5;i<=n;i++) printf " %s", f[i]
			printf "\n"
			next
		}

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

mol2_sanitize_for_mcpb() {
	local in_mol2="$1"
	local subst="${2:-LIG}"
	local tmp="${in_mol2}.tmp"

	awk -v subst="$subst" '
		function isnum(s) { return (s ~ /^[-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$/) }

		BEGIN { sect = "" }

		/^@<TRIPOS>ATOM/         { sect = "ATOM"; print; next }
		/^@<TRIPOS>SUBSTRUCTURE/ { sect = "SUB";  print; next }
		/^@<TRIPOS>/             { sect = "";     print; next }

		{
			# Passthrough unless in ATOM/SUBSTRUCTURE sections
			if (sect != "ATOM" && sect != "SUB") { print; next }

			# Keep blank lines as-is
			if ($0 ~ /^[ \t]*$/) { print; next }

			# ----------------
			# ATOM section
			# ----------------
			if (sect == "ATOM") {
				# Copy fields
				for (i = 1; i <= NF; i++) f[i] = $i
				n = NF

				# If element symbol is present as column 3 (id name elem x y z ...), drop it.
				if (n >= 7 && !isnum(f[3]) && isnum(f[4])) {
					for (i = 3; i < n; i++) f[i] = f[i+1]
					n--
				}

				# Require at least the base 6 columns: id name x y z type
				if (n < 6) { print; next }

				# Base columns
				id   = f[1]
				name = f[2]
				x    = f[3]
				y    = f[4]
				z    = f[5]
				type = f[6]

				# Fallback if coords are still not numeric (leave line untouched)
				if (!isnum(x) || !isnum(y) || !isnum(z)) { print; next }

				# Substructure id/name and charge
				sid = 1
				if (n >= 7 && isnum(f[7])) sid = int(f[7])

				# Charge: standard MOL2 is column 9, but sometimes an element column is appended.
				q = 0.0
				if (n >= 9 && isnum(f[9])) q = f[9]
				else if (n >= 10 && isnum(f[10])) q = f[10]
				else if (n == 8 && isnum(f[8])) q = f[8]

				# Always force subst name to match the PDB residue name MCPB.py uses
				printf(" %d %s %.4f %.4f %.4f %s %d %s %.6f\n", id, name, x, y, z, type, sid, subst, q)
				next
			}

			# ----------------
			# SUBSTRUCTURE section
			# ----------------
			if (sect == "SUB") {
				# Expect: subst_id subst_name root_atom ...
				if ($1 ~ /^[0-9]+$/) {
					$2 = subst
					print
					next
				}
				# If malformed, emit a minimal valid record
				printf("     1 %s         1 TEMP              0 ****  ****    0 ROOT\n", subst)
				next
			}
		}
	' "$in_mol2" > "$tmp"

	mv "$tmp" "$in_mol2" || die "Failed to sanitize: $in_mol2"
}


# mol2_normalize_obabel_output_inplace FILE MOL_NAME
# Fixes OpenBabel side-effects:
#  - forces MOLECULE name to MOL_NAME
#  - lowercases atom types in the ATOM section (GAFF/GAFF2 expects lowercase)
# Globals: none
# Returns: nothing
mol2_normalize_obabel_output_inplace() {
	local file="$1"
	local mol_name="$2"

	[[ -n "$file" && -f "$file" ]] || die "mol2_normalize_obabel_output_inplace: Missing file"
	[[ -n "$mol_name" ]] || die "mol2_normalize_obabel_output_inplace: Missing MOL_NAME"

	local tmp="${file}.tmp"

	awk -v molname="$mol_name" '
		BEGIN { in_mol=0; mol_line=0; in_atom=0; }

		/^@<TRIPOS>MOLECULE/ { in_mol=1; mol_line=0; print; next; }

		# First line after MOLECULE tag is the molecule name
		in_mol && mol_line==0 { print molname; mol_line=1; next; }

		# Leave MOLECULE section when a new section starts
		in_mol && /^@<TRIPOS>/ && $0 !~ /^@<TRIPOS>MOLECULE/ { in_mol=0; }

		/^@<TRIPOS>ATOM/ { in_atom=1; print; next; }
		/^@<TRIPOS>/ && $0 !~ /^@<TRIPOS>ATOM/ { in_atom=0; print; next; }

		# Lowercase atom_type column (6) inside ATOM section
		in_atom && NF>=6 { $6=tolower($6); print; next; }

		{ print; }
	' "$file" > "$tmp" || die "mol2_normalize_obabel_output_inplace: Failed to normalize mol2"

	mv "$tmp" "$file" || die "mol2_normalize_obabel_output_inplace: Failed to replace mol2"
}
