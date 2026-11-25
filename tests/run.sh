#!/usr/bin/env bash
set -eu

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BASH_BIN=$(command -v bash)
SUITE_TMP=$(mktemp -d)
trap 'rm -rf -- "$SUITE_TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

assert_status() {
    [[ $status == "$1" ]] || fail "expected status $1, got $status: $(cat "$case_dir/stderr")"
}

assert_args() {
    local arg
    local actual=()
    while IFS= read -r -d '' arg; do actual+=("$arg"); done < "$ARGS_FILE"
    [[ ${#actual[@]} -eq $# ]] || fail "argument count: expected $#, got ${#actual[@]}"
    for arg in "${actual[@]}"; do
        [[ $arg == "$1" ]] || fail "expected argument <$1>, got <$arg>"
        shift
    done
}

run_devr() {
    status=0
    PATH="$test_bin" "$entry" "$@" < /dev/null > "$case_dir/stdout" 2> "$case_dir/stderr" || status=$?
}

setup() {
    case_dir=$(mktemp -d "$SUITE_TMP/case.XXXXXX")
    test_bin="$case_dir/bin"
    mkdir -p "$test_bin" "$case_dir/project"
    ln -s "$BASH_BIN" "$test_bin/bash"
    ln -s "$ROOT/tests/fixtures/docker" "$test_bin/docker"
    ln -s "$ROOT/tests/fixtures/node-tool" "$test_bin/yarn"
    ln -s "$ROOT/tests/fixtures/node-tool" "$test_bin/npm"
    export ARGS_FILE="$case_dir/args" TRACE_FILE="$case_dir/trace"
    export HOST_USER_FILE="$case_dir/host-user"
    export NODE_DIR_FILE="$case_dir/node-dir" NODE_ARGS_FILE="$case_dir/node-args"
    export USER=test-host-user
    unset PHP_SERVICE NODE_SERVICE CONTAINER_USER SHELL_DEFAULT_SERVICE SHELL_EXECUTABLE
    unset COMPOSE_VERSION_STATUS PS_STATUS SERVICE_RUNNING TOOL_STATUS RUN_CONTAINER CONTAINER_WORKDIR
    unset CONTAINER_BIN_ROOT SHELL_CHOICE_FILE SHELL_STATUS
    entry="$ROOT/devr"
    cd "$case_dir/project"
    : > .devrrc # Stop discovery before reaching the host's parent directories.
}

test_help() {
    rm "$test_bin/docker"
    printf 'printf loaded > "%s"\nfalse\n' "$case_dir/config-loaded" > .devrrc
    local option
    for option in '' -h --help; do
        if [[ -z $option ]]; then run_devr; else run_devr "$option"; fi
        assert_status 0
        [[ $(< "$case_dir/stdout") == *'Usage: devr'* ]] || fail 'missing help'
        [[ ! -e $case_dir/config-loaded ]] || fail 'help loaded configuration'
    done
}

test_sourcing() {
    # Inspect shell state inside the child Bash process.
    # shellcheck disable=SC2016
    "$BASH_BIN" -c '
        set +e
        before=$-
        options=$(set +o)
        # shellcheck source=/dev/null
        if source "$1"; then exit 99; fi
        [[ $- == "$before" && $(set +o) == "$options" ]] || exit 98
        printf "%s\n" survived
    ' bash "$entry" > "$case_dir/stdout" 2> "$case_dir/stderr"
    [[ $(< "$case_dir/stdout") == survived ]] || fail 'sourcing affected caller'
    [[ $(< "$case_dir/stderr") == *'must be executed'* ]] || fail 'missing sourcing diagnostic'
    [[ ! -e $TRACE_FILE ]] || fail 'sourcing invoked Docker'
}

test_routing() {
    local command
    for command in artisan composer php; do
        run_devr "$command"
        assert_status 0
        case "$command" in
            artisan) assert_args compose exec -u 1000 -T php php artisan ;;
            composer) assert_args compose exec -u 1000 -T php composer ;;
            php) assert_args compose exec -u 1000 -T php php ;;
        esac
        [[ $(< "$HOST_USER_FILE") == test-host-user ]] || fail 'USER overwritten'
    done
    run_devr up --build php
    assert_status 0
    assert_args compose up -d --build php
    run_devr php --help
    assert_status 0
    assert_args compose exec -u 1000 -T php php --help
}

