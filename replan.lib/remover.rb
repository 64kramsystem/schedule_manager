require 'fileutils'
require 'tmpdir'

require_relative 'replan_helper'
require_relative 'shared_constants'

class Remover
  include ReplanHelper
  include SharedConstants

  def execute(schedule_filename, archive_filename, content)
    current_date_section = remove_section_from_schedule(schedule_filename, content)
    add_section_to_archive(archive_filename, current_date_section)
  end

  def remove_section_from_schedule(schedule_filename, content)
    schedule_copy = Dir::Tmpname.create(['schedule', '.txt']) { }
    FileUtils.cp(schedule_filename, schedule_copy)

    current_date = find_first_date(content)
    current_date_section = find_date_section(content, current_date)

    if (lines_with_replan = current_date_section.lines.grep(/\breplan\b/)).any?
      raise "Found unsubstituted `replan`s into current date (#{current_date}) section!; first occurrence: #{lines_with_replan.first.chomp.inspect}"
    end
    raise "Found todo section into current date (#{current_date}) section!" if current_date_section =~ TODO_SECTION_SEPARATOR_REGEX

    content = content.sub(current_date_section, "")
    IO.write(schedule_filename, content)

    current_date_section
  end

  def add_section_to_archive(archive_filename, current_date_section)
    new_content = current_date_section

    if File.exist?(archive_filename)
      new_content += IO.read(archive_filename)
    end

    IO.write(archive_filename, new_content)
  end
end
