#!/usr/bin/env bash
# Tests for the atest log directory parsing in mixed_build_test_runner.sh.
#
# Two properties matter.
#
# When atest prints no "Test logs:" line, the job must degrade on its own and
# the matrix run must carry on. Before the fix the failing grep ended the whole
# script, which also skipped virtual device teardown and leaked a cloud
# instance.
#
# When atest is started by a coding agent it never prints that line, because it
# mutes its own stdout. The results must still be found, through the line that
# names the directory before atest starts. Before the fix every job of an agent
# run lost its results, and the report listed all of them as crashes although
# every test had passed.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_DIR="$(dirname "${TESTS_DIR}")"
TOOLS_DIR="$(dirname "${RUNNER_DIR}")"
export TOOLS_DIR

# shellcheck source=../../tests/lib/test_common.sh
source "${TOOLS_DIR}/tests/lib/test_common.sh"
# shellcheck source=../../tests/fixtures/matrix_sandbox.sh
source "${TOOLS_DIR}/tests/fixtures/matrix_sandbox.sh"

require_cmd jq python3

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
SANDBOX="${TMPROOT}/sandbox"
RUNNER="${SANDBOX}/tools/mixed_build_test_runner/mixed_build_test_runner.sh"
OURS="ins-cccc3333-16407304-aosp-cf-x86-64-only-phone"
RUN_ID="fixedrun"

# Writes a two job config, so a test can prove the second job still runs after
# the first one goes wrong.
function make_two_job_config() {
    local path="$1" device_type="$2"
    cat > "$path" <<EOF
{
  "global_config": {
    "test_timeout": "5s",
    "test_suite": "dummy_suite"
  },
  "jobs": [
    {
      "job_id": "job_one",
      "display_name": "Job One",
      "device_type": "${device_type}",
      "serial_port": "127.0.0.1:6520",
      "builds": {
        "pb": {
          "branch": "git_main",
          "target": "aosp_cf_x86_64_only_phone-trunk_staging-userdebug",
          "build_id": "16407304"
        }
      }
    },
    {
      "job_id": "job_two",
      "display_name": "Job Two",
      "device_type": "${device_type}",
      "serial_port": "127.0.0.1:6520",
      "builds": {
        "pb": {
          "branch": "git_main",
          "target": "aosp_cf_x86_64_only_phone-trunk_staging-userdebug",
          "build_id": "16407304"
        }
      }
    }
  ]
}
EOF
}

function run_matrix() {
    local config="$1"
    shift
    rm -rf "${SANDBOX}/state/reports"
    : > "${SANDBOX}/state/acloud.log"
    printf 'ins-bystander-000-target\n' > "${SANDBOX}/state/acloud_instances"
    (
        export PATH="${SANDBOX}/bin:${PATH}"
        export STUB_STATE_DIR="${SANDBOX}/state"
        export STUB_NEW_INSTANCE="$OURS"
        "$@" "$RUNNER" -c "$config" \
            -od "${SANDBOX}/state/reports" --run-id "$RUN_ID" \
            > "${SANDBOX}/state/run.log" 2>&1
        echo "$?" > "${SANDBOX}/state/run.rc"
    )
}

function rc()              { cat "${SANDBOX}/state/run.rc"; }
function log_has()         { grep -qF -- "$1" "${SANDBOX}/state/run.log" && echo yes || echo no; }
function reached_summary() { log_has "Matrix Run Summary:"; }
function deletes()         { grep -c '^acloud delete' "${SANDBOX}/state/acloud.log" || true; }
function report_of()       { echo "${SANDBOX}/state/reports/${RUN_ID}/$1"; }
# Whether the results a stubbed atest finished writing reached a job's report.
function has_results() {
    [[ "$(cat "$(report_of "$1")/test_result" 2> /dev/null)" == '{"stub": "result"}' ]] \
        && echo yes || echo no
}

make_sandbox "$SANDBOX"
printf '127.0.0.1:6520\tdevice\n' > "${SANDBOX}/state/adb_devices"
CONFIG="${SANDBOX}/matrix.json"
make_two_job_config "$CONFIG" virtual

section "atest prints no log path"

run_matrix "$CONFIG" env TEST_STUB_MODE=nologline
check "the run is not aborted" "yes" "$(reached_summary)"
check "the run exits cleanly" "0" "$(rc)"
check "both jobs succeed" "yes" "$(log_has 'TOTAL SUCCESS: 2')"
check "the missing log path is reported" "yes" \
    "$(log_has 'Could not extract ATest log directory')"
