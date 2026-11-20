# Troubleshooting

Failures that have actually happened here, what caused them, and which test
now stops them coming back.

If you hit something new, add a row rather than a page. The detailed reasoning
belongs in the test that enforces the fix.

| Symptom | Section |
| :--- | :--- |
| Run freezes at "Launching AVD(s) and waiting for boot up" | [1](#1-a-launch-freezes-and-then-dies-exactly-at-the-timeout) |
| A Pontis device is "not found", or flashing never returns | [2](#2-a-pontis-bridged-device-is-not-found-or-hangs) |
| A job fails even though the device is reachable | [3](#3-a-job-fails-but-the-device-is-reachable) |
| Somebody else's Cuttlefish disappeared | [4](#4-a-device-that-was-not-ours-got-deleted) |
| A cloud instance is still running after the matrix ended | [5](#5-a-cloud-instance-is-left-running) |
| The matrix stops after the first job | [6](#6-the-whole-matrix-stops-after-one-job) |
| Every job is listed as a runner crash although its tests passed | [7](#7-every-job-is-reported-as-a-crash-although-the-tests-passed) |

---

## 1. A launch freezes, and then dies exactly at the timeout

**Symptom.** The job sits at "Launching AVD(s) and waiting for boot up" and is
killed after exactly the launch timeout, to the second. Running
'launch_cvd.sh' by hand works every time.

**Cause.** This is terminal job control, not a slow boot. GNU 'timeout' puts
its child in a new process group, which is not the terminal's foreground
group. During boot, and only during boot, acloud uses 'ssh -t'. That calls
tcsetattr() to put the terminal in raw mode, and tcsetattr() from a background
process group always raises SIGTTOU, whatever TOSTOP is set to. The whole
group stops. 'timeout' ignores SIGTTOU, so it stays alive and its clock keeps
running, then kills everything at the deadline.

The job was never waiting for boot. It was stopped from the first second.

**How to confirm.** Look at the process states:

```
ps -o pid,pgid,tpgid,stat,cmd -g <pgid>
```

STAT is "T" (stopped), and PGID differs from TPGID. A foreground run has
PGID equal to TPGID and STAT "S+".

**Fix in the tree.** 'run_with_timeout' redirects stdin from /dev/null. A
single '-t' only enters raw mode when stdin is a tty, so ssh prints
"Pseudo-terminal will not be allocated" and carries on. This also turns a
would-be SIGTTIN into a clean EOF.

> [!WARNING]
> Do not "fix" this with 'timeout --foreground'. It works, but only because it
> stops creating a new process group, which means timeout can no longer kill
> the tree. acloud and ssh become orphans and the GCE instance leaks.

**Guarded by** [tools/tests/run_with_timeout_test.sh](../../tests/run_with_timeout_test.sh),
including a control case proving the harness still reproduces the freeze, and
an assertion that '--foreground' does not appear in the implementation.

---

## 2. A Pontis bridged device is "not found", or hangs

Three separate causes have produced this.

**Column shift.** 'pontis devices' prints a TAB separated table, and TYPE can
contain spaces, for example "ADB with optimizations". Splitting on any
whitespace shifts every later column, so PORT is read as "with". Parse with an
explicit tab separator and match TYPE on its first word.

**Wrong endpoint spelling.** adb only accepts "localhost:PORT" and rejects
"tcp:127.0.0.1:PORT" with "device not found". fastboot needs the "tcp:" form.
'pontis_endpoint_for' returns the right shape for the transport asked for.

**A transport that never answers.** 'fastboot getvar' over a TCP transport can
block forever. Never call it directly; use 'fastboot_getvar', which applies a
deadline.

**Guarded by** [tools/tests/device_util_test.sh](../../tests/device_util_test.sh).

---

## 3. A job fails but the device is reachable

**Cause.** 'device_util::init' used to do its own inline detection with no
fallback, so any problem reading Pontis failed the whole job. It also accepted
devices in "offline" or "unauthorized" state as found, because it matched with
a plain grep over 'adb devices'.

**Now.** init delegates to the two find_*_serial helpers, which fall back to
probing each endpoint directly. A broken or missing pontis binary no longer
matters when the device answers.

**Guarded by** [tools/tests/device_util_test.sh](../../tests/device_util_test.sh),
which includes garbled Pontis output and a deleted pontis binary.

---

## 4. A device that was not ours got deleted

**Cause.** The teardown fallback used "acloud delete --all" whenever SERIAL was
empty, which is exactly what happens when a launch fails. Every Cuttlefish the
user had running went with it.

**Rule now.** Identify the instance, in this order:

1. the adb port, when the launch succeeded
2. the instance name in the acloud report file, when acloud failed cleanly
3. the difference between the instance list before and after, when the launch
   was killed and wrote no report

If none of those gives exactly one answer, **delete nothing** and print what
was found. Two instances appearing at once, because a colleague started one
during our launch, must never be resolved by guessing. "--all" is never
correct.

**Guarded by** [tools/mixed_build_test_runner/tests/device_cleanup_test.sh](../tests/device_cleanup_test.sh).

---

## 5. A cloud instance is left running

**Cause.** Killing the process tree does not reclaim the remote machine. A
killed launch leaves a GCE instance running, and billing, for as long as
nobody notices. One survived two hours this way.

A timeout is necessary but never sufficient. Teardown has to run as well, and
it has to run even when the job failed, which is why a failing step must not
abort the script (see section 6).

**Guarded by** [tools/mixed_build_test_runner/tests/device_cleanup_test.sh](../tests/device_cleanup_test.sh),
which asserts teardown still happens after every failure mode.

---

## 6. The whole matrix stops after one job

**Cause.** An unguarded command in a pipeline. When atest printed no
"Test logs:" line, the grep looking for it failed, and that ended the script.
The remaining jobs never ran, and, worse, teardown was skipped so the cloud
instance leaked.

**Rule.** A job may fail. The run may not. Anything that can legitimately find
nothing needs "|| true" and an explicit check afterwards.

**Guarded by** [tools/mixed_build_test_runner/tests/atest_log_parse_test.sh](../tests/atest_log_parse_test.sh),
which also patches the old line back into a sandbox copy to prove the bug was
real.

---

## 7. Every job is reported as a crash although the tests passed

**Symptom.** A coding agent started the matrix. Every job passes, yet the
runner warns "Could not extract ATest log directory", each job directory holds
nothing but 'runner_stdout.log', and the report lists every job under "Runner
Crashes Detected". The same command typed into a terminal works.

**Cause.** atest changes its output when its environment tells it an agent is
the caller ('is_agentic_invocation' in tools/asuite/atest/atest_utils.py).
Results go to stderr, and stdout is sent to /dev/null once logging is set up.
"Test logs:" is printed after that, so it never appears, and it was the only
line the runner looked for. The results were on disk the whole time, in the
directory atest names before it goes quiet:

```
Atest results and logs directory: /tmp/atest_result_<user>/<run>
```

**How to confirm.** In the job's 'runner_stdout.log' that line is at the very
end instead of where atest starts, and there is no "Test logs:". In the
'atest.log' of the directory it names, the result summary is logged as STDERR
and "Test logs:" as STDOUT.

**Now.** When "Test logs:" does not lead to a directory, the runner takes the
one from that line, but only if the 'test_result' in it has content. The line
is printed before atest does any work, so by itself it also matches an atest
that was killed half way, and copying an empty 'test_result' makes the report
show a JSON error for the job instead of the end of its log.

> [!WARNING]
> Do not unset the variables to get the old output back. The same switch keeps
> atest from opening a browser for OAuth and from asking which test was meant,
> and an agent can answer neither.

A report that was lost this way can be rebuilt while /tmp still holds the
directories: copy each one into its job directory and run 'matrix-reporter'
again.

**Guarded by** [tools/mixed_build_test_runner/tests/atest_log_parse_test.sh](../tests/atest_log_parse_test.sh),
which also takes the second lookup back out of a sandbox copy to prove the
results really were lost.

---

## Things that look like fixes but are not

**Raising acloud's --boot-timeout.** The help text does not mention it, but the
default is 450 seconds, minus the time already spent downloading artifacts.
Passing 1200 does not add protection, it loosens the only protection there is
by about three times. It also does not help: under the "Launching AVD(s)"
progress bar there are four ssh calls, and --boot-timeout covers only one of
them. The other three have no timeout at all, and two of them retry five
times. acloud's ssh command line sets neither ConnectTimeout nor
ServerAliveInterval, so a half-dead TCP connection hangs forever. The outer
'run_with_timeout' is the only thing that recovers from that.

'ACLOUD_BOOT_TIMEOUT_SECS' exists in launch_cvd.sh for cases that genuinely
need it, but it is off by default and the command line is byte for byte
unchanged when it is unset.

**'timeout --foreground'.** See section 1.

**Hiding the agent from atest.** See section 7.
