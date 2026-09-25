"""lib/stufen.py -- which files of the Toolserver belong to which tier, or to which module.

    git -C <src> show HEAD:db/schema_seed.sql | python3 lib/stufen.py base [<module> ...]

Each argument is a tier (base, addon, internal) or a module, named by its tile key (crm)
or its Python package (customers). Prints one sparse-checkout pattern ("/<path>") per
active, registered file of what was named, sorted. Step 7 and setup-module.sh hand the
list to "git sparse-checkout set --no-cone --stdin", so the working copy -- and with it
/opt/toolserver -- holds exactly those files.

WHY THE REGISTRY (operator 2026-09-25: "der Auftrag war, nur opencore zu installieren und
die anderen Module nachzuziehen bei der Erstinstallation. Als DEMO." -- and the same day:
"die Erweiterungen werden selectiv ueber die oberflaeche nach Terminalinstallation geholt",
"lingra darf niemals auftauchen"): until then step 7 cloned the whole repository and copied
all of it, so a new server carried every module -- lingra's internal tile included, which
is never part of a customer's installation (D-OPENCORE-04). What belongs to which tier is
not decided here and not by directory names: governance.project_files names every file of
the platform and its module, public.platform_modules gives each module its tier (base =
open core, addon = extension, shipped as demo, internal = lingra's own, never shipped).
Both travel with the repository in the start dump (db/schema_seed.sql) -- the same rows the
new server's database is loaded from a minute later. This script only reads them.

Refused, with the reason on stderr: a registered file whose module has no tier (exit 2 --
left out it would be missing on the server, let in it could be lingra's), a module name the
dump does not know (exit 2), and a module of the internal tier named on its own (exit 3 --
nothing installs lingra). The tier internal as a whole stays listable: step 7 needs it to
recognise a host that still carries such files.
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


def module_of(modules):
    """{name: (key, tier)} -- a module answers to its tile key and to its package."""
    out = {}
    for m in modules:
        for name in (m.get("key"), m.get("package")):
            if name and m.get("tier"):
                out[name] = (m["key"], m["tier"])
    return out


def main(argv):
    # one pattern per LF-terminated line on every system: git reads a CR as part of the path
    sys.stdout.reconfigure(newline="\n")
    asked = argv[1:]
    if not asked:
        sys.stderr.write("usage: python3 stufen.py <tier or module>... (tiers: %s) < schema_seed.sql\n"
                         % " ".join(TIERS))
        return 1
    blocks = copy_blocks(sys.stdin, (FILES, MODULES))
    for table in (FILES, MODULES):
        if not blocks.get(table):
            sys.stderr.write("the start dump carries no rows of %s -- nothing can be decided\n" % table)
            return 2
    modules = module_of(blocks[MODULES])
    tiers, keys = set(), set()
    for a in asked:
        if a in TIERS:
            tiers.add(a)
        elif a not in modules:
            sys.stderr.write("module '%s' is not in the start dump\n" % a)
            return 2
        elif modules[a][1] == "internal":
            sys.stderr.write("module '%s' belongs to lingra's internal tier -- it is never installed\n" % a)
            return 3
        else:
            keys.add(modules[a][0])
    chosen, unknown = [], []
    for f in blocks[FILES]:
        if f.get("active") != "t":
            continue
        mod = modules.get(f.get("module") or "")
        if mod is None:
            unknown.append("%s (module %s)" % (f["path"], f.get("module") or "-"))
        elif mod[1] in tiers or mod[0] in keys:
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