check "the second job still runs" "yes" "$(log_has 'Job Two')"
check "stdout is still kept for job one" "yes" \
    "$([[ -s "$(report_of job_one)/runner_stdout.log" ]] && echo yes || echo no)"
check "stdout is still kept for job two" "yes" \
    "$([[ -s "$(report_of job_two)/runner_stdout.log" ]] && echo yes || echo no)"
# The teardown is the reason this bug was worth fixing: an abort here would
# have left the cloud instance running.
check "both devices are still torn down" "2" "$(deletes)"
check "teardown never uses --all" "no" \
    "$(grep -q -- '--all' "${SANDBOX}/state/acloud.log" && echo yes || echo no)"

section "atest crashes before printing anything"

run_matrix "$CONFIG" env TEST_STUB_MODE=crash
check "crash: the run is not aborted" "yes" "$(reached_summary)"
check "crash: both jobs are marked as errors" "yes" "$(log_has 'TOTAL ERROR: 2')"
check "crash: the run reports failure" "1" "$(rc)"
check "crash: the second job still runs" "yes" "$(log_has 'Job Two')"
check "crash: both devices are still torn down" "2" "$(deletes)"

section "atest hangs and is timed out"

if slow_enabled; then
    run_matrix "$CONFIG" env TEST_STUB_MODE=hang
    check "timeout: the run is not aborted" "yes" "$(reached_summary)"
    check "timeout: the timeout is named" "yes" "$(log_has 'Tests timed out after')"
    check "timeout: both jobs are marked as errors" "yes" "$(log_has 'TOTAL ERROR: 2')"
    check "timeout: both devices are still torn down" "2" "$(deletes)"
else
    skip_test "atest hangs and is timed out" "SKIP_SLOW"
fi

section "the normal path is unchanged"

run_matrix "$CONFIG" env TEST_STUB_MODE=success
check "success: the run exits cleanly" "0" "$(rc)"
check "success: both jobs succeed" "yes" "$(log_has 'TOTAL SUCCESS: 2')"
check "success: no warning about the log path" "no" \
    "$(log_has 'Could not extract ATest log directory')"
check "success: the atest logs are copied" "yes" \
    "$([[ -f "$(report_of job_one)/result.txt" ]] && echo yes || echo no)"
check "success: the copy is reported" "yes" "$(log_has 'Copying test logs from')"
check "success: both devices are torn down" "2" "$(deletes)"

section "physical jobs are unaffected"

PHYS_CONFIG="${SANDBOX}/matrix_phys.json"
make_two_job_config "$PHYS_CONFIG" physical
run_matrix "$PHYS_CONFIG" env TEST_STUB_MODE=nologline
check "physical: the run is not aborted" "yes" "$(reached_summary)"
check "physical: acloud is never called" "0" "$(deletes)"

section "atest is run from a terminal"

# What a real atest prints, as opposed to the 'success' stub above: it names
# the results directory before it starts, and prints "Test logs:" at the end.
run_matrix "$CONFIG" env TEST_STUB_MODE=terminal
check "terminal: both jobs succeed" "yes" "$(log_has 'TOTAL SUCCESS: 2')"
check "terminal: no warning about the log path" "no" \
    "$(log_has 'Could not extract ATest log directory')"
check "terminal: the results are copied" "yes" "$(has_results job_one)"
check "terminal: the logs beside them are copied" "yes" \
    "$([[ -f "$(report_of job_one)/atest.log" ]] && echo yes || echo no)"

section "atest is started by a coding agent"

run_matrix "$CONFIG" env TEST_STUB_MODE=agent
check "agent: the run exits cleanly" "0" "$(rc)"
check "agent: both jobs succeed" "yes" "$(log_has 'TOTAL SUCCESS: 2')"
check "agent: no warning about the log path" "no" \
    "$(log_has 'Could not extract ATest log directory')"
check "agent: the results are copied for job one" "yes" "$(has_results job_one)"
check "agent: the results are copied for job two" "yes" "$(has_results job_two)"
check "agent: the logs beside them are copied" "yes" \
    "$([[ -f "$(report_of job_one)/atest.log" ]] && echo yes || echo no)"
check "agent: the copy is reported" "yes" "$(log_has 'Copying test logs from')"
check "agent: stdout is still kept" "yes" \
    "$([[ -s "$(report_of job_one)/runner_stdout.log" ]] && echo yes || echo no)"
