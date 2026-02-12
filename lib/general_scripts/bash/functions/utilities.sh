# shellcheck disable=SC2148
# Guard so we don't load twice
[[ ${_UTILITIES_SH_LOADED:-0} -eq 1 ]] && return
_UTILITIES_SH_LOADED=1

# ensure_dir DIR_NAME
# Makes sure the dir exists by creating it
# Globals: none
# Returns: Nothing
ensure_dir() { mkdir -p "$1"; }

# ----- Pipeline resuming helpers (idempotent steps) -----

# mark_step_ok DIR
# Creates/updates a .ok stamp in DIR. A step is considered done only if
# its outputs validate and .ok exists.
mark_step_ok() {
	local dir="$1"
	ensure_dir "$dir"

	# Write atomically to avoid half-written stamps on disconnects
	{
		printf "ok %s\n" "$(date -Iseconds)"
	} > "${dir}/.ok.tmp" 2>/dev/null || true

	mv -f "${dir}/.ok.tmp" "${dir}/.ok" 2>/dev/null || touch "${dir}/.ok"
}

# step_is_ok DIR
step_is_ok() { [[ -f "$1/.ok" ]]; }

# step_invalidate DIR
step_invalidate() { rm -f "$1/.ok"; }

# wait_for_jobid_file META JOBID_FILE
# If JOBID_FILE exists and qstat is available, wait until the job is no longer present.
# (Prevents accidental resubmission when the driver disconnects but the cluster job keeps running.)
wait_for_jobid_file() {
	local meta="$1"
	local jobid_file="$2"

	[[ -f "$jobid_file" ]] || return 0
	command -v qstat >/dev/null 2>&1 || return 0

	local jid
	jid="$(head -n 1 "$jobid_file" 2>/dev/null || true)"
	[[ -n "$jid" ]] || return 0

	while qstat "$jid" >/dev/null 2>&1; do
		sleep 30
	done
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

			# Also consider the substructure/residue name (field 8 in standard MOL2):
			# this avoids missing metals when atom names are mangled.
			subst_name = $8
			sym_sub = subst_name
			sub(/[^A-Za-z].*$/, "", sym_sub)
			u_sub = toupper(sym_sub)

			# Validate numeric charge; default to 0.0 if missing/weird
			if (charge !~ /^[-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$/) {
				charge = "0.0"
			}

			# Extend this list if needed
			if (u_name ~ /^(AU|AG|HG|ZN|FE|CU|NI|CO|MN|MG|CA|CD|PT|PD|IR|RU|RH|OS|PB|SN)$/ || u_sub ~ /^(AU|AG|HG|ZN|FE|CU|NI|CO|MN|MG|CA|CD|PT|PD|IR|RU|RH|OS|PB|SN)$/) {
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
	local x="${4:-0.0000}"
	local y="${5:-0.0000}"
	local z="${6:-0.0000}"

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


# mol2_write_with_coords_from_xyz MOL2_IN XYZ_IN MOL2_OUT
# Writes MOL2_OUT identical to MOL2_IN, but with ATOM coordinates replaced by
# the XYZ coordinates (by atom index). Connectivity (BOND section) is preserved.
#
# This is critical for metal-containing systems: XYZ has no bond information and
# converting XYZ->MOL2 with OpenBabel will *perceive* bonds based on interatomic
# distances, which can accidentally introduce spurious metal-ligand "covalent"
# bonds.
mol2_write_with_coords_from_xyz() {
	local mol2_in="$1"
	local xyz_in="$2"
	local mol2_out="$3"

	[[ -f "$mol2_in" ]] || die "MOL2 input missing: $mol2_in"
	[[ -f "$xyz_in"  ]] || die "XYZ input missing: $xyz_in"

	awk '
		function isnum(v) { return (v ~ /^[-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$/) }
		# Read XYZ first
		NR==FNR {
			if (FNR==1) { natom = int($1); next }
			if (FNR==2) { next }
			i = FNR - 2
			xyz_e[i] = toupper($1)
			x[i] = $2; y[i] = $3; z[i] = $4
			next
		}

		BEGIN { inatom=0; ai=0 }
		/^@<TRIPOS>ATOM/ { inatom=1; print; next }
		/^@<TRIPOS>/ && $0 !~ /^@<TRIPOS>ATOM/ { inatom=0; print; next }
		{
			if (!inatom) { print; next }
			# Preserve blank lines
			if ($0 ~ /^[ \t]*$/) { print; next }

			# Only rewrite standard ATOM records
			if ($1 !~ /^[0-9]+$/) { print; next }
			ai++
			if (ai > natom) { print; next }

			# Detect where the x,y,z columns are (field 3-5 or 4-6)
			cs = 0
			if (isnum($3) && isnum($4) && isnum($5)) cs = 3
			else if (isnum($4) && isnum($5) && isnum($6)) cs = 4


			if (cs == 0) { print; next }

			# Sanity-check that XYZ atom ordering matches MOL2 ordering.
			# If the XYZ was re-ordered (rare but possible), index-based mapping will
			# produce a corrupted structure.
			# Infer element from MOL2 atom name (field 2) to avoid ambiguity with
			# force-field atom types (e.g., GAFF "ca" vs element Ca).
			mol_e = $2
			gsub(/[^A-Za-z]/, "", mol_e)      # keep letters only
			mol_e = toupper(mol_e)
			if (mol_e != "" && xyz_e[ai] != "" && mol_e != xyz_e[ai]) mism++

			$(cs)   = sprintf("%.6f", x[ai])
			$(cs+1) = sprintf("%.6f", y[ai])
			$(cs+2) = sprintf("%.6f", z[ai])
			print
		}

		END {
			if (mism > 0) {
				print "ERROR: XYZ/MOL2 atom ordering mismatch (" mism ")" > "/dev/stderr"
				exit 2
			}
		}
	' "$xyz_in" "$mol2_in" > "$mol2_out" || die "Failed to write MOL2 with authoritative bonds: $mol2_out"
}

mol2_sanitize_for_mcpb() {
	local in_mol2="$1"
	local subst="${2:-LIG}"
	# Ensure residue/substructure name is a short, safe token (never a path)
	subst="${subst##*/}"        # drop any directory prefix
	subst="${subst%.mol2}"      # drop common extensions
	subst="${subst%.MOL2}"
	subst="${subst//[^[:alnum:]]/}"
	subst="${subst:0:4}"
	[[ -n "$subst" ]] || subst="LIG"
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


# tleap_filter_metal_bonds_by_mol2_connectivity AUTH_MOL2 BONDS_IN [BONDS_OUT]
# Filters TLeap "bond ..." commands, keeping only metal-ligand bonds present in
# the authoritative MOL2 connectivity. This is important because MCPB.py can
# infer extra metal coordination bonds from geometry (distance-based), which can
# be undesirable when the MOL2 bond table is the single source of truth.
#
# If no metal is detected in AUTH_MOL2, the file is copied unmodified.
tleap_filter_metal_bonds_by_mol2_connectivity()
{
	local auth_mol2="$1"
	local bonds_in="$2"
	local bonds_out="${3:-$2}"
	local tmp="${bonds_out}.tmp"
	local cnt="${bonds_out}.dropped_count"

	[[ -f "$auth_mol2" ]] || die "Authoritative MOL2 missing: $auth_mol2"
	[[ -f "$bonds_in" ]] || die "Bond commands file missing: $bonds_in"

	local metal_line
	metal_line="$(mol2_first_metal "$auth_mol2" || true)"
	if [[ -z "$metal_line" ]]; then
		cp -f "$bonds_in" "$bonds_out" || die "Failed to copy bond commands: $bonds_out"
		return 0
	fi

	local metal_id metal_elem
	read -r metal_id metal_elem <<<"$metal_line"
	local metal_pdb
	metal_pdb="$(echo "$metal_elem" | tr '[:lower:]' '[:upper:]')"

	# Allowed partner atom names are taken from the authoritative MOL2 bond list
	local allowed_names=()
	local pid
	while read -r pid; do
		[[ -n "$pid" ]] || continue
		allowed_names+=("$(mol2_atom_name_by_id "$auth_mol2" "$pid")")
	done < <(mol2_bonded_atoms "$auth_mol2" "$metal_id")

	# Nothing bonded to the metal in the authoritative MOL2 => keep only non-metal bonds
	if [[ ${#allowed_names[@]} -eq 0 ]]; then
		cp -f "$bonds_in" "$bonds_out" || die "Failed to copy bond commands: $bonds_out"
		return 0
	fi

	local allowed_csv
	allowed_csv="$(printf '%s,' "${allowed_names[@]}")"

	awk -v metal="$metal_pdb" -v allowed_csv="$allowed_csv" -v cntfile="$cnt" '
		function atomname(tok,   t) {
			t = tok
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", t)
			sub(/.*\./, "", t)          # keep suffix after last dot
			gsub(/[^A-Za-z0-9_]/, "", t) # strip punctuation
			return toupper(t)
		}
		BEGIN {
			n = split(allowed_csv, a, ",")
			for (i=1; i<=n; i++) {
				if (a[i] != "") ok[toupper(a[i])] = 1
			}
			dropped = 0
		}
		/^[[:space:]]*bond[[:space:]]+/ {
			a = $2
			b = $3
			an = atomname(a)
			bn = atomname(b)
			m  = toupper(metal)

			# If this is a metal bond command, keep only if the partner is allowed
			if (an == m && bn != m) {
				if (ok[bn]) print
				else dropped++
				next
			}
			if (bn == m && an != m) {
				if (ok[an]) print
				else dropped++
				next
			}

			# Non-metal bond commands are preserved
			print
			next
		}
		{ print }
		END {
			print dropped > cntfile
		}
	' "$bonds_in" > "$tmp" || die "Failed to filter TLeap bond commands: $bonds_in"

	mv -f "$tmp" "$bonds_out" || die "Failed to replace filtered bond commands: $bonds_out"

	local dropped
	dropped="$(cat "$cnt" 2>/dev/null || echo 0)"
	rm -f "$cnt" 2>/dev/null || true
	if [[ "$dropped" -gt 0 ]]; then
		warning "Filtered out $dropped spurious metal bond(s) from MCPB TLeap commands (authoritative connectivity preserved)."
	fi
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


# mol2_rebalance_total_charge_inplace MOL2FILE TARGET_TOTAL
# Shifts all per-atom charges by a constant so that sum(charges) == TARGET_TOTAL.
# This is used to ensure MCPB.py sees consistent total charge when ligand charges are placeholders.
mol2_rebalance_total_charge_inplace() {
	local mol2="$1"
	local target="$2"
	local tmp="${mol2}.tmp"

	[[ -f "$mol2" ]] || die "Missing MOL2 for charge rebalance: $mol2"
	[[ "$target" =~ ^[-+]?[0-9]+$ ]] || die "Target total charge must be an integer; got: '$target'"

	awk -v target="$target" '
	function isnum(v) { return (v ~ /^[-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$/) }

	BEGIN { inA=0; n=0; sum=0 }

	{ lines[NR] = $0; nf[NR] = NF }

	/^@<TRIPOS>ATOM/ { inA=1; next }
	/^@<TRIPOS>/     { if (inA) inA=0 }

	{
		if (inA && $1 ~ /^[0-9]+$/ && isnum($NF)) {
			n++
			sum += ($NF + 0.0)
		}
	}

	END {
		if (n == 0) exit 2

		delta = (target - sum) / n

		inA = 0
		seen = 0

		for (i=1; i<=NR; i++) {
			line = lines[i]

			if (line ~ /^@<TRIPOS>ATOM/) { inA=1; print line; continue }
			if (line ~ /^@<TRIPOS>/ && line !~ /^@<TRIPOS>ATOM/) { inA=0; print line; continue }

			if (!inA) { print line; continue }

			# Re-split the ATOM line and adjust the last (charge) field.
			split(line, f, /[ \t]+/)
			if (f[1] ~ /^[0-9]+$/ && isnum(f[length(f)])) {
				seen++
				newc = (f[length(f)] + 0.0) + delta
				# Put any floating residual into the last atom to reduce drift.
				if (seen == n) {
					# residual = target - (sum + delta*n) (should be ~0, but correct for float noise)
					residual = target - (sum + delta*n)
					newc += residual
				}
				f[length(f)] = sprintf("%.6f", newc)

				out = f[1]
				for (k=2; k<=length(f); k++) out = out " " f[k]
				print out
			} else {
				print line
			}
		}
	}
	' "$mol2" > "$tmp" || {
		rc=$?
		if [[ $rc -eq 2 ]]; then
			die "Charge rebalance failed (no ATOM records / no numeric charges): $mol2"
		fi
		die "Charge rebalance failed for: $mol2"
	}

	mv -f "$tmp" "$mol2" || die "Failed to update MOL2 after charge rebalance: $mol2"
}


# fix_prmtop_molecules PRMTOP
# Rebuild ATOMS_PER_MOLECULE / SOLVENT_POINTERS if inconsistent (common with metal systems).
fix_prmtop_molecules() {
	local prmtop="$1"
	[[ -f "$prmtop" ]] || die "Missing topology: $prmtop"

	command -v parmed >/dev/null 2>&1 || die "parmed not found in PATH (load AmberTools/Amber first)"

	local natom apm
	natom=$(awk '
		$0 ~ /^%FLAG POINTERS/ {p=1; next}
		p && $0 ~ /^%FORMAT/ {next}
		p {for (i=1;i<=NF;i++) {print $i; exit}}
	' "$prmtop")

	apm=$(awk '
		$0 ~ /^%FLAG ATOMS_PER_MOLECULE/ {a=1; next}
		a && $0 ~ /^%FORMAT/ {next}
		a && $0 ~ /^%FLAG/ {a=0}
		a {for (i=1;i<=NF;i++) s+=$i}
		END {print s+0}
	' "$prmtop")

	[[ -n "$natom" && -n "$apm" ]] || die "Failed reading NATOM/ATOMS_PER_MOLECULE from: $prmtop"

	if [[ "$natom" -eq "$apm" ]]; then
		return 0
	fi

	warn "Topology molecule table inconsistent: NATOM=$natom but SUM(ATOMS_PER_MOLECULE)=$apm. Rebuilding via ParmEd setMolecules."

	local in_file out_file
	in_file="${prmtop}.parmed_setMolecules.in"
	out_file="${prmtop}.fixed"

	cat >"$in_file" <<EOF
setMolecules
outparm $out_file
quit
EOF

	parmed -O -p "$prmtop" -i "$in_file" >/dev/null || die "ParmEd setMolecules failed for: $prmtop"

	mv -f "$out_file" "$prmtop" || die "Failed replacing topology: $prmtop"
	rm -f "$in_file"
}


# mol2_apply_mcpb_ytypes_from_pdb
# Retype atoms in a residue mol2 to match MCPB.py-generated Y* types for atoms bonded to the metal (M1).
# The mapping is derived from:
#   - PDB CONECT around the metal (AU) to identify which ligand atoms coordinate the metal
#   - FRCMOD BOND+MASS to identify which Y* type corresponds to halide vs non-halide
# Args:
#   $1: mol2 file (e.g., LG1.mol2)
#   $2: MCPB PDB file (e.g., gold1_mcpbpy.pdb)
#   $3: MCPB frcmod file (e.g., gold1_mcpbpy.frcmod)

mol2_apply_mcpb_ytypes_from_pdb() {
  local mol2_file=$1
  local pdb_file=$2
  local frcmod_file=$3
  local auth_mol2_file=${4:-}

  [[ -f "$mol2_file" ]] || die "mol2_apply_mcpb_ytypes_from_pdb: missing mol2: $mol2_file"
  [[ -f "$pdb_file" ]] || die "mol2_apply_mcpb_ytypes_from_pdb: missing pdb: $pdb_file"
  [[ -f "$frcmod_file" ]] || die "mol2_apply_mcpb_ytypes_from_pdb: missing frcmod: $frcmod_file"

  # 1) Identify Au serial + coordinates from PDB (AU may appear as element AU or atom name AU)
  local au_serial au_x au_y au_z
  au_serial=$(awk '($1=="HETATM"||$1=="ATOM") {elem=substr($0,77,2); gsub(/ /,"",elem); an=substr($0,13,4); gsub(/^ +| +$/,"",an); if (toupper(elem)=="AU" || toupper(an)=="AU") {print $2; exit}}' "$pdb_file")
  if [[ -z "$au_serial" ]]; then
    warn "mol2_apply_mcpb_ytypes_from_pdb: could not find AU in $pdb_file; skipping Y-type assignment"
    return 0
  fi
  read -r au_x au_y au_z < <(awk -v a="$au_serial" '($1=="HETATM"||$1=="ATOM") && $2==a {print $6,$7,$8; exit}' "$pdb_file")

  # 2) Collect the atom types in the MCPB frcmod that are directly bonded to M1
  mapfile -t m1_partners < <(
    awk 'BEGIN{inB=0}
         /^BOND/{inB=1;next}
         /^ANGLE|^ANGL|^DIHE|^IMPR|^NONB|^NONBON/{inB=0}
         inB && NF>=1 {print $1}' "$frcmod_file"     | awk -F'-' '$1=="M1"{print $2} $2=="M1"{print $1}'     | sort -u
  )
  if [[ ${#m1_partners[@]} -eq 0 ]]; then
    warn "mol2_apply_mcpb_ytypes_from_pdb: no M1-* bonds found in $frcmod_file; skipping"
    return 0
  fi

  # 3) Pick best partner types by mass (prevents O/N being mis-mapped to a C-type when no O/N-type exists)
  local halide_type="" sulfur_type="" selenium_type="" carbon_type="" nitrogen_type="" oxygen_type="" nonhalide_type="" best_nonhal_mass=1e9
  for t in "${m1_partners[@]}"; do
    mass=$(awk -v t="$t" 'BEGIN{inM=0}
         /^MASS/{inM=1;next}
         /^BOND|^ANGLE|^ANGL|^DIHE|^IMPR|^NONB|^NONBON/{inM=0}
         inM && $1==t {print $2; exit}' "$frcmod_file")
    [[ -n "$mass" ]] || continue
    # Halides: ~35-127; S: ~32; Se: ~79; N: ~14; O: ~16; C: ~12
    if (( $(awk -v m="$mass" 'BEGIN{print (m>=34 && m<=130)}') )); then
      if [[ -z "$halide_type" ]]; then halide_type="$t"; fi
    elif (( $(awk -v m="$mass" 'BEGIN{print (m>=29 && m<=34.5)}') )); then
      if [[ -z "$sulfur_type" ]]; then sulfur_type="$t"; fi
    elif (( $(awk -v m="$mass" 'BEGIN{print (m>=76 && m<=82)}') )); then
      if [[ -z "$selenium_type" ]]; then selenium_type="$t"; fi
    elif (( $(awk -v m="$mass" 'BEGIN{print (m>=11 && m<=13.5)}') )); then
      if [[ -z "$carbon_type" ]]; then carbon_type="$t"; fi
      if (( $(awk -v m="$mass" -v b="$best_nonhal_mass" 'BEGIN{print (m<b)}') )); then best_nonhal_mass="$mass"; nonhalide_type="$t"; fi
    elif (( $(awk -v m="$mass" 'BEGIN{print (m>13.5 && m<=15.5)}') )); then
      if [[ -z "$nitrogen_type" ]]; then nitrogen_type="$t"; fi
      if (( $(awk -v m="$mass" -v b="$best_nonhal_mass" 'BEGIN{print (m<b)}') )); then best_nonhal_mass="$mass"; nonhalide_type="$t"; fi
    elif (( $(awk -v m="$mass" 'BEGIN{print (m>15.5 && m<=18.5)}') )); then
      if [[ -z "$oxygen_type" ]]; then oxygen_type="$t"; fi
      if (( $(awk -v m="$mass" -v b="$best_nonhal_mass" 'BEGIN{print (m<b)}') )); then best_nonhal_mass="$mass"; nonhalide_type="$t"; fi
    else
      if (( $(awk -v m="$mass" -v b="$best_nonhal_mass" 'BEGIN{print (m<b)}') )); then best_nonhal_mass="$mass"; nonhalide_type="$t"; fi
    fi
  done
  [[ -n "$nonhalide_type" ]] || nonhalide_type="${m1_partners[0]}"

  # 4) Determine which atoms are bonded to AU.
  #    Priority: (a) PDB CONECT; (b) authoritative MOL2 bond list; (c) geometry fallback.
  local bonded_names=""

  # (a) CONECT
  local bonded_serials
  bonded_serials=$(awk -v a="$au_serial" '$1=="CONECT" && $2==a {for(i=3;i<=NF;i++) if($i!="") print $i}' "$pdb_file" | sort -u | tr '
' ' ')
  if [[ -n "$bonded_serials" ]]; then
    bonded_names=$(awk -v list="$bonded_serials" 'BEGIN{n=split(list,A," "); for(i=1;i<=n;i++) if(A[i]!="") S[A[i]]=1}
         ($1=="HETATM"||$1=="ATOM") && ($2 in S) {an=substr($0,13,4); gsub(/^ +| +$/,"",an); print an}' "$pdb_file" | sort -u | tr '
' ' ')
  fi

  # (b) authoritative MOL2 bond list (this is what fixes the di_cys_gold1 / di_secys_gold1 false positives)
  if [[ -z "$bonded_names" && -n "$auth_mol2_file" && -f "$auth_mol2_file" ]]; then
    local metal_line metal_id
    metal_line=$(mol2_first_metal "$auth_mol2_file" || true)
    metal_id=$(awk '{print $1}' <<<"$metal_line")
    if [[ -n "$metal_id" ]]; then
      while read -r nid; do
        [[ -n "$nid" ]] || continue
        nname=$(mol2_atom_name_by_id "$auth_mol2_file" "$nid" || true)
        [[ -n "$nname" ]] && bonded_names+="$nname "
      done < <(mol2_bonded_atoms "$auth_mol2_file" "$metal_id")
    fi
  fi

  # (c) geometry fallback (filtered by existence of matching partner type)
  if [[ -z "$bonded_names" ]]; then
    local allowC=0 allowN=0 allowO=0 allowS=0 allowSe=0 allowHal=0
    [[ -n "$carbon_type" || -n "$nonhalide_type" ]] && allowC=1
    [[ -n "$nitrogen_type" ]] && allowN=1
    [[ -n "$oxygen_type" ]] && allowO=1
    [[ -n "$sulfur_type" ]] && allowS=1
    [[ -n "$selenium_type" ]] && allowSe=1
    [[ -n "$halide_type" ]] && allowHal=1

    bonded_names=$(awk -v ax="$au_x" -v ay="$au_y" -v az="$au_z"       -v allowC="$allowC" -v allowN="$allowN" -v allowO="$allowO" -v allowS="$allowS" -v allowSe="$allowSe" -v allowHal="$allowHal"       'function dist(x1,y1,z1,x2,y2,z2){dx=x1-x2;dy=y1-y2;dz=z1-z2;return sqrt(dx*dx+dy*dy+dz*dz)}
       ($1=="ATOM"||$1=="HETATM") {
         an=substr($0,13,4); gsub(/^ +| +$/,"",an)
         elem=substr($0,77,2); gsub(/ /,"",elem); elem=toupper(elem)
         if(elem=="") { elem=an; gsub(/[0-9].*$/, "", elem); elem=toupper(elem) }
         if(elem=="AU") next
         # heavy atom filter
         if(elem=="H") next
         d=dist(ax,ay,az,$6,$7,$8)
         # element allow-list + cutoffs
         if((elem=="F"||elem=="CL"||elem=="BR"||elem=="I") && allowHal && d<3.2) {print an}
         else if(elem=="S" && allowS && d<2.8) {print an}
         else if(elem=="SE" && allowSe && d<2.9) {print an}
         else if(elem=="C" && allowC && d<2.6) {print an}
         else if(elem=="N" && allowN && d<2.4) {print an}
         else if(elem=="O" && allowO && d<2.4) {print an}
       }' "$pdb_file" | sort -u | tr '
' ' ')
  fi

  bonded_names=$(echo "$bonded_names" | xargs)
  if [[ -z "$bonded_names" ]]; then
    warn "mol2_apply_mcpb_ytypes_from_pdb: could not determine AU neighbors from CONECT, auth MOL2, or geometry; skipping"
    return 0
  fi

  # 5) Build name->type mapping. IMPORTANT: only map elements that have a compatible partner type.
  local map_str=""
  for n in $bonded_names; do
    el=$(echo "$n" | sed 's/[0-9].*$//' | tr '[:lower:]' '[:upper:]')
    want=""
    case "$el" in
      F|CL|BR|I)
        want="$halide_type"
        ;;
      S)
        want="$sulfur_type"
        ;;
      SE)
        want="$selenium_type"
        ;;
      C)
        want="${carbon_type:-$nonhalide_type}"
        ;;
      N)
        want="$nitrogen_type"
        ;;
      O)
        want="$oxygen_type"
        ;;
      *)
        # Unknown element: do not guess; skip.
        want=""
        ;;
    esac
    [[ -n "$want" ]] || continue
    map_str+="${n}:${want},"
  done
  map_str=${map_str%,}

  if [[ -z "$map_str" ]]; then
    warn "mol2_apply_mcpb_ytypes_from_pdb: AU neighbors found ($bonded_names) but none matched partner types in $frcmod_file; nothing to apply"
    return 0
  fi

  # 6) Apply mapping to LG1.mol2 by ATOM NAME (not numeric id), keeping all other GAFF types intact.
  awk -v map="$map_str" 'BEGIN{
      n=split(map,P,",");
      for(i=1;i<=n;i++){
        split(P[i],KV,":");
        if(KV[1]!="" && KV[2] != "") M[KV[1]]=KV[2];
      }
      inA=0
    }
    /^@<TRIPOS>ATOM/{inA=1;print;next}
    /^@<TRIPOS>/{inA=0;print;next}
    inA{
      if($2 in M) $6=M[$2];
      print;next
    }
    {print}
  ' "$mol2_file" > "$mol2_file.tmp" && mv "$mol2_file.tmp" "$mol2_file"
}


# mol2_write_mcpb_add_atomtypes_for_frcmod
# Writes a small LEaP snippet defining MCPB-generated atom types (M1 and the Y* types bonded to M1).
# Args:
#   $1: MCPB frcmod file
#   $2: output file (e.g., mcpb_atomtypes.in)
mol2_write_mcpb_add_atomtypes_for_frcmod() {
	local frcmod_file=$1
	local out_file=$2

	[[ -f "$frcmod_file" ]] || die "mol2_write_mcpb_add_atomtypes_for_frcmod: missing frcmod: $frcmod_file"
	[[ -n "${out_file:-}" ]] || die "mol2_write_mcpb_add_atomtypes_for_frcmod: missing output path"

	# Gather M1 partners from BOND section
	local partners
	partners="$(
		awk '
			BEGIN{inp=0}
			$1=="BOND"{inp=1; next}
			inp && ($1=="ANGL" || $1=="ANGLE" || $1=="DIHE" || $1=="IMPR" || $1=="NONB" || $1=="MASS") {exit}
			inp && ($1 ~ /-/ || $2 ~ /-/) {
				s = ($1 ~ /-/ ? $1 : $2)
				split(s,a,"-")
				if (a[1]=="M1") print a[2]
				else if (a[2]=="M1") print a[1]
			}
		' "$frcmod_file" | sort -u
	)"

	# Type->mass map
	declare -A mass
	while read -r t m; do
		[[ -n "${t:-}" ]] || continue
		[[ -n "${m:-}" ]] || continue
		mass["$t"]="$m"
	done < <(
		awk '
			BEGIN{inp=0}
			$1=="MASS"{inp=1; next}
			inp && $1=="BOND"{exit}
			inp && NF>=2 {
				if ($1=="YES" || $1=="NON" || $1=="NO") { print $2, $3 }
				else { print $1, $2 }
			}
		' "$frcmod_file"
	)

	# Build list: M1 + partners
	local all_types=("M1")
	local t
	for t in $partners; do
		all_types+=("$t")
	done

	# Emit addAtomTypes
	{
		echo "addAtomTypes {"
		for t in "${all_types[@]}"; do
			local m="${mass[$t]:-0}"
			local element="Du"
			local hyb="sp3"

			if [[ "$t" == "M1" ]]; then
				element="Au"
				hyb="sp3"
			else
				# crude but effective for your case: handle S separately (S~32 would otherwise look like Cl by mass)
				awk -v mm="$m" 'BEGIN{exit !(mm>76 && mm<82)}' && element="Se"
				awk -v mm="$m" 'BEGIN{exit !(mm>28 && mm<34)}' && element="S"
				awk -v mm="$m" 'BEGIN{exit !(mm>=34 && mm<60)}' && element="Cl"
				awk -v mm="$m" 'BEGIN{exit !(mm>5 && mm<25)}' && element="C"
				[[ "$element" == "C" ]] && hyb="sp2"
			fi

			printf '\t{ "%s" "%s" "%s" }\n' "$t" "$element" "$hyb"
		done
		echo "}"
	} > "$out_file"
}