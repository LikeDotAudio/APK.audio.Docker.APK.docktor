import os
import sys
import json

def get_config_path():
    repo_root = os.environ.get("APKAUDIO_REPO")
    if not repo_root:
        d = os.path.dirname(os.path.abspath(__file__))
        while d != "/" and not os.path.exists(os.path.join(d, "docktor.json")):
            d = os.path.dirname(d)
        if d == "/":
            return None
        return os.path.join(d, "docktor.json")
    return os.path.join(repo_root, "APK:PODS", "docktor.json")

def load_config():
    path = get_config_path()
    if not path or not os.path.exists(path):
        return None
    with open(path, "r") as f:
        return json.load(f)

def cmd_bash_eval(project_name, dockers_dir):
    config = load_config()
    if not config:
        return
        
    bash_lines = []
    
    # We will need arrays for forward and reverse order
    stacks = config.get("stacks", [])
    
    forward_stacks = sorted(stacks, key=lambda s: s.get("up_order", 99))
    forward_names = " ".join(s["name"] for s in forward_stacks)
    bash_lines.append(f"DOCKTOR_STACKS_FORWARD=({forward_names})")
    
    reverse_stacks = sorted(stacks, key=lambda s: s.get("up_order", 99), reverse=True)
    reverse_names = " ".join(s["name"] for s in reverse_stacks)
    bash_lines.append(f"DOCKTOR_STACKS_REVERSE=({reverse_names})")
    
    for s in stacks:
        name = s["name"]
        up_name = name.upper()
        # Handle special mappings required by legacy scripts
        var_suffix = up_name
        if name == "node":
            var_suffix = "NODE"
            file_var = "BAREMETAL_COMPOSE_FILE"
        elif name == "core":
            file_var = "COMPOSE_FILE"
        elif name == "docktor":
            var_suffix = "MANAGER"
            file_var = "MANAGER_COMPOSE_FILE"
        else:
            file_var = f"{up_name}_COMPOSE_FILE"
            
        full_path = os.path.join(dockers_dir, s["compose_path"])
        
        bash_lines.append(f"{file_var}=\"{full_path}\"")
        bash_lines.append(f"COMPOSE_{var_suffix}=(\"${{COMPOSE_BASE[@]}}\" -f \"{full_path}\")")
        
    print("\n".join(bash_lines))

if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(1)
    
    action = sys.argv[1]
    if action == "bash_eval":
        cmd_bash_eval(sys.argv[2], sys.argv[3])