check "agent: both devices are torn down" "2" "$(deletes)"

section "the directory is named where it is hard to find"

# Two things an agent run can do to the output. A test may print "Test logs:"
# itself, and stderr may be in the middle of a line when atest exits and
# flushes the line that names the directory.
run_matrix "$CONFIG" env TEST_STUB_MODE=agent_noisy
check "noisy: both jobs succeed" "yes" "$(log_has 'TOTAL SUCCESS: 2')"
check "noisy: no warning about the log path" "no" \
    "$(log_has 'Could not extract ATest log directory')"
check "noisy: the results are copied for job one" "yes" "$(has_results job_one)"
check "noisy: the results are copied for job two" "yes" "$(has_results job_two)"

section "atest names its directory and dies before writing results"

# Naming the directory is the first thing atest does, so that line says nothing
# about what is in it. A directory without results is left alone, as it always
# was, and the report shows the end of the job's stdout instead.
run_matrix "$CONFIG" env TEST_STUB_MODE=noresult
check "noresult: the run is not aborted" "yes" "$(reached_summary)"
check "noresult: both jobs are marked as errors" "yes" "$(log_has 'TOTAL ERROR: 2')"
check "noresult: the second job still runs" "yes" "$(log_has 'Job Two')"
check "noresult: the missing log path is reported" "yes" \
    "$(log_has 'Could not extract ATest log directory')"
check "noresult: nothing is copied" "no" "$(log_has 'Copying test logs from')"
check "noresult: the empty result file stays out of the report" "no" \
    "$([[ -e "$(report_of job_one)/test_result" ]] && echo yes || echo no)"
check "noresult: stdout is still kept" "yes" \
    "$([[ -s "$(report_of job_one)/runner_stdout.log" ]] && echo yes || echo no)"
check "noresult: both devices are still torn down" "2" "$(deletes)"

section "the old code really did abort (regression proof)"

# Put the pre-fix line back in the sandbox copy only, and show the difference.
# If the implementation is reworked this patch stops applying, and the block
# below skips rather than reporting a phantom failure.
if python3 - "$RUNNER" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()
fixed = """                ATEST_LOG_DIR=$(grep 'Test logs:' "$ATEST_LOG_FILE" \\
                    | awk '{print $3}' | sed 's|/log$||' | head -n 1) || true"""
broken = """                ATEST_LOG_DIR=$(grep 'Test logs:' "$ATEST_LOG_FILE" | awk '{print $3}' | sed 's|/log$||' | head -n 1)"""
if fixed not in src:
    sys.exit(1)
open(path, "w").write(src.replace(fixed, broken))
PY
then
    run_matrix "$CONFIG" env TEST_STUB_MODE=nologline
    check "old code: the run is aborted before the summary" "no" "$(reached_summary)"
    check "old code: job two never runs" "no" "$(log_has 'Job Two')"
    check "old code: the device is left running" "0" "$(deletes)"
else
    skip_test "old code: the pre-fix behaviour is reproduced" \
        "the guarded line has changed; update this test"
fi

section "the old code really did lose an agent run's results (regression proof)"

# The same idea for the second lookup: take it back out of a fresh sandbox
# copy, and skip if the line is no longer there to be taken out.
cp "${RUNNER_DIR}/mixed_build_test_runner.sh" "$RUNNER"
chmod +x "$RUNNER"
if python3 - "$RUNNER" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()
fixed = """                if [[ ! -d "$ATEST_LOG_DIR" ]]; then"""
broken = """                if false; then"""
if src.count(fixed) != 1:
    sys.exit(1)
open(path, "w").write(src.replace(fixed, broken))
PY
then
    run_matrix "$CONFIG" env TEST_STUB_MODE=agent
    check "old code: the agent run itself still passes" "yes" \
        "$(log_has 'TOTAL SUCCESS: 2')"
    check "old code: its results never reach the report" "no" "$(has_results job_one)"
    check "old code: all that is left is the warning" "yes" \
        "$(log_has 'Could not extract ATest log directory')"
else
    skip_test "old code: an agent run loses its results" \
        "the second lookup has changed; update this test"
fi

if (( TESTS_FAIL > 0 )); then
    echo "--- last run log ---"
    tail -n 40 "${SANDBOX}/state/run.log"
fi

finish_tests
