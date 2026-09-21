import os
import sys
import glob

import re

PROJECT = re.compile(r'^name:\s*["\']?([^"\'\s#]+)', re.M)

# Hardcoded legacy variable names so old scripts don't break
LEGACY_MAPPINGS = {
    "APK:BareMetal": ("CORE", "COMPOSE_FILE"),
    "DATABASE:volume:Log STORAGE": ("LOGGER", "LOGGER_COMPOSE_FILE"),
    "DATABASE:server:SQL": ("SQLCLUSTER", "SQLCLUSTER_COMPOSE_FILE"),
    "DATABUS:Broker:MQTT": ("MQTT", "MQTT_COMPOSE_FILE"),
    "APK:audio:WebPortal": ("PORTAL", "PORTAL_COMPOSE_FILE"),
    "PROTOCOL:discovery:NMOS": ("NMOS", "NMOS_COMPOSE_FILE"),
    "PROTOCOL:DEV:AES70": ("AES70", "AES70_COMPOSE_FILE"),
    "PROTOCOL:DEV:EMBER": ("EMBER", "EMBER_COMPOSE_FILE"),
    "DATABASE:server:NETBOX": ("NETBOX", "NETBOX_COMPOSE_FILE"),
    "POD:protocols": ("PROTOCOLS", "PROTOCOLS_COMPOSE_FILE"),
    "APK:discovery": ("PLUGINS", "PLUGINS_COMPOSE_FILE"),
    "APK:plugins:Build": ("PLUGINS", "PLUGINS_COMPOSE_FILE"),
    "APK:Docktor": ("MANAGER", "MANAGER_COMPOSE_FILE")
}

# WHICH STACKS ARE CONTAINERS IN SOMEONE ELSE'S POD. A member declares a
# compose file of its own and is `include:`d by its parent's, so the parent is
# what `up`/`down`/`rebuild-all` walk -- see "member_of" below.
# ⚠️ THE PARENT MUST BE A STACK HERE TOO, or its members become unreachable:
#    POD:protocols/Docker/docker-compose.yml is what makes this table true.
MEMBER_OF = {
    "PROTOCOL:discovery:NMOS": "POD:protocols",
    "PROTOCOL:DEV:AES70": "POD:protocols",
    "PROTOCOL:DEV:EMBER": "POD:protocols",
}


def cmd_bash_eval(project_name, dockers_dir):
    bash_lines = []
    stacks = []

    # Find all docker-compose files
    patterns = [
        os.path.join(dockers_dir, "*", "*", "*", "*", "Docker", "docker-compose*.yml"),
        os.path.join(dockers_dir, "*", "*", "*", "Docker", "docker-compose*.yml"),
        os.path.join(dockers_dir, "*", "*", "Docker", "docker-compose*.yml"),
        os.path.join(dockers_dir, "*", "Docker", "docker-compose*.yml")
    ]
    
    seen_paths = set()
    seen_folders = set()
    for pattern in patterns:
        for path in sorted(glob.glob(pattern)):
            real_path = os.path.realpath(path)
            if real_path in seen_paths:
                continue
            seen_paths.add(real_path)
            
            # Extract folder name
            folder_name = os.path.basename(os.path.dirname(os.path.dirname(path)))
            file_base = os.path.basename(path)

            if folder_name.startswith("APK:plugin:"):
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
            elif folder_name == "DATABUS:Broker:MQTT": up_order = 2
            elif "Log STORAGE" in folder_name: up_order = 3
            elif "server:SQL" in folder_name or "cluster:SQL" in folder_name: up_order = 4
            elif folder_name == "APK:BareMetal": up_order = 6
            elif folder_name in ("APK:discovery", "APK:plugins:Build"): up_order = 7
            elif folder_name == "POD:protocols": up_order = 8

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
                "member_of": MEMBER_OF.get(folder_name)
            }
            stacks.append(stack_info)
            
    LEGACY_MAPPINGS["node"] = ("NODE", "BAREMETAL_COMPOSE_FILE")

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
            clean_name = name.replace(":", "_").replace("-", "_").upper()
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
            safe_name = name.replace(':', '_').replace('-', '_').replace(' ', '_')
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
