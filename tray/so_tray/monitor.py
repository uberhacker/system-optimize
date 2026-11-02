"""Live readings from /proc and /sys. Read-only; needs no root.

Every path goes through Monitor.path(), which puts the root prefix in front
(SO_ROOT in the tests, "/" on a real machine), so the whole module runs
against a fake tree. Nothing here raises on a missing or odd file: a value
that cannot be read is None and the UI shows a dash.
"""

import glob
import json
import os
import shutil
import subprocess
import threading
import time

# hwmon chips, in the order we prefer them for "the CPU temperature".
CPU_CHIPS = ("k10temp", "zenpower", "coretemp", "cpu_thermal", "acpitz")
# Labels that name the package / die temperature on those chips.
CPU_LABELS = ("Tctl", "Tdie", "Package id 0", "CPU")
GPU_CHIPS = ("amdgpu", "nouveau", "radeon", "i915", "xe")

# Pressure stall alert thresholds, as psi-notify ships them: the share of
# the last 10 seconds that tasks spent stalled on a resource.
PSI_THRESHOLDS = {"cpu": ("some", 50.0), "memory": ("some", 10.0), "io": ("full", 15.0)}


def _read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read().strip()
    except OSError:
        return None


def _read_int(path):
    text = _read(path)
    if text is None:
        return None
    try:
        return int(text.split()[0])
    except (ValueError, IndexError):
        return None


def parse_meminfo(text):
    """{'MemTotal': kB, ...} from /proc/meminfo."""
    out = {}
    for line in (text or "").splitlines():
        key, _, rest = line.partition(":")
        parts = rest.split()
        if parts:
            try:
                out[key.strip()] = int(parts[0])
            except ValueError:
                pass
    return out


def parse_cpu_times(text):
    """(busy, total) jiffies of the aggregate 'cpu' line of /proc/stat."""
    for line in (text or "").splitlines():
        if line.startswith("cpu "):
            try:
                fields = [int(x) for x in line.split()[1:]]
            except ValueError:
                return None
            if len(fields) < 4:
                return None
            # user nice system idle iowait irq softirq steal (guest* are
            # already counted in user/nice).
            idle = fields[3] + (fields[4] if len(fields) > 4 else 0)
            total = sum(fields[:8])
            return total - idle, total
    return None


def cpu_percent(prev, cur):
    """CPU use in percent between two parse_cpu_times() samples."""
    if not prev or not cur:
        return None
    busy = cur[0] - prev[0]
    total = cur[1] - prev[1]
    if total <= 0:
        return None
    return max(0.0, min(100.0, 100.0 * busy / total))


def parse_pressure(text):
    """/proc/pressure/<resource>: {'some': {'avg10': .., 'avg60': .., 'avg300': ..}, 'full': {..}}."""
    out = {}
    for line in (text or "").splitlines():
        parts = line.split()
        if not parts or parts[0] not in ("some", "full"):
            continue
        vals = {}
        for kv in parts[1:]:
            k, _, v = kv.partition("=")
            if k.startswith("avg"):
                try:
                    vals[k] = float(v)
                except ValueError:
                    pass
        out[parts[0]] = vals
    return out


def pressure_alerts(pressure, thresholds=PSI_THRESHOLDS):
    """[(resource, kind, avg10, limit)] for each resource over its threshold."""
    out = []
    for res, (kind, limit) in thresholds.items():
        v = ((pressure or {}).get(res) or {}).get(kind, {}).get("avg10")
        if v is not None and v >= limit:
            out.append((res, kind, v, limit))
    return out


