#!/bin/bash
# ---
# name: reveal_in_finder
# runtime: shell
# description: Open Finder revealing the given absolute file path.
# author: seed
# params:
#   - name: path
#     type: abs_path
#     required: true
# ---
set -eu
open -R "$ALI_ARG_PATH"
