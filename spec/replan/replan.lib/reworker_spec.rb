require 'rspec'

require_relative '../../../replan.lib/reworker.rb'

describe Reworker do
  # Includes all the work formats, although not the whole code paths.
  #
  it 'compute the work times and add the accounting entry to the following day' do
    content = <<~TEXT
          MON 07/JUN/2021
      - 9:00. work
      - 10:00. foo
      - 10:00. work (some_comment) -1.5h
      -----
      * 15:00. foo
        - 15:20. work
          ~ foo
        . 16:00. foo
      - 16:00. work -10
      - 17:00. foo
      - work 1h
      ~ work 20

          TUE 08/JUN/2021
      - foo
        - RSS, email
        - bar

    TEXT

    result = subject.execute(content)

    expected_result = <<~TEXT
          TUE 08/JUN/2021
      - foo
        - RSS, email
        - lpimw -t ye '9:00-10:00, 10:00-15:00 -1.5h, 15:20-16:00, 16:00-17:00 -10, 1h, 20' # -c half|off
        - bar

    TEXT

    expect(result).to include(expected_result)
  end

  context "errors" do
    # This also includes the case where a timestamped work entry is the last entry.
    #
    it "should raise an error if an equally indented, required, entry is missing" do
      content = <<~TEXT
            MON 07/JUN/2021
        - 15:00. foo
          - 15:20. work
        - 16:00. bar

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

    ERROR_LINES = [
      "XX work 30",
      "- work -9:20",
    ]

    ERROR_LINES.each do |error_line|
      it "should be raised if an invalid work line format is found (#{error_line.inspect})" do
        content = <<~TEXT
              MON 07/JUN/2021
          - 9:00. work
          #{error_line}
          - etc

        TEXT

        expect { subject.execute(content) }.to raise_error(RuntimeError, "Invalid work line format: #{error_line.inspect}")
      end
    end
  end # context "invalid work lines should raise an error"
end # describe Reworker