def parse_amdgpu_top(obj):
    """One amdgpu_top -J sample -> {'vram_used_mb', 'vram_total_mb', 'gtt_used_mb',
    'gtt_total_mb', 'busy_percent', 'name', 'top'} for the first device
    (the APU or the first card), or None."""
    def val(d, *keys):
        for k in keys:
            if not isinstance(d, dict):
                return None
            d = d.get(k)
        if isinstance(d, dict):
            d = d.get("value")
        return d if isinstance(d, (int, float)) and not isinstance(d, bool) else None

    devices = (obj or {}).get("devices") if isinstance(obj, dict) else None
    if not devices or not isinstance(devices, list) or not isinstance(devices[0], dict):
        return None
    dev = devices[0]
    vram = dev.get("VRAM") or {}
    out = {
        "name": (dev.get("Info") or {}).get("DeviceName"),
        "vram_used_mb": val(vram, "Total VRAM Usage"),
        "vram_total_mb": val(vram, "Total VRAM"),
        "gtt_used_mb": val(vram, "Total GTT Usage"),
        "gtt_total_mb": val(vram, "Total GTT"),
        "busy_percent": val(dev, "gpu_activity", "GFX"),
    }
    procs = []
    for pid, p in (dev.get("fdinfo") or {}).items():
        if not isinstance(p, dict):
            continue
        usage = p.get("usage") or {}
        v, g = val(usage, "VRAM") or 0, val(usage, "GTT") or 0
        if v + g > 0:
            procs.append({"pid": str(pid), "name": str(p.get("name") or "?")[:40], "vram_mb": v, "gtt_mb": g})
    procs.sort(key=lambda p: -(p["vram_mb"] + p["gtt_mb"]))
    out["top"] = procs[:3]
    if not isinstance(out["name"], str):
        out["name"] = None
    return out