# Shell syntax is intentionally passed as literal tool arguments.
# shellcheck disable=SC2016
test_arguments() {
    run_devr artisan 'argument with spaces' '' '$(touch should-not-exist)' '*' 'a;b'
    assert_status 0
    assert_args compose exec -u 1000 -T php php artisan 'argument with spaces' '' '$(touch should-not-exist)' '*' 'a;b'
    [[ ! -e should-not-exist ]] || fail 'argument executed as shell code'
}

test_symlink() {
    ln -s "$entry" "$test_bin/devr"
    entry="$test_bin/devr"
    run_devr php -v
    assert_status 0
    assert_args compose exec -u 1000 -T php php -v
}

test_config() {
    printf '%s\n' 'PHP_SERVICE=api' 'NODE_SERVICE=assets' 'CONTAINER_USER=1234:1234' 'SHELL_DEFAULT_SERVICE=jobs' 'SHELL_EXECUTABLE=sh' > .devrrc
    run_devr php -v
    assert_status 0
    assert_args compose exec -u 1234:1234 -T api php -v
    run_devr shell
    assert_status 0
    assert_args compose exec -u 1234:1234 -T jobs sh
    run_devr shell assets
    assert_status 0
    assert_args compose exec -u 1234:1234 -T assets sh
    local tool
    for tool in yarn npm; do
        run_devr "$tool" install
        assert_status 0
        assert_args compose exec -u 1234:1234 -T assets "$tool" install
    done
}

test_environment() {
    printf '%s\n' 'PHP_SERVICE=api' 'NODE_SERVICE=assets' 'CONTAINER_USER=1234' 'SHELL_DEFAULT_SERVICE=jobs' 'SHELL_EXECUTABLE=sh' > .devrrc
    export PHP_SERVICE=worker NODE_SERVICE=frontend CONTAINER_USER=5678 SHELL_DEFAULT_SERVICE=queue SHELL_EXECUTABLE=/bin/sh
    run_devr php -v
    assert_status 0
    assert_args compose exec -u 5678 -T worker php -v
    run_devr shell
    assert_status 0
    assert_args compose exec -u 5678 -T queue /bin/sh
    run_devr shell frontend
    assert_status 0
    assert_args compose exec -u 5678 -T frontend /bin/sh
    local tool
    for tool in yarn npm; do
        run_devr "$tool" install
        assert_status 0
        assert_args compose exec -u 5678 -T frontend "$tool" install
    done
}

test_parent_config() {
    printf 'PHP_SERVICE=parent\n' > .devrrc
    mkdir -p child/deep sibling
    printf 'PHP_SERVICE=sibling\n' > sibling/.devrrc
    cd child/deep
    run_devr php -v
    assert_status 0
    assert_args compose exec -u 1000 -T parent php -v
    printf 'PHP_SERVICE=nearest\n' > ../.devrrc
    run_devr php -v
    assert_status 0
    assert_args compose exec -u 1000 -T nearest php -v
}

test_failed_config() {
    printf 'false\n' > .devrrc
    run_devr php -v
    assert_status 1
    [[ ! -e $TRACE_FILE ]] || fail 'Docker ran after config failure'
}

test_missing_service() {
    export SERVICE_RUNNING=0
    run_devr php -v
    assert_status 1
    [[ $(< "$case_dir/stderr") == *"Docker service 'php' is not running."* ]] || fail 'missing service diagnostic'
    assert_args compose ps -q php
}

test_compose_fallback() {
    ln -s "$ROOT/tests/fixtures/docker" "$test_bin/docker-compose"
    export COMPOSE_VERSION_STATUS=1
    run_devr php -v
    assert_status 0
    assert_args exec -u 1000 -T php php -v
    [[ $(< "$TRACE_FILE") == *docker-compose* ]] || fail 'standalone Compose not used'
    rm "$test_bin/docker"
    run_devr up
    assert_status 0
    assert_args up -d
}

test_missing_compose() {
    rm "$test_bin/docker"
    run_devr php -v
    assert_status 1
    [[ $(< "$case_dir/stderr") == *'Docker Compose is required.'* ]] || fail 'missing Compose diagnostic'
}

test_exit_codes() {
    export TOOL_STATUS=42
    run_devr php -v
    assert_status 42
    run_devr up
    assert_status 42
    export PS_STATUS=43
    run_devr php -v
    assert_status 43
}

