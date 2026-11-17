"""Tests for server/hermes-plugin/phone_location. Run: python3 -m unittest discover -s server/tests

A fake ``tools.registry`` module stands in for Hermes. A fake findmy plugin stands in for Find My.
No test connects to a real server.
"""

import importlib.util
import inspect
import json
import os
import sys
import tempfile
import types
import typing
import unittest
from datetime import datetime, timedelta, timezone
from unittest import mock

from support import SERVER_DIR, GateTestCase

PLUGIN_DIR = os.path.join(SERVER_DIR, "hermes-plugin", "phone_location")
PLUGIN = os.path.join(PLUGIN_DIR, "__init__.py")

FAKE_FINDMY = '''
import json, os
from tools.registry import tool_error, tool_result
def _available():
    with open(os.environ["FAKE_FINDMY_CALLS"], "a") as out:
        out.write("available\\n")
    if os.environ.get("FAKE_FINDMY_AVAILABLE", "1") == "raise":
        raise OSError("config unreadable")
    return os.environ.get("FAKE_FINDMY_AVAILABLE", "1") == "1"
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
        os.environ.pop("FAKE_FINDMY_AVAILABLE", None)
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
        """The number of times the findmy handler ran (not counting _available checks)."""
        try:
            with open(self.calls) as stream:
                return stream.read().splitlines().count("call")
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
        self.write_fix(record(minutes_ago=-4.5))
        result = self.call()
        self.assertEqual(result["source"], "hermesconnect")
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


class NotMovedTests(PluginTestCase):
    """Issue #51 (owner decision): no newer phone fix means "not moved". The old fix wins over Find My."""

    def test_old_background_fix_is_used_instead_of_findmy(self):
        # The VPS test: a background fix, 86 minutes old, 1000 m, no speed or course. Find My is 2 minutes old.
        self.install_findmy(age=2)
        self.write_fix(record(minutes_ago=86, accuracy_m=1000, speed=None, course=None))
        result = self.call()
        self.assertEqual(result["source"], "hermesconnect")
        self.assertEqual((result["latitude"], result["longitude"]), (37.3349, -122.009))
        self.assertEqual(result["accuracy_m"], 1000)
        self.assertAlmostEqual(result["minutes_ago"], 86, delta=0.2)
        self.assertTrue(result["stale"])
        self.assertTrue(result["not_moved"])
        self.assertNotIn("phone_fix", result)
        self.assertIn("86 minutes old", result["note"])
        self.assertIn("1000 m", result["note"])
        self.assertIn("probably has not moved", result["note"])
        self.assertEqual(self.findmy_calls(), 0, "an old valid phone fix must not call Find My")

    def test_fix_just_over_30_minutes_is_not_moved(self):
        self.install_findmy()
        self.write_fix(record(minutes_ago=30.5))
        result = self.call()
        self.assertEqual(result["source"], "hermesconnect")
        self.assertTrue(result["not_moved"])
        self.assertEqual(self.findmy_calls(), 0)

    def test_a_fix_up_to_12_hours_old_probably_has_not_moved(self):
        self.write_fix(record(minutes_ago=11.9 * 60, accuracy_m=65))
        result = self.call()
        self.assertTrue(result["not_moved"])
        self.assertIn("about 12 hours old", result["note"])
        self.assertIn("65 m", result["note"])
        self.assertIn("probably has not moved", result["note"])

    def test_a_fix_over_12_hours_old_is_the_last_known_location(self):
        # QA #53 risk 3 (main decision): no "not moved" claim after 12 hours. Keep the coordinates, no Find My.
        self.install_findmy()
        self.write_fix(record(minutes_ago=3 * 24 * 60))
        result = self.call()
        self.assertEqual(result["source"], "hermesconnect")
        self.assertEqual((result["latitude"], result["longitude"]), (37.3349, -122.009))
        self.assertAlmostEqual(result["minutes_ago"], 3 * 24 * 60, delta=0.2)
        self.assertTrue(result["stale"])
        self.assertFalse(result["not_moved"])
        self.assertIn("Last known phone location, about 3 days old, may be out of date.", result["note"])
        self.assertNotIn("not moved", result["note"])
        self.assertEqual(self.findmy_calls(), 0)

    def test_the_arrival_time_of_a_visit_is_in_the_result(self):
        arrived = iso(datetime.now(timezone.utc) - timedelta(minutes=50))
        self.write_fix(record(minutes_ago=50, arrived_at=arrived))
        result = self.call()
        self.assertEqual(result["arrived_at"], arrived[:19] + "Z")
        self.assertIn("arrived at this place", result["note"])
        self.write_fix(record(minutes_ago=5, arrived_at=None))
        self.assertNotIn("arrived_at", self.call())
        self.write_fix(record(minutes_ago=5, arrived_at="soon"))
        result = self.call()
        self.assertEqual(result["source"], "hermesconnect")
        self.assertNotIn("arrived_at", result)

    def test_fresh_fix_is_not_marked_not_moved(self):
        self.write_fix(record(minutes_ago=5))
        self.assertNotIn("not_moved", self.call())

    def test_old_fix_without_findmy_needs_no_setup_hint(self):
        self.write_fix(record(minutes_ago=45))
        result = self.call()
        self.assertEqual(result["source"], "hermesconnect")
        self.assertTrue(result["not_moved"])
        self.assertIn("45 minutes old", result["note"])
        self.assertNotIn("Find My", result["note"])

    def test_schema_says_find_my_is_only_for_a_missing_or_invalid_fix(self):
        description = self.plugin.SCHEMA["description"]
        self.assertIn("missing or not valid", description)
        self.assertNotIn("more than 30 minutes old, the tool uses Find My", description)
        self.assertIn("not_moved", description)
        self.assertIn("12 hours", description)
        self.assertIn("arrived_at", description)


class FallbackTests(PluginTestCase):

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

    def test_old_findmy_result_is_marked_stale(self):
        self.install_findmy(age=90)
        result = self.call()
        self.assertEqual(result["source"], "findmy")
        self.assertTrue(result["stale"])

    def test_invalid_fix_with_findmy_error_gives_the_reason(self):
        self.install_findmy(mode="error")
        self.write_fix("lat=1")
        result = self.call()
        self.assertEqual(set(result), {"error"})
        self.assertIn("not sharing a location", result["error"])
        self.assertIn("the phone location file is not valid", result["error"])

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
            "timestamp before 2025": record(timestamp="2024-12-31T23:59:59.000Z"),
            "too large": json.dumps(record()) + " " * 70000,
        }
        for name, value in cases.items():
            with self.subTest(case=name):
                self.write_fix(value)
                result = self.call()
                self.assertEqual(result["source"], "findmy")
                self.assertEqual(result["phone_fix"], "missing: the phone location file is not valid")

    def test_fix_more_than_5_minutes_in_the_future_is_clock_skew(self):
        self.install_findmy()
        for name, value in {"6 minutes": iso(datetime.now(timezone.utc) + timedelta(minutes=6)),
                            "year 2099": "2099-01-01T00:00:00.000Z"}.items():
            with self.subTest(case=name):
                self.write_fix(record(timestamp=value))
                result = self.call()
                self.assertEqual(result["source"], "findmy")
                self.assertIn("clock skew", result["phone_fix"])

    def test_future_fix_without_findmy_is_an_error(self):
        self.write_fix(record(timestamp="2099-01-01T00:00:00.000Z"))
        result = self.call()
        self.assertEqual(set(result), {"error"})
        self.assertIn("clock skew", result["error"])

    def test_extreme_timestamps_count_as_not_valid(self):
        self.install_findmy()
        for value in ("0001-01-01T00:00:00+05:00", "9999-12-31T23:59:59-05:00",
                      "0001-01-01T00:00:00Z", "9999-12-31T23:59:59Z"):
            with self.subTest(timestamp=value):
                self.write_fix(record(timestamp=value))
                result = self.call()
                self.assertNotIn("error", result)
                self.assertEqual(result["source"], "findmy")

    def test_deeply_nested_json_counts_as_not_valid(self):
        self.install_findmy()
        self.write_fix("[" * 60000)
        real_loads = json.loads

        def loads(text, **kwargs):  # Python 3.9 raises RecursionError for this input. Force it everywhere.
            if text.startswith("[[[["):
                raise RecursionError("maximum recursion depth exceeded")
            return real_loads(text, **kwargs)

        for name, patch in {"real input": mock.patch.object(json, "loads", real_loads),
                            "forced RecursionError": mock.patch.object(json, "loads", loads)}.items():
            with self.subTest(case=name):
                with patch:
                    text = self.plugin.handle({})
                result = real_loads(text)
                self.assertEqual(result["source"], "findmy")
                self.assertEqual(result["phone_fix"], "missing: the phone location file is not valid")

    def test_unexpected_exception_returns_tool_error(self):
        self.write_fix(record())
        with mock.patch.object(self.plugin, "_read_fix", side_effect=KeyError("boom")):
            text = self.plugin.handle({})
        result = json.loads(text)
        self.assertEqual(set(result), {"error"})
        self.assertIn("phone_location failed (KeyError)", result["error"])

    def test_findmy_not_set_up_is_not_called(self):
        self.install_findmy()
        os.environ["FAKE_FINDMY_AVAILABLE"] = "0"
        result = self.call()
        self.assertEqual(set(result), {"error"})
        self.assertIn("Find My is not set up", result["error"])
        self.assertEqual(self.findmy_calls(), 0, "the findmy handler must not run")

    def test_findmy_available_check_that_fails_is_not_set_up(self):
        self.install_findmy()
        os.environ["FAKE_FINDMY_AVAILABLE"] = "raise"
        result = self.call()
        self.assertIn("Find My is not set up", result["error"])
        self.assertEqual(self.findmy_calls(), 0)

    def test_findmy_without_available_check_is_not_called(self):
        self.install_findmy()
        path = os.path.join(self.home, ".hermes", "plugins", "findmy", "__init__.py")
        with open(path) as stream:
            source = stream.read().replace("def _available():", "def _not_available_check():")
        with open(path, "w") as out:
            out.write(source)
        result = self.call()
        self.assertIn("Find My is not set up", result["error"])
        self.assertEqual(self.findmy_calls(), 0)

    def test_fifo_at_the_file_path_does_not_block(self):
        self.install_findmy()
        os.makedirs(os.path.dirname(self.location))
        os.mkfifo(self.location)
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
        fix = {"lat": 51.5007, "lon": -0.1246, "accuracy_m": 8, "timestamp": iso(moment), "speed": None,
               "arrived_at": iso(moment)}
        result = self.gate("location", stdin=json.dumps(fix).encode())
        self.assertEqual(result.stdout, b"OK\n", result.stderr)
        with mock.patch.dict(os.environ, {"HOME": self.home}), mock.patch.dict(sys.modules, fake_registry()):
            os.environ.pop("HERMES_HOME", None)
            data = json.loads(load_plugin().handle({}))
        self.assertEqual(data["source"], "hermesconnect")
        self.assertEqual((data["latitude"], data["longitude"], data["accuracy_m"]), (51.5007, -0.1246, 8))
        self.assertAlmostEqual(data["minutes_ago"], 4, delta=0.2)
        self.assertFalse(data["stale"])
        self.assertEqual(data["arrived_at"], iso(moment)[:19] + "Z")


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


class ContractTests(PluginTestCase):
    """Issue #55: the weather and maps plugins on the server parse this tool's output.

    If one of these tests fails, the change breaks weather and maps. Change those plugins first.
    """

    def assert_location(self, raw, source):
        self.assertIsInstance(raw, str)
        result = json.loads(raw)
        self.assertIsInstance(result, dict)
        self.assertNotIn("error", result)
        self.assertEqual(result["source"], source)
        for key in ("latitude", "longitude"):
            self.assertIsInstance(result[key], (int, float), key)
            self.assertNotIsInstance(result[key], bool, key)
        self.assertTrue(-90 <= result["latitude"] <= 90)
        self.assertTrue(-180 <= result["longitude"] <= 180)
        return result

    def test_tool_name_is_phone_location(self):
        ctx = mock.Mock()
        self.plugin.register(ctx)
        kwargs = ctx.register_tool.call_args.kwargs
        self.assertEqual(kwargs["name"], "phone_location")
        self.assertEqual(kwargs["schema"]["name"], "phone_location")
        self.assertIs(kwargs["handler"], self.plugin.handle)

    def test_handle_signature_is_args_dict_kw_returns_str(self):
        signature = inspect.signature(self.plugin.handle)
        params = list(signature.parameters.values())
        self.assertEqual([p.name for p in params], ["args", "kw"])
        self.assertEqual(params[0].kind, inspect.Parameter.POSITIONAL_OR_KEYWORD)
        self.assertIs(params[0].default, inspect.Parameter.empty)
        self.assertEqual(params[1].kind, inspect.Parameter.VAR_KEYWORD)
        hints = typing.get_type_hints(self.plugin.handle)
        self.assertIs(hints["args"], dict)
        self.assertIs(hints["return"], str)

    def test_handle_accepts_extra_keyword_arguments(self):
        self.write_fix(record(minutes_ago=1))
        self.assert_location(self.plugin.handle({}, task_id="t1", session="s"), "hermesconnect")

    def test_phone_path_has_latitude_longitude_source(self):
        self.write_fix(record(minutes_ago=1))
        result = self.assert_location(self.plugin.handle({}), "hermesconnect")
        self.assertEqual((result["latitude"], result["longitude"]), (37.3349, -122.009))

    def test_old_phone_fix_has_latitude_longitude_source(self):
        self.write_fix(record(minutes_ago=13 * 60))
        self.assert_location(self.plugin.handle({}), "hermesconnect")

    def test_findmy_path_has_latitude_longitude_source(self):
        self.install_findmy()
        result = self.assert_location(self.plugin.handle({}), "findmy")
        self.assertEqual((result["latitude"], result["longitude"]), (40.0, -74.0))

    def test_no_location_gives_only_error(self):
        raw = self.plugin.handle({})
        self.assertIsInstance(raw, str)
        result = json.loads(raw)
        self.assertEqual(set(result), {"error"})
        self.assertIsInstance(result["error"], str)
        self.assertTrue(result["error"])

    def test_no_location_uses_tool_error(self):
        calls = []
        registry = sys.modules["tools.registry"]
        with mock.patch.object(self.plugin, "tool_error",
                               side_effect=lambda text: calls.append(text) or registry.tool_error(text)):
            result = json.loads(self.plugin.handle({}))
        self.assertEqual(len(calls), 1)
        self.assertEqual(set(result), {"error"})


if __name__ == "__main__":
    unittest.main()
