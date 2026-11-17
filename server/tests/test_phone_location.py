"""Tests for server/hermes-plugin/phone_location. Run: python3 -m unittest discover -s server/tests

A fake ``tools.registry`` module stands in for Hermes. A fake findmy plugin stands in for Find My.
No test connects to a real server.
"""

import importlib.util
import json
import os
import sys
import tempfile
import types
import unittest
from datetime import datetime, timedelta, timezone
from unittest import mock

from support import SERVER_DIR, GateTestCase

PLUGIN_DIR = os.path.join(SERVER_DIR, "hermes-plugin", "phone_location")
PLUGIN = os.path.join(PLUGIN_DIR, "__init__.py")

FAKE_FINDMY = '''
import json, os
from tools.registry import tool_error, tool_result
def handle(args, **kw):
    with open(os.environ["FAKE_FINDMY_CALLS"], "a") as out:
        out.write("call\\n")
    mode = os.environ.get("FAKE_FINDMY_MODE", "ok")
    if mode == "raise":
        raise RuntimeError("secret +15555550123 must not leak")
    if mode == "error":
        return tool_error("Owner is not sharing a location with this iMessage line right now.")
    return tool_result({"person": "Owner", "latitude": 40.0, "longitude": -74.0, "accuracy_m": 30,
                        "located_at": "2026-11-16T12:00:00Z",
                        "minutes_ago": float(os.environ.get("FAKE_FINDMY_AGE", "2")),
                        "apple_maps": "https://maps.apple.com/?ll=40.000000,-74.000000"})
'''


def fake_registry():
    tools = types.ModuleType("tools")
    registry = types.ModuleType("tools.registry")
    registry.tool_result = lambda data: json.dumps(data)
    registry.tool_error = lambda text: json.dumps({"error": text})
    tools.registry = registry
    return {"tools": tools, "tools.registry": registry}


def load_plugin():
    with mock.patch.dict(sys.modules, fake_registry()):
        spec = importlib.util.spec_from_file_location("phone_location_under_test", PLUGIN)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    return module


def iso(moment):
    return moment.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (moment.microsecond // 1000)


def record(minutes_ago=1.0, **overrides):
    value = {"schemaVersion": 1, "lat": 37.3349, "lon": -122.009, "accuracy_m": 12.5,
             "timestamp": iso(datetime.now(timezone.utc) - timedelta(minutes=minutes_ago)),
             "speed": 1.5, "course": 90.0, "received_at": iso(datetime.now(timezone.utc)),
             "source": "hermesconnect"}
    value.update(overrides)
    return value


class PluginTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="hcplugin-")
        self.home = os.path.realpath(self._tmp.name)
        self.calls = os.path.join(self.home, "findmy-calls")
        env = {"HOME": self.home, "FAKE_FINDMY_CALLS": self.calls}
        patcher = mock.patch.dict(os.environ, env)
        patcher.start()
        self.addCleanup(patcher.stop)
        os.environ.pop("HERMES_HOME", None)
        os.environ.pop("FAKE_FINDMY_MODE", None)
        os.environ.pop("FAKE_FINDMY_AGE", None)
        modules = mock.patch.dict(sys.modules, fake_registry())
        modules.start()
        self.addCleanup(modules.stop)
        self.plugin = load_plugin()
        self.location = os.path.join(self.home, ".hermes", "hermesconnect", "location.json")

    def tearDown(self):
        self._tmp.cleanup()

    def write_fix(self, value):
        os.makedirs(os.path.dirname(self.location), mode=0o700, exist_ok=True)
        with open(self.location, "w") as out:
            out.write(value if isinstance(value, str) else json.dumps(value))

    def install_findmy(self, root=None, mode="ok", age=None):
        folder = os.path.join(root or os.path.join(self.home, ".hermes"), "plugins", "findmy")
        os.makedirs(folder, exist_ok=True)
        with open(os.path.join(folder, "__init__.py"), "w") as out:
            out.write(FAKE_FINDMY)
        os.environ["FAKE_FINDMY_MODE"] = mode
        if age is not None:
            os.environ["FAKE_FINDMY_AGE"] = str(age)

    def findmy_calls(self):
        try:
            with open(self.calls) as stream:
                return len(stream.read().splitlines())
        except OSError:
            return 0

    def call(self):
        return json.loads(self.plugin.handle({}))


