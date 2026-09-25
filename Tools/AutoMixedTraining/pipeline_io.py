"""Local, strict JSON I/O. Diagnostics never include corpus text or context."""
import hashlib
import importlib.metadata
import json
import math
from pathlib import Path
import platform

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SPLITS = ("train", "dev", "calibration", "test")


class PipelineError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise PipelineError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def encoded(value):
    return (json.dumps(value, ensure_ascii=True, sort_keys=True, separators=(",", ":"), allow_nan=False) + "\n").encode()


def fingerprint(value):
    return digest(encoded(value))


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON property")
        result[key] = value
    return result


def parse(text):
    def invalid_constant(_):
        raise PipelineError("nonfinite JSON number")
    try:
        return json.loads(text, object_pairs_hook=_pairs, parse_constant=invalid_constant)
    except (json.JSONDecodeError, UnicodeError) as exc:
        raise PipelineError("invalid JSON encoding") from exc


def read(path):
    return parse(Path(path).read_bytes())


def write_new(path, value):
    """Refuse overwriting an existing artifact, including a frozen evaluation."""
    data = encoded(value)
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("xb") as stream:
        stream.write(data)


def fields(value, required, optional=()):
    require(isinstance(value, dict), "expected JSON object")
    require(set(required) <= set(value) <= set(required) | set(optional), "missing or unknown fields")


def integer(value, lower, upper):
    require(type(value) is int and lower <= value <= upper, "integer outside allowed range")


def number(value, lower, upper):
    require(type(value) in (float, int) and math.isfinite(value) and lower <= value <= upper,
            "number outside allowed range")


def local_file(base, relative):
    require(isinstance(relative, str) and relative and not Path(relative).is_absolute()
            and "://" not in relative, "source paths must be local and relative")
    result = (Path(base) / relative).resolve()
    require(result.is_file(), "required local source file missing")
    return result


def checked_file(base, entry):
    fields(entry, ("path", "sha256"))
    path = local_file(base, entry["path"])
    require(digest(path.read_bytes()) == entry["sha256"], "source/evidence checksum mismatch")
    return path


def environment():
    packages = {}
    for line in (HERE / "requirements.lock").read_text().splitlines():
        name, expected = line.split("==")
        try:
            actual = importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError as exc:
            raise PipelineError("install the training requirements.lock in an isolated environment") from exc
        require(actual == expected, "training dependency differs from requirements.lock")
        packages[name] = actual
    return {"python": platform.python_version(), "packages": packages,
            "lock_sha256": digest((HERE / "requirements.lock").read_bytes()),
            "implementation_sha256": fingerprint({p.name: digest(p.read_bytes()) for p in sorted(HERE.glob("*.py"))})}
