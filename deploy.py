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

Run with:  uv run deploy.py
       or: ./deploy.py  (if executable)

Optional overrides:
  --host HOST
  --user USER
  --password PASS
"""
import argparse, getpass, os, shlex, sys
import paramiko

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIGS_DIR = os.path.join(HERE, "configs")


# ── Helpers ────────────────────────────────────────────────────────────────────

def read_env():
    env = {}
    try:
        with open(os.path.join(HERE, ".env")) as f:
            for line in f:
                if ":" in line:
                    k, v = line.split(":", 1)
                    env[k.strip()] = v.strip()
    except FileNotFoundError:
        pass
    return env


def connect(host, user, password):
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(host, username=user, password=password, timeout=5)
    return c


def scan_configs():
    """
    Scan all config scripts and extract:
      - IPs from  uci set network.lan.ipaddr lines
      - passwords from  # router-password: <value>  comment lines
    Returns (ips, passwords) as lists of unique values.
    """
    import re
    ips, passwords = [], []
    try:
        for name in sorted(os.listdir(CONFIGS_DIR)):
            if not name.endswith(".sh"):
                continue
            with open(os.path.join(CONFIGS_DIR, name)) as f:
                for line in f:
                    if "network.lan.ipaddr" in line:
                        m = re.search(r"(\d+\.\d+\.\d+\.\d+)", line)
                        if m and m.group(1) not in ips:
                            ips.append(m.group(1))
                    if line.startswith("# router-password:"):
                        pw = line.split(":", 1)[1].strip()
                        if pw and pw not in passwords:
                            passwords.append(pw)
    except FileNotFoundError:
        pass
    return ips, passwords


def auto_detect_host(user, passwords, ips):
    """Try every combination of known IPs and passwords. Returns (host, password)."""
    if not ips:
        ips = ["192.168.8.1", "192.168.10.89"]
    print(f"  (trying: {', '.join(ips)})")
    for host in ips:
        for pw in passwords:
            try:
                connect(host, user, pw).close()
                return host, pw
            except Exception:
                pass
    return None, None


def run(client, cmd):
    _, stdout, _ = client.exec_command(cmd)
    return stdout.read().decode().strip()


def upload(client, local_path, remote_path):
    with open(local_path) as f:
        content = f.read()
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


def pick_script(position, scripts):
    print(f"\nAvailable scripts for '{position}' position:")
    for i, name in enumerate(scripts, 1):
        print(f"  {i}) {name}")
    while True:
        choice = input(f"Select script for '{position}' [1-{len(scripts)}]: ").strip()
        if choice.isdigit() and 1 <= int(choice) <= len(scripts):
            return scripts[int(choice) - 1]
        print("  Invalid choice, try again.")


# ── Main ───────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host",     help="Router IP (auto-detected if omitted)")
    parser.add_argument("--user",     help="SSH username (default: from .env or 'root')")
    parser.add_argument("--password", help="SSH password (default: from .env)")
    args = parser.parse_args()

    # ── Credentials & known IPs from configs ──────────────────────────
    env  = read_env()
    user = args.user or env.get("username", "root")

    config_ips, config_passwords = scan_configs()

    # Build password candidates: explicit arg → .env → from config scripts
    if args.password:
        passwords = [args.password]
    else:
        passwords = []
        if env.get("password"):
            passwords.append(env["password"])
        passwords += [p for p in config_passwords if p not in passwords]

    if not passwords:
        passwords = [getpass.getpass(f"Password for {user}@router: ")]

    # ── Router IP ─────────────────────────────────────────────────────
    host = args.host
    if host:
        # Host given — still need to find the right password
        password = None
        for pw in passwords:
            try:
                connect(host, user, pw).close()
                password = pw
                break
            except Exception:
                pass
        if not password:
            print(f"Could not authenticate to {host}", file=sys.stderr)
            sys.exit(1)
    else:
        print("Auto-detecting router...", end=" ", flush=True)
        host, password = auto_detect_host(user, passwords, config_ips)
        if host:
            print(f"found at {host}")
        else:
            print("not found.")
            host      = input("Router IP: ").strip()
            password  = getpass.getpass(f"Password for {user}@{host}: ")

    # ── Script selection ──────────────────────────────────────────────
    scripts = list_configs()
    if not scripts:
        print(f"No .sh scripts found in {CONFIGS_DIR}/", file=sys.stderr)
        sys.exit(1)

    dot_script   = pick_script("dot",   scripts)
    clear_script = pick_script("clear", scripts)

    # ── Confirm ───────────────────────────────────────────────────────
    print(f"\n  Router : {user}@{host}")
    print(f"  dot    → {dot_script}")
    print(f"  clear  → {clear_script}\n")

    if input("Proceed? [y/N] ").strip().lower() != "y":
        print("Aborted.")
        sys.exit(0)

    # ── Deploy ────────────────────────────────────────────────────────
    client = connect(host, user, password)  # password resolved during detection

    for position, script_name in [("dot", dot_script), ("clear", clear_script)]:
        remote_dir  = f"/usr/sbin/{position}-active"
        remote_path = f"{remote_dir}/{script_name}"
        local_path  = os.path.join(CONFIGS_DIR, script_name)

        run(client, f"mkdir -p {shlex.quote(remote_dir)}")
        run(client, f"rm -f {shlex.quote(remote_dir)}/*.sh")
        upload(client, local_path, remote_path)

        size = run(client, f"wc -c < {shlex.quote(remote_path)}")
        print(f"  {position:5} → {remote_path} ({size} bytes)")

    client.close()
    print("\nDone. Flip the switch to test.")


if __name__ == "__main__":
    main()