# Shell syntax is intentionally passed as literal package manager arguments.
# shellcheck disable=SC2016
test_node_arguments() {
    export CONTAINER_WORKDIR="$case_dir/container frontend" RUN_CONTAINER=1
    mkdir "$CONTAINER_WORKDIR"
    local tool
    for tool in yarn npm; do
        run_devr "$tool" run 'task with spaces' '' '$(touch should-not-exist)' '*'
        assert_status 0
        assert_args compose exec -u 1000 -T node "$tool" run 'task with spaces' '' '$(touch should-not-exist)' '*'
        [[ $(< "$NODE_DIR_FILE") == "$CONTAINER_WORKDIR" ]] || fail "$tool did not use the container working directory"
        ARGS_FILE="$NODE_ARGS_FILE" assert_args run 'task with spaces' '' '$(touch should-not-exist)' '*'
        [[ ! -e "$CONTAINER_WORKDIR/should-not-exist" ]] || fail "$tool argument executed as shell code"
    done
    export TOOL_STATUS=44
    for tool in yarn npm; do
        run_devr "$tool" install
        assert_status 44
    done
}

test_shell_services() {
    export PHP_SERVICE=api CONTAINER_USER=1234 SHELL_EXECUTABLE=bash
    run_devr shell
    assert_status 0
    assert_args compose exec -u 1234 -T api bash
    run_devr shell node
    assert_status 0
    assert_args compose exec -u 1234 -T node bash
    run_devr shell worker
    assert_status 0
    assert_args compose exec -u 1234 -T worker bash
    rm "$TRACE_FILE"
    run_devr shell node extra
    assert_status 1
    [[ ! -e $TRACE_FILE ]] || fail 'invalid shell arguments invoked Docker'
    export SERVICE_RUNNING=0
    run_devr shell worker
    assert_status 1
    assert_args compose ps -q worker
    [[ $(< "$case_dir/stderr") == *"Docker service 'worker' is not running."* ]] || fail 'missing shell service diagnostic'
}

test_shell_detection() {
    export RUN_CONTAINER=1 CONTAINER_BIN_ROOT="$case_dir/containers"
    export SHELL_CHOICE_FILE="$case_dir/chosen-shell"
    mkdir -p "$CONTAINER_BIN_ROOT/php" "$CONTAINER_BIN_ROOT/node"
    ln -s "$ROOT/tests/fixtures/shell" "$CONTAINER_BIN_ROOT/php/sh"
    ln -s "$ROOT/tests/fixtures/shell" "$CONTAINER_BIN_ROOT/php/bash"
    ln -s "$ROOT/tests/fixtures/shell" "$CONTAINER_BIN_ROOT/node/sh"
    run_devr shell
    assert_status 0
    [[ $(< "$SHELL_CHOICE_FILE") == bash ]] || fail 'PHP service did not select Bash'
    run_devr shell node
    assert_status 0
    [[ $(< "$SHELL_CHOICE_FILE") == sh ]] || fail 'Node service did not fall back to sh'
    export SHELL_STATUS=42
    run_devr shell
    assert_status 42
    [[ $(< "$SHELL_CHOICE_FILE") == bash ]] || fail 'Bash failure incorrectly triggered fallback'
    unset SHELL_STATUS
    export SHELL_EXECUTABLE=sh
    run_devr shell
    assert_status 0
    [[ $(< "$SHELL_CHOICE_FILE") == sh ]] || fail 'explicit shell override ignored'
    export SHELL_EXECUTABLE=bash
    run_devr shell node
    assert_status 127
}

test_unknown_command() {
    run_devr unknown
    assert_status 1
    [[ $(< "$case_dir/stderr") == *'Unknown command: unknown'* ]] || fail 'missing unknown command diagnostic'
    [[ ! -e $TRACE_FILE ]] || fail 'unknown command invoked Docker'
}

count=0
for test in test_help test_sourcing test_routing test_arguments test_symlink \
    test_config test_environment test_parent_config test_failed_config \
    test_missing_service test_compose_fallback test_missing_compose \
    test_exit_codes test_node_arguments test_shell_services test_shell_detection test_unknown_command; do
    (setup; "$test")
    printf 'PASS: %s\n' "$test"
    count=$((count + 1))
done
printf '%s tests passed.\n' "$count"
