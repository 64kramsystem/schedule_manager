require_relative 'replan_helper'

# Remove temporary separators and template-only flags from schedule content.
#
class Cleaner
  include ReplanHelper

  TEMPORARY_SEPARATOR_PATTERN = /^[~=]\n/

  def execute(content)
    remove_template_top_flags(content.gsub(TEMPORARY_SEPARATOR_PATTERN, ''))
  end
end
