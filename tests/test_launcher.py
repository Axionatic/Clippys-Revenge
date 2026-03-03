"""Tests for effect discovery and the clippy launcher CLI."""
from __future__ import annotations

import os
import stat
from pathlib import Path
from unittest import mock

import pytest

from clippy.effects import discover_effects
from clippy.launcher import (
    _escape_toml_string,
    ensure_executable,
    find_tattoy,
    generate_config,
    main,
)


# ---------------------------------------------------------------------------
# Effect discovery
# ---------------------------------------------------------------------------

class TestDiscoverEffects:
    def test_discovers_fire(self):
        effects = discover_effects()
        assert "fire" in effects

    def test_meta_structure(self):
        meta = discover_effects()["fire"]
        assert meta["name"] == "fire"
        assert meta["class_name"] == "FireEffect"
        assert Path(meta["module_path"]).is_absolute()
        assert Path(meta["module_path"]).is_file()

    def test_excludes_init(self):
        for meta in discover_effects().values():
            assert not meta["module_path"].endswith("__init__.py")


# ---------------------------------------------------------------------------
# find_tattoy
# ---------------------------------------------------------------------------

class TestFindTattoy:
    def test_found_on_path(self):
        with mock.patch("shutil.which", return_value="/usr/bin/tattoy"):
            assert find_tattoy() == "/usr/bin/tattoy"

    def test_found_in_cargo(self, tmp_path):
        cargo_bin = tmp_path / ".cargo" / "bin"
        cargo_bin.mkdir(parents=True)
        fake = cargo_bin / "tattoy"
        fake.write_text("#!/bin/sh\n")
        fake.chmod(0o755)

        with mock.patch("shutil.which", return_value=None), \
             mock.patch("pathlib.Path.home", return_value=tmp_path):
            result = find_tattoy()
        assert result is not None
        assert result.endswith("tattoy")

    def test_not_found(self, tmp_path):
        with mock.patch("shutil.which", return_value=None), \
             mock.patch("pathlib.Path.home", return_value=tmp_path):
            assert find_tattoy() is None


# ---------------------------------------------------------------------------
# ensure_executable
# ---------------------------------------------------------------------------

class TestEnsureExecutable:
    def test_adds_shebang(self, tmp_path):
        script = tmp_path / "test.py"
        script.write_text('"""docstring"""\nimport sys\n')
        ensure_executable(script)
        assert script.read_text().startswith("#!/usr/bin/env python3\n")
        assert '"""docstring"""' in script.read_text()

    def test_preserves_existing_shebang(self, tmp_path):
        script = tmp_path / "test.py"
        script.write_text("#!/usr/bin/env python3\nimport sys\n")
        ensure_executable(script)
        assert script.read_text().count("#!/usr/bin/env python3") == 1

    def test_sets_executable(self, tmp_path):
        script = tmp_path / "test.py"
        script.write_text("#!/usr/bin/env python3\n")
        script.chmod(0o644)
        ensure_executable(script)
        assert script.stat().st_mode & stat.S_IXUSR


# ---------------------------------------------------------------------------
# generate_config
# ---------------------------------------------------------------------------

class TestGenerateConfig:
    def test_creates_file(self, tmp_path):
        path = generate_config("/path/to/fire.py", config_dir=str(tmp_path))
        assert Path(path).is_file()

    def test_toml_content(self, tmp_path):
        path = generate_config(
            "/path/to/fire.py",
            shell_cmd="/bin/zsh",
            fps=60,
            config_dir=str(tmp_path),
        )
        content = Path(path).read_text()
        assert 'command = "/bin/zsh"' in content
        assert "frame_rate = 60" in content
        assert 'path = "/path/to/fire.py"' in content
        assert "[[plugins]]" in content
        assert "layer = 1" in content

    def test_default_shell(self, tmp_path):
        with mock.patch.dict(os.environ, {"SHELL": "/bin/fish"}):
            path = generate_config("/path/to/fire.py", config_dir=str(tmp_path))
        content = Path(path).read_text()
        assert 'command = "/bin/fish"' in content

    def test_backslash_escaping(self, tmp_path):
        path = generate_config(
            r"C:\Users\test\fire.py",
            shell_cmd=r"C:\Windows\system32\cmd.exe",
            config_dir=str(tmp_path),
        )
        content = Path(path).read_text()
        assert r'command = "C:\\Windows\\system32\\cmd.exe"' in content
        assert r'path = "C:\\Users\\test\\fire.py"' in content

    def test_quote_escaping(self, tmp_path):
        path = generate_config(
            '/path/to/"fire".py',
            shell_cmd='/bin/sh -c "echo hi"',
            config_dir=str(tmp_path),
        )
        content = Path(path).read_text()
        assert r'command = "/bin/sh -c \"echo hi\""' in content
        assert r'path = "/path/to/\"fire\".py"' in content


# ---------------------------------------------------------------------------
# CLI integration (main)
# ---------------------------------------------------------------------------

class TestMain:
    def test_list_effects(self, capsys):
        assert main(["--list"]) == 0
        assert "fire" in capsys.readouterr().out

    def test_list_empty(self, capsys):
        with mock.patch("clippy.effects.discover_effects", return_value={}):
            assert main(["--list"]) == 0
        assert "No effects" in capsys.readouterr().out

    def test_unknown_effect(self, capsys):
        assert main(["--effect", "nonexistent"]) == 1
        assert "Unknown effect" in capsys.readouterr().err

    def test_demo_runs(self):
        with mock.patch("clippy.demo.demo_run") as mock_demo:
            assert main(["--demo", "fire"]) == 0
        mock_demo.assert_called_once()
        _, kwargs = mock_demo.call_args
        assert kwargs["fps"] == 30

    def test_demo_unknown(self, capsys):
        assert main(["--demo", "nonexistent"]) == 1
        assert "Unknown effect" in capsys.readouterr().err

    def test_no_tattoy(self, capsys):
        with mock.patch("clippy.launcher.find_tattoy", return_value=None):
            assert main(["--effect", "fire"]) == 1
        captured = capsys.readouterr()
        assert "tattoy not found" in captured.err

    def test_launch_execs_tattoy(self, tmp_path):
        with mock.patch("clippy.launcher.find_tattoy", return_value="/usr/bin/tattoy"), \
             mock.patch("clippy.launcher.generate_config", return_value="/tmp/test.toml"), \
             mock.patch("clippy.launcher.ensure_executable"), \
             mock.patch("os.execvp") as mock_exec:
            main(["--effect", "fire"])

        mock_exec.assert_called_once()
        args = mock_exec.call_args[0]
        assert args[0] == "/usr/bin/tattoy"
        assert "--main-config" in args[1]
        assert "/tmp/test.toml" in args[1]

    def test_command_passthrough(self):
        with mock.patch("clippy.launcher.find_tattoy", return_value="/usr/bin/tattoy"), \
             mock.patch("clippy.launcher.generate_config", return_value="/tmp/test.toml") as mock_gen, \
             mock.patch("clippy.launcher.ensure_executable"), \
             mock.patch("os.execvp"):
            main(["--effect", "fire", "--", "vim", "file.txt"])

        _, kwargs = mock_gen.call_args
        assert kwargs["shell_cmd"] == "vim file.txt"

    def test_no_effects_exits_1(self, capsys):
        with mock.patch("clippy.effects.discover_effects", return_value={}):
            assert main([]) == 1
        assert "No effects" in capsys.readouterr().err
