#!/usr/bin/env python3
"""Collect and validate the one-time, owner-only switchover credential file."""
import argparse
import getpass
import json
import os
from pathlib import Path
import stat
import tempfile


SECTIONS = (
    "source",
    "target",
    "proxy_admin",
    "proxy_app",
    "forward_replication",
    "reverse_replication",
)


def credential_entries(config):
    entries = {}
    for section in SECTIONS:
        endpoint = config.get(section, {})
        name = endpoint.get("password_env")
        if name and name not in entries:
            entries[name] = (section, endpoint.get("user", ""))
    return entries


def save_passwords(path, passwords):
    path = Path(path).expanduser()
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    fd, temporary = tempfile.mkstemp(prefix=".credentials-", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump({"version": 1, "passwords": passwords}, stream)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    except BaseException:
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def load_passwords(path, required_names):
    path = Path(path).expanduser()
    if path.is_symlink() or not path.is_file():
        raise RuntimeError(f"Credential file is missing or is not a regular file: {path}")
    metadata = path.stat()
    if metadata.st_uid != os.getuid():
        raise PermissionError(f"Credential file must be owned by the current user: {path}")
    if stat.S_IMODE(metadata.st_mode) & 0o077:
        raise PermissionError(f"Credential file must have mode 0600: {path}")
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeError(f"Cannot read credential file {path}: {error}") from error
    if document.get("version") != 1 or not isinstance(document.get("passwords"), dict):
        raise RuntimeError(f"Unsupported credential file format: {path}")
    passwords = document["passwords"]
    missing = [name for name in required_names if not isinstance(passwords.get(name), str) or not passwords[name]]
    if missing:
        raise RuntimeError(f"Credential file is missing values for: {', '.join(missing)}")
    return passwords


def setup(config_path, output_path):
    config = json.loads(Path(config_path).read_text(encoding="utf-8"))
    entries = credential_entries(config)
    if not entries:
        raise RuntimeError("No password_env entries were found in the config")
    passwords = {}
    for name, (section, user) in entries.items():
        label = f"{section} ({user})" if user else section
        value = getpass.getpass(f"{label} password: ")
        if not value:
            raise RuntimeError(f"Empty password is not accepted for {label}")
        passwords[name] = value
    save_passwords(output_path, passwords)
    print(f"Saved {len(passwords)} credentials to {Path(output_path).expanduser()} (mode 0600).")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("setup", "validate"))
    parser.add_argument("--config", required=True)
    parser.add_argument("--file", required=True)
    args = parser.parse_args()
    config = json.loads(Path(args.config).read_text(encoding="utf-8"))
    names = list(credential_entries(config))
    if args.command == "setup":
        setup(args.config, args.file)
    else:
        load_passwords(args.file, names)
        print("Credential file is ready.")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        raise SystemExit(f"ERROR: {error}") from error
