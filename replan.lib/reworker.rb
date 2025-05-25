require 'English'
require 'time'

require_relative 'replan_helper'

# Compute the work for the current day, and add it to the next.
#
class Reworker
  include ReplanHelper
  include SharedConstants

  LPIM_TEMPLATE = "#LPIM_INSERT\n"
  # The day reference approach is the simplest one to allow running this command on different days
  # (use case: re-run it on a separate system on a different day).
  #
  LPIM_GENERATOR = -> { (Date.today - 1).strftime "lpimw -t %F '%%s' # -c half|off # %a\n" }

  # Valid reduction/intervals:
  #
  # - 666, 66h, 66.66h
  # - -666, -66h, -66.66h
  #
  # That part of the regexp is for the lulz, and in order to easily understand it, after `-?\d+`, read
  # it from `h)?` backwards.
  #
  WORK_TASK_PATTERN = /^( *)\S( \d+:\d+\.)? work(?: \(.+\))?( -?\d+((\.\d+)?h)?)?$/

  # - (start_time, end_time, reduction) and (interval) are two mutually exclusive groups
  #
  # - end_time is set when the next entry is found
  # - reduction is optional
  #
  WorkEntry = Struct.new(:original_line, :indentation, :start_time, :end_time, :reduction, :interval) do
    def self.from(hash)
      hash.each_with_object(self.new) do |(key, value), entry|
        entry[key] = value
      end
    end

    def to_s
      if interval
        interval
      else
        "#{start_time}-#{end_time} #{reduction}".rstrip
      end
    end

    def inspect
      original_line.inspect
    end
  end

  # options:
  #
  # - :extract_only   only for testing; avoids having to add a subsequent day.
  #
  def initialize(extract_only: false)
    @extract_only = extract_only
  end

  # If :extract_only was enabled, the addition (to the next day) is not performed.
  #
  def execute(content)
    current_date = find_first_date(content)
    current_date_section = find_date_section(content, current_date)

    work_times = extract_work_times(current_date_section)

    return if @extract_only

    next_date = current_date + 1
    next_date_section = find_date_section(content, next_date)

    new_next_date_section = add_lpim_to_next_day(next_date_section, work_times)

    content.sub(next_date_section, new_next_date_section)
  end

  # Compute the hours of work for the first date (rounded to two decimals).
  #
  def compute_first_date_work_hours(content)
    current_date = find_first_date(content)
    current_date_section = find_date_section(content, current_date)

    work_times = extract_work_times(current_date_section)

    # `, ` splits into each work line; ` ` splits the work line in two intervals, if there is a
    # subtractive time.
    #
    time_intervals = work_times.split(/, | /)

    # The regular expressions could be further normalized, but they get ugly.
    #
    total = time_intervals.sum do |time_interval|
      case time_interval
      when /^(\d+:\d+)-(\d+:\d+)$/
        time_diff = (Time.parse($LAST_MATCH_INFO[2]) - Time.parse($LAST_MATCH_INFO[1])) / 3600
        time_diff += 24 if time_diff.negative? # end time later than midnight
        time_diff
      when /^-?\d+$/
        time_interval.to_f / 60
      when /^-?\d+(\.\d+)?h$/
        time_interval.chomp('h').to_f
      else
        raise "Unrecognized time interval: #{time_interval}"
      end
    end

    total.round(2)
  end

  private

  def extract_work_times(section)
    work_entries = []

    # Having the current entry simplifies the logic, rather than inspecting the last work_entries values
    # to understand if it's current or not.
    #
    current_work_entry = nil

    entries = section.rstrip.lines[1..] # skip header

    entries.each do |line|
      work_line_match = line.match(WORK_TASK_PATTERN)

      if work_line_match
        raise "Work entries can't follow each other! (previous: #{current_work_entry.inspect})" if current_work_entry

        indentation, start_time, interval_or_reduction = work_line_match[1..3]

        start_time = start_time&.lstrip&.chomp('.')
        interval_or_reduction = interval_or_reduction&.lstrip

        case interval_or_reduction
        when /^-/
          reduction = interval_or_reduction
        when //
          interval = interval_or_reduction
        end

        if interval
          # In this case, we don't need a closing entry.
          #
          work_entries << WorkEntry.from(
            original_line: line.strip,
            indentation:   indentation,
            interval:      interval
          )
        else
          current_work_entry = WorkEntry.from(
            original_line: line.strip,
            indentation:   indentation,
            start_time:    start_time,
            reduction:     reduction,
          )
        end
      else
        next if current_work_entry.nil? # skip lines precending the first work line
        next if line == TIME_BRACKETS_SEPARATOR

        indentation, start_time = line.match(/^( *)\S( \d+:\d+[\.-])?/)[1..]

        start_time = start_time&.lstrip&.chop

        work_entry_indentation = current_work_entry.indentation

        if indentation.size <= work_entry_indentation.size
          current_work_entry.end_time = start_time || raise("Subsequent entry has no time! (previous: #{current_work_entry.inspect})")
          work_entries << current_work_entry
          current_work_entry = nil
        end
        # Ignore deeper (lower) indented lines.
      end
    end

    raise "Missing closing entry for work entry #{current_work_entry.inspect}" if current_work_entry

    work_entries.join(', ')
  end

  def add_lpim_to_next_day(section, work_times)
    raise "Insertion point not found!" if !section.include?(LPIM_TEMPLATE)

    section.sub(LPIM_TEMPLATE, LPIM_GENERATOR[] % work_times)
  end
end
