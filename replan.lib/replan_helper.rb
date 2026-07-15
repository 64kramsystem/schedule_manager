require 'date'

require_relative "shared_constants"

module ReplanHelper
  include SharedConstants

  DATE_HEADER_TEMPLATE = '    %a %d/%b/%Y'
  private_constant :DATE_HEADER_TEMPLATE

  # The schedule can end either with this, or just with EOF.
  #
  END_OF_SCHEDULE_SEPARATOR = "-------------------------------------------------------------------------------"

  # Matches day_word, day_number, month, [year]
  #
  # Minor simplification handling the slash preceding the year.
  #
  DATE_HEADER_REGEX = %r(^(    (\S{3}) (\d{2})/(\w{3})/?(\d{4})?))
  private_constant :DATE_HEADER_REGEX

  ##################################################################################################
  # FINDING
  ##################################################################################################

  def find_header_matches(content)
    matches = content.scan(DATE_HEADER_REGEX)

    matches.empty? ? raise("No dates found!") : matches
  end

  # Convenience method. Raises an error if the date is greater than the current date!
  #
  def find_first_date(content)
    first_header = find_header_matches(content).first
    first_date = convert_header_to_date(first_header)

    raise "First date is in the future!" if first_date > Date.today

    first_date
  end

  def find_last_date(content)
    last_header = find_header_matches(content).last
    convert_header_to_date(last_header)
  end

  def find_all_dates(content)
    headers = find_header_matches(content)
    headers.map(&method(:convert_header_to_date))
  end

  # After getting the value, check if it matches the date, to know if it's an existing entry!
  #
  #===
  #
  # This method could use `header_matches`, however, since `content` is modified, `header_matches` should
  # be kept in sync, which is easy to forget. Performance is not a concern, so this takes the safe route.
  #
  def find_preceding_or_existing_date(content, date)
    header_matches = find_header_matches(content)
    header_dates = header_matches.map(&method(:convert_header_to_date))

    raise "Target date (#{date}) is earlier than then the first available (#{header_dates.first})!" if date < header_dates.first

    header_dates.each_cons(2) do |previous_date, next_date|
      if previous_date >= next_date
        raise "Inconsistent consecutive dates found!: #{previous_date}, #{next_date}"
      end

      return previous_date if previous_date <= date && date < next_date
    end

    header_dates.last
  end

  # Performs some checks on the section, including the number of separators.
  #
  # The section needs a terminating empty line, which is returned.
  #
  def find_date_section(content, date, allow_not_found: false)
    today_header = convert_date_to_header(date)
    today_section_regex = /^#{Regexp.escape(today_header)}.*?^\n/m

    section = content[today_section_regex]

    if section
      verify_date_section_header_after(content, date)

      if section.include?(TIME_BRACKETS_SEPARATOR)
        if !section.end_with?(TIME_BRACKETS_SEPARATOR + "\n")
          raise "Date `#{date}` section doesn't end with a separator!"
        elsif (separators_count = section.scan(/^#{TIME_BRACKETS_SEPARATOR}/).size) > TIME_BRACKETS_COUNT
          raise "Date `#{date}` section has too many separators (#{separators_count})!"
        end
      end

      section
    elsif allow_not_found
      nil
    else
      raise("Section not found for date: #{date}")
    end
  end

  # WATCH OUT! The case where the next date is the end of the document, is acceptable.
  #
  def verify_date_section_header_after(content, date)
    today_header = convert_date_to_header(date)

    # A bit tricky. Needs to consider that /m makes `.+` match text across multiple lines.
    #
    # - /.*?^\n/   -> match all the lines, until the first blank one
    # - /.+?\n/ -> non greedy, since we want only the first line
    #
    result_regex = /^#{Regexp.escape(today_header)}.*?^\n(.+?\n|\Z)/m

    # Remove the trailing newline (ignoring it via regex makes it too ugly).
    #
    next_header = content[result_regex, 1]&.rstrip

    if next_header == ""
      # end of the document; this is ok
    elsif next_header.nil?
      raise("Header not found after date: #{date}")
    elsif next_header !~ DATE_HEADER_REGEX && next_header != END_OF_SCHEDULE_SEPARATOR
      raise "The header after date #{date} is not a correct date header: #{next_header.inspect}"
    end
  end

  ##################################################################################################
  # MODIFICATION
  ##################################################################################################

  # find_date_section requires every section (including the last) to be terminated by a blank line;
  # editors can trim the file's trailing blank line on save, so restore it.
  #
  def ensure_trailing_blank_line(content)
    content.end_with?("\n\n") ? content : content + "\n"
  end

  def add_new_date_section(content, preceding_date, new_date)
    preceding_date_header = convert_date_to_header(preceding_date)
    preceding_date_section_regex = /^(#{Regexp.escape(preceding_date_header)}.*?^\n)/m

    new_date_header = convert_date_to_header(new_date)

    raise "Preceding date (#{preceding_date}) not found!" if content !~ preceding_date_section_regex

    new_date_section = <<~TXT
      #{new_date_header}
      #{TIME_BRACKETS_SEPARATOR * TIME_BRACKETS_COUNT}
    TXT

    content.sub(preceding_date_section_regex, "\\1#{new_date_section}")
  end

  # Line is added at the beginning of the given bracket of the given date section.
  # If there aren't enough brackets, the missing ones are added.
  #
  # new_line: doesn't matter if it ends with a newline or note.
  #
  # A nice generic implementation of this could receive {bracket_i => new_line}.
  #
  def add_line_to_date_section(content, date, new_line, bracket_i)
    old_date_section = find_date_section(content, date)

    # find_date_section() correctly returns two new lines at the end, but in processing terms, it's
    # relatively ugly and fragile, so better to guard.
    #
    raise "Unexpected end of date section #{old_date_section.inspect}" if !old_date_section.end_with?("\n\n")

    old_date_section = old_date_section.chomp("\n")

    date_section_lines = old_date_section.lines

    date_header = date_section_lines.shift

    # We need to workaround a very odd API behavior here. According to the String#split documentation,
    # the method returns an empty array if the string is empty, but this is not exact.
    # An empty array is also returned if the string is composed only of separators; such choice is very
    # strange, since the split makes semantical sense (the result should be an array of empty strings,
    # in quantity of (separators + 1)).
    #
    brackets = date_section_lines
      .join
      .split(/(#{Regexp.escape(TIME_BRACKETS_SEPARATOR)})/)
      .delete_if { |token| token == TIME_BRACKETS_SEPARATOR }

    brackets.fill(brackets.size, TIME_BRACKETS_COUNT - brackets.size + 1) { "" }

    brackets[bracket_i] = brackets[bracket_i].prepend("#{new_line.rstrip}\n")

    new_date_section = date_header + brackets.join(TIME_BRACKETS_SEPARATOR)

    content.sub(old_date_section, new_date_section)
  end

  ##################################################################################################
  # DATA CONVERSION
  ##################################################################################################

  def convert_header_to_date(header_match)
    _, _, day_number, month_word, year = header_match

    day_number = day_number.to_i
    year = year.to_i

    # Timecop is buggy and poorly maintained. Date.parse has been broken in at least v0.8 and v0.9
    # (see https://github.com/travisjeffery/timecop/issues/222).
    # This is the workaround.
    #
    month_number = Date.strptime(month_word, '%b').month

    Date.new(year, month_number, day_number)
  end

  def convert_date_to_header(date)
    date.strftime(DATE_HEADER_TEMPLATE).upcase
  end
end
