"""Install/remove only the local azooKey Mixed test build. Never targets azooKeyMac."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import time

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build/auto-mixed/mixed-ime"
BUNDLE_ID = "dev.azookey.inputmethod.azooKeyMixed"
SERVICE = BUNDLE_ID + ".ConverterServer"


def execute(args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)


class MixedInstaller:
    def __init__(self, home, control, runner=execute):
        self.home, self.control, self.run = home, control, runner
        self.app = home / "Library/Input Methods/azooKeyMixed.app"
        self.agent = home / "Library/LaunchAgents" / (SERVICE + ".plist")
        self.domain = "gui/" + str(os.getuid())

    def validate_app(self, app):
        if app.is_symlink():
            raise ValueError("Refusing an app symlink")
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        modes = info.get("ComponentInputModeDict", {}).get("tsInputModeListKey", {})
        identifiers = {mode.get("TISInputSourceID") for mode in modes.values()}
        expected = {BUNDLE_ID + "." + suffix for suffix in ["Automatic", "Japanese", "Roman"]}
        if (info.get("CFBundleIdentifier") != BUNDLE_ID or info.get("CFBundleExecutable") != "azooKeyMixed"
                or info.get("InputMethodConnectionName") != BUNDLE_ID + "_Connection"
                or info.get("AzooKeyMixedLocalBuild") is not True or identifiers != expected):
            raise ValueError("This is not the isolated three-mode azooKey Mixed build")
        self.run(["codesign", "--verify", "--deep", "--strict", app])
        helper = app / "Contents/Helpers/ConverterServer/ConverterServer"
        result = self.run([helper, "--identity"], capture_output=True, text=True)
        identity = json.loads(result.stdout)
        if identity != {"bundleIdentifier": BUNDLE_ID, "machServiceName": SERVICE,
                        "preferencesIdentifier": BUNDLE_ID + ".preferences",
                        "keychainAccount": BUNDLE_ID + ".preference.OpenAiApiKey", "dataScope": "isolated-local"}:
            raise ValueError("Embedded server identity/storage does not match the isolated app")

    def validate_targets(self):
        for directory in [self.app.parent, self.agent.parent]:
            if directory.is_symlink() or not directory.resolve().is_relative_to(self.home.resolve()):
                raise ValueError("Refusing a redirected install directory")
        if self.app.exists() or self.app.is_symlink():
            self.validate_app(self.app)
        if self.agent.exists() or self.agent.is_symlink():
            if self.agent.is_symlink():
                raise ValueError("Refusing a LaunchAgent symlink")
            value = plistlib.loads(self.agent.read_bytes())
            expected_helper = str(self.app / "Contents/Helpers/ConverterServer/ConverterServer")
            if value.get("Label") != SERVICE or value.get("MachServices") != {SERVICE: True} or value.get("ProgramArguments") != [expected_helper]:
                raise ValueError("Existing LaunchAgent is not owned by this installer")

    def stop_server(self):
        # An absent job is expected on the first installation. Never boot out another label.
        try:
            self.run(["launchctl", "bootout", self.domain + "/" + SERVICE], capture_output=True)
        except subprocess.CalledProcessError as error:
            if error.returncode != 3:
                raise
        # bootout can return before the job and its Mach endpoint disappear.
        # Wait for this exact label to leave launchd before replacing/restarting it.
        for attempt in range(81):
            try:
                self.run(["launchctl", "print", self.domain + "/" + SERVICE], capture_output=True)
            except subprocess.CalledProcessError as error:
                if error.returncode in {3, 113}:
                    return
                raise
            if attempt == 80:
                raise TimeoutError("Mixed ConverterServer did not finish stopping within eight seconds")
            time.sleep(0.1)

    def start_server(self):
        # launchd may briefly retain the old Mach endpoint after a successful bootout.
        # Retry only EIO and only while this exact job is absent, never replace a live job.
        for attempt in range(11):
            try:
                self.run(["launchctl", "bootstrap", self.domain, self.agent], capture_output=True)
                return
            except subprocess.CalledProcessError as error:
                if error.returncode != 5 or attempt == 10:
                    raise
                try:
                    self.run(["launchctl", "print", self.domain + "/" + SERVICE], capture_output=True)
                except subprocess.CalledProcessError as absent:
                    if absent.returncode not in {3, 113}:
                        raise
                else:
                    raise error
                time.sleep(0.2)

    def install(self, source, dry_run=False, update_only=False):
        source = source.resolve()
        self.validate_app(source)
        self.validate_targets()
        if update_only and (not self.app.exists() or not self.agent.exists()):
            raise ValueError("Update requires an existing isolated app and LaunchAgent")
        if source == self.app.resolve():
            raise ValueError("Source must be the build output, not the installed app")
        if dry_run:
            print("Validated: update Mixed files without registering or enabling input sources." if update_only else
                  "Validated: install azooKeyMixed.app and its dedicated LaunchAgent; enable only its three modes.")
            return
        stage = self.app.with_name("azooKeyMixed.installing.app")
        backup = self.app.with_name("azooKeyMixed.previous.app")
        if stage.exists() or stage.is_symlink() or backup.exists() or backup.is_symlink():
            raise ValueError("A previous staging/backup directory exists; refusing to overwrite it")
        self.app.parent.mkdir(parents=True, exist_ok=True)
        self.agent.parent.mkdir(parents=True, exist_ok=True)
        old_agent = self.agent.read_bytes() if self.agent.exists() else None
        moved_old = False
        installed_new = False
        server_stopped = False
        try:
            self.run(["ditto", source, stage])
            self.validate_app(stage)
            self.run([self.control, "terminate", self.app])
            self.stop_server()
            server_stopped = True
            if self.app.exists():
                self.app.rename(backup)
                moved_old = True
            stage.rename(self.app)
            installed_new = True
            value = {"Label": SERVICE, "ProgramArguments": [str(self.app / "Contents/Helpers/ConverterServer/ConverterServer")],
                     "MachServices": {SERVICE: True}, "KeepAlive": True, "RunAtLoad": True,
                     "StandardOutPath": os.devnull, "StandardErrorPath": os.devnull}
            self.agent.write_bytes(plistlib.dumps(value))
            self.start_server()
            self.run(["launchctl", "kickstart", self.domain + "/" + SERVICE])
            if not update_only:
                self.run([self.control, "register", self.app])
            if moved_old:
                shutil.rmtree(backup)
        except Exception:
            if server_stopped:
                self.stop_server()
            if installed_new:
                self.validate_app(self.app)
                shutil.rmtree(self.app)
            if moved_old:
                backup.rename(self.app)
            if server_stopped and old_agent is not None:
                self.agent.write_bytes(old_agent)
                self.start_server()
            elif server_stopped:
                self.agent.unlink(missing_ok=True)
            raise
        finally:
            if stage.exists():
                shutil.rmtree(stage)
        print("Updated azooKey Mixed files. Existing input source registration and enabled modes were preserved." if update_only else
              "Installed azooKey Mixed files. Check status for macOS activation; a logout/login and Keyboard > Text Input > Add may be needed. The selected input source was not changed.")

    def uninstall(self, dry_run=False):
        self.validate_targets()
        if dry_run:
            print("Validated: remove only azooKey Mixed and its LaunchAgent; keep its settings and dictionaries.")
            return
        self.run([self.control, "disable"])
        self.run([self.control, "terminate", self.app])
        self.stop_server()
        self.agent.unlink(missing_ok=True)
        if self.app.exists():
            shutil.rmtree(self.app)
        print("Removed azooKey Mixed. Its settings/dictionaries and the standard IME are preserved.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["install", "update", "uninstall", "status"])
    parser.add_argument("--app", type=Path, default=BUILD / "azooKeyMixed.app")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    installer = MixedInstaller(Path.home(), BUILD / "MixedIMEControl")
    if args.action in {"install", "update"}:
        installer.install(args.app, args.dry_run, update_only=args.action == "update")
    elif args.action == "uninstall":
        installer.uninstall(args.dry_run)
    else:
        execute([installer.control, "status"])