class FreshFixTests(PluginTestCase):
    def test_fresh_fix_returns_coordinates_and_time(self):
        self.install_findmy()
        fix = record(minutes_ago=5)
        self.write_fix(fix)
        result = self.call()
        self.assertEqual(result["source"], "hermesconnect")
        self.assertEqual((result["latitude"], result["longitude"]), (37.3349, -122.009))
        self.assertEqual(result["accuracy_m"], 12)
        self.assertEqual(result["located_at"], fix["timestamp"][:19] + "Z")
        self.assertAlmostEqual(result["minutes_ago"], 5, delta=0.2)
        self.assertFalse(result["stale"])
        self.assertEqual(result["apple_maps"], "https://maps.apple.com/?ll=37.334900,-122.009000")
        self.assertEqual((result["speed_mps"], result["course_deg"]), (1.5, 90))
        self.assertNotIn("note", result)
        self.assertEqual(self.findmy_calls(), 0, "a fresh fix must not call Find My")

    def test_fix_just_under_30_minutes_is_fresh(self):
        self.write_fix(record(minutes_ago=29.5))
        result = self.call()
        self.assertEqual(result["source"], "hermesconnect")
        self.assertFalse(result["stale"])

    def test_small_clock_skew_into_the_future_is_age_zero(self):
        self.write_fix(record(minutes_ago=-2))
        result = self.call()
        self.assertEqual(result["minutes_ago"], 0)
        self.assertFalse(result["stale"])

    def test_null_speed_and_course_are_left_out(self):
        self.write_fix(record(speed=None, course=None))
        result = self.call()
        self.assertNotIn("speed_mps", result)
        self.assertNotIn("course_deg", result)

    def test_offset_timestamp_is_read(self):
        moment = datetime.now(timezone(timedelta(hours=2))) - timedelta(minutes=3)
        self.write_fix(record(timestamp=moment.strftime("%Y-%m-%dT%H:%M:%S+02:00")))
        self.assertAlmostEqual(self.call()["minutes_ago"], 3, delta=0.2)


class FallbackTests(PluginTestCase):
    def test_stale_fix_uses_findmy(self):
        self.install_findmy(age=2)
        self.write_fix(record(minutes_ago=45))
        result = self.call()
        self.assertEqual(result["source"], "findmy")
        self.assertEqual((result["latitude"], result["longitude"]), (40.0, -74.0))
        self.assertFalse(result["stale"])
        self.assertEqual(result["phone_fix"], "stale: 45 minutes old")
        self.assertEqual(self.findmy_calls(), 1)

    def test_missing_fix_uses_findmy(self):
        self.install_findmy()
        result = self.call()
        self.assertEqual(result["source"], "findmy")
        self.assertEqual(result["phone_fix"], "missing: no phone location has arrived yet")
        self.assertEqual(self.findmy_calls(), 1)

    def test_findmy_under_hermes_home_is_found(self):
        profile = os.path.join(self.home, "profile")
        os.environ["HERMES_HOME"] = profile
        self.install_findmy(root=profile)
        self.assertEqual(self.call()["source"], "findmy")

    def test_findmy_that_is_older_than_the_stale_fix_is_not_used(self):
        self.install_findmy(age=120)
        self.write_fix(record(minutes_ago=45))
        result = self.call()
        self.assertEqual(result["source"], "hermesconnect")
        self.assertTrue(result["stale"])
        self.assertIn("Find My is older", result["note"])

    def test_old_findmy_result_is_marked_stale(self):
        self.install_findmy(age=90)
        result = self.call()
        self.assertEqual(result["source"], "findmy")
        self.assertTrue(result["stale"])

    def test_stale_fix_without_findmy_is_returned_with_a_note(self):
        self.write_fix(record(minutes_ago=45))
        result = self.call()
        self.assertEqual(result["source"], "hermesconnect")
        self.assertTrue(result["stale"])
        self.assertIn("45 minutes old", result["note"])
        self.assertIn("Find My is not installed", result["note"])
        self.assertIn("HermesConnect app", result["note"])

    def test_stale_fix_with_findmy_error_gives_the_reason(self):
        self.install_findmy(mode="error")
        self.write_fix(record(minutes_ago=45))
        result = self.call()
        self.assertTrue(result["stale"])
        self.assertIn("not sharing a location", result["note"])

    def test_missing_fix_without_findmy_says_how_to_turn_on_sharing(self):
        result = self.call()
        self.assertEqual(set(result), {"error"})
        self.assertIn("no phone location has arrived yet", result["error"])
        self.assertIn("Find My is not installed", result["error"])
        self.assertIn("turn on location sharing in the HermesConnect app", result["error"])

    def test_findmy_exception_gives_only_the_type_name(self):
        self.install_findmy(mode="raise")
        result = self.call()
        self.assertIn("Find My failed (RuntimeError)", result["error"])
        self.assertNotIn("15555550123", result["error"])

    def test_invalid_files_count_as_missing(self):
        self.install_findmy()
        huge = json.dumps(record(lat=0)).replace('"lat": 0', '"lat": ' + "9" * 3000)
        cases = {
            "not json": "lat=1",
            "array": "[1, 2]",
            "empty": "",
            "nan": json.dumps(record()).replace("37.3349", "NaN"),
            "lat 91": record(lat=91),
            "lon text": record(lon="-122"),
            "lat bool": record(lat=True),
            "huge integer": huge,
            "accuracy negative": record(accuracy_m=-1),
            "timestamp missing": {k: v for k, v in record().items() if k != "timestamp"},
            "timestamp no zone": record(timestamp="2026-11-16T12:00:00"),
            "timestamp unix": record(timestamp=1763294400),
            "too large": json.dumps(record()) + " " * 70000,
        }
        for name, value in cases.items():
            with self.subTest(case=name):
                self.write_fix(value)
                result = self.call()
                self.assertEqual(result["source"], "findmy")
                self.assertEqual(result["phone_fix"], "missing: the phone location file is not valid")

    def test_symlinked_file_is_not_followed(self):
        self.install_findmy()
        target = os.path.join(self.home, "elsewhere.json")
        with open(target, "w") as out:
            json.dump(record(), out)
        os.makedirs(os.path.dirname(self.location))
        os.symlink(target, self.location)
        result = self.call()
        self.assertEqual(result["source"], "findmy")
        self.assertIn("cannot be read", result["phone_fix"])


