require 'rspec'
require 'timecop'

require_relative '../../../replan.lib/reworker.rb'

describe Reworker do
  # For ease of testing, enable the execute :extract_only option (except where required).
  #
  let(:subject) { described_class.new(extract_only: true) }

  # Includes all the work formats, although not the whole code paths.
  #
  it 'compute the work times and add the accounting entry to the following day' do
    content = <<~TEXT
          MON 07/JUN/2021
      - 9:00. work
      - 10:00. foo
      - 10:00. work (some comment) -1.5h
      -----
      * 15:00. foo
        - 15:20. work
          ~ foo
        . 16:00. foo
      - 16:00. work -10
      - 17:00. foo
        - 17:20. work
      - 17:30. foo
      - work 1h
      ~ work 20
      -----
      -----
      -----

          TUE 08/JUN/2021
      - foo
        - shell-dos
          #LPIM_REPLACE
          bar

    TEXT

    result = Timecop.freeze(Date.new(2021, 6, 8)) do
      described_class.new.execute(content)
    end

    expected_result = <<~TEXT
          TUE 08/JUN/2021
      - foo
        - shell-dos
          lpimw -t 2021-06-07 '9:00-10:00, 10:00-15:00 -1.5h, 15:20-16:00, 16:00-17:00 -10, 17:20-17:30, 1h, 20' # -c half|off # Mon
          bar

    TEXT

    expect(result).to include(expected_result)
  end

  it 'compute the work hours' do
    content = <<~TEXT
          MON 07/JUN/2021
      - 9:00. work
      - 11:00. blah
      - 11:00. work -1.5h
      - 15:30. blah
      - 15:30. work -10
      - 16:30-17:00. blah
      - work 40
      - work 2.5h

    TEXT

    result = subject.compute_first_date_work_hours(content)
    expected_result = 9.0

    expect(result).to eql(expected_result)
  end

  context "errors" do
    it "should raise an error if a closing entry is missing" do
      content = <<~TEXT
            MON 07/JUN/2021
        - 15:20. work

      TEXT

      expect { subject.execute(content) }.to raise_error('Missing closing entry for work entry "- 15:20. work"')
    end

    it "should raise an error if two work entries are following" do
      content = <<~TEXT
            MON 07/JUN/2021
        - 15:20. work
        - 16:00. work

      TEXT

      expect { subject.execute(content) }.to raise_error('Work entries can\'t follow each other! (previous: "- 15:20. work")')
    end

    it "should raise an error if the subsequent (relevant) entry has no time" do
      content = <<~TEXT
            MON 07/JUN/2021
        - 15:20. work
        - pizza

      TEXT

      expect { subject.execute(content) }.to raise_error('Subsequent entry has no time! (previous: "- 15:20. work")')
    end

    it "should raise an error if the insertion point is not found in the next day section" do
      content = <<~TEXT
            MON 07/JUN/2021
        - 9:00. work
        - 10:00. foo

            TUE 08/JUN/2021
        - foo
          - shell-dos
            bar

      TEXT

      Timecop.freeze(Date.new(2021, 6, 8)) do
        expect { described_class.new.execute(content) }.to raise_error('Insertion point not found!')
      end
    end
  end # context "errors"
end # describe Reworker
