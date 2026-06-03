require 'rspec'
require 'tempfile'

require_relative '../../../replan.lib/remover.rb'

describe Remover do
  it "should raise an error if the current date section includes a todo marker" do
    content = <<~TXT
        MON 20/SEP/2021
    - foo
    ~~~~~
    - baz

    TXT

    phony_schedule_file = Tempfile.create('schedule')
    phony_archive_file = Tempfile.create('archive')

    expect { subject.execute(phony_schedule_file, phony_archive_file, content) }.to raise_error("Found todo section into current date (2021-09-20) section!")
  end

  # This is actually a bug in the program.
  #
  it "should raise an error if the current date section includes a replan" do
    # The equal replan lines need to have different indentation in order to trigger the bug.
    #
    content = <<~TXT
        MON 20/SEP/2021
    - foo (replan 1)
      - foo (replan 1)

    TXT

    phony_schedule_file = Tempfile.create('schedule')
    phony_archive_file = Tempfile.create('archive')

    expect { subject.execute(phony_schedule_file, phony_archive_file, content) }.to raise_error('Found unsubstituted `replan`s into current date (2021-09-20) section!; first occurrence: "- foo (replan 1)"')
  end

  it "should remove the current date section from the schedule and prepend it to an existing archive" do
    content = <<~TXT
        MON 20/SEP/2021
    - foo

        TUE 21/SEP/2021
    - bar

    TXT

    schedule_file = Tempfile.create('schedule')
    schedule_file.write(content)
    schedule_file.close

    archive_file = Tempfile.create('archive')
    archive_file.write(<<~TXT)
        SUN 19/SEP/2021
    - previous

    TXT
    archive_file.close

    subject.execute(schedule_file.path, archive_file.path, content)

    expect(IO.read(schedule_file.path)).to eq(<<~TXT)
        TUE 21/SEP/2021
    - bar

    TXT

    expect(IO.read(archive_file.path)).to eq(<<~TXT)
        MON 20/SEP/2021
    - foo

        SUN 19/SEP/2021
    - previous

    TXT
  end

  it "should create the archive file when it doesn't exist" do
    content = <<~TXT
        MON 20/SEP/2021
    - foo

        TUE 21/SEP/2021
    - bar

    TXT

    schedule_file = Tempfile.create('schedule')
    schedule_file.write(content)
    schedule_file.close

    archive_filename = File.join(Dir.mktmpdir, 'archive')

    subject.execute(schedule_file.path, archive_filename, content)

    expect(IO.read(archive_filename)).to eq(<<~TXT)
        MON 20/SEP/2021
    - foo

    TXT
  end
end # describe Remover
