require_relative 'replan_helper'

# Remove temporary separators, blank lines within days, and template-only flags.
#
class Cleaner
  include ReplanHelper

  TEMPORARY_SEPARATOR_PATTERN = /^[~=]\n/

  def execute(content)
    content = content.gsub(TEMPORARY_SEPARATOR_PATTERN, '')
    remove_template_top_flags(remove_blank_lines_within_days(content))
  end

  private

  def remove_blank_lines_within_days(content)
    result = +''
    blank_lines = +''
    within_day = false

    content.each_line do |line|
      if line == "\n"
        blank_lines << line
        next
      end

      date_header = line.match?(DATE_HEADER_REGEX)
      schedule_end = line.chomp == END_OF_SCHEDULE_SEPARATOR
      result << blank_lines if !within_day || date_header || schedule_end
      blank_lines.clear
      result << line

      within_day = true if date_header
      within_day = false if schedule_end
    end

    result << blank_lines
  end
end
