require_relative "replan_helper"

# Add missing headers for the next number of days.
#
class Readder
  include ReplanHelper

  DEFAULT_DAYS_TO_ADD = 183 # 6 months

  def execute(content, days: DEFAULT_DAYS_TO_ADD)
    dates_added = 0
    first_date = find_first_date(content)
    end_date = first_date + days

    (first_date..end_date).each do |current_date|
      insertion_date = find_preceding_or_existing_date(content, current_date)

      if insertion_date != current_date
        content = add_new_date_section(content, insertion_date, current_date)
        dates_added += 1
      end
    end

    content
  end
end
