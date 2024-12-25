require 'English'

require_relative 'input_helper'
require_relative 'replan_parser'

class ReplanCodec
  # Used only to match the presence of the replan; the content is parsed by the parser
  #
  # Also invalid replans are matched (without data), which are checked only on actualy replanning; this
  # allows to convenient store placeholder replans in the future.
  #
  # The keywords are checked in the decoding stage.
  #
  REPLAN_REGEX = /\((replan.*)\)/
  private_constant :REPLAN_REGEX

  def initialize(input_helper: InputHelper.new)
    @input_helper = input_helper
  end

  # Returns an Openstruct with fields:
  #
  # - fixed       : `f` (optional)
  # - fixed_time  : `HH:MM` (also sets :fixed; optional)
  # - skip        : `s` (optional)
  # - update      : `u` (optional)
  # - update_full : `U` (optional)
  # - interval    : interval format
  # - next        : interval format, `%a`, `%b/%d` (optional)
  #
  def extract_replan_tokens(line, allow_placeholder: false)
    replan_content = line[REPLAN_REGEX, 1] || raise("Trying to parse replan on a non-replan line")

    if allow_placeholder && replan_content == 'replan'
      OpenStruct.new
    else
      ReplanParser.new.parse(replan_content)
    end
  rescue
    $stderr.puts("Error on line #{line.inspect}")
    raise
  end

  def replan_line?(line)
    if line =~ REPLAN_REGEX
      # See REPLAN_REGEX comment.
      #
      true
    elsif line =~ /replan/
      # Make sure replans without parentheses (potential mistakes) are caught.
      #
      raise("Line with invalid `replan`: #{line}")
    else
      false
    end
  end

  def skipped_event?(line)
    !extract_replan_tokens(line, allow_placeholder: true).skip.nil?
  end

  def once_off_event?(line)
    !extract_replan_tokens(line, allow_placeholder: true).once.nil?
  end

  def remove_replan(line)
    # The regex doesn't include the preceding whitespace, so it must be removed separately.
    # This must not remove the trailing newline!
    #
    line.sub(REPLAN_REGEX, '').sub(/ +$/, '')
  end

  def update_line(line)
    # There's no "String#split_at"-like method in Ruby. There are lots of clever alternatives, but
    # they're not worth.
    #
    replan_i = line.index(REPLAN_REGEX)
    prefix, description, replan = line[...2], line[2...(replan_i - 1)], line[replan_i..].rstrip

    new_description = @input_helper.ask("Enter the new description:", prefill: description)

    "#{prefix}#{new_description} #{replan}"
  end

  def full_update_line(line)
    prefix, description = line[...2], line[2..].rstrip

    new_description = @input_helper.ask("Enter the new description:", prefill: description)

    "#{prefix}#{new_description}"
  end

  def rewrite_replan(line)
    # There's no "String#split_at"-like method in Ruby. There are lots of clever alternatives, but
    # they're not worth.
    #
    replan_i = line.index(REPLAN_REGEX)
    description, replan = line[0...replan_i], [replan_i..]

    replan_data = ReplanParser.new.parse($LAST_MATCH_INFO[1])

    if replan_data.once
      description
    else
      keywords = " #{replan_data.fixed}#{replan_data.fixed_time}#{replan_data.update}#{replan_data.update_full}".rstrip
      interval = " #{replan_data.interval}".rstrip

      # Special case.
      #
      if replan_data.update_full
        next_ = ""
        next_ += " #{replan_data.next_prefix}" if replan_data.next_prefix
        next_ += " #{replan_data.next}" if replan_data.next
      end

      # TODO: can just stick the replan_data back? it depends on whether skip can be present.
      #
      description + "(replan#{keywords}#{interval}#{next_})"
    end
  end
end # class ReplanCodec
