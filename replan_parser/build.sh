#!/bin/bash

set -o pipefail
set -o errexit
set -o nounset
set -o errtrace
shopt -s inherit_errexit

rex lexer.rex -o "$(dirname "$0")"/../replan.lib/replan_lexer.rb
racc parser.y -o "$(dirname "$0")"/../replan.lib/replan_parser.rb

ruby -r "$(dirname "$0")"/../replan.lib/replan_parser.rb <<'RUBY'
  examples = [
    "replan 2.5w",
    "replan fsu 2w",
    "replan U 2w",
    "replan f18:33su 2w",
    "replan s sun",
    "replan sun",
    "replan mon+",
    # For simplicity, the parser currently support `sun sun`, and cases of `sun in N` where (Today+N)
    # is not `sun`; they are not realworld, but they're consistent, so they're not worth excluding.
    # The case `sun in N` is kept undocumented.
    "replan sun sun+",
    "replan -mon",
    "replan -2mon",
    "replan -11",
    "replan +mon",
    "replan +2mon",
    "replan 2w in 3d",
    "replan 2w dec/31",
    "replan fsu 2w in 3d",
    "replan o in 3d",
    "replan o wed+",
  ]

  examples.each do |example|
    puts "#{example}:"
    puts
    pp ReplanParser.new.parse(example).to_h
    puts
  end
RUBY
