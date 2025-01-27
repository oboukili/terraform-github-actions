#!/bin/bash

set -euo pipefail

# shellcheck source=../workflow_commands.sh
source /usr/local/workflow_commands.sh

function debug() {
    debug_cmd ls -la /root
    debug_cmd pwd
    debug_cmd ls -la
    debug_cmd ls -la "$HOME"
    debug_cmd printenv
    debug_file "$GITHUB_EVENT_PATH"
    echo
}

function detect-terraform-version() {
    local TF_SWITCH_OUTPUT

    debug_cmd tfswitch --version

    TF_SWITCH_OUTPUT=$(cd "$INPUT_PATH" && echo "" | tfswitch | grep -e Switched -e Reading | sed 's/^.*Switched/Switched/')
    if echo "$TF_SWITCH_OUTPUT" | grep Reading >/dev/null; then
        echo "$TF_SWITCH_OUTPUT"
    else
        echo "Reading latest terraform version"
        tfswitch "$(latest_terraform_version)"
    fi

    debug_cmd ls -la "$(which terraform)"

    local TF_VERSION
    TF_VERSION=$(terraform version -json | jq -r '.terraform_version' 2>/dev/null || terraform version | grep 'Terraform v' | sed 's/Terraform v//')

    TERRAFORM_VER_MAJOR=$(echo "$TF_VERSION" | cut -d. -f1)
    TERRAFORM_VER_MINOR=$(echo "$TF_VERSION" | cut -d. -f2)
    TERRAFORM_VER_PATCH=$(echo "$TF_VERSION" | cut -d. -f3)

    debug_log "Terraform version major $TERRAFORM_VER_MAJOR minor $TERRAFORM_VER_MINOR patch $TERRAFORM_VER_PATCH"
}

function job_markdown_ref() {
    echo "[${GITHUB_WORKFLOW} #${GITHUB_RUN_NUMBER}](${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID})"
}

function detect-tfmask() {
    TFMASK="tfmask"
    if ! hash tfmask 2>/dev/null; then
        TFMASK="cat"
    fi

    export TFMASK
}

function execute_run_commands() {
    if [[ -v TERRAFORM_PRE_RUN ]]; then
        start_group "Executing TERRAFORM_PRE_RUN"

        echo "Executing init commands specified in 'TERRAFORM_PRE_RUN' environment variable"
        printf "%s" "$TERRAFORM_PRE_RUN" >"$STEP_TMP_DIR/TERRAFORM_PRE_RUN.sh"
        disable_workflow_commands
        bash -xeo pipefail "$STEP_TMP_DIR/TERRAFORM_PRE_RUN.sh"
        enable_workflow_commands

        end_group
    fi
}

function setup() {
    if [[ "$INPUT_PATH" == "" ]]; then
        error_log "input 'path' not set"
        exit 1
    fi

    if [[ ! -d "$INPUT_PATH" ]]; then
        error_log "Path does not exist: \"$INPUT_PATH\""
        exit 1
    fi

    local TERRAFORM_BIN_DIR
    TERRAFORM_BIN_DIR="$JOB_TMP_DIR/terraform-bin-dir"
    # tfswitch guesses the wrong home directory...
    start_group "Installing Terraform"
    if [[ ! -d $TERRAFORM_BIN_DIR ]]; then
        debug_log "Initializing tfswitch with image default version"
        mkdir -p "$TERRAFORM_BIN_DIR"
        cp --recursive /root/.terraform.versions.default "$TERRAFORM_BIN_DIR"
    fi

    ln -s "$TERRAFORM_BIN_DIR" /root/.terraform.versions

    debug_cmd ls -lad /root/.terraform.versions
    debug_cmd ls -lad "$TERRAFORM_BIN_DIR"
    debug_cmd ls -la "$TERRAFORM_BIN_DIR"

    export TF_DATA_DIR="$STEP_TMP_DIR/terraform-data-dir"
    export TF_PLUGIN_CACHE_DIR="$HOME/.terraform.d/plugin-cache"
    mkdir -p "$TF_DATA_DIR" "$TF_PLUGIN_CACHE_DIR"

    unset TF_WORKSPACE

    detect-terraform-version

    debug_cmd ls -la "$TERRAFORM_BIN_DIR"
    end_group

    detect-tfmask

    execute_run_commands
}

function relative_to() {
    local absbase
    local relpath

    absbase="$1"
    relpath="$2"
    realpath --no-symlinks --canonicalize-missing --relative-to="$absbase" "$relpath"
}

function init() {
    start_group "Initializing Terraform"

    write_credentials

    rm -rf "$TF_DATA_DIR"
    (cd "$INPUT_PATH" && terraform init -input=false -backend=false)

    end_group
}

function init-backend() {
    start_group "Initializing Terraform"

    write_credentials

    INIT_ARGS=""

    if [[ -n "$INPUT_BACKEND_CONFIG_FILE" ]]; then
        for file in $(echo "$INPUT_BACKEND_CONFIG_FILE" | tr ',' '\n'); do
            INIT_ARGS="$INIT_ARGS -backend-config=$(relative_to "$INPUT_PATH" "$file")"
        done
    fi

    if [[ -n "$INPUT_BACKEND_CONFIG" ]]; then
        for config in $(echo "$INPUT_BACKEND_CONFIG" | tr ',' '\n'); do
            INIT_ARGS="$INIT_ARGS -backend-config=$config"
        done
    fi

    export INIT_ARGS

    rm -rf "$TF_DATA_DIR"

    set +e
    # shellcheck disable=SC2086
    (cd "$INPUT_PATH" && TF_WORKSPACE=$INPUT_WORKSPACE terraform init -input=false $INIT_ARGS \
        2>"$STEP_TMP_DIR/terraform_init.stderr")

    local INIT_EXIT=$?
    set -e

    if [[ $INIT_EXIT -eq 0 ]]; then
        cat "$STEP_TMP_DIR/terraform_init.stderr" >&2
    else
        if grep -q "No existing workspaces." "$STEP_TMP_DIR/terraform_init.stderr" || grep -q "Failed to select workspace" "$STEP_TMP_DIR/terraform_init.stderr"; then
            # Couldn't select workspace, but we don't really care.
            # select-workspace will give a better error if the workspace is required to exist
            :
        else
            cat "$STEP_TMP_DIR/terraform_init.stderr" >&2
            exit $INIT_EXIT
        fi
    fi

    end_group
}

