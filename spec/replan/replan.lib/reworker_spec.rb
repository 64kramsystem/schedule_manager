require 'rspec'
require 'timecop'

require_relative '../../../replan.lib/cleaner.rb'
require_relative '../../../replan.lib/reworker.rb'

describe Reworker do
  # For ease of testing, enable the execute :extract_only option (except where required).
  #
  let(:subject) { described_class.new(extract_only: true) }

  context "Accounting entry" do
    it 'uses the next-day replacement marker when the current day and notes contain insert markers' do
      content = <<~TEXT
            MON 07/JUN/2021
        - work 1h
        #LPIM_INSERT

            TUE 08/JUN/2021
        #LPIM_REPLACE

        #{ReplanHelper::END_OF_SCHEDULE_SEPARATOR}
        #LPIM_INSERT
      TEXT

      result = Timecop.freeze(Date.new(2021, 6, 8)) do
        described_class.new.execute(content)
      end

      expected_result = content.sub('#LPIM_REPLACE', "; lpimw -t 2021-06-07 '1h' # -c half|off # Mon")
      expect(result).to eq(expected_result)
    end

    it 'add the accounting entry via LPIM_INSERT (retaining the placeholder)' do
      content = <<~TEXT
            MON 07/JUN/2021
        - work 1h

            WED 09/JUN/2021
        #LPIM_INSERT

      TEXT

      result = Timecop.freeze(Date.new(2021, 6, 8)) do
        described_class.new.execute(content)
      end

      expected_result = <<~TEXT
            WED 09/JUN/2021
        ; lpimw -t 2021-06-07 '1h' # -c half|off # Mon
        #LPIM_INSERT

      TEXT

      expect(result).to include(expected_result)
    end

    it 'prefers a later insertion marker to the next-day replacement marker' do
      content = <<~TEXT
            MON 07/JUN/2021
        - work 1h
        #LPIM_REPLACE

            TUE 08/JUN/2021
        #LPIM_REPLACE

            WED 09/JUN/2021
        #LPIM_INSERT

      TEXT

      result = Timecop.freeze(Date.new(2021, 6, 8)) do
        described_class.new.execute(content)
      end

      expected_result = <<~TEXT
            MON 07/JUN/2021
        - work 1h
        #LPIM_REPLACE

            TUE 08/JUN/2021
        # (lpim added to insert placeholder)

            WED 09/JUN/2021
        ; lpimw -t 2021-06-07 '1h' # -c half|off # Mon
        #LPIM_INSERT

      TEXT

      expect(result).to eq(expected_result)
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

  it 'supports an exclamation mark as the work type prefix' do
    content = <<~TEXT
          MON 07/JUN/2021
      ! work 1h

    TEXT

    result = subject.compute_first_date_work_hours(content)

    expect(result).to eql(1.0)
  end

  it 'ignore work comments when computing the work hours' do
    content = <<~TEXT
          MON 07/JUN/2021
      - 9:00. work # brogramming
      - 11:00. blah

    TEXT

    result = subject.compute_first_date_work_hours(content)
    expected_result = 2.0

    expect(result).to eql(expected_result)
  end

  it 'computes work end times after temporary separators are cleaned' do
    content = <<~TEXT
          MON 07/JUN/2021
      - 9:00. work
      ~
      - 11:00. foo

    TEXT

    result = subject.compute_first_date_work_hours(Cleaner.new.execute(content))

    expect(result).to eql(2.0)
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