class GateToPluginTests(GateTestCase):
    def test_fix_stored_by_the_gate_is_read_by_the_plugin(self):
        moment = datetime.now(timezone.utc) - timedelta(minutes=4)
        fix = {"lat": 51.5007, "lon": -0.1246, "accuracy_m": 8, "timestamp": iso(moment), "speed": None}
        result = self.gate("location", stdin=json.dumps(fix).encode())
        self.assertEqual(result.stdout, b"OK\n", result.stderr)
        with mock.patch.dict(os.environ, {"HOME": self.home}), mock.patch.dict(sys.modules, fake_registry()):
            os.environ.pop("HERMES_HOME", None)
            data = json.loads(load_plugin().handle({}))
        self.assertEqual(data["source"], "hermesconnect")
        self.assertEqual((data["latitude"], data["longitude"], data["accuracy_m"]), (51.5007, -0.1246, 8))
        self.assertAlmostEqual(data["minutes_ago"], 4, delta=0.2)
        self.assertFalse(data["stale"])


class RegistrationTests(unittest.TestCase):
    def test_register_adds_one_tool_with_agent_guidance(self):
        plugin = load_plugin()
        ctx = mock.Mock()
        plugin.register(ctx)
        ctx.register_tool.assert_called_once()
        kwargs = ctx.register_tool.call_args.kwargs
        self.assertEqual(kwargs["name"], "phone_location")
        self.assertIs(kwargs["handler"], plugin.handle)
        schema = kwargs["schema"]
        self.assertEqual(schema["name"], "phone_location")
        self.assertEqual(schema["parameters"]["required"], [])
        for words in ("places near them", "travel time", "weather", "findmy_location",
                      "Do not repeat exact coordinates"):
            self.assertIn(words, schema["description"])

    def test_manifest_names_the_tool(self):
        with open(os.path.join(PLUGIN_DIR, "plugin.yaml")) as stream:
            text = stream.read()
        self.assertIn("name: phone_location", text)
        self.assertIn("  - phone_location", text)

    def test_plugin_opens_no_command_channel(self):
        with open(PLUGIN) as stream:
            source = stream.read()
        for word in ("subprocess", "socket", "os.system", "os.popen", "Popen", "urllib", "http.client",
                     "open(path, \"w", "eval(", "exec("):
            self.assertNotIn(word, source.replace("exec_module", ""), word)


if __name__ == "__main__":
    unittest.main()
