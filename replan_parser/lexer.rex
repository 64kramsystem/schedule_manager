class ReplanParser
macro
  REPLAN     replan
  WHITESPACE \s+
  F          f
  S          s
  U          u
  TIME       \d{1,2}:\d\d
  INTERVAL   \d+(\.\d+)?[dwmy]?
  IN         in

rule
  {REPLAN}     { [:REPLAN, text] }
  {WHITESPACE} { [:WHITESPACE, text] }
  {F}          { [:F, text] }
  {S}          { [:S, text] }
  {U}          { [:U, text] }
  {TIME}       { [:TIME, text] }
  {INTERVAL}   { [:INTERVAL, text] }
  {IN}         { [:IN, text] }

inner
  def tokenize(code)
    scan_setup(code)
    tokens = []
    while token = next_token
      tokens << token
    end
    tokens
  end
end
