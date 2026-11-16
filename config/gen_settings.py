#!/usr/bin/env python3
"""gen_settings.py — compile config/settings.json into a bash-3.2 sourceable cache.

Usage: python3 gen_settings.py settings.json   (cache on stdout)

Never run by hand in normal use: config/load_settings.sh invokes it whenever the
JSON (or this generator) is newer than config/settings.cache.sh, then sources the
result. If generation fails, the loader keeps the previous cache (last-good), so a
bad edit to settings.json can never brick window management.

SCHEMA — settings.json
  apps: ordered list. Order matters: the `canonical: true` entries, in order, form
        the slot sequence's canonical app order (slotlib APPS / placeapp splicing).
    key        (required) state key — how slotlib records the app in slot_members.
    open       name for `open -a` / System Events process lookups when LAUNCHING
               (app_resolve OPEN_NAME). Default: key.
    activate   name slotlib activates/restores by (activate_app, scene_restore
               args — settings_open_name). Default: key, NOT `open`: e.g. Kindle
               launches as "Amazon Kindle" but activates as "Kindle".
    alt_names  other window-OWNER spellings the app shows up under in window lists
               (e.g. Fusion also reports as "Autodesk Fusion"). key+open are always
               included automatically.
    aliases    extra CLI shorthands for goto_app/focus.sh ("chrome", "btt"). The
               normalized forms of key and open (lowercased, spaces/hyphens
               stripped) are always accepted automatically.
    special    app_resolve hook: "finder" | "btt" | "parallels" | "coherence" |
               "controlroom" | "explorer" (window-creation quirks; "parallels" opens the VM itself,
               ~/Parallels/*.pvm, not Parallels' Control Center; "coherence" is a
               Windows app on its own full-screen Space — goto_app/focus.sh just
               open its Parallels stub app, bypassing the slots; "controlroom" is
               always a floater — goto_app/focus.sh both run remap/remap_open.sh,
               which shows it or, when it is already in view, puts it away;
               "explorer" is Windows' File Explorer, a floater on the Windows
               Spaces — app_resolve.sh open_explorer, via max/winlink).
    label      what Control Room's app pickers call it (default: key). Display
               only — every reader here still goes by key.
    titlebar   px of title bar to push above the top screen edge whenever the app
               is snapped to a tile that touches the top (full / left / right /
               top-*): the window is set to y=-titlebar, h+titlebar, so the strip
               is off-screen (menu bar is auto-hidden). Photoshop's Application
               Frame has no setting to drop its 22px strip. Applied by do_move
               (snap) and realize_plan.py (reveal); readers clamp to the screen,
               so the window still classifies as its tile. Default 0.
    cad        presence marks a CAD app (reanchor/scroll/dwell handoff):
               { top_bar: px, bottom_bar: px } — the bar heights were read by
               cadbars, retired (ARCHITECTURE.md § cadbars); kept as data.
  place_layouts: list of { primary, members: [ { app, pos } ] } — when `primary`
        gets its own new space via placeapp, open it with these members instead of
        solo-full (see slots/MODEL.md §Custom default layouts). Order is the
        companion-side tiebreak.
  aux_trackpad: "builtin" | "<device id>" | "none" — the modifier pad: its resting
        fingers are remapd's `fingers` axis and it never drives the pointer or
        reanchor nav. Read by bin/auxpad.h (remapd + reanchor) at launch / pad
        reconnect; ids are logged as "trackpad bound: id=…". Not cached here.

EMITTED CACHE (consumed by slotlib.sh, app_resolve.sh, slots/cad_handoff.sh):
  SLOTS_SETTINGS_OK=1
  APPS=(...)                      canonical state keys, in order
  PLACE_LAYOUTS=(...)             "PRIMARY|app:pos;app:pos" entries
  CAD_APPS="..."                  space-separated CAD state keys
  CAD_MATCH_NAMES="..."           newline-separated: every owner spelling of CAD apps
  COHERENCE_APPS="..."            newline-separated: owner spellings of special "coherence"
  settings_normalize NAME         → state key (owner spelling → key)
  settings_open_name KEY          → activation/restore name (see `activate`)
  settings_alt_names KEY          → every owner spelling, one per line
  settings_titlebar KEY           → px of title bar hidden above the screen (0)
  settings_resolve NORMKEY        sets OPEN_NAME/SLOT_NAME/PGREP_PAT/SPECIAL,
                                  returns 1 for unknown apps (caller falls back)
"""
import json
import sys


