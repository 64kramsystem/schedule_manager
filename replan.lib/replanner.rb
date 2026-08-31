require_relative 'replan_codec'
require_relative 'replan_helper'
require_relative 'shared_constants'

require 'date'
require 'English'

class Replanner
  include ReplanHelper
  include SharedConstants

  MOVED_REPLAN_CHILD_MARKER = "\0REPLAN_CHILD_MOVED"
  private_constant :MOVED_REPLAN_CHILD_MARKER

  INTERPOLATIONS = {
    %r<[a-z]{3}/\d{2}> => ->(_, curr_date, _, skip) { curr_date.strftime('%a/%d').downcase unless skip}, # "mon/19"
    /(-\d+)/ => ->(match, curr_date, plan_date, skip) do # "-3"
      # Accumulate when skipping; reset otherwise.
      (skip ? match[1].to_i : 0) - (plan_date - curr_date).to_i
    end,
  }

  TIME_BLOCK_BRACKETS = {
    'M' => 0,
    'N' => 1,
    'A' => 2,
    'E' => 3,
  }.freeze
  private_constant :TIME_BLOCK_BRACKETS

  def initialize
    @replan_codec = ReplanCodec.new
  end

  def execute(content, debug: false, skips_only: false)
    dates = find_all_dates(content)

    # Validate the whole schedule before an update can prompt the user. Full updates are checked
    # again below because their new text can introduce a skip/once flag.
    #
    dates.each_with_index do |date, date_i|
      replan_lines = find_replan_lines(find_date_section(content, date))
      verify_no_children_on_moved_events(replan_lines)
      replan_children_to_move(replan_lines, reject_unskipped: date_i.zero?)
    end

    prepended_replan_line_counts = Hash.new(0)
    prepended_root_replan_line_counts = Hash.new(0)

    dates.each_with_index do |current_date, date_i|
      appended_replan_line_counts = Hash.new(0)
      appended_root_replan_line_counts = Hash.new(0)
      current_prepended_replan_line_counts = Hash.new(0)
      current_prepended_root_replan_line_counts = Hash.new(0)
      current_prepended_day_qualifier_line_counts = Hash.new(0)
      current_date_section = find_date_section(content, current_date)

      current_line_edits = {}

      replan_lines = find_replan_lines(
        current_date_section,
        ignored_line_marker: MOVED_REPLAN_CHILD_MARKER,
      )
      replan_child_line_is_by_parent = replan_children_to_move(
        replan_lines,
        reject_unskipped: date_i.zero?,
      )
      moved_replan_child_line_is = replan_child_line_is_by_parent.values.flatten

      # Entries are processed in reverse. Repeated top insertions restore their original order; trailing
      # line counts do the same for entries appended to a bracket.
      #
      replan_lines.reverse.each do |replan_line, bracket_i, child_lines, replan_line_i, child_line_is, descendants, source_root_line|
        next if moved_replan_child_line_is.include?(replan_line_i)

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
          verify_no_children(planned_line, replan_data, child_lines)

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
        if replan_data.carry
          carried_child_lines = if replan_child_line_is_by_parent.key?(replan_line_i)
            parent_moved_replan_child_line_is = replan_child_line_is_by_parent.fetch(replan_line_i)
            descendants.map do |line, line_i|
              if parent_moved_replan_child_line_is.include?(line_i)
                line.sub(/\n\z/, "#{MOVED_REPLAN_CHILD_MARKER}\n")
              else
                line
              end
            end
          else
            child_lines
          end
          planned_line = append_children(planned_line, replan_line, carried_child_lines)
        end

        insertion_date = find_preceding_or_existing_date(content, planned_date)

        if insertion_date != planned_date
          content = add_new_date_section(content, insertion_date, planned_date)
        end

        destination_bracket_i = TIME_BLOCK_BRACKETS.fetch(replan_data.time_block, bracket_i)
        destination_key = [planned_date, destination_bracket_i]
        matching_root_line = if matching_root_in_block?(
          content,
          planned_date,
          destination_bracket_i,
          source_root_line,
        )
          source_root_line
        end
        destination_root_key = [planned_date, destination_bracket_i, matching_root_line]
        day_qualifier = !matching_root_line && destination_bracket_i.zero? && day_qualifier_line?(planned_line)
        # top_insertion_index has already advanced past qualifiers inserted earlier during this
        # source date. Subtract their lines to keep a fixed insertion point while iterating in reverse.
        #
        top_offset = if matching_root_line
          prepended_root_replan_line_counts[destination_root_key]
        elsif day_qualifier
          -current_prepended_day_qualifier_line_counts[destination_key]
        else
          prepended_replan_line_counts[destination_key]
        end
        trailing_lines = if matching_root_line
          appended_root_replan_line_counts[destination_root_key]
        else
          appended_replan_line_counts[destination_key]
        end
        content = add_line_to_date_section(
          content,
          planned_date,
          planned_line,
          destination_bracket_i,
          top: !replan_data.top.nil?,
          top_offset:,
          trailing_lines:,
          root_line: matching_root_line,
        )

        if matching_root_line
          if replan_data.top
            current_prepended_root_replan_line_counts[destination_root_key] += planned_line.lines.count
          else
            appended_root_replan_line_counts[destination_root_key] += planned_line.lines.count
          end
        elsif replan_data.top
          if day_qualifier
            current_prepended_day_qualifier_line_counts[destination_key] += planned_line.lines.count
          else
            current_prepended_replan_line_counts[destination_key] += planned_line.lines.count
          end
        else
          appended_replan_line_counts[destination_key] += planned_line.lines.count
        end

        edited_replan_line = if replan_data.skip || replan_data.once
          ''
        else
          remove_replan(updated_replan_line || replan_line)
        end

        current_line_edits[replan_line_i] = edited_replan_line
        # Skip/once occurrences leave the source date, so their carried children leave with them.
        if (replan_data.skip || replan_data.once) && replan_data.carry
          carried_child_line_is = if replan_child_line_is_by_parent.key?(replan_line_i)
            descendants.map(&:last)
          else
            child_line_is
          end
          carried_child_line_is.each { |child_line_i| current_line_edits[child_line_i] = '' }
        end

        if skips_only && !debug && replan_line != edited_replan_line
          puts "> Moving line: #{replan_line.strip}"
        end
      end

      current_prepended_replan_line_counts.each do |destination_key, count|
        prepended_replan_line_counts[destination_key] += count
      end
      current_prepended_root_replan_line_counts.each do |destination_root_key, count|
        prepended_root_replan_line_counts[destination_root_key] += count
      end

      edited_current_date_section = current_date_section.lines.each_with_index.map do |line, line_i|
        current_line_edits.fetch(line_i, line)
      end.join

      # No-op if no changes have been performed (see conditional before change block).
      #
      content = content.sub(current_date_section, edited_current_date_section)
    end

    content.gsub(MOVED_REPLAN_CHILD_MARKER, '')
  end

  private

  # Returns [[replan, bracket_i, child_lines, replan_line_i, child_line_is, descendants,
  # source_root_line], ...]. Child lines exclude nested replans, since they're normally replanned
  # independently (see #own_children).
  #
  def find_replan_lines(section, ignored_line_marker: nil)
    lines = section.lines
    bracket_i = 0
    bracket_start_i = 0

    lines.each_with_index.filter_map do |line, line_i|
      if line == TIME_BRACKETS_SEPARATOR
        bracket_i += 1
        bracket_start_i = line_i + 1
        next
      end

      next if ignored_line_marker && line.include?(ignored_line_marker)
      next unless @replan_codec.replan_line?(line)

      indentation = line[/\A */].length
      descendants = lines.each_with_index.drop(line_i + 1).take_while do |candidate, _|
        !candidate.strip.empty? && candidate[/\A */].length > indentation
      end
      child_lines_with_indices = own_children(descendants)
      parent_line = lines[bracket_start_i...line_i].reverse.find do |candidate|
        !candidate.strip.empty? && candidate[/\A */].length < indentation
      end
      source_root_line = parent_line&.match?(/\A\S/) ? parent_line : nil

      [
        line,
        bracket_i,
        child_lines_with_indices.map(&:first),
        line_i,
        child_lines_with_indices.map(&:last),
        descendants,
        source_root_line,
      ]
    end
  end

  def matching_root_in_block?(content, date, bracket_i, root_line)
    return false unless root_line

    date_section = find_date_section(content, date)
    bracket = date_section.split(TIME_BRACKETS_SEPARATOR)[bracket_i]
    bracket&.lines&.include?(root_line)
  end

  def verify_no_children_on_moved_events(replan_lines)
    replan_lines.each do |replan_line, _, child_lines|
      replan_data = @replan_codec.extract_replan_tokens(replan_line, allow_placeholder: true)
      verify_no_children(replan_line, replan_data, child_lines)
    end
  end

  def verify_no_children(replan_line, replan_data, child_lines)
    # child_lines excludes nested replans, which are scheduled independently.
    return unless child_lines.any? && (replan_data.skip || replan_data.once) && !replan_data.carry

    raise "Skip/once replan entry has children: #{replan_line.rstrip.inspect}"
  end

  def replan_children_to_move(replan_lines, reject_unskipped:)
    replan_lines_by_line_i = replan_lines.to_h { |replan_line| [replan_line.fetch(3), replan_line] }

    replan_lines.each_with_object({}) do |replan_line, result|
      line, _, _, line_i, _, descendants = replan_line
      replan_data = @replan_codec.extract_replan_tokens(line, allow_placeholder: true)
      next unless replan_data.carry

      replan_children = descendants.filter_map do |_, descendant_line_i|
        replan_lines_by_line_i[descendant_line_i]
      end
      next if replan_children.empty?

      if !replan_data.skip
        if reject_unskipped
          raise "Carry replan entry has replan children without `s`: #{line.strip.inspect}"
        end

        next
      end

      replan_children.each do |replan_child|
        child_line, _, _, _, _, child_descendants = replan_child
        if child_descendants.any?
          raise "Replan child has children: #{child_line.strip.inspect}"
        end
      end

      result[line_i] = replan_children.map { |replan_child| replan_child.fetch(3) }
    end
  end

  # Nested replan lines are normally events of their own, so they don't move with the parent.
  #
  def own_children(descendants)
    nested_replan_indentation = nil

    descendants.select do |line, _|
      indentation = line[/\A */].length

      if nested_replan_indentation && indentation <= nested_replan_indentation
        nested_replan_indentation = nil
      end

      if nested_replan_indentation
        false
      elsif @replan_codec.replan_line?(line)
        nested_replan_indentation = indentation
        false
      else
        true
      end
    end
  end

  def append_children(planned_line, replan_line, child_lines)
    return planned_line if child_lines.empty?

    parent_indentation = replan_line[/\A */]
    dedented_children = child_lines.map { |line| line.sub(/\A#{Regexp.escape(parent_indentation)}/, '') }
    "#{planned_line.rstrip}\n#{dedented_children.join}"
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
      when %r|^\w{3}/\d{1,2}$|, %r|^\d{1,2}/\w{3}$|
        # The current year is always assigned.
        #
        format = replan_value.match?(/^\d/) ? "%d/%b" : "%b/%d"
        next_date = Date.strptime(replan_value, format)

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
        if new_content
          new_line = line.gsub(/\{\{#{matcher}\}\}/, "\{\{#{new_content}\}\}")
          puts "> Interpolation: #{current_date.strftime("%b/%d")}:'#{line[/^ *\S (.+) \(replan/, 1]}' → #{planned_date.strftime("%b/%d")}:'#{new_line[/^ *\S (.+) \(replan/, 1]}'"
          line = new_line
        end
      end
    end

    line
  end

  def handle_time(line, replan_data)
    if replan_data.once
      line
    elsif replan_data.fixed
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
