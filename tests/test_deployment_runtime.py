"""Run against: docker build -f Dockerfile.production -t osticket-web:deployment-tests ."""

import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import time
import unittest
import urllib.error
import urllib.request


ROOT = Path(__file__).resolve().parents[1]
IMAGE = os.environ.get("OSTICKET_TEST_IMAGE", "osticket-web:deployment-tests")
CONFIG_TARGET = "/var/www/html/ticket/include/ost-config.php"


def docker(*args, check=True):
    return subprocess.run(
        ["docker", *args], check=check, capture_output=True, text=True, timeout=90
    )


def bind(source, target, readonly=False):
    return ["--mount", f"type=bind,source={source},target={target}" + (",readonly" if readonly else "")]


class DeploymentRuntimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if docker("image", "inspect", IMAGE, check=False).returncode:
            raise RuntimeError(f"Build the production test image first: {IMAGE}")

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="osticket-runtime-test-")
        self.addCleanup(self.temp.cleanup)
        self.fixture = Path(self.temp.name)

    def config(self, text="<?php\ndefine('OSTINSTALLED', TRUE);\n", root_owned=True):
        config = self.fixture / "ost-config.php"
        config.write_text(text)
        config.chmod(0o644)
        if root_owned:
            docker("run", "--rm", "--network", "none", *bind(self.fixture, "/fixtures"),
                   "--entrypoint", "chown", IMAGE, "0:0", "/fixtures/ost-config.php")
        return config

    def entrypoint(self, config=None, mode="production", readonly=True):
        mounts = bind(config, CONFIG_TARGET, readonly) if config else []
        return docker("run", "--rm", "--network", "none", "-e", f"OSTICKET_MODE={mode}",
                      *mounts, IMAGE, "true", check=False)

    def test_missing_config_fails_without_seeding_image(self):
        result = self.entrypoint()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("pre-seeded", result.stderr)

    def test_production_requires_installed_config(self):
        config = self.config("<?php\ndefine('OSTINSTALLED', FALSE);\n")
        result = self.entrypoint(config)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must define OSTINSTALLED as TRUE", result.stderr)
        self.assertEqual(stat.S_IMODE(config.stat().st_mode), 0o644)

    def test_production_rejects_writable_bind(self):
        result = self.entrypoint(self.config(), readonly=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("read-only file bind", result.stderr)

    def test_production_rejects_non_root_owner(self):
        config = self.config(root_owned=False)
        docker("run", "--rm", "--network", "none", *bind(self.fixture, "/fixtures"),
               "--entrypoint", "chown", IMAGE, "12345:12345", "/fixtures/ost-config.php")
        result = self.entrypoint(config)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("owned by root", result.stderr)

    def test_auto_accepts_installed_readonly_config_without_chmod(self):
        config = self.config("<?php\ndefine(\"OSTINSTALLED\", true);\n")
        result = self.entrypoint(config, mode="auto")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(stat.S_IMODE(config.stat().st_mode), 0o644)

    def test_install_prepares_uninstalled_config(self):
        config = self.config("<?php\ndefine('OSTINSTALLED',FALSE);\n")
        result = self.entrypoint(config, mode="install", readonly=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(stat.S_IMODE(config.stat().st_mode), 0o666)

    def test_install_never_widens_installed_config(self):
        config = self.config()
        result = self.entrypoint(config, mode="install", readonly=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires production mode", result.stderr)
        self.assertEqual(stat.S_IMODE(config.stat().st_mode), 0o644)

    def test_unknown_mode_and_invalid_php_fail(self):
        result = self.entrypoint(self.config(), mode="typo")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must be install", result.stderr)
        # Recreate the root-owned fixture rather than changing its contents.
        (self.fixture / "ost-config.php").unlink()
        result = self.entrypoint(self.config("<?php broken syntax here"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid PHP syntax", result.stderr)

    def test_release_image_excludes_operator_artifacts(self):
        paths = [".env", ".git", "docker-compose.yml", "docker-compose.production.yml",
                 "Dockerfile", "Dockerfile.production", "docker", "docs", "scripts", "tests",
                 ".dockerignore", ".github", ".cursor"]
        command = "for path in " + " ".join(paths) + "; do test ! -e /var/www/html/ticket/$path || exit 1; done"
        result = docker("run", "--rm", "--network", "none", "--entrypoint", "sh", IMAGE, "-c", command,
                        check=False)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_http_blocks_artifacts_and_bootstrap_error_display(self):
        config = self.config()
        probe = self.fixture / "probe.php"
        probe.write_text("<?php require __DIR__.'/bootstrap.php'; echo 'display='.ini_get('display_errors'); "
                         "trigger_error('OSTICKET_TEST_WARNING', E_USER_WARNING);")
        probe.chmod(0o644)
        artifact = self.fixture / "artifact"
        artifact.write_text("TEST_ARTIFACT_MUST_NOT_BE_PUBLIC")
        artifact.chmod(0o644)
        container = docker("run", "-d", "-p", "127.0.0.1::80", "-e", "OSTICKET_MODE=production",
                           *bind(config, CONFIG_TARGET, True),
                           *bind(probe, "/var/www/html/ticket/probe.php", True),
                           *bind(artifact, "/var/www/html/ticket/.env", True),
                           *bind(artifact, "/var/www/html/ticket/docker-compose.production.yml", True),
                           IMAGE).stdout.strip()
        self.addCleanup(lambda: docker("rm", "-f", container, check=False))
        address = docker("port", container, "80/tcp").stdout.strip()
        base = f"http://{address}/ticket/"
        for _ in range(50):
            try:
                with urllib.request.urlopen(base + "probe.php", timeout=1) as response:
                    body = response.read().decode()
                break
            except (OSError, urllib.error.URLError):
                time.sleep(0.1)
        else:
            self.fail(docker("logs", container).stdout + docker("logs", container).stderr)
        self.assertEqual(body, "display=0")
        for path in [".env", ".git/config", "docker-compose.production.yml", "Dockerfile.production",
                     "docker/ost-config.php", "docs/deploy-prsmusa.md"]:
            with self.subTest(path=path), self.assertRaises(urllib.error.HTTPError) as error:
                urllib.request.urlopen(base + path, timeout=5)
            self.assertIn(error.exception.code, [403, 404])
        logs = docker("logs", container)
        self.assertIn("OSTICKET_TEST_WARNING", logs.stdout + logs.stderr)

    def test_restore_defaults_to_database_only(self):
        env = {**os.environ, "MYSQL_USER": "review", "MYSQL_PASSWORD": "review",
               "MYSQL_ROOT_PASSWORD": "review", "OSTICKET_IMAGE_TAG": "deployment-tests",
               "OSTICKET_RESTORE_CONFIG_PATH": str(self.fixture / "restore-config.php")}
        base = ["docker", "compose", "-f", str(ROOT / "docker-compose.restore-test.yml")]
        default = subprocess.run(base + ["config", "--services"], env=env, capture_output=True,
                                 text=True, check=True)
        self.assertEqual(default.stdout.strip(), "db")
        full = subprocess.run(base + ["--profile", "restore", "config", "--format", "json"],
                              env=env, capture_output=True, text=True, check=True)
        config = json.loads(full.stdout)
        services = config["services"]
        self.assertEqual(set(services["web"]["networks"]), {"internal"})
        self.assertEqual(set(services["db"]["networks"]), {"internal"})
        self.assertEqual(set(services["ingress"]["networks"]), {"internal", "default"})
        self.assertTrue(services["web"]["volumes"][0]["read_only"])
        self.assertFalse(services["web"]["volumes"][0]["bind"].get("create_host_path", False))


if __name__ == "__main__":
    unittest.main()
