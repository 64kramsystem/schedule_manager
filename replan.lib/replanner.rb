require_relative 'replan_codec'
require_relative 'replan_helper'
require_relative 'shared_constants'

require 'date'
require 'English'

class Replanner
  include ReplanHelper
  include SharedConstants

  INTERPOLATIONS = {
    %r<[a-z]{3}/\d{2}> => ->(_, curr_date, _, skip) { curr_date.strftime('%a/%d').downcase unless skip}, # "mon/19"
    /(-\d+)/ => ->(match, curr_date, plan_date, skip) do # "-3"
      # Accumulate when skipping; reset otherwise.
      (skip ? match[1].to_i : 0) - (plan_date - curr_date).to_i
    end,
  }

  CLEANUP_PATTERNS = [
    /^~\n/,
  ]

  def initialize
    @replan_codec = ReplanCodec.new
  end

  def execute(content, debug: false, skips_only: false)
    dates = find_all_dates(content)

    dates.each_with_index do |current_date, date_i|
      current_date_section = find_date_section(content, current_date)

      edited_current_date_section = current_date_section.dup

      CLEANUP_PATTERNS.each do |pattern|
        edited_current_date_section.gsub!(pattern, '')
      end

      replan_lines = find_replan_lines(current_date_section)

      # Since the replan entries are pushed to the top of the destination date, process them in reverse,
      # so that they will appear in the original order.
      #
      replan_lines.reverse.each do |replan_line, bracket_i|
        puts "> Processing replan line: #{replan_line.strip}" if debug

        event_on_current_date = !(@replan_codec.skipped_event?(replan_line) || @replan_codec.once_off_event?(replan_line))

        if event_on_current_date && (skips_only || date_i > 0)
          puts ">> Ignoring" if debug
          next
        end

        replan_data = decode_replan_data(replan_line)

        planned_line = lstrip_line(replan_line)

        # On full update, still prompt for update, because the user may want to change the day.
        #
        if replan_data.update && !replan_data.skip
          planned_line = update_line(planned_line)

          # This is the (updated or not) replan line; no further processing is applied, since that's for
          # the planned line.
          # We need to restore the newline, which is stripped by the update.
          #
          updated_replan_line = planned_line + "\n"
        elsif replan_data.update_full
          planned_line = full_update_line(planned_line)
          replan_data = decode_replan_data(planned_line)

          # See simple update case.
          #
          updated_replan_line = planned_line + "\n"
        end

        # There is no easy way to distinguish to identical replan lines, but fortunately, this case
        # is not realistic.
        #
        if updated_replan_line && content.scan(replan_line).count > 1
          raise "Unsupported: Multiple instances of the same update replan text: #{replan_line.rstrip.inspect}"
        end

        planned_date = decode_planned_date(replan_data, current_date, replan_line)

        planned_line = handle_time(planned_line, replan_data)
        planned_line = compose_planned_line(planned_line)
        planned_line = apply_interpolations(planned_line, current_date, planned_date, replan_data.skip)

        insertion_date = find_preceding_or_existing_date(content, planned_date)

        if insertion_date != planned_date
          content = add_new_date_section(content, insertion_date, planned_date)
        end

        content = add_line_to_date_section(content, planned_date, planned_line, bracket_i)

        edited_replan_line = if replan_data.skip || replan_data.once
          ''
        else
          remove_replan(updated_replan_line || replan_line)
        end

        # No-op if the update didn't change the content
        #
        edited_current_date_section = edited_current_date_section.sub(replan_line, edited_replan_line)

        if skips_only && !debug && replan_line != edited_replan_line
          puts "> Moving line: #{replan_line.strip}"
        end
      end

      # No-op if no changes have been performed (see conditional before change block).
      #
      content = content.sub(current_date_section, edited_current_date_section)
    end

    content
  end

  private

  # Returns [[replan, bracket_i], ...].
  #
  def find_replan_lines(section)
    brackets = section.split(TIME_BRACKETS_SEPARATOR)

    brackets.each_with_index.flat_map do |bracket, i|
      bracket
        .lines
        .select { |line| @replan_codec.replan_line?(line) }
        .map { |line| [line, i] }
    end
  end

  def lstrip_line(line)
    line.lstrip
  end

  def decode_replan_data(line)
    replan_data = @replan_codec.extract_replan_tokens(line)

    if replan_data.interval.nil? && replan_data.skip.nil? && replan_data.next.nil?
      raise "No period found (required by the options): #{line}"
    end

    replan_data
  end

  def update_line(line)
    @replan_codec.update_line(line)
  end

  def full_update_line(line)
    @replan_codec.full_update_line(line)
  end

  def decode_planned_date(replan_data, current_date, line)
    replan_value = replan_data.next || replan_data.interval

    # WATCH OUT!!! Don't use `Date.today` - use `current_date`, since when replanning, `Date.today` is
    # actually past.
    #
    displacement = case replan_value
      when /^\d+$/
        replan_value.to_i
      when /^\d+w$/
        7 * replan_value[0..-2].to_i
      when /^\d+(\.\d)?m$/
        30 * replan_value[0..-2].to_f
      when /^\d+(\.\d)?y$/
        365 * replan_value[0..-2].to_f
      when /^\+(\d)?(\w{3})$/
        weekday_int = Date.strptime($LAST_MATCH_INFO[2], '%a').wday
        weekday_factor = $LAST_MATCH_INFO[1]&.to_i || 1

        first_day_next_month = Date.new(current_date.year, current_date.month, 1) >> 1
        offset = (weekday_int - first_day_next_month.wday) % 7
        replanned_date = first_day_next_month + offset + (weekday_factor - 1) * 7

        replanned_date - current_date
      when /^-(\d+)$/
        first_day_next_month = Date.new(
          current_date.next_month.year,
          current_date.next_month.month,
          1
        )

        current_candidate = first_day_next_month - $LAST_MATCH_INFO[1].to_i

        if current_candidate > current_date
          current_candidate - current_date
        else
          first_day_next_month.next_month - $LAST_MATCH_INFO[1].to_i - current_date
        end
      when /^-(\d+)?(\w{3})$/
        weekday_int = Date.strptime($LAST_MATCH_INFO[2], '%a').wday
        weekday_factor = $LAST_MATCH_INFO[1]&.to_i || 1

        # Same algorithm as "First day of month" version, only difference being that it refers to the
        # last day of the current month instead of the first day of the next month.

        last_day_current_month = Date.new(current_date.year, current_date.month + 1, 1) - 1
        offset = (weekday_int - last_day_current_month.wday) % 7
        replanned_date = last_day_current_month + offset + (weekday_factor - 1) * 7

        replanned_date - current_date
      when /^(\w{3})(\+)?$/
        # strptime() finds the closest next weekday, starting from (can be chosen) `Date.today`.
        #---
        # In this case, Timecop correctly handles Date.parse (see ReplanHelper#convert_header_to_date),
        # however, considering the project quality, it's safer to avoid it.
        #
        next_weekday_occurrence = Date.strptime($LAST_MATCH_INFO[1], '%a')

        # Difference in days, between current_date  and the weekday corresponding to `next_weekday_occurrence`;
        # covers both cases where `next_weekday_occurrence`` is greater or less than `current_date``
        #
        displacement = (next_weekday_occurrence - current_date) % 7

        # If they were same, we need to correct, though.
        #
        displacement += 7 if displacement == 0

        displacement += 7 if $LAST_MATCH_INFO[2]

        displacement
      when %r|^(\w{3}/\d{1,2})$|
        # The current year is always assigned.
        #
        next_date = Date.strptime($LAST_MATCH_INFO[0], "%b/%d")

        next_date >>= 12 if next_date < current_date

        next_date - current_date
      else
        raise "Invalid replan value: #{replan_value.inspect}; line: #{line.inspect}"
      end

    current_date + displacement
  end

  def remove_replan(line)
    @replan_codec.remove_replan(line)
  end

  def apply_interpolations(line, current_date, planned_date, skip)
    INTERPOLATIONS.each do |matcher, replacement|
      if line =~ /\{\{#{matcher}\}\}/
        new_content = replacement[Regexp.last_match, current_date, planned_date, skip]
        line = line.gsub(/\{\{#{matcher}\}\}/, "\{\{#{new_content}\}\}") if new_content
      end
    end

    line
  end

  def handle_time(line, replan_data)
    if replan_data.fixed
      if replan_data.fixed_time
        # Replace the time with the specified one.
        #
        line.sub(/(?<=^. )(\d{1,2}:\d{2}(-\d{1,2}:\d{2})?\. )?/, "#{replan_data.fixed_time}. ")
      elsif line.start_with?(/. \d{1,2}:\d{2}\b/)
        line
      else
        raise "Fixed timestamp is set, but no timestamp is provided: #{line.rstrip.inspect}"
      end
    else
      # Remove the time.
      #
      line.sub(/(?<=^. )\d{1,2}:\d{2}. /, '')
    end
  end

  def compose_planned_line(line)
    @replan_codec.rewrite_replan(line)
  end
end
