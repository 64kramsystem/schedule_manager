require 'rspec'
require 'timecop'

require_relative '../../../replan.lib/reworker.rb'

describe Reworker do
  # For ease of testing, enable the execute :extract_only option (except where required).
  #
  let(:subject) { described_class.new(extract_only: true) }

  context "Accounting entry" do
    it 'add the accounting entry via LPIM_REPLACE' do
      content = <<~TEXT
            MON 07/JUN/2021
        - work 1h

            WED 09/JUN/2021
        - shell-dos
          #LPIM_REPLACE

      TEXT

      result = Timecop.freeze(Date.new(2021, 6, 8)) do
        described_class.new.execute(content)
      end

      expected_result = <<~TEXT
            WED 09/JUN/2021
        - shell-dos
          lpimw -t 2021-06-07 '1h' # -c half|off # Mon

      TEXT

      expect(result).to include(expected_result)
    end

    it 'add the accounting entry via LPIM_INSERT (retaining the placeholder)' do
      content = <<~TEXT
            MON 07/JUN/2021
        - work 1h

            WED 09/JUN/2021
        - shell-dos
          #LPIM_INSERT

      TEXT

      result = Timecop.freeze(Date.new(2021, 6, 8)) do
        described_class.new.execute(content)
      end

      expected_result = <<~TEXT
            WED 09/JUN/2021
        - shell-dos
          lpimw -t 2021-06-07 '1h' # -c half|off # Mon
          #LPIM_INSERT

      TEXT

      expect(result).to include(expected_result)
    end

    it 'add the accounting entry via LPIM_INSERT, when also LPIM_REPLACE is present' do
      content = <<~TEXT
            MON 07/JUN/2021
        - work 1h

            WED 09/JUN/2021
        - shell-dos
          #LPIM_INSERT
          #LPIM_REPLACE

      TEXT

      result = Timecop.freeze(Date.new(2021, 6, 8)) do
        described_class.new.execute(content)
      end

      expected_result = <<~TEXT
            WED 09/JUN/2021
        - shell-dos
          lpimw -t 2021-06-07 '1h' # -c half|off # Mon
          #LPIM_INSERT
          # (lpim added to insert placeholder)

      TEXT

      expect(result).to include(expected_result)
    end
  end # context "Accounting entry"

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

    context "Accounting entry" do
      it 'raise an error if no LPIM_REPLACE and LPIM_INSERT are present' do
        content = <<~TEXT
              MON 07/JUN/2021
          - work 1h

              TUE 08/JUN/2021
          - foo

        TEXT

        Timecop.freeze(Date.new(2021, 6, 8)) do
          expect { described_class.new.execute(content) }.to raise_error('No replacement or insertion point found!')
        end
      end
    end # context "Accounting entry"
  end # context "errors"
end # describe Reworker
