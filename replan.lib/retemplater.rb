require_relative "replan_helper"
require_relative "shared_constants"

# Fill the next date (first date + 1) with the template.
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
  def execute(content)
    next_date = find_first_date(content) + 1

    # This avoids disasters when the user accidentally leaves a space, which confuses the program in
    # multiple ways.
    #
    verify_date_section_header_after(content, next_date)

    next_date_section = find_date_section(content, next_date)

    # A terminating blank line is considered part of a date section. For simplicity, we strip it.
    #
    next_date_time_brackets = next_date_section
      .split(/^#{TIME_BRACKETS_SEPARATOR}/, -1)
      .slice(0..-2)

    missing_brackets = TIME_BRACKETS_COUNT - next_date_time_brackets.size
    next_date_time_brackets += [''] * missing_brackets

    template_time_brackets = @template
      .split(/^#{TIME_BRACKETS_SEPARATOR}/, -1)
      .slice(0..-2)

    raise "Unexpected number of time brackets found in the template: #{template_time_brackets.size}" if template_time_brackets.size != TIME_BRACKETS_COUNT

    new_date_section = next_date_time_brackets
      .zip(template_time_brackets)
      .map.with_index do |(next_date_bracket, template_bracket), bracket_i|
        merge_time_bracket(next_date_bracket, template_bracket, top_bracket: bracket_i.zero?)
      end
      .join(TIME_BRACKETS_SEPARATOR)
      .concat(TIME_BRACKETS_SEPARATOR)
      .concat("\n")

    content.sub(next_date_section, new_date_section)
  end

  private

  def merge_time_bracket(next_date_bracket, template_bracket, top_bracket:)
    top_template_lines, bottom_template_lines = split_template_lines(template_bracket)
    next_date_lines = next_date_bracket.lines

    insertion_i = top_bracket ? top_insertion_index(next_date_lines, start_i: 1) : 0
    next_date_lines.insert(insertion_i, *top_template_lines)

    next_date_lines.join + bottom_template_lines.join
  end

  # A caret after an event symbol is template-only syntax and may appear at any indentation.
  # Indented descendants belong to the caret-suffixed event and must move to the top along with it;
  # redundant carets on those descendants are stripped as well.
  #
  def split_template_lines(template_bracket)
    top_lines = []
    bottom_lines = []
    top_entry_indentation = nil

    template_bracket.lines.each do |line|
      indentation = line[/\A */].size

      if top_entry_indentation && indentation > top_entry_indentation
        top_lines << remove_top_flag(line)
      elsif line.match?(/^ *\S\^(?=\s)/)
        top_entry_indentation = indentation
        top_lines << remove_top_flag(line)
      else
        top_entry_indentation = nil
        bottom_lines << line
      end
    end

    [top_lines, bottom_lines]
  end

  def remove_top_flag(line)
    line.sub(/^( *\S)\^(?=\s)/, '\1')
  end
end
