require_relative "replan_helper"
require_relative "shared_constants"

# Fill the selected date (default: first date + 1) with the template.
#
class Retemplater
  include ReplanHelper
  include SharedConstants

  # template: String (filename) or IO (content).
  #
  def initialize(template)
    @template = template.respond_to?(:read) ? template.read : IO.read(template)
  end

  # TODO: This logic should be implemented by multiple invocations to ReplanHelper#add_line_to_date_section,
  # in order to use a single logic to add entries to a date (it's inefficient, but it doesn't matter).
  #
  def execute(content, date: find_first_date(content) + 1)
    # This avoids disasters when the user accidentally leaves a space, which confuses the program in
    # multiple ways.
    #
    verify_date_section_header_after(content, date)

    date_section = find_date_section(content, date)

    # A terminating blank line is considered part of a date section. For simplicity, we strip it.
    #
    date_time_brackets = date_section.chomp.split(/^#{TIME_BRACKETS_SEPARATOR}/, -1)
    date_time_brackets.pop if date_time_brackets.last.empty?

    missing_brackets = TIME_BRACKETS_COUNT - date_time_brackets.size
    date_time_brackets += [''] * missing_brackets
    date_brackets = date_time_brackets.map(&:lines)

    template_content = @template
      .gsub(/\$\{([a-z_]\w*)\}/i) { |placeholder| ENV.fetch(Regexp.last_match(1), placeholder) }
    template_time_brackets = template_content
      .split(/^#{TIME_BRACKETS_SEPARATOR}/, -1)
      .slice(0..-2)

    case template_time_brackets.size
    when 0
      template_lines = "#{template_content.chomp}\n".lines
      unmatched_lines = merge_matching_top_level_entries!(date_brackets, template_lines)
      unmatched = unmatched_lines.find { |line| !line.strip.empty? }
      raise "No matching parent or template bracket for #{unmatched.strip.inspect}" if unmatched
    when TIME_BRACKETS_COUNT
      # Defer append operations so every parent lookup sees only entries already on the day.
      additions = template_time_brackets.map do |bracket|
        merge_matching_top_level_entries!(date_brackets, bracket.lines)
      end
      date_brackets.zip(additions).each { |bracket, lines| bracket.concat(lines) }
    else
      raise "Unexpected number of time brackets found in the template: #{template_time_brackets.size}"
    end

    new_date_section = date_brackets
      .map(&:join)
      .join(TIME_BRACKETS_SEPARATOR)
      .concat(TIME_BRACKETS_SEPARATOR)
      .concat("\n")

    content.sub(date_section) { new_date_section }
  end

  private

  # Top-level matches ignore timestamps and comments, preserving the existing parent.
  # A childless match only deduplicates the parent.
  #
  def merge_matching_top_level_entries!(date_brackets, template_lines)
    remaining_lines = []
    template_i = 0

    while template_i < template_lines.size
      line = template_lines[template_i]

      if line.match?(/\A\S/)
        entry_end_i = template_i + 1
        entry_end_i += 1 while template_lines[entry_end_i]&.match?(/\A /)

        parent_keys = template_parent_keys(line)
        matching_bracket, matching_i = find_matching_parent(date_brackets, parent_keys)

        if matching_i
          insertion_i = matching_i + 1
          insertion_i += 1 while matching_bracket[insertion_i]&.match?(/\A /)
          children = template_lines[(template_i + 1)...entry_end_i]
          matching_bracket.insert(insertion_i, *children)
        elsif parent_keys.size > 1
          raise "No matching parent on the selected day for #{line.strip.inspect}"
        else
          remaining_lines.concat(template_lines[template_i...entry_end_i])
        end

        template_i = entry_end_i
      else
        remaining_lines << line
        template_i += 1
      end
    end

    remaining_lines
  end

  def find_matching_parent(date_brackets, parent_keys)
    date_brackets.each do |bracket|
      matching_i = bracket.index { |candidate| parent_keys.include?(template_parent_key(candidate)) }
      return [bracket, matching_i] if matching_i
    end

    nil
  end

  def template_parent_keys(line)
    key = template_parent_key(line)
    alternatives = key.match(/\A([^;\s] )(.+\|.+)\z/)
    return [key] unless alternatives

    prefix, titles = alternatives.captures
    titles.split('|').map { |title| prefix + title.strip }
  end

  def template_parent_key(line)
    line
      .sub(/\A(. )\d{1,2}:\d{2}(?:-\d{1,2}:\d{2})?\. /, '\1')
      .sub(/ #.*$/, '')
      .rstrip
  end
end
