#!/usr/bin/env python3
"""Run a command under a physical-footprint cap, killing its whole process group over the cap.

Usage: memcap.py <cap_gb> <command> [args...]

macOS RSS excludes compressed memory, so this reads ri_phys_footprint via proc_pid_rusage(2)
and sums it across the process group, polling from a separate process.
"""

import ctypes
import os
import signal
import subprocess
import sys
import time

RUSAGE_INFO_CURRENT = 0


class RUsageInfoV4(ctypes.Structure):
    _fields_ = [("ri_uuid", ctypes.c_uint8 * 16)] + [
        (n, ctypes.c_uint64)
        for n in (
            "ri_user_time",
            "ri_system_time",
            "ri_pkg_idle_wkups",
            "ri_interrupt_wkups",
            "ri_pageins",
            "ri_wired_size",
            "ri_resident_size",
            "ri_phys_footprint",
            "ri_proc_start_abstime",
            "ri_proc_exit_abstime",
            "ri_child_user_time",
            "ri_child_system_time",
            "ri_child_pkg_idle_wkups",
            "ri_child_interrupt_wkups",
            "ri_child_pageins",
            "ri_child_elapsed_abstime",
            "ri_diskio_bytesread",
            "ri_diskio_byteswritten",
            "ri_cpu_time_qos_default",
            "ri_cpu_time_qos_maintenance",
            "ri_cpu_time_qos_background",
            "ri_cpu_time_qos_utility",
            "ri_cpu_time_qos_legacy",
            "ri_cpu_time_qos_user_initiated",
            "ri_cpu_time_qos_user_interactive",
            "ri_billed_system_time",
            "ri_serviced_system_time",
            "ri_logical_writes",
            "ri_lifetime_max_phys_footprint",
            "ri_instructions",
            "ri_cycles",
            "ri_billed_energy",
            "ri_serviced_energy",
            "ri_interval_max_phys_footprint",
            "ri_runnable_time",
            "ri_flags",
        )
    ]


_libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
_libc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.POINTER(ctypes.c_void_p)]


def footprint(pid):
    info = RUsageInfoV4()
    rc = _libc.proc_pid_rusage(
        pid, RUSAGE_INFO_CURRENT, ctypes.cast(ctypes.byref(info), ctypes.POINTER(ctypes.c_void_p))
    )
    return info.ri_phys_footprint if rc == 0 else 0


def group_pids(pgid):
    out = subprocess.run(["ps", "-o", "pid=", "-g", str(pgid)], check=False, capture_output=True, text=True).stdout
    return [int(x) for x in out.split()]


def main():
    cap = float(sys.argv[1]) * (1 << 30)
    proc = subprocess.Popen(sys.argv[2:], start_new_session=True)
    pgid = os.getpgid(proc.pid)
    peak = 0
    while proc.poll() is None:
        total = sum(footprint(p) for p in group_pids(pgid))
        peak = max(peak, total)
        if total > cap:
            print(
                f"memcap: {total / (1 << 30):.2f} GB > {cap / (1 << 30):.2f} GB cap; killing group {pgid}",
                file=sys.stderr,
                flush=True,
            )
            os.killpg(pgid, signal.SIGKILL)
            proc.wait()
            sys.exit(137)
        time.sleep(0.25)
    print(f"memcap: peak {peak / (1 << 20):.0f} MiB, exit {proc.returncode}", file=sys.stderr)
    sys.exit(proc.returncode)


main()
