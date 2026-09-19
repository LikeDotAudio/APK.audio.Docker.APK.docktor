import os
import sys
import glob

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
    "APK:plugins:Build": ("PLUGINS", "PLUGINS_COMPOSE_FILE"),
    "APK:Docktor": ("MANAGER", "MANAGER_COMPOSE_FILE")
}

def cmd_bash_eval(project_name, dockers_dir):
    bash_lines = []
    stacks = []

    # Find all docker-compose files
    patterns = [
        os.path.join(dockers_dir, "*", "*", "Docker", "docker-compose.yml"),
        os.path.join(dockers_dir, "*", "Docker", "docker-compose.yml")
    ]
    
    seen_paths = set()
    for pattern in patterns:
        for path in glob.glob(pattern):
            real_path = os.path.realpath(path)
            if real_path in seen_paths:
                continue
            seen_paths.add(real_path)
            
            # Extract folder name
            folder_name = os.path.basename(os.path.dirname(os.path.dirname(path)))
            
            # Priority logic
            up_order = 50
            if folder_name == "APK:Docktor": up_order = 1
            elif "Log STORAGE" in folder_name: up_order = 2
            elif "SQL" in folder_name: up_order = 3
            elif folder_name == "APK:BareMetal": up_order = 4
            elif folder_name == "DATABUS:Broker:MQTT": up_order = 5
            
            stack_info = {
                "name": folder_name,
                "compose_path": real_path,
                "up_order": up_order
            }
            stacks.append(stack_info)
            
    # Include hardware overlay for backwards compatibility
    hw_path = os.path.join(dockers_dir, "POD:APK_THICK", "APK:BareMetal", "Docker", "docker-compose.hardware.yml")
    if os.path.exists(hw_path):
        stacks.append({
            "name": "node",
            "compose_path": hw_path,
            "up_order": 11
        })
        LEGACY_MAPPINGS["node"] = ("NODE", "BAREMETAL_COMPOSE_FILE")

    forward_stacks = sorted(stacks, key=lambda s: s["up_order"])
    forward_names = " ".join(s["name"] for s in forward_stacks)
    bash_lines.append(f"DOCKTOR_STACKS_FORWARD=({forward_names})")
    
    reverse_stacks = sorted(stacks, key=lambda s: s["up_order"], reverse=True)
    reverse_names = " ".join(s["name"] for s in reverse_stacks)
    bash_lines.append(f"DOCKTOR_STACKS_REVERSE=({reverse_names})")
    
    all_driven = []
    
    for s in stacks:
        name = s["name"]
        full_path = s["compose_path"]
        all_driven.append(full_path)
        
        # Legacy mapping or dynamic name
        if name in LEGACY_MAPPINGS:
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
