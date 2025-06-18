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
end # describe Remover
