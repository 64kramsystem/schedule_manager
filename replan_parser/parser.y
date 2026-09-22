class ReplanParser
rule
  expression
    : REPLAN WHITESPACE definition
    ;

  definition
    : once_options WHITESPACE once_next
    | options_optional period_and_next
    ;

  once_options
    : option_once
    | shared_options option_once
    | once_options once_option
    ;

  shared_options
    : once_option
    | shared_options once_option
    ;

  once_option
    : CARRY                        { checked_assign(:v_carry, val.fetch(0)) }
    | CARRY_PARENT                 { checked_assign(:v_carry_parent, val.fetch(0)) }
    | TOP                          { checked_assign(:v_top, val.fetch(0)) }
    | TIME_BLOCK                   { assign_time_block(val.fetch(0)) }
    ;

  options_optional
    : | options WHITESPACE
    ;

  options
    : shared_options
    | recurring_options
    | shared_options recurring_options
    ;

  recurring_options
    : recurring_option
    | recurring_options option
    ;

  option
    : recurring_option
    | once_option
    ;

  recurring_option
    : F                            { checked_assign(:v_f, val.fetch(0)) }
    | F TIME                       { checked_assign(:v_f, val.fetch(0)); checked_assign(:v_f_time, val.fetch(1)) }
    | S                            { checked_assign(:v_s, val.fetch(0)) }
    | U_LOW                        { checked_assign(:v_ul, val.fetch(0)) }
    | U_UP                         { checked_assign(:v_uu, val.fetch(0)) }
    ;

  option_once
    : ONCE                         { checked_assign(:v_o, val.fetch(0)) }
    ;

  period_and_next
    : INTERVAL                     { self.v_interval = val.fetch(0) }
    | INTERVAL WHITESPACE next     { self.v_interval = val.fetch(0) }
    | DAY                          { self.v_interval = val.fetch(0) }
    | DAY WHITESPACE next          { self.v_interval = val.fetch(0) }
    | LAST_DAY                     { self.v_interval = val.fetch(0) }
    | LAST_DAYNUM                  { self.v_interval = val.fetch(0) }
    | FIRST_DAY                    { self.v_interval = val.fetch(0) }
    ;

  once_next
    : DAY                          { self.v_next = val.fetch(0) }
    | next
    ;

  next
    : IN WHITESPACE INTERVAL       { self.v_next_prefix = val.fetch(0); self.v_next = val.fetch(2) }
    | ON WHITESPACE DAY            { self.v_next_prefix = val.fetch(0); self.v_next = val.fetch(2) }
    | ON WHITESPACE MONTH_DAY      { self.v_next_prefix = val.fetch(0); self.v_next = val.fetch(2) }
    ;
end

---- header
  require 'ostruct'

  require_relative 'replan_lexer'

---- inner
  attr_accessor :v_f, :v_f_time, :v_s, :v_ul, :v_uu, :v_o, :v_carry, :v_top,
    :v_time_block, :v_interval, :v_next_prefix, :v_next, :v_carry_parent

  def parse(input)
    scan_str(input)

    OpenStruct.new(
      fixed:       self.v_f,
      fixed_time:  self.v_f_time,
      skip:        self.v_s,
      update:      self.v_ul,
      update_full: self.v_uu,
      once:        self.v_o,
      carry:       self.v_carry,
      carry_parent: self.v_carry_parent,
      top:         self.v_top,
      time_block:  self.v_time_block,
      interval:    self.v_interval,
      next_prefix: self.v_next_prefix,
      next:        self.v_next,
    )
  end

  private

  # Assign to self.<var>, checking that it's not already assigned.
  #
  def checked_assign(var, value)
    self.send(var).nil? ?
      self.send("#{var}=", value) :
      raise("Option '#{var}' is already assigned: #{self.send(var)}")
  end

  def assign_time_block(value)
    self.v_time_block.nil? ?
      self.v_time_block = value :
      raise("A time-block flag is already assigned: #{self.v_time_block}")
  end
