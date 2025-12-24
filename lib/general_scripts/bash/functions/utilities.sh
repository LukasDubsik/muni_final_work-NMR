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
		BEGIN { in_atoms = 0 }

		$0 ~ /^@<TRIPOS>ATOM/ { in_atoms = 1; next }
		$0 ~ /^@<TRIPOS>BOND/ { in_atoms = 0 }

		in_atoms == 1 && $1 ~ /^[0-9]+$/ {
			atom_id   = $1
			atom_name = $2
			x = $3
			y = $4
			z = $5
			atom_type = $6
			charge    = $NF

			# Normalize to just leading letters from ATOM NAME.
			# IMPORTANT: MOL2 atom_type may be GAFF like "cd"/"ca" and must NOT be used for element detection.
			sym_name = atom_name
			sub(/[^A-Za-z].*$/, "", sym_name)

			u_name = toupper(sym_name)

			# Validate numeric charge; default to 0.0 if missing/weird
			if (charge !~ /^[-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$/) {
				charge = "0.0"
			}

			# Extend this list if needed
			if (u_name ~ /^(AU|AG|HG|ZN|FE|CU|NI|CO|MN|MG|CA|CD|PT|PD|IR|RU|RH|OS|PB|SN)$/) {
				print atom_id, sym_name, charge, x, y, z
				exit 0
			}

		}
	' "$mol2"
}



