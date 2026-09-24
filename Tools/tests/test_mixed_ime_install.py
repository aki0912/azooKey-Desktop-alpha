"""Failure injection for the isolated installer; never calls macOS registration APIs."""
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("installer", Path(__file__).parents[1] / "install_mixed_ime.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
BUNDLE = module.BUNDLE_ID


def make_app(path, payload="new"):
    (path / "Contents").mkdir(parents=True)
    info = {"CFBundleIdentifier": BUNDLE, "CFBundleExecutable": "azooKeyMixed", "AzooKeyMixedLocalBuild": True,
            "InputMethodConnectionName": BUNDLE + "_Connection",
            "ComponentInputModeDict": {"tsInputModeListKey": {
                name: {"TISInputSourceID": BUNDLE + "." + name} for name in ["Automatic", "Japanese", "Roman"]}}}
    (path / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    (path / "payload").write_text(payload)


class Runner:
    def __init__(self, failure=None):
        self.calls = []
        self.failure = failure
        self.service_loaded = False

    def __call__(self, args, **kwargs):
        args = list(map(str, args))
        self.calls.append(args)
        if self.failure and self.failure in args:
            self.failure = None
            raise subprocess.CalledProcessError(1, args)
        if args[0] == "ditto":
            shutil.copytree(args[1], args[2])
        if args[:2] == ["launchctl", "bootout"]:
            self.service_loaded = False
        if args[:2] == ["launchctl", "bootstrap"]:
            self.service_loaded = True
        if args[:2] == ["launchctl", "print"] and not self.service_loaded:
            raise subprocess.CalledProcessError(113, args)
        identity = {"bundleIdentifier": BUNDLE, "machServiceName": module.SERVICE,
                    "preferencesIdentifier": BUNDLE + ".preferences", "keychainAccount": BUNDLE + ".preference.OpenAiApiKey",
                    "dataScope": "isolated-local"}
        return subprocess.CompletedProcess(args, 0, stdout=json.dumps(identity))


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        self.source = self.home / "build/azooKeyMixed.app"
        make_app(self.source)
        self.normal = self.home / "Library/Input Methods/azooKeyMac.app"
        make_app(self.normal, "normal-untouched")
        self.settings = self.home / "Library/Application Support/azooKeyMixed/dictionary"
        self.settings.parent.mkdir(parents=True)
        self.settings.write_text("keep")
        self.runner = Runner()
        self.installer = module.MixedInstaller(self.home, "MixedIMEControl", self.runner)

    def tearDown(self):
        self.assertEqual((self.normal / "payload").read_text(), "normal-untouched")
        self.assertEqual(self.settings.read_text(), "keep")
        for args in self.runner.calls:
            self.assertNotIn(str(self.normal), args)
            if args[0] == "launchctl":
                self.assertTrue(any(module.SERVICE in value for value in args))
        self.temp.cleanup()

    def test_dry_run_has_no_install_or_launch_side_effects(self):
        self.installer.install(self.source, dry_run=True)
        self.assertFalse(self.installer.app.exists())
        self.assertFalse(self.installer.agent.exists())
        self.assertFalse(any(args[0] in {"ditto", "launchctl", "MixedIMEControl"} for args in self.runner.calls))

    def test_install_and_remove_preserve_normal_app_and_user_data(self):
        self.installer.install(self.source)
        self.assertEqual((self.installer.app / "payload").read_text(), "new")
        self.assertEqual(plistlib.loads(self.installer.agent.read_bytes())["Label"], module.SERVICE)
        self.installer.uninstall()
        self.assertFalse(self.installer.app.exists())
        self.assertFalse(self.installer.agent.exists())

    def test_update_preserves_input_source_registration_and_enabled_modes(self):
        self.installer.install(self.source)
        self.runner.calls.clear()
        self.installer.install(self.source, update_only=True)
        self.assertEqual((self.installer.app / "payload").read_text(), "new")
        self.assertFalse(any("register" in args or "disable" in args or "select" in args for args in self.runner.calls))

    def test_update_cannot_be_used_for_first_install(self):
        with self.assertRaises(ValueError): self.installer.install(self.source, update_only=True)
        self.assertFalse(self.installer.app.exists())
        self.assertFalse(any(args[0] in {"ditto", "launchctl", "MixedIMEControl"} for args in self.runner.calls))

    def test_copy_failure_does_not_remove_existing_app_or_stop_service(self):
        make_app(self.installer.app, "old")
        self.runner.failure = "ditto"
        with self.assertRaises(subprocess.CalledProcessError): self.installer.install(self.source)
        self.assertEqual((self.installer.app / "payload").read_text(), "old")
        self.assertFalse(any(args[0] == "launchctl" for args in self.runner.calls))

    def test_registration_failure_restores_previous_app_and_agent(self):
        self.installer.install(self.source)
        (self.installer.app / "payload").write_text("old")
        old_agent = self.installer.agent.read_bytes()
        self.runner.failure = "register"
        with self.assertRaises(subprocess.CalledProcessError): self.installer.install(self.source)
        self.assertEqual((self.installer.app / "payload").read_text(), "old")
        self.assertEqual(self.installer.agent.read_bytes(), old_agent)

    def test_first_install_failure_cleans_up_only_new_app_and_agent(self):
        self.runner.failure = "bootstrap"
        with self.assertRaises(subprocess.CalledProcessError): self.installer.install(self.source)
        self.assertFalse(self.installer.app.exists())
        self.assertFalse(self.installer.agent.exists())

    def test_transient_launchd_endpoint_release_is_retried_only_when_job_is_absent(self):
        runner = self.runner
        attempts = []
        def transient(args, **kwargs):
            if args[0:2] == ["launchctl", "bootstrap"]:
                attempts.append(args)
                if len(attempts) == 1: raise subprocess.CalledProcessError(5, args)
            if args[0:2] == ["launchctl", "print"]: raise subprocess.CalledProcessError(113, args)
            return runner(args, **kwargs)
        self.installer.run = transient
        with patch.object(module.time, "sleep"):
            self.installer.install(self.source)
        self.assertEqual(len(attempts), 2)
        self.assertEqual((self.installer.app / "payload").read_text(), "new")

    def test_bootstrap_error_does_not_retry_over_a_live_job(self):
        self.runner.service_loaded = True
        attempts = []
        def running(args, **kwargs):
            if args[0:2] == ["launchctl", "bootstrap"]:
                attempts.append(args)
                raise subprocess.CalledProcessError(5, args)
            return self.runner(args, **kwargs)
        self.installer.run = running
        with self.assertRaises(subprocess.CalledProcessError): self.installer.start_server()
        self.assertEqual(len(attempts), 1)

    def test_update_waits_for_departing_job_before_replacing_files(self):
        self.installer.install(self.source)
        (self.installer.app / "payload").write_text("old")
        remaining = 0
        observed = []
        def departing(args, **kwargs):
            nonlocal remaining
            if args[:2] == ["launchctl", "bootout"]:
                remaining = 2
            if args[:2] == ["launchctl", "print"] and remaining:
                remaining -= 1
                observed.append((self.installer.app / "payload").read_text())
                return subprocess.CompletedProcess(args, 0)
            return self.runner(args, **kwargs)
        self.installer.run = departing
        with patch.object(module.time, "sleep"):
            self.installer.install(self.source, update_only=True)
        self.assertEqual(observed, ["old", "old"])
        self.assertEqual((self.installer.app / "payload").read_text(), "new")

    def test_stop_timeout_is_bounded(self):
        self.installer.run = lambda args, **kwargs: subprocess.CompletedProcess(args, 0)
        with patch.object(module.time, "sleep") as sleep:
            with self.assertRaises(TimeoutError): self.installer.stop_server()
        self.assertEqual(sleep.call_count, 80)

    def test_wrong_identity_or_agent_is_not_overwritten(self):
        make_app(self.installer.app, "unknown")
        info_path = self.installer.app / "Contents/Info.plist"
        value = plistlib.loads(info_path.read_bytes()); value["CFBundleIdentifier"] = "another.app"
        info_path.write_bytes(plistlib.dumps(value))
        with self.assertRaises(ValueError): self.installer.install(self.source)
        self.assertEqual((self.installer.app / "payload").read_text(), "unknown")
        shutil.rmtree(self.installer.app)
        self.installer.agent.parent.mkdir(parents=True)
        self.installer.agent.write_bytes(plistlib.dumps({"Label": "another.service"}))
        with self.assertRaises(ValueError): self.installer.install(self.source)
        self.assertEqual(plistlib.loads(self.installer.agent.read_bytes())["Label"], "another.service")

    def test_symlink_target_is_rejected(self):
        self.installer.app.symlink_to(self.normal, target_is_directory=True)
        with self.assertRaises(ValueError): self.installer.install(self.source)
        self.assertTrue(self.installer.app.is_symlink())


if __name__ == "__main__": unittest.main()
