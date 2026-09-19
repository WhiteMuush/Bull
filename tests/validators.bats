#!/usr/bin/env bats
# tests/validators.bats - lib/core.sh: input validation helpers.

load 'test_helper'

setup() {
    load_libs
}

@test "validate_vm_name: accepts a valid name" {
    run validate_vm_name "kali-01"
    [ "$status" -eq 0 ]
}

@test "validate_vm_name: rejects an empty name" {
    run validate_vm_name ""
    [ "$status" -ne 0 ]
}

@test "validate_vm_name: rejects a name not starting with a letter" {
    run validate_vm_name "1kali"
    [ "$status" -ne 0 ]
}

@test "validate_vm_name: rejects a name longer than 11 characters" {
    run validate_vm_name "abcdefghijkl"
    [ "$status" -ne 0 ]
}

@test "validate_vm_name: rejects shell metacharacters" {
    run validate_vm_name 'a;rm'
    [ "$status" -ne 0 ]
    run validate_vm_name 'a b'
    [ "$status" -ne 0 ]
}

@test "validate_positive_int: accepts a positive integer" {
    run validate_positive_int "4096" "ram"
    [ "$status" -eq 0 ]
}

@test "validate_positive_int: rejects zero" {
    run validate_positive_int "0" "cpu"
    [ "$status" -ne 0 ]
}

@test "validate_positive_int: rejects non-numeric input" {
    run validate_positive_int "2x" "cpu"
    [ "$status" -ne 0 ]
}

@test "require_argument: passes for a non-empty value" {
    run require_argument "value" "field"
    [ "$status" -eq 0 ]
}

@test "require_argument: fails for an empty value" {
    run require_argument "" "field"
    [ "$status" -ne 0 ]
}
