"""Tests for clippy.noise — 3D simplex noise."""
import pytest

from clippy.noise import noise3


def test_noise3_deterministic():
    """Same inputs always produce the same output."""
    a = noise3(1.5, 2.3, 0.7)
    b = noise3(1.5, 2.3, 0.7)
    assert a == b


def test_noise3_range():
    """Output is bounded to [-1.0, 1.0] across a broad sample of inputs."""
    import itertools
    coords = [-10.0, -1.0, 0.0, 0.5, 1.0, 3.7, 10.0]
    for x, y, z in itertools.product(coords, repeat=3):
        val = noise3(x, y, z)
        assert -1.0 <= val <= 1.0, f"noise3({x}, {y}, {z}) = {val} out of [-1, 1]"