# mol2_has_metal MOL2FILE
mol2_has_metal()
{
	local mol2="$1"
	[[ -n "$(mol2_first_metal "$mol2")" ]]
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
			# Metal: derive element from atom NAME (NOT atom_type; GAFF types like "cd"/"ca" are not elements)
			elem = guess_elem(name);
			resn = toupper(substr(elem,1,2));
			atn  = toupper(elem);             # keep proper case (e.g., "Au")
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

			# Start molecule block
			if (lines[i] ~ /^@<TRIPOS>MOLECULE/) { inmol=1; mol_line=0; print lines[i]; continue }

			# End molecule block ONLY when next section starts (do not truncate it)
			if (inmol && lines[i] ~ /^@<TRIPOS>/ && lines[i] !~ /^@<TRIPOS>MOLECULE/) {
				inmol=0
				# fall through to handle the section tag normally
			}

			if (inmol) {
				mol_line++
				if (mol_line == 2) {
					printf "%d %d 0 0 0\n", nat, nb
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

		# Lowercase atom_type column (6) inside ATOM section,
		# but preserve metal atom types (MCPB/LEaP are case-sensitive; metals are not GAFF types).
		in_atom && NF>=6 {
			t = $6
			u = toupper(t)

			if (u ~ /^(AU|AG|ZN|FE|CU|NI|CO|MN|CR|V|TI|MO|W|RE|RU|RH|PD|CD|PT|IR|OS|HG|AL|GA|IN|TL|SN|PB|BI|ZR|HF)$/) {
				$6 = t
			} else {
				$6 = tolower(t)
			}

			print
			next
		}

		{ print; }
	' "$file" > "$tmp" || die "mol2_normalize_obabel_output_inplace: Failed to normalize mol2"

	mv "$tmp" "$file" || die "mol2_normalize_obabel_output_inplace: Failed to replace mol2"
}

mol2_bonded_atoms()
{
	local mol2="$1"
	local atom_id="$2"

	awk -v id="$atom_id" '
		BEGIN { in_bonds = 0 }
		$0 ~ /^@<TRIPOS>BOND/ { in_bonds = 1; next }
		$0 ~ /^@<TRIPOS>/ && in_bonds == 1 { exit 0 }

		in_bonds == 1 && NF >= 4 {
			a = $2
			b = $3
			if (a == id) print b
			else if (b == id) print a
		}
	' "$mol2" | sort -n | uniq
}

mol2_atom_name_by_id()
{
	local mol2="$1"
	local atom_id="$2"

	awk -v id="$atom_id" '
		BEGIN { in_atoms = 0 }
		$0 ~ /^@<TRIPOS>ATOM/ { in_atoms = 1; next }
		$0 ~ /^@<TRIPOS>BOND/ { in_atoms = 0 }

		in_atoms == 1 && $1 == id {
			print $2
			exit 0
		}
	' "$mol2"
}

mol2_atom_is_halide_by_id()
{
	local mol2="$1"
	local atom_id="$2"

	local aname
	aname="$(mol2_atom_name_by_id "$mol2" "$atom_id")"
	aname="${aname%%[^A-Za-z]*}"         # leading letters only
	aname="$(echo "$aname" | tr '[:lower:]' '[:upper:]')"

	# Extend if needed; for your case Cl is enough
	[[ "$aname" == "CL" || "$aname" == "BR" || "$aname" == "I" || "$aname" == "F" ]]
}

mol2_write_mcpb_typed_mol2()
{
	local src="$1"
	local dst="$2"
	local metal_id="$3"
	local resname="$4"
	shift 4
	local halide_ids=("$@")

	local halide_set
	halide_set="$(printf "%s " "${halide_ids[@]}")"

	awk -v mid="$metal_id" -v res="$resname" -v hids="$halide_set" '
		BEGIN {
			in_atoms = 0
			n = split(hids, a, " ")
			for (i = 1; i <= n; i++) {
				if (a[i] ~ /^[0-9]+$/) h[a[i]] = 1
			}
		}

		$0 ~ /^@<TRIPOS>ATOM/ { in_atoms = 1; print; next }
		$0 ~ /^@<TRIPOS>BOND/ { in_atoms = 0; print; next }

		in_atoms == 1 && $1 ~ /^[0-9]+$/ {
			# force residue name
			if (NF >= 8) $8 = res

			# MCPB types:
			#   M1 = Au
			#   Y1 = Cl
			if ($1 == mid)      $6 = "M1"
			else if (h[$1] == 1) $6 = "Y1"

			print
			next
		}

		{ print }
	' "$src" > "$dst"
}

# mol2_force_atom_type_inplace MOL2FILE NEWTYPE
# Forces the Tripos MOL2 ATOM type column (field 6) to NEWTYPE for all ATOM records.
# Intended for single-ion residue templates (e.g., AU1.mol2) so teLeap matches MCPB types (M1).
mol2_force_atom_type_inplace()
{
	local mol2="$1"
	local newtype="$2"
	local tmp="${mol2}.tmp"

	awk -v t="$newtype" '
		BEGIN { in_atoms = 0 }

		$0 ~ /^@<TRIPOS>ATOM/ { in_atoms = 1; print; next }
		$0 ~ /^@<TRIPOS>BOND/ { in_atoms = 0; print; next }

		{
			if (in_atoms == 1 && $1 ~ /^[0-9]+$/) {
				# Tripos MOL2 ATOM: id name x y z type subst_id subst_name charge ...
				$6 = t
			}
			print
		}
	' "$mol2" > "$tmp" || die "Failed to force MOL2 atom types: $mol2"

	mv "$tmp" "$mol2" || die "Failed to replace MOL2: $mol2"
}

mol2_quick_validate_for_tleap()
{
	local mol2="$1"

	[[ -r "$mol2" ]] || return 1

	# Keep this intentionally permissive:
	# - require a usable @<TRIPOS>ATOM block
	# - do NOT require BOND/SUBSTRUCTURE blocks (single-ion templates are valid)
	awk '
		BEGIN {
			in_atoms = 0
			nat = 0
			bad = 0
			num = "^[+-]?[0-9]*([.][0-9]+)?([eE][+-]?[0-9]+)?$"
		}

		$0 ~ /^@<TRIPOS>ATOM/ { in_atoms = 1; next }
		$0 ~ /^@<TRIPOS>/ && $0 !~ /^@<TRIPOS>ATOM/ { in_atoms = 0 }

		in_atoms == 1 {
			line = $0
			sub(/^[ \t]+/, "", line)
			if (line == "" || line ~ /^@/) next

			n = split(line, f, /[ \t]+/)
			# Tripos MOL2 atom line: at least 8 fields (charge may be absent)
			if (n < 8) { bad = 1; next }

			if (f[1] !~ /^[0-9]+$/) bad = 1
			if (f[3] !~ num || f[4] !~ num || f[5] !~ num) bad = 1
			if (f[6] == "" || f[6] ~ /^@/) bad = 1

			nat++
		}

		END {
			if (bad || nat < 1) exit 1
			exit 0
		}
	' "$mol2"
}

# mol2_build_full_with_first_metal FULL_MOL2 LIG_TYPED_MOL2 OUT_MOL2
# Builds a metal-containing MOL2 for MCPB.py by appending the first metal atom
# (and its metal-ligand bonds) from FULL_MOL2 onto the GAFF-typed ligand MOL2.
# The metal is appended as the last atom; atom/bond counts are updated.
# Assumes FULL_MOL2 differs from the ligand by removal of a single metal atom.
mol2_build_full_with_first_metal() {
	local full="$1"
	local lig="$2"
	local out="$3"

	[[ -f "$full" ]] || die "Missing FULL_MOL2: $full"
	[[ -f "$lig" ]] || die "Missing LIG_TYPED_MOL2: $lig"

	local mid
	mid="$(mol2_first_metal "$full" | awk 'NR==1{print $1}')"
	[[ -n "$mid" && "$mid" != "-1" ]] || die "No metal detected in FULL_MOL2: $full"

	local tmp="${out}.tmp"

	awk -v full="$full" -v mid="$mid" '
		function isnum(s){ return (s ~ /^[-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$/) }

		BEGIN{
			in_atom=0; in_bond=0; metal_line=""; nmb=0

			# Read FULL_MOL2 to capture the metal atom record and all metal-ligand bonds
			while ((getline line < full) > 0) {
				if (line ~ /^@<TRIPOS>ATOM/) { in_atom=1; in_bond=0; continue }
				if (line ~ /^@<TRIPOS>BOND/) { in_atom=0; in_bond=1; continue }
				if (line ~ /^@<TRIPOS>/)      { in_atom=0; in_bond=0; continue }

				if (in_atom && line ~ /^[ \t]*[0-9]+[ \t]/) {
					sub(/^[ \t]+/, "", line)
					n=split(line, f, /[ \t]+/)
					if (f[1]==mid) {
						metal_line=line
					}
				}

				if (in_bond && line ~ /^[ \t]*[0-9]+[ \t]/) {
					sub(/^[ \t]+/, "", line)
					n=split(line, b, /[ \t]+/)
					a1=b[2]; a2=b[3]; bt=(n>=4 ? b[4] : "1")
					if (a1==mid || a2==mid) {
						other=(a1==mid ? a2 : a1)
						mb_other[++nmb]=other
						mb_type[nmb]=bt
					}
				}
			}
			close(full)

			if (metal_line=="") {
				# If we cannot locate the metal ATOM line, we cannot build a consistent output
				exit 2
			}

			sect=""
			mol_line=0
			nat_lig=0; nb_lig=0
		}

		/^@<TRIPOS>MOLECULE/ { sect="MOL"; mol_line=0; print; next }

		/^@<TRIPOS>ATOM/ { sect="ATOM"; print; next }

		/^@<TRIPOS>BOND/ {
			# Append metal atom right before BOND starts
			if (sect=="ATOM") {
				new_mid=nat_lig+1
				n=split(metal_line, mf, /[ \t]+/)

				# Keep name/type/coords from FULL_MOL2, but force a fresh atom id (append at end)
				x=(n>=5 && isnum(mf[3]) ? mf[3] : 0.0)
				y=(n>=5 && isnum(mf[4]) ? mf[4] : 0.0)
				z=(n>=5 && isnum(mf[5]) ? mf[5] : 0.0)
				t=(n>=6 ? mf[6] : mf[2])
				sid=(n>=7 && mf[7] ~ /^[0-9]+$/ ? mf[7] : 1)
				subst=(n>=8 ? mf[8] : "LIG")
				q=(isnum(mf[n]) ? mf[n] : 0.0)

				printf(" %d %s %.4f %.4f %.4f %s %d %s %.6f\n", new_mid, mf[2], x, y, z, t, sid, subst, q)
			}

			sect="BOND"
			print
			next
		}

		/^@<TRIPOS>SUBSTRUCTURE/ {
			# Append metal bonds right before SUBSTRUCTURE starts
			if (sect=="BOND") {
				new_mid=nat_lig+1
				for (i=1; i<=nmb; i++) {
					other=mb_other[i]
					# Map old ligand ids to ligand-only ids: remove one index if it was after the removed metal
					other_new=(other > mid ? other-1 : other)
					printf(" %d %d %d %s\n", nb_lig+i, new_mid, other_new, mb_type[i])
				}
			}
			sect="SUB"
			print
			next
		}

		sect=="MOL" {
			mol_line++
			# line 1 after MOLECULE is name; line 2 is counts
			if (mol_line==2) {
				nat_lig=$1
				nb_lig=$2
				nat_total=nat_lig+1
				nb_total=nb_lig+nmb
				printf("%d %d %d %d %d\n", nat_total, nb_total, ($3?$3:1), ($4?$4:0), ($5?$5:0))
				next
			}
			print
			next
		}

		{ print }

		END{
			# If the file ends inside BOND section (no SUBSTRUCTURE), still append metal bonds
			if (sect=="BOND") {
				new_mid=nat_lig+1
				for (i=1; i<=nmb; i++) {
					other=mb_other[i]
					other_new=(other > mid ? other-1 : other)
					printf(" %d %d %d %s\n", nb_lig+i, new_mid, other_new, mb_type[i])
				}
			}
		}
	' "$lig" > "$tmp" || die "Failed to build full MOL2: $out"

	mv "$tmp" "$out" || die "Failed to write: $out"
	[[ -s "$out" ]] || die "Failed to build full MOL2 (empty): $out"
}
