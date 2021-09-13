require 'English'

require_relative 'replan_helper'

# Compute the work for the current day, and add it to the next.
#
class Reworker
  include ReplanHelper

  LPIM_DAY_OFF = :off
  LPIM_HALF_DAY = :half

  # New line is inserted after this.
  #
  INSERTION_POINT_PATTERN = /^( +)(- RSS, email\n)/

  WORK_TASK_PATTERN = /^ *[-~]( \d+:\d+\.)? work (.+)/

  ADDED_TASK_TEMPLATE = "- lpimw -t ye '%s' %s\n"

  def execute(content, lpim_day:)
    current_date = find_first_date(content)
    current_date_section = find_date_section(content, current_date)

    work_times = extract_work_times(current_date_section)

    next_date = current_date + 1
    next_date_section = find_date_section(content, next_date)

    new_next_date_section = add_lpim_to_next_day(next_date_section, work_times, lpim_day: lpim_day)

    content.sub(next_date_section, new_next_date_section)
  end

  def extract_work_times(section)
    all_lines_with_work = section.lines.grep(/\bwork\b/)

    times = all_lines_with_work.map do |work_line|
      work_line_match = work_line.match(WORK_TASK_PATTERN)

      raise "Unexpected work line format: #{work_line.strip}" if work_line_match.nil?

      raw_time, raw_description = work_line_match[1, 2]

      # For the `raw_time` format, see WORK_TASK_PATTERN.
      #
      time = raw_time[1...-1] if raw_time

      case raw_description
      when /^-\d+:\d+( -\d+| -\d(\.\d)?+h)?$/
        time + $LAST_MATCH_INFO.to_s
      when /^(-\d+|-\d\.\d+h) (-\d+:\d+)$/
        time + $LAST_MATCH_INFO[2] + " " + $LAST_MATCH_INFO[1]
      when /^\d+(\.\d+)?h$/
        $LAST_MATCH_INFO.to_s
      when /^\d+$/
        $LAST_MATCH_INFO.to_s
      else
        raise "Unexpected work description found: #{raw_description.inspect}"
      end
    end

    times.join(', ')
  end

  def add_lpim_to_next_day(section, work_times, lpim_day:)
    raise "Found lpim in next day!" if section =~ /\blpimw\b/
    raise "Insertion point not found!" if section !~ INSERTION_POINT_PATTERN

    day_option = "--comment #{lpim_day}" if lpim_day

    section.sub(INSERTION_POINT_PATTERN) do |match|
      "#{$LAST_MATCH_INFO[0]}#{$LAST_MATCH_INFO[1]}" + ADDED_TASK_TEMPLATE % [work_times, day_option]
    end
  end
end