def norm_alias(s):
    return s.lower().replace(" ", "").replace("-", "")


def sq(s):  # single-quote for shell
    return "'" + s.replace("'", "'\\''") + "'"


def main():
    with open(sys.argv[1]) as f:
        cfg = json.load(f)

    apps = cfg["apps"]
    for a in apps:
        a.setdefault("open", a["key"])
        a.setdefault("activate", a["key"])
        # every owner spelling, deduped, key first
        names = [a["key"]]
        for n in [a["open"], a["activate"]] + a.get("alt_names", []):
            if n not in names:
                names.append(n)
        a["_owners"] = names
        al = {norm_alias(a["key"]), norm_alias(a["open"])}
        al.update(norm_alias(x) for x in a.get("aliases", []))
        a["_aliases"] = sorted(al)

    canon = [a for a in apps if a.get("canonical")]
    cad = [a for a in apps if "cad" in a]

    out = []
    w = out.append
    w("# GENERATED by config/gen_settings.py from config/settings.json — do not edit.")
    w("SLOTS_SETTINGS_OK=1")

    w("APPS=(%s)" % " ".join(sq(a["key"]) for a in canon))

    layouts = []
    for l in cfg.get("place_layouts", []):
        spec = ";".join("%s:%s" % (m["app"], m["pos"]) for m in l["members"])
        layouts.append("%s|%s" % (l["primary"], spec))
    w("PLACE_LAYOUTS=(%s)" % " ".join(sq(x) for x in layouts))

    w("CAD_APPS=%s" % sq(" ".join(a["key"] for a in cad)))
    cad_names = []
    for a in cad:
        cad_names.extend(a["_owners"])
    w("CAD_MATCH_NAMES=%s" % sq("\n".join(cad_names)))
    w("COHERENCE_APPS=%s" % sq("\n".join(
        n for a in apps if a.get("special") == "coherence" for n in a["_owners"])))

    # owner spelling → state key (identity for unknown names)
    w("settings_normalize() {")
    w("  case \"$1\" in")
    for a in apps:
        alts = [n for n in a["_owners"] if n != a["key"]]
        if alts:
            w("    %s) echo %s ;;" % ("|".join(sq(n) for n in alts), sq(a["key"])))
    w("    *) echo \"$1\" ;;")
    w("  esac")
    w("}")

    # state key → activation/restore name (identity for unknown keys)
    w("settings_open_name() {")
    w("  case \"$1\" in")
    for a in apps:
        if a["activate"] != a["key"]:
            w("    %s) echo %s ;;" % (sq(a["key"]), sq(a["activate"])))
    w("    *) echo \"$1\" ;;")
    w("  esac")
    w("}")

    # state key → every owner spelling, one per line (just the key for unknowns)
    w("settings_alt_names() {")
    w("  case \"$1\" in")
    for a in apps:
        if len(a["_owners"]) > 1:
            w("    %s) printf '%%s\\n' %s ;;"
              % (sq(a["key"]), " ".join(sq(n) for n in a["_owners"])))
    w("    *) printf '%s\\n' \"$1\" ;;")
    w("  esac")
    w("}")

    # state key → px of title bar hidden above the screen top (0 for most apps)
    w("settings_titlebar() {")
    w("  case \"$1\" in")
    for a in apps:
        if a.get("titlebar"):
            w("    %s) echo %d ;;" % (sq(a["key"]), int(a["titlebar"])))
    w("    *) echo 0 ;;")
    w("  esac")
    w("}")

    # normalized alias → OPEN_NAME/SLOT_NAME/PGREP_PAT/SPECIAL globals
    w("settings_resolve() {")
    w("  case \"$1\" in")
    for a in apps:
        pgrep = "|".join(a["_owners"])
        w("    %s)" % "|".join(a["_aliases"]))
        w("      OPEN_NAME=%s; SLOT_NAME=%s; PGREP_PAT=%s; SPECIAL=%s ;;"
          % (sq(a["open"]), sq(a["key"]), sq(pgrep), sq(a.get("special", ""))))
    w("    *) return 1 ;;")
    w("  esac")
    w("}")

    sys.stdout.write("\n".join(out) + "\n")


if __name__ == "__main__":
    main()
