require_relative 'replan_codec'
require_relative 'replan_helper'
require_relative 'shared_constants'

require 'date'
require 'English'

class Replanner
  include ReplanHelper
  include SharedConstants

  INTERPOLATIONS = {
    'date' => ->(date) { date.strftime('%a/%d').downcase } # "mon/19"
  }

  def initialize
    @replan_codec = ReplanCodec.new
  end

  def execute(content, debug: false, skips_only: false)
    dates = find_all_dates(content)

    dates.each_with_index do |current_date, date_i|
      current_date_section = find_date_section(content, current_date)

      edited_current_date_section = current_date_section.dup

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

        planned_line = handle_time(planned_line, replan_data)
        planned_line = compose_planned_line(planned_line)
        planned_line = apply_interpolations(planned_line, current_date) unless replan_data.skip

        planned_date = decode_planned_date(replan_data, current_date, replan_line)

        insertion_date = find_preceding_or_existing_date(content, planned_date)

        if insertion_date != planned_date
          content = add_new_date_section(content, insertion_date, planned_date)
        end

        content = add_line_to_date_section(content, planned_date, planned_line, bracket_i)

        edited_replan_line = if replan_data.skip || replan_data.once
          ''
        else
          line_without_interpolations = strip_interpolations(updated_replan_line || replan_line)
          remove_replan(line_without_interpolations)
        end

        # No-op if the update didn't change the content
        #
        edited_current_date_section = edited_current_date_section.sub(replan_line, edited_replan_line)
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
        # This is (currently) valid for `interval` only
        # Assumes that the input is valid.

        weekday_int = Date.strptime($LAST_MATCH_INFO[2], '%a').wday
        weekday_factor = $LAST_MATCH_INFO[1]&.to_i || 1

        first_day_next_month = Date.new(current_date.year, current_date.month, 1) >> 1
        offset = (weekday_int - first_day_next_month.wday) % 7
        replanned_date = first_day_next_month + offset + (weekday_factor - 1) * 7

        replanned_date - current_date
      when /^-(\d+)$/
        # This is (currently) valid for `interval` only

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
      when /^-(\w{3})$/
        # This is (currently) valid for `interval` only

        # Fun algorithm: start with the next occurrence, then add one week on each cycle, until the
        # month changes. Once the month changes, the previous date was the last given weekday of the
        # month =)

        current_candidate = Date.strptime($LAST_MATCH_INFO[1], '%a')
        current_candidate += 7 if current_candidate == current_date

        while true
          following_candidate = current_candidate + 7

          if following_candidate.month != current_candidate.month
            break current_candidate - current_date
          end

          current_candidate = following_candidate
        end
      when /^(\w{3})(\+)?$/
        # This is (currently) valid for `next` only
        #
        # In this case, Timecop correctly handles Date.parse (see ReplanHelper#convert_header_to_date),
        # however, considering the project quality, it's safer to avoid it.
        #
        parsed_next = Date.strptime($LAST_MATCH_INFO[1], '%a')

        # When parsing weekdays, the date in the current week is always returned, which for Ruby starts
        # on Sunday, so we need to adjust.
        # A weekday that matches the current day results in the same weekday on the following week.
        #
        diff_with_current = parsed_next - current_date
        diff_with_current += 7 if diff_with_current <= 0
        diff_with_current += 7 if $LAST_MATCH_INFO[2]
        diff_with_current
      else
        raise "Invalid replan value: #{replan_value.inspect}; line: #{line.inspect}"
      end

    current_date + displacement
  end

  def remove_replan(line)
    @replan_codec.remove_replan(line)
  end

  def apply_interpolations(line, date)
    INTERPOLATIONS.inject(line) do |line, (token, replacement)|
      new_content = replacement[date]
      line.gsub(/(.*)\(.*?\)(\{\{#{token}\}\})/, "\\1(#{new_content})\\2")
    end
  end

  def strip_interpolations(line)
    INTERPOLATIONS.keys.inject(line) do |line, token|
      line.gsub(/\{\{#{token}\}\}/, '')
    end
  end

  def handle_time(line, replan_data)
    if replan_data.fixed
      if replan_data.fixed_time
        # Replace the time with the specified one.
        #
        line.sub(/(?<=^. )(\d{1,2}:\d{2}. )?/, "#{replan_data.fixed_time}. ")
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
