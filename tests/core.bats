#!/usr/bin/env bats
# tests/core.bats - lib/core.sh: credential encryption with a real passphrase.

load 'test_helper'

setup() {
    load_libs
}

@test "gpg: encrypt produces an armored PGP message" {
    export BULL_CREDENTIALS_PASSPHRASE="unit-test-pass"
    run _bull_encrypt "s3cr3t-value"
    [ "$status" -eq 0 ]
    [[ "$output" == *"BEGIN PGP MESSAGE"* ]]
}

@test "gpg: encrypt then decrypt round-trips the plaintext" {
    export BULL_CREDENTIALS_PASSPHRASE="unit-test-pass"
    local enc dec
    enc="$(_bull_encrypt "s3cr3t-value")"
    dec="$(_bull_decrypt "${enc}")"
    [ "${dec}" = "s3cr3t-value" ]
}

@test "gpg: decrypt fails with a wrong passphrase" {
    export BULL_CREDENTIALS_PASSPHRASE="right-pass"
    local enc
    enc="$(_bull_encrypt "s3cr3t-value")"
    export BULL_CREDENTIALS_PASSPHRASE="wrong-pass"
    run _bull_decrypt "${enc}"
    [ "$status" -ne 0 ]
}

@test "gpg: encrypt fails when no passphrase can be obtained" {
    unset BULL_CREDENTIALS_PASSPHRASE
    # stdin is not a TTY under bats, so there is no way to prompt.
    run _bull_encrypt "s3cr3t-value"
    [ "$status" -ne 0 ]
}