class AmdgpuTop:
    """Runs `amdgpu_top -J -s 5000ms` in the background and keeps its latest
    sample, so the readout never waits on it. Started on first use; a
    missing or failing amdgpu_top just means no data (sysfs is used)."""

    def __init__(self, which=None, popen=None, interval_ms=5000):
        self._which = which or shutil.which
        self._popen = popen or subprocess.Popen
        self.interval_ms = interval_ms
        self.latest = None
        self.proc = None
        self.failed = False
        self._lock = threading.Lock()

    def available(self):
        return not self.failed and bool(self._which("amdgpu_top"))

    def start(self):
        if self.proc or not self.available():
            return
        try:
            self.proc = self._popen(["amdgpu_top", "-J", "-s", "%dms" % self.interval_ms],
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        except OSError:
            self.failed = True
            return
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        dec = json.JSONDecoder()
        buf = ""
        stream = self.proc.stdout
        for line in stream:
            buf += line
            while True:
                buf = buf.lstrip()
                if not buf:
                    break
                try:
                    obj, end = dec.raw_decode(buf)
                except ValueError:
                    break           # incomplete: wait for more lines
                buf = buf[end:]
                parsed = parse_amdgpu_top(obj)
                if parsed:
                    with self._lock:
                        self.latest = (time.monotonic(), parsed)
            if len(buf) > 4_000_000:   # garbage, not JSON: give up
                break
        self.failed = True
        self.proc = None

    def get(self, max_age=20):
        self.start()
        with self._lock:
            if self.latest and time.monotonic() - self.latest[0] <= max_age:
                return self.latest[1]
        return None

    def stop(self):
        if self.proc:
            try:
                self.proc.terminate()
            except OSError:
                pass
            self.proc = None


def parse_diskstats(text, disks):
    """(sectors read, sectors written) summed over the whole disks named."""
    rd = wr = 0
    for line in (text or "").splitlines():
        f = line.split()
        if len(f) >= 10 and f[2] in disks:
            try:
                rd += int(f[5])
                wr += int(f[9])
            except ValueError:
                pass
    return rd, wr


class Monitor:
    """Samples the machine. Keep one instance: CPU use needs two samples."""

    def __init__(self, root="/", run=None, which=None, amdgpu_top=None):
        self.root = root or "/"
        self._run = run or _run_quiet
        self._which = which or shutil.which
        self._prev_cpu = None
        self._prev_disk = None    # (time, sectors read, sectors written)
        # amdgpu_top only on a real machine: under a fake root its numbers
        # would not match the tree
        self.amdgpu_top = amdgpu_top if amdgpu_top is not None else (
            AmdgpuTop(which=self._which) if self.root == "/" else None)
        self._warn_cache = (0.0, [])
        self.psi_notify = False   # psi-notify runs: it does the pressure notifications

    def path(self, p):
        return os.path.join(self.root, p.lstrip("/"))

    # -- CPU -----------------------------------------------------------
    def cpu(self):
        cur = parse_cpu_times(_read(self.path("/proc/stat")))
        pct = cpu_percent(self._prev_cpu, cur)
        self._prev_cpu = cur
        freqs = []
        for f in glob.glob(self.path("/sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq")):
            v = _read_int(f)
            if v:
                freqs.append(v)
        load = _read(self.path("/proc/loadavg"))
        try:
            load1 = float(load.split()[0]) if load else None
        except ValueError:
            load1 = None
        gov = _read(self.path("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"))
        epp = _read(self.path("/sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference"))
        return {
            "percent": None if pct is None else round(pct, 1),
            "mhz": round(sum(freqs) / len(freqs) / 1000) if freqs else None,
            "mhz_max": round(max(freqs) / 1000) if freqs else None,
            "load1": load1,
            "cores": len(glob.glob(self.path("/sys/devices/system/cpu/cpu[0-9]*"))) or os.cpu_count(),
            "governor": gov,
            "epp": epp,
        }

    # -- memory --------------------------------------------------------
    def memory(self):
        mi = parse_meminfo(_read(self.path("/proc/meminfo")))
        total = mi.get("MemTotal")
        avail = mi.get("MemAvailable")
        swap_total = mi.get("SwapTotal", 0)
        swap_free = mi.get("SwapFree", 0)
        used = (total - avail) if total and avail is not None else None
        return {
            "total_mb": total // 1024 if total else None,
            "used_mb": used // 1024 if used is not None else None,
            "percent": round(100.0 * used / total, 1) if total and used is not None else None,
            "swap_total_mb": swap_total // 1024,
            "swap_used_mb": max(0, swap_total - swap_free) // 1024,
            "zram": bool(glob.glob(self.path("/sys/block/zram[0-9]*"))),
        }

    # -- temperatures --------------------------------------------------
    def temperatures(self):
        """{'cpu': C, 'gpu': C, 'nvme': C, 'sensors': [{chip,label,c}]}."""
        sensors = []
        for hw in sorted(glob.glob(self.path("/sys/class/hwmon/hwmon*"))):
            chip = _read(os.path.join(hw, "name")) or os.path.basename(hw)
            for inp in sorted(glob.glob(os.path.join(hw, "temp*_input"))):
                milli = _read_int(inp)
                if milli is None or milli <= -40000 or milli >= 150000:
                    continue
                label = _read(inp[: -len("_input")] + "_label") or os.path.basename(inp)[: -len("_input")]
                sensors.append({"chip": chip, "label": label, "c": round(milli / 1000.0, 1)})
        out = {"cpu": None, "gpu": None, "nvme": None, "sensors": sensors}
        for chip in CPU_CHIPS:
            mine = [s for s in sensors if s["chip"] == chip]
            if not mine:
                continue
            labelled = [s for lab in CPU_LABELS for s in mine if s["label"] == lab]
            out["cpu"] = (labelled or mine)[0]["c"]
            break
        if out["cpu"] is None:
            # No hwmon chip we know: the thermal zone of type x86_pkg_temp
            # or the first zone.
            zones = sorted(glob.glob(self.path("/sys/class/thermal/thermal_zone*")))
            pick = None
            for z in zones:
                if (_read(os.path.join(z, "type")) or "") in ("x86_pkg_temp", "cpu-thermal", "cpu_thermal"):
                    pick = z
                    break
            if pick is None and zones:
                pick = zones[0]
            if pick:
                milli = _read_int(os.path.join(pick, "temp"))
                if milli is not None and -40000 < milli < 150000:
                    out["cpu"] = round(milli / 1000.0, 1)
        for chip in GPU_CHIPS:
            mine = [s for s in sensors if s["chip"] == chip]
            if mine:
                edge = [s for s in mine if s["label"] in ("edge", "junction")]
                out["gpu"] = (edge or mine)[0]["c"]
                break
        nvme = [s for s in sensors if s["chip"] == "nvme"]
        if nvme:
            out["nvme"] = max(s["c"] for s in nvme)
        return out

    # -- power ---------------------------------------------------------
    def power(self):
        """Active power profile, who owns it, AC and battery."""
        profile = None
        owner = None
        if self._which("powerprofilesctl"):
            text = self._run(["powerprofilesctl", "get"])
            if text:
                profile, owner = text.strip().splitlines()[0], "power-profiles-daemon"
        if profile is None and self._which("tuned-adm"):
            text = self._run(["tuned-adm", "active"])
            if text and ":" in text:
                profile, owner = text.split(":", 1)[1].strip().splitlines()[0], "tuned"
        if profile is None:
            pp = _read(self.path("/sys/firmware/acpi/platform_profile"))
            if pp:
                profile, owner = pp, "firmware"
        ac = None
        batteries = []
        for sup in sorted(glob.glob(self.path("/sys/class/power_supply/*"))):
            kind = _read(os.path.join(sup, "type"))
            if kind == "Mains":
                online = _read_int(os.path.join(sup, "online"))
                if online is not None:
                    ac = bool(online) or bool(ac)
            elif kind == "Battery":
                # A wireless mouse or keyboard reports scope=Device: not ours.
                if (_read(os.path.join(sup, "scope")) or "System") != "System":
                    continue
                batteries.append({
                    "name": os.path.basename(sup),
                    "percent": _read_int(os.path.join(sup, "capacity")),
                    "status": _read(os.path.join(sup, "status")),
                    "limit": _read_int(os.path.join(sup, "charge_control_end_threshold")),
                })
        return {"profile": profile, "owner": owner, "ac": ac, "batteries": batteries}

    # -- disks and GPU ----------------------------------------------
    def whole_disks(self):
        out = set()
        for d in glob.glob(self.path("/sys/block/*")):
            name = os.path.basename(d)
            if name.startswith(("loop", "ram", "zram", "fd", "sr", "md", "dm-")):
                continue
            out.add(name)
        return out

    def disk(self):
        now = time.monotonic()
        cur = parse_diskstats(_read(self.path("/proc/diskstats")), self.whole_disks())
        out = {"read_mbs": None, "write_mbs": None}
        if self._prev_disk:
            dt = now - self._prev_disk[0]
            if dt > 0:
                out["read_mbs"] = round(max(0, cur[0] - self._prev_disk[1]) * 512 / dt / 1e6, 2)
                out["write_mbs"] = round(max(0, cur[1] - self._prev_disk[2]) * 512 / dt / 1e6, 2)
        self._prev_disk = (now, cur[0], cur[1])
        return out

    def gpu(self):
        """GPU busy and memory. VRAM is the carve-out; GTT is system RAM the
        GPU has mapped, which is where an APU keeps most of a model. From
        amdgpu_top when it runs (it also names the processes using it),
        else from amdgpu's sysfs files."""
        busy = None
        mem = {}
        for dev in sorted(glob.glob(self.path("/sys/class/drm/card[0-9]*/device"))):
            v = _read_int(os.path.join(dev, "gpu_busy_percent"))
            if v is not None:
                busy = v if busy is None else max(busy, v)
            if not mem:
                vals = {k: _read_int(os.path.join(dev, "mem_info_%s" % k))
                        for k in ("vram_used", "vram_total", "gtt_used", "gtt_total")}
                if any(x is not None for x in vals.values()):
                    mem = {k + "_mb": (None if x is None else round(x / 1048576)) for k, x in vals.items()}
        out = {"busy_percent": busy, "vram_used_mb": None, "vram_total_mb": None, "gtt_used_mb": None,
               "gtt_total_mb": None, "source": None, "top": [], "name": None}
        if mem:
            out.update(mem)
            out["source"] = "sysfs"
        top = self.amdgpu_top.get() if self.amdgpu_top else None
        if top:
            for k, v in top.items():
                if v is not None and v != []:
                    out[k] = v
            out["source"] = "amdgpu_top"
        used = [out[k] for k in ("vram_used_mb", "gtt_used_mb") if out[k] is not None]
        total = [out[k] for k in ("vram_total_mb", "gtt_total_mb") if out[k] is not None]
        out["mem_used_mb"] = sum(used) if used else None
        out["mem_total_mb"] = sum(total) if total else None
        out["mem_percent"] = (round(100.0 * sum(used) / sum(total), 1)
                              if used and total and sum(total) > 0 else None)
        return out

    # -- pressure and conflicts ---------------------------------------
    def pressure(self):
        out = {}
        for res in ("cpu", "memory", "io"):
            text = _read(self.path("/proc/pressure/%s" % res))
            if text:
                out[res] = parse_pressure(text)
        return out

    def _running(self, names):
        """Which of these process names are running (from /proc/*/comm)."""
        found = set()
        for comm in glob.glob(self.path("/proc/[0-9]*/comm")):
            name = _read(comm)
            if name in names:
                found.add(name)
        return found

    def warnings(self, every=30):
        """Tools that fight each other, checked every 30 s: an scx (sched_ext)
        scheduler with ananicy-cpp, which can stall or destabilise it."""
        now = time.monotonic()
        if self._warn_cache[0] and now - self._warn_cache[0] < every:
            return self._warn_cache[1]
        out = []
        running = self._running({"ananicy-cpp", "psi-notify"})
        self.psi_notify = "psi-notify" in running
        state = _read(self.path("/sys/kernel/sched_ext/state"))
        if state == "enabled":
            ops = _read(self.path("/sys/kernel/sched_ext/root/ops")) or "an scx scheduler"
            if "ananicy-cpp" in running:
                out.append({"id": "scx-ananicy",
                            "text": "%s and ananicy-cpp are both running. ananicy-cpp can stall or destabilise "
                                    "sched_ext schedulers: stop one of them." % ops})
        self._warn_cache = (now, out)
        return out

    def sample(self):
        return {
            "time": int(time.time()),
            "cpu": self.cpu(),
            "memory": self.memory(),
            "temperature": self.temperatures(),
            "power": self.power(),
            "disk": self.disk(),
            "gpu": self.gpu(),
            "pressure": self.pressure(),
            "warnings": self.warnings(),
            "pressure_notifier": "psi-notify" if self.psi_notify else None,
        }

    def close(self):
        if self.amdgpu_top:
            self.amdgpu_top.stop()


def _run_quiet(argv, timeout=3):
    try:
        res = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    return res.stdout if res.returncode == 0 else None


def summary(sample):
    """One short line for a panel label or a tooltip: 'CPU 12% 54°C · RAM 41%'."""
    cpu = sample.get("cpu", {})
    mem = sample.get("memory", {})
    temp = sample.get("temperature", {})
    parts = []
    c = "CPU " + ("–" if cpu.get("percent") is None else "%d%%" % round(cpu["percent"]))
    if temp.get("cpu") is not None:
        c += " %d°C" % round(temp["cpu"])
    parts.append(c)
    parts.append("RAM " + ("–" if mem.get("percent") is None else "%d%%" % round(mem["percent"])))
    return " · ".join(parts)
