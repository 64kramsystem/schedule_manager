require 'date'

class ArchiveReader
  def initialize(archive_filename, current_year: Date.today.year)
    @archive_filename = archive_filename
    @current_year = current_year
  end

  # The unsuffixed archive contains the current year's entries. Completed years are moved to files
  # named after the year, e.g. `todamns-2025.txt`.
  #
  # Regular listings only need the current archive. Exports can start in an earlier year, so load
  # every completed year from the requested year onward and fail rather than silently returning an
  # incomplete interval.
  def read(export_start: nil)
    filenames = export_start ? export_filenames(export_start) : existing_current_archive

    filenames.map { |filename| IO.read(filename) }
  end

  private

  def existing_current_archive
    File.exist?(@archive_filename) ? [@archive_filename] : []
  end

  def export_filenames(export_start)
    return [] if export_start.year > @current_year

    previous_year_filenames = (export_start.year...@current_year).map do |year|
      filename = filename_for_year(year)

      raise "Archive file not found: #{filename}" if !File.exist?(filename)

      filename
    end

    raise "Archive file not found: #{@archive_filename}" if !File.exist?(@archive_filename)

    previous_year_filenames + [@archive_filename]
  end

  def filename_for_year(year)
    extension = File.extname(@archive_filename)
    basename = @archive_filename.delete_suffix(extension)

    "#{basename}-#{year}#{extension}"
  end
end
