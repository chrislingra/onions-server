"""lib/stufen.py -- which files of the Toolserver belong to which tier.

    git -C <src> show HEAD:db/schema_seed.sql | python3 lib/stufen.py base [addon ...]

Prints one sparse-checkout pattern ("/<path>") per active, registered file of the named
tiers, sorted. Step 7 hands the list to "git sparse-checkout set --no-cone --stdin", so
the working copy -- and with it /opt/toolserver -- holds exactly those files.

WHY THE REGISTRY (operator 2026-09-25: "der Auftrag war, nur opencore zu installieren und
die anderen Module nachzuziehen bei der Erstinstallation. Als DEMO."): until then step 7
cloned the whole repository and copied all of it, so a new server carried every module --
lingra's internal tile included, which is never part of a customer's installation
(D-OPENCORE-04). What belongs to which tier is not decided here and not by directory
names: governance.project_files names every file of the platform and its module,
public.platform_modules gives each module its tier (base = open core, addon = extension,
shipped as demo, internal = lingra's own, never shipped). Both travel with the repository
in the start dump (db/schema_seed.sql) -- the same rows the new server's database is
loaded from a minute later. This script only reads them.

A registered file whose module has no tier stops the run (exit 2) and is named: left out,
it would be missing on the server; let in, it could be lingra's. Neither is guessed.
Standard library only -- it runs on the bare host before the Toolserver exists.
"""
import sys

TIERS = ("base", "addon", "internal")
FILES = "governance.project_files"
MODULES = "public.platform_modules"


def copy_blocks(stream, wanted):
    """{table: [row dict]} of the COPY blocks of a pg_dump for the wanted tables."""
    blocks, table, cols = {}, None, None
    for line in stream:
        line = line.rstrip("\n")
        if table is None:
            if line.startswith("COPY ") and line.endswith(" FROM stdin;"):
                name = line[5:line.index(" (")]
                if name in wanted:
                    table = name
                    cols = [c.strip() for c in line[line.index("(") + 1:line.rindex(")")].split(",")]
                    blocks[table] = []
            continue
        if line == "\\.":
            table = None
            continue
        values = [None if v == "\\N" else v for v in line.split("\t")]
        blocks[table].append(dict(zip(cols, values)))
    return blocks


def main(argv):
    # one pattern per LF-terminated line on every system: git reads a CR as part of the path
    sys.stdout.reconfigure(newline="\n")
    wanted = argv[1:]
    if not wanted or any(t not in TIERS for t in wanted):
        sys.stderr.write("usage: python3 stufen.py <tier>... (tiers: %s) < schema_seed.sql\n"
                         % " ".join(TIERS))
        return 1
    blocks = copy_blocks(sys.stdin, (FILES, MODULES))
    for table in (FILES, MODULES):
        if not blocks.get(table):
            sys.stderr.write("the start dump carries no rows of %s -- nothing can be decided\n" % table)
            return 2
    # a file names its module by the tile key (crm) or by the Python package (customers)
    tier_of = {}
    for m in blocks[MODULES]:
        for name in (m.get("key"), m.get("package")):
            if name and m.get("tier"):
                tier_of[name] = m["tier"]
    chosen, unknown = [], []
    for f in blocks[FILES]:
        if f.get("active") != "t":
            continue
        tier = tier_of.get(f.get("module") or "")
        if tier is None:
            unknown.append("%s (module %s)" % (f["path"], f.get("module") or "-"))
        elif tier in wanted:
            chosen.append(f["path"])
    if unknown:
        sys.stderr.write("registered files without a tier -- the installation stops here:\n")
        for u in unknown:
            sys.stderr.write("    %s\n" % u)
        return 2
    for path in sorted(chosen):
        sys.stdout.write("/%s\n" % path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
