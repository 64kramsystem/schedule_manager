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
    date_time_brackets = date_section
      .split(/^#{TIME_BRACKETS_SEPARATOR}/, -1)
      .slice(0..-2)

    missing_brackets = TIME_BRACKETS_COUNT - date_time_brackets.size
    date_time_brackets += [''] * missing_brackets

    template_time_brackets = @template
      .gsub(/\$\{([a-z_]\w*)\}/i) { |placeholder| ENV.fetch(Regexp.last_match(1), placeholder) }
      .split(/^#{TIME_BRACKETS_SEPARATOR}/, -1)
      .slice(0..-2)

    raise "Unexpected number of time brackets found in the template: #{template_time_brackets.size}" if template_time_brackets.size != TIME_BRACKETS_COUNT

    new_date_section = date_time_brackets
      .zip(template_time_brackets)
      .map { |date_bracket, template_bracket| merge_time_bracket(date_bracket, template_bracket) }
      .join(TIME_BRACKETS_SEPARATOR)
      .concat(TIME_BRACKETS_SEPARATOR)
      .concat("\n")

    content.sub(date_section) { new_date_section }
  end

  private

  def merge_time_bracket(next_date_bracket, template_bracket)
    next_date_lines = next_date_bracket.lines
    remaining_template_lines = merge_matching_top_level_entries!(next_date_lines, template_bracket.lines)

    next_date_lines.concat(remaining_template_lines).join
  end

  # Top-level matches ignore timestamps and comments, preserving the existing parent.
  # A childless match only deduplicates the parent.
  #
  def merge_matching_top_level_entries!(next_date_lines, template_lines)
    remaining_lines = []
    template_i = 0

    while template_i < template_lines.size
      line = template_lines[template_i]

      if line.match?(/\A\S/)
        entry_end_i = template_i + 1
        entry_end_i += 1 while template_lines[entry_end_i]&.match?(/\A /)

        parent_key = template_parent_key(line)
        matching_i = next_date_lines.index { |candidate| template_parent_key(candidate) == parent_key }

        if matching_i
          insertion_i = matching_i + 1
          insertion_i += 1 while next_date_lines[insertion_i]&.match?(/\A /)
          children = template_lines[(template_i + 1)...entry_end_i]
          next_date_lines.insert(insertion_i, *children)
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

  def template_parent_key(line)
    line
      .sub(/\A(. )\d{1,2}:\d{2}(?:-\d{1,2}:\d{2})?\. /, '\1')
      .sub(/ #.*$/, '')
      .rstrip
  end
end
