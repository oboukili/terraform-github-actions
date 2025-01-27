#!/bin/bash

# shellcheck source=../actions.sh
source /usr/local/actions.sh

debug
setup

# You can't properly validate without initializing.
# You can't initialize without having valid terraform.
# How do you get a full validation report? You can't.

init || true

if ! (cd "$INPUT_PATH" && terraform validate -json | convert_validate_report "$INPUT_PATH"); then
    (cd "$INPUT_PATH" && terraform validate)
else
    echo -e "\033[1;32mSuccess!\033[0m The configuration is valid"
fi
