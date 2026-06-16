load helper

@test "bare hgt prints usage, exit 0" {
  run "$HGT_BIN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage: hgt <command>"* ]]
}

@test "--help prints usage" {
  run "$HGT_BIN" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"commands:"* ]]
}

@test "--version prints a version" {
  run "$HGT_BIN" --version
  [ "$status" -eq 0 ]
  [[ "$output" == hgt\ * ]]
}

@test "unknown command errors non-zero" {
  run "$HGT_BIN" bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown command: bogus"* ]]
}

@test "issue is a non-zero Slice-1 placeholder" {
  run "$HGT_BIN" issue
  [ "$status" -ne 0 ]
  [[ "$output" == *"not implemented in Slice 1"* ]]
}

@test "work with no issue number errors non-zero" {
  run "$HGT_BIN" work
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing issue number"* ]]
}
