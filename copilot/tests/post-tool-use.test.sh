#!/usr/bin/env bash
# post-tool-use.sh — runs after a tool call. It must stay quiet for anything
# that is not a file edit, and must not block ordinary non-code edits.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

sid="copilot-selftest-post"
rm -rf "${STATE_HOME:?}/$sid"

expect_out "post-tool-use ignores non-file tools" post-tool-use.sh \
  "$(payload_tool $sid bash '{"command":"echo hi"}')" '. == {}'

expect_out "post-tool-use passes a non-code edit through the edit gate" post-tool-use.sh \
  "$(payload_tool $sid edit '{"path":"/tmp/does-not-exist-'"$sid"'/notes.md","old_str":"a","new_str":"b"}')" \
  '. == {}'

rm -rf "${STATE_HOME:?}/$sid"
summary
