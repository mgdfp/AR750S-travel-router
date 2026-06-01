#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.8"
# dependencies = ["paramiko"]
# ///
"""
Deploy mode-switch scripts to the GL-AR750S router.

Assigns one script from the configs/ folder to each physical switch position:
  dot   = one position of the slide switch
  clear = the other position

Reads credentials and known IPs from .env. Substitutes {{ROUTER_IP}},
{{WIFI_SSID}}, and {{WIFI_PASSWORD}} into each script before uploading,
so the files in configs/ contain no real credentials.

Run with:  uv run deploy.py
       or: ./deploy.py  (if executable)

Optional overrides:
  --host HOST
  --user USER
  --password PASS
"""
import argparse, getpass, os, re, shlex, sys
import paramiko

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIGS_DIR = os.path.join(HERE, "configs")


# ── Helpers ────────────────────────────────────────────────────────────────────

def read_env():
    env = {"hosts": []}
    try:
        with open(os.path.join(HERE, ".env")) as f:
            for line in f:
                if ":" not in line:
                    continue
                k, v = line.split(":", 1)
                k, v = k.strip(), v.strip()
                if re.match(r"router-static-ip-\d+$", k):
                    env["hosts"].append(v)
                else:
                    env[k] = v
    except FileNotFoundError:
        pass
    return env


def connect(host, user, password):
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(host, username=user, password=password, timeout=5)
    return c


def auto_detect_host(user, password, hosts):
    if not hosts:
        hosts = ["192.168.8.1", "192.168.10.89"]
    print(f"  (trying: {', '.join(hosts)})")
    for host in hosts:
        try:
            connect(host, user, password).close()
            return host
        except Exception:
            pass
    return None


def run(client, cmd):
    _, stdout, _ = client.exec_command(cmd)
    return stdout.read().decode().strip()


def upload(client, local_path, remote_path, substitutions):
    with open(local_path) as f:
        content = f.read()
    for placeholder, value in substitutions.items():
        content = content.replace(placeholder, value)
    stdin, stdout, _ = client.exec_command(
        f"tee {shlex.quote(remote_path)} > /dev/null"
    )
    stdin.write(content.encode())
    stdin.channel.shutdown_write()
    stdout.read()
    run(client, f"chmod 755 {shlex.quote(remote_path)}")


def list_configs():
    try:
        return sorted(f for f in os.listdir(CONFIGS_DIR) if f.endswith(".sh"))
    except FileNotFoundError:
        return []


def pick(prompt, options):
    for i, opt in enumerate(options, 1):
        print(f"  {i}) {opt}")
    while True:
        choice = input(f"{prompt} [1-{len(options)}]: ").strip()
        if choice.isdigit() and 1 <= int(choice) <= len(options):
            return options[int(choice) - 1]
        print("  Invalid choice, try again.")


# ── Main ───────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host",     help="Router IP (auto-detected if omitted)")
    parser.add_argument("--user",     help="SSH username (default: from .env or 'root')")
    parser.add_argument("--password", help="SSH password (default: from .env)")
    args = parser.parse_args()

    env      = read_env()
    user     = args.user or env.get("username", "root")
    password = args.password or env.get("password") or getpass.getpass(f"Password for {user}@router: ")
    hosts    = env["hosts"]

    # ── Find the router ───────────────────────────────────────────────
    host = args.host
    if host:
        try:
            connect(host, user, password).close()
        except Exception:
            print(f"Could not connect to {host}", file=sys.stderr)
            sys.exit(1)
    else:
        print("Auto-detecting router...", end=" ", flush=True)
        host = auto_detect_host(user, password, hosts)
        if host:
            print(f"found at {host}")
        else:
            print("not found.")
            host = input("Router IP: ").strip()
            try:
                connect(host, user, password).close()
            except Exception:
                print(f"Could not connect to {host}", file=sys.stderr)
                sys.exit(1)

    # ── Script and IP selection ───────────────────────────────────────
    scripts = list_configs()
    if not scripts:
        print(f"No .sh scripts found in {CONFIGS_DIR}/", file=sys.stderr)
        sys.exit(1)

    if not hosts:
        print("No router-static-ip entries found in .env", file=sys.stderr)
        sys.exit(1)

    print("\nAvailable scripts for 'dot' position:")
    dot_script = pick("Select script for 'dot'", scripts)
    print("\nAvailable IPs for 'dot' position:")
    dot_ip = pick("Select IP for 'dot'", hosts)

    print("\nAvailable scripts for 'clear' position:")
    clear_script = pick("Select script for 'clear'", scripts)
    print("\nAvailable IPs for 'clear' position:")
    clear_ip = pick("Select IP for 'clear'", hosts)

    # ── Confirm ───────────────────────────────────────────────────────
    print(f"\n  Router : {user}@{host}")
    print(f"  dot    → {dot_script}  (IP: {dot_ip})")
    print(f"  clear  → {clear_script}  (IP: {clear_ip})\n")

    if input("Proceed? [y/N] ").strip().lower() != "y":
        print("Aborted.")
        sys.exit(0)

    # ── Deploy ────────────────────────────────────────────────────────
    client = connect(host, user, password)

    base_subs = {
        "{{WIFI_SSID}}":     env.get("wifi-ssid", ""),
        "{{WIFI_PASSWORD}}": env.get("wifi-password", ""),
    }

    for position, script_name, router_ip in [
        ("dot",   dot_script,   dot_ip),
        ("clear", clear_script, clear_ip),
    ]:
        remote_dir  = f"/usr/sbin/{position}-active"
        remote_path = f"{remote_dir}/{script_name}"
        local_path  = os.path.join(CONFIGS_DIR, script_name)

        subs = {**base_subs, "{{ROUTER_IP}}": router_ip}

        run(client, f"mkdir -p {shlex.quote(remote_dir)}")
        run(client, f"rm -f {shlex.quote(remote_dir)}/*.sh")
        upload(client, local_path, remote_path, subs)

        size = run(client, f"wc -c < {shlex.quote(remote_path)}")
        print(f"  {position:5} → {remote_path} ({size} bytes, IP: {router_ip})")

    client.close()
    print("\nDone. Flip the switch to test.")


if __name__ == "__main__":
    main()
