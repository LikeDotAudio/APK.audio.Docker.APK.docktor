import os
import sys
import glob

import re

PROJECT = re.compile(r'^name:\s*["\']?([^"\'\s#]+)', re.M)

# Legacy variable names so old scripts don't break. KEYED BY TODAY'S FOLDER
# NAMES: a key naming a folder that no longer exists matches nothing and the
# variable is simply never emitted (APK:BareMetal, APK:discovery and
# APK:audio:WebPortal sat here after the pods landed, and COMPOSE_NODE /
# COMPOSE_PLUGINS / COMPOSE_PORTAL with them). _common.sh builds COMPOSE_CORE,
# COMPOSE_NODE, COMPOSE_PORTAL and COMPOSE_PLUGINS itself after the eval.
LEGACY_MAPPINGS = {
    "NODE.BareMetal": ("NODE", "BAREMETAL_COMPOSE_FILE"),
    "DATABASE.volume.Log-STORAGE": ("LOGGER", "LOGGER_COMPOSE_FILE"),
    "DATABASE.server.SQL": ("SQLCLUSTER", "SQLCLUSTER_COMPOSE_FILE"),
    "DATABUS.Broker.MQTT": ("MQTT", "MQTT_COMPOSE_FILE"),
    "PROTOCOL.discovery.NMOS": ("NMOS", "NMOS_COMPOSE_FILE"),
    "PROTOCOL.DEV.AES70": ("AES70", "AES70_COMPOSE_FILE"),
    "PROTOCOL.DEV.EMBER": ("EMBER", "EMBER_COMPOSE_FILE"),
    "DATABASE.server.NETBOX": ("NETBOX", "NETBOX_COMPOSE_FILE"),
    "POD.protocols": ("PROTOCOLS", "PROTOCOLS_COMPOSE_FILE"),
    "DISCOVERY.Engine": ("PLUGINS", "PLUGINS_COMPOSE_FILE"),
}

# WHICH STACKS ARE CONTAINERS IN SOMEONE ELSE'S POD. A member declares a
# compose file of its own and is `include:`d by its parent's, so the parent is
# what `up`/`down`/`rebuild-all` walk -- see "member_of" below.
# READ OFF THE PARENT'S `include:` BLOCK, NOT TYPED HERE. This was a table
# naming POD.protocols' three children; POD.workers then `include:`d
# DATATYPE.wireless.CSV, the table did not know, and up.sh walked the worker
# twice -- once on its own and once inside POD.workers
# (LOOSE-manager-docktor-stackssh-now-lists). The include IS the membership,
# so a new pod root or a new member needs no edit here. A POD ROOT is a
# `POD.<x>` folder (the tree's naming rule), read from its docker-compose.yml.
INCLUDE_BLOCK = re.compile(r'^include:[ \t]*\n((?:[ \t]+.*\n|[ \t]*\n|#.*\n)*)', re.M)
INCLUDE_PATH = re.compile(r'^[ \t]*-?[ \t]*(?:path:[ \t]*)?["\']?([^"\'\s#]+\.ya?ml)["\']?[ \t]*(?:#.*)?$', re.M)


def included_files(compose_path, text):
    """Real paths of every compose file `compose_path`'s top-level `include:` names."""
    match = INCLUDE_BLOCK.search(text if text.endswith('\n') else text + '\n')
    if not match:
        return []
    base = os.path.dirname(compose_path)
    return [os.path.realpath(os.path.join(base, rel))
            for rel in INCLUDE_PATH.findall(match.group(1))]


# NOT WALKED INTO: nothing under these holds a stack's Docker/ folder, and
# node_modules / target are where a walk would spend all its time.
_PRUNE = ('node_modules', 'target', '__pycache__')


