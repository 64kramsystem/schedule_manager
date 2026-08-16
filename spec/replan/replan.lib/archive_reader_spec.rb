require 'fileutils'
require 'rspec'
require 'tmpdir'

require_relative '../../../replan.lib/archive_reader.rb'

describe ArchiveReader do
  around :each do |example|
    @temporary_directory = Dir.mktmpdir
    example.run
  ensure
    FileUtils.remove_entry(@temporary_directory)
  end

  let(:archive_filename) { File.join(@temporary_directory, 'todamns.txt') }
  let(:subject) { described_class.new(archive_filename, current_year: 2026) }

  def write_archive(filename, content)
    IO.write(File.join(@temporary_directory, filename), content)
  end

  it "reads only the current archive for a regular listing" do
    write_archive('todamns-2025.txt', '2025 archive')
    write_archive('todamns.txt', 'current archive')

    expect(subject.read).to eq(['current archive'])
  end

  it "allows a regular listing when there is no archive yet" do
    expect(subject.read).to eq([])
  end

  it "reads each yearly archive needed by an export, followed by the current archive" do
    write_archive('todamns-2024.txt', '2024 archive')
    write_archive('todamns-2025.txt', '2025 archive')
    write_archive('todamns.txt', 'current archive')

    contents = subject.read(export_start: Date.new(2024, 8, 16))

    expect(contents).to eq(['2024 archive', '2025 archive', 'current archive'])
  end

  it "does not read archives older than the export start" do
    write_archive('todamns-2024.txt', '2024 archive')
    write_archive('todamns-2025.txt', '2025 archive')
    write_archive('todamns.txt', 'current archive')

    contents = subject.read(export_start: Date.new(2025, 8, 16))

    expect(contents).to eq(['2025 archive', 'current archive'])
  end

  it "reads the current archive when the export starts in the current year" do
    write_archive('todamns.txt', 'current archive')

    contents = subject.read(export_start: Date.new(2026, 8, 16))

    expect(contents).to eq(['current archive'])
  end

  it "does not require an archive when the export starts in a future year" do
    expect(subject.read(export_start: Date.new(2027, 1, 1))).to eq([])
  end

  it "raises when the archive for the requested year is missing" do
    write_archive('todamns-2025.txt', '2025 archive')
    write_archive('todamns.txt', 'current archive')

    expect {
      subject.read(export_start: Date.new(2024, 8, 16))
    }.to raise_error(
      "Archive file not found: #{@temporary_directory}/todamns-2024.txt"
    )
  end

  it "raises when an intermediate yearly archive is missing" do
    write_archive('todamns-2024.txt', '2024 archive')
    write_archive('todamns.txt', 'current archive')

    expect {
      subject.read(export_start: Date.new(2024, 8, 16))
    }.to raise_error(
      "Archive file not found: #{@temporary_directory}/todamns-2025.txt"
    )
  end

  it "raises when the current archive is missing" do
    write_archive('todamns-2024.txt', '2024 archive')
    write_archive('todamns-2025.txt', '2025 archive')

    expect {
      subject.read(export_start: Date.new(2024, 8, 16))
    }.to raise_error(
      "Archive file not found: #{@temporary_directory}/todamns.txt"
    )
  end
end