function select-workspace() {
    (cd "$INPUT_PATH" && terraform workspace select "$INPUT_WORKSPACE") >"$STEP_TMP_DIR/workspace_select" 2>&1

    if [[ -s "$STEP_TMP_DIR/workspace_select" ]]; then
        start_group "Selecting workspace"
        cat "$STEP_TMP_DIR/workspace_select"
        end_group
    fi
}

function set-plan-args() {
    PLAN_ARGS=""

    if [[ "$INPUT_PARALLELISM" -ne 0 ]]; then
        PLAN_ARGS="$PLAN_ARGS -parallelism=$INPUT_PARALLELISM"
    fi

    if [[ -n "$INPUT_VAR" ]]; then
        for var in $(echo "$INPUT_VAR" | tr ',' '\n'); do
            PLAN_ARGS="$PLAN_ARGS -var $var"
        done
    fi

    if [[ -n "$INPUT_VAR_FILE" ]]; then
        for file in $(echo "$INPUT_VAR_FILE" | tr ',' '\n'); do
            PLAN_ARGS="$PLAN_ARGS -var-file=$(relative_to "$INPUT_PATH" "$file")"
        done
    fi

    if [[ -n "$INPUT_VARIABLES" ]]; then
        echo "$INPUT_VARIABLES" >"$STEP_TMP_DIR/variables.tfvars"
        PLAN_ARGS="$PLAN_ARGS -var-file=$STEP_TMP_DIR/variables.tfvars"
    fi

    export PLAN_ARGS
}

function set-remote-plan-args() {
    PLAN_ARGS=""

    if [[ "$INPUT_PARALLELISM" -ne 0 ]]; then
        PLAN_ARGS="$PLAN_ARGS -parallelism=$INPUT_PARALLELISM"
    fi

    local AUTO_TFVARS_COUNTER=0

    if [[ -n "$INPUT_VAR_FILE" ]]; then
        for file in $(echo "$INPUT_VAR_FILE" | tr ',' '\n'); do
            cp "$file" "$INPUT_PATH/zzzz-dflook-terraform-github-actions-$AUTO_TFVARS_COUNTER.auto.tfvars"
            AUTO_TFVARS_COUNTER=$(( AUTO_TFVARS_COUNTER + 1 ))
        done
    fi

    if [[ -n "$INPUT_VARIABLES" ]]; then
        echo "$INPUT_VARIABLES" >"$STEP_TMP_DIR/variables.tfvars"
        cp "$STEP_TMP_DIR/variables.tfvars" "$INPUT_PATH/zzzz-dflook-terraform-github-actions-$AUTO_TFVARS_COUNTER.auto.tfvars"
    fi

    debug_cmd ls -la "$INPUT_PATH"

    export PLAN_ARGS
}

function output() {
    (cd "$INPUT_PATH" && terraform output -json | convert_output)
}

function update_status() {
    local status="$1"

    if ! STATUS="$status" github_pr_comment status 2>"$STEP_TMP_DIR/github_pr_comment.stderr"; then
        debug_file "$STEP_TMP_DIR/github_pr_comment.stderr"
    fi
}

function random_string() {
    python3 -c "import random; import string; print(''.join(random.choice(string.ascii_lowercase) for i in range(8)))"
}

function write_credentials() {
    format_tf_credentials >>"$HOME/.terraformrc"
    netrc-credential-actions >>"$HOME/.netrc"

    chmod 700 /.ssh
    if [[ -v TERRAFORM_SSH_KEY ]]; then
      echo "$TERRAFORM_SSH_KEY" >>/.ssh/id_rsa
      chmod 600 /.ssh/id_rsa
    fi

    debug_cmd git config --list
}

function plan() {

    local PLAN_OUT_ARG
    if [[ -n "$PLAN_OUT" ]]; then
        PLAN_OUT_ARG="-out=$PLAN_OUT"
    else
        PLAN_OUT_ARG=""
    fi

    set +e
    # shellcheck disable=SC2086
    (cd "$INPUT_PATH" && terraform plan -input=false -no-color -detailed-exitcode -lock-timeout=300s $PLAN_OUT_ARG $PLAN_ARGS) \
        2>"$STEP_TMP_DIR/terraform_plan.stderr" \
        | $TFMASK \
        | tee /dev/fd/3 \
        | compact_plan \
            >"$STEP_TMP_DIR/plan.txt"

    PLAN_EXIT=${PIPESTATUS[0]}
    set -e
}

# Every file written to disk should use one of these directories
readonly STEP_TMP_DIR="/tmp"
readonly JOB_TMP_DIR="$HOME/.dflook-terraform-github-actions"
readonly WORKSPACE_TMP_DIR=".dflook-terraform-github-actions/$(random_string)"