def compose_files(dockers_dir):
    """Every `<stack>/Docker/docker-compose*.yml` under PODS/, AT ANY DEPTH.

    THE ONE WALKER. stacks.sh, staleness.sh, api.declared_projects and this
    file each used to glob a fixed number of rungs (one, two, or four), so a
    stack nested deeper than the reader expected -- Scanalyzer-API, at
    POD.THIN/Softapps/SCANALYZER_SUITE/SCANALYZER.Like.audio/Docker -- was
    driven by one script and invisible to the next. A glob that matches
    nothing is not an error, so a missing rung reads as a stack that does not
    exist. Hidden folders and _PRUNE are skipped; nothing else is.
    Sorted by path; callers that need another order sort again.
    """
    found = []
    if not dockers_dir or not os.path.isdir(dockers_dir):
        return found
    for base, directories, files in os.walk(dockers_dir):
        directories[:] = [d for d in directories
                          if not d.startswith('.') and d not in _PRUNE]
        if os.path.basename(base) != 'Docker':
            continue
        for filename in files:
            if filename.startswith('docker-compose') and filename.endswith('.yml'):
                found.append(os.path.join(base, filename))
    return sorted(found)


def cmd_bash_eval(project_name, dockers_dir):
    bash_lines = []
    stacks = []

    # Membership first: which compose file is `include:`d by which pod root.
    member_of_path = {}
    for path in compose_files(dockers_dir):
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                text = f.read()
        except OSError:
            continue
        parent = os.path.basename(os.path.dirname(os.path.dirname(path)))
        # ANY STACK'S PRIMARY FILE MAKES MEMBERS: a pod root's (POD.protocols,
        # POD.workers) and DISCOVERY.Engine's, which `include:`s every
        # PLUGIN.*. Only pod roots counted here once, so each plugin was walked
        # on its own AND again inside the engine -- 29 extra `up`s that mount
        # nothing new (LOOSE-docktor-walks-template). The broker's
        # portal-broker overlay is not a primary file, so the web stacks it
        # `include:`s are still walked on their own (the broker stays second up).
        if os.path.basename(path) != "docker-compose.yml":
            continue
        for child in included_files(os.path.realpath(path), text):
            member_of_path.setdefault(child, parent)

    # Every compose file, DEEPEST FIRST -- the order the four fixed-rung globs
    # this replaced walked in, which is what decides a folder-name tie below.
    seen_paths = set()
    seen_folders = set()
    for path in sorted(compose_files(dockers_dir),
                       key=lambda p: (-p.count(os.sep), p)):
        real_path = os.path.realpath(path)
        if real_path in seen_paths:
            continue
        seen_paths.add(real_path)
        
        # Extract folder name
        folder_name = os.path.basename(os.path.dirname(os.path.dirname(path)))
        file_base = os.path.basename(path)

        if folder_name.startswith("APK:plugin:"):
            continue

        # A LEADING `_` IS A SUPPORT FOLDER, NOT A STACK: PLUGINS/_template is
        # copied by new-plugin.sh, never run (plugin-includes.sh reads `_` the
        # same way). Declared, it was walked by up.sh and rebuild-all as a real
        # stack with a placeholder service (LOOSE-docktor-walks-template).
        if folder_name.startswith("_"):
            continue

        # Only primary compose files represent standalone stacks
        if file_base not in ("docker-compose.yml", "docker-compose.manager.yml"):
            continue

        if folder_name in seen_folders:
            continue
        seen_folders.add(folder_name)

        try:
            with open(real_path, "r", encoding="utf-8", errors="replace") as f:
                text = f.read()
        except OSError:
            continue
        if not PROJECT.search(text):
            continue
        
        # Priority logic: DockTor is 1, MQTT Mosquitto is 2 (first to launch after DockTor)
        up_order = 50
        if folder_name == "APK:Docktor" or "manager" in file_base: up_order = 1
        elif folder_name == "DATABUS.Broker.MQTT": up_order = 2
        elif "Log STORAGE" in folder_name or "Log-STORAGE" in folder_name: up_order = 3
        elif any(k in folder_name for k in ("server:SQL", "cluster:SQL", "server.SQL", "cluster.SQL")): up_order = 4
        elif folder_name == "NODE.BareMetal": up_order = 6
        elif folder_name == "DISCOVERY.Engine": up_order = 7
        elif folder_name == "POD.protocols": up_order = 8

        stack_info = {
            "name": folder_name,
            "compose_path": real_path,
            "file_base": file_base,
            "up_order": up_order,
            # A MEMBER IS DECLARED BUT NOT WALKED. Its compose variables are
            # still emitted (compose.sh nmos, verify.sh and panic-reboot.sh
            # all name them, and stacks.sh calls a file in ALL_DRIVEN_FILES
            # `driven`), and up-stack.sh still finds it by folder name --
            # it is only kept out of DOCKTOR_STACKS_FORWARD/REVERSE, because
            # the pod root `include:`s it and `up.sh` would otherwise mount
            # the same three containers twice.
            # APK:plugin:* is the other shape of this and takes the harder
            # road: skipped entirely above, then re-declared `driven` by name
            # in stacks.sh. Membership belongs here, where the parent is.
            "member_of": member_of_path.get(real_path)
        }
        stacks.append(stack_info)
        

    walked = [s for s in stacks if not s.get("member_of")]
    forward_stacks = sorted([s for s in walked if s["name"] != "APK:Docktor" and "manager" not in s.get("file_base", "")], key=lambda s: s["up_order"])
    docktor_stacks = [s for s in walked if s["name"] == "APK:Docktor" or "manager" in s.get("file_base", "")]
    
    forward_final = docktor_stacks + forward_stacks
    forward_names = " ".join(f'"{s["name"]}"' for s in forward_final)
    bash_lines.append(f"DOCKTOR_STACKS_FORWARD=({forward_names})")
    
    reverse_stacks = sorted([s for s in walked if s["name"] != "APK:Docktor" and "manager" not in s.get("file_base", "")], key=lambda s: s["up_order"], reverse=True)
    reverse_final = reverse_stacks + docktor_stacks
    reverse_names = " ".join(f'"{s["name"]}"' for s in reverse_final)
    bash_lines.append(f"DOCKTOR_STACKS_REVERSE=({reverse_names})")
    
    all_driven = []
    
    for s in stacks:
        name = s["name"]
        full_path = s["compose_path"]
        file_base = s.get("file_base", "")
        all_driven.append(full_path)
        
        # Legacy mapping or dynamic name
        if file_base == "docker-compose.portal-broker.yml":
            var_suffix, file_var = ("PORTAL", "PORTAL_COMPOSE_FILE")
        elif file_base == "docker-compose.manager.yml":
            var_suffix, file_var = ("MANAGER", "MANAGER_COMPOSE_FILE")
        elif name in LEGACY_MAPPINGS:
            var_suffix, file_var = LEGACY_MAPPINGS[name]
        else:
            # Sanitize name for bash variable
            clean_name = name.replace(":", "_").replace(".", "_").replace("-", "_").upper()
            var_suffix = clean_name
            file_var = f"{clean_name}_COMPOSE_FILE"
            
        bash_lines.append(f"{file_var}=\"{full_path}\"")
        bash_lines.append(f"COMPOSE_{var_suffix}=(\"${{COMPOSE_BASE[@]}}\" -f \"{full_path}\")")
        
        # In for_each_stack it checks stack name
        # We also want an eval rule for the dynamic names
        if file_base == "docker-compose.portal-broker.yml":
            safe_name = "PORTAL"
        elif file_base == "docker-compose.manager.yml":
            safe_name = "MANAGER"
        else:
            safe_name = name.replace(':', '_').replace('.', '_').replace('-', '_').replace(' ', '_')
        bash_lines.append(f"COMPOSE_BY_NAME_{safe_name}=(\"${{COMPOSE_BASE[@]}}\" -f \"{full_path}\")")
        
    # Export all driven files for stacks.sh
    driven_str = "\n".join(all_driven)
    bash_lines.append(f"export ALL_DRIVEN_FILES=\"{driven_str}\"")
        
    print("\n".join(bash_lines))

if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(1)
    
    action = sys.argv[1]
    if action == "bash_eval":
        cmd_bash_eval(sys.argv[2], sys.argv[3])
