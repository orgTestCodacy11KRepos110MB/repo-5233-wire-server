#!/usr/bin/env bash
set -euo pipefail

NAMESPACE=${NAMESPACE:-test-integration}

echo "Running integration tests on wire-server"

CHART=wire-server
tests=(cargohold gundeck federator spar brig galley)

summary() {
    echo "==============="
    echo "=== summary ==="
    echo "==============="
    printf '%s\n' "${tests[@]}" | parallel echo "=== tail {}: ===" ';' tail -2 logs-{}

    for t in "${tests[@]}"; do
        x=$(cat "stat-$t")
        if ((x > 0)); then
            echo "$t-integration FAILED ❌. pfff..."
        else
            echo "$t-integration passed ✅."
        fi
    done
}

# Run tests in parallel using GNU parallel (see https://www.gnu.org/software/parallel/)
# The below commands are a little convoluted, but we wish to:
# - run integration tests. If they fail, keep track of this, but still go and get logs, so we see what failed
# - run all tests. Perhaps multiple flaky tests in multiple services exist, if so, we wish to see all problems
printf '%s\n' "${tests[@]}" | parallel echo "Running helm tests for {}..."
printf '%s\n' "${tests[@]}" | parallel -P 6 \
    helm test -n "${NAMESPACE}" "${NAMESPACE}-${CHART}" --timeout 900s --filter name="${NAMESPACE}-${CHART}-{}-integration" '> logs-{};' \
    echo '$? > stat-{};' \
    echo "==== Done testing {}. ====" '};' \
    kubectl -n "${NAMESPACE}" logs "${NAMESPACE}-${CHART}-{}-integration" '>> logs-{};'

summary

# in case any integration test suite failed, exit this script with an error.
exit_code=0
for t in "${tests[@]}"; do
    x=$(cat "stat-$t")
    if ((x > 0)); then
        exit_code=1
    fi
done

if ((exit_code > 0)); then
    echo "======================="
    echo "=== failed job logs ==="
    echo "======================="
    # in case a integration test suite failed, print relevant logs
    for t in "${tests[@]}"; do
        x=$(cat "stat-$t")
        if ((x > 0)); then
            echo "=== logs for failed $t-integration ==="
            cat "logs-$t"
        fi
    done
    summary
fi

if ((exit_code > 0)); then
    echo "Tests failed."
    exit 1
else
    echo "All integration tests passed ✅."
fi
